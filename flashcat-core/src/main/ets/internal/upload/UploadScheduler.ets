import { UploadPersistence, Batch } from '../persistence/FilePersistenceStrategy';
import { BatchUploader, UploadStatus } from './DataUploader';
import { FlashcatLog } from '../FlashcatLog';
import { BatchProcessingLevel } from '../../config/Batching';

// Fallback for direct construction (tests / internal callers); the configured
// value comes from BatchProcessingLevel. Draining without a bound empties a
// backlog in one uninterrupted burst, which is what starves an app's own
// latency-sensitive requests on a narrow uplink.
const DEFAULT_MAX_BATCHES_PER_CYCLE: number = BatchProcessingLevel.MEDIUM;

/**
 * Drains persisted batches to the uploader on a cadence, with exponential backoff
 * on RETRY. While the app is foregrounded this runs an in-process timer; for
 * deferred/retry-on-network delivery, back it with @ohos.resourceschedule.workScheduler.
 *
 * Mirrors Android's DataUploadScheduler + UploadRunnable (WorkManager-backed there).
 */
export class UploadScheduler {
  private readonly persistence: UploadPersistence;
  private readonly uploader: BatchUploader;
  private readonly baseDelayMs: number;
  /** Batches shipped back-to-back before the cycle yields; see Configuration.batchProcessingLevel. */
  private readonly maxBatchesPerCycle: number;
  private currentDelayMs: number;
  /** Batches already shipped in the current cycle. Reset when a cycle ends. */
  private cycleCount: number = 0;
  /**
   * Pacing is two separate concerns, and they are lifted separately:
   *
   * - `retryNotBeforeMs` — the intake is failing and we are backing off. Every
   *   path honors this, including a backgrounding flush: hammering a broken
   *   intake helps nobody, and the batch is already durable on disk.
   * - `cycleNotBeforeMs` — the uplink was yielded to the app after a cycle spent
   *   its budget. A backgrounding flush ignores this one: the app is going away,
   *   so there is no foreground request left to protect.
   *
   * Both are enforced in scheduleAt rather than at each call site — a floor only
   * some paths remember is not a floor, which is how force-flushes used to punch
   * straight through both the budget and the backoff.
   */
  private retryNotBeforeMs: number = 0;
  private cycleNotBeforeMs: number = 0;
  private timerId: number = -1;
  private running: boolean = false;
  private draining: boolean = false;      // a drainOnce (incl. its await) is in flight
  private retrigger: boolean = false;     // triggerNow arrived while draining
  // A backgrounding flush that arrived mid-drain: the coalesced retrigger must
  // keep its cycle-budget exemption, or the last batch waits for a timer that
  // a frozen process will never fire.
  private retriggerIgnoresCycle: boolean = false;
  // Set by stop(), cleared by start(). flushForWork gates on THIS rather than
  // `running` because extension/tests legitimately flush without start().
  private stopRequested: boolean = false;

  constructor(persistence: UploadPersistence, uploader: BatchUploader, baseDelayMs: number,
              maxBatchesPerCycle: number = DEFAULT_MAX_BATCHES_PER_CYCLE) {
    this.persistence = persistence;
    this.uploader = uploader;
    this.baseDelayMs = baseDelayMs;
    this.maxBatchesPerCycle = Math.max(1, maxBatchesPerCycle);
    this.currentDelayMs = baseDelayMs;
  }

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.stopRequested = false;
    // A previous stop (consent PENDING) must not carry its backed-off delay
    // into the new run — restart the exponential ladder from base.
    this.currentDelayMs = this.baseDelayMs;
    this.cycleCount = 0;
    this.retryNotBeforeMs = 0;
    this.cycleNotBeforeMs = 0;
    this.scheduleNext(this.baseDelayMs);
  }

  /**
   * Drain as soon as pacing allows. Used after a force-flushed error/crash write
   * and when the app goes to the background.
   *
   * @param ignoreCycleBudget set only by the backgrounding flush. The app is
   *   going away, so the uplink no longer needs to be shared with it, and a
   *   frozen process will not run the timer the budget would otherwise impose.
   *   The retry backoff still applies either way.
   */
  triggerNow(ignoreCycleBudget: boolean = false): void {
    if (!this.running) {
      return;
    }
    // While a drain is in flight (possibly awaiting a 30 s upload), do NOT start
    // a second chain — each force-flushed error used to spawn one, so N errors
    // while offline meant N parallel never-ending chains sharing one backoff.
    if (this.draining) {
      this.retrigger = true;
      this.retriggerIgnoresCycle = this.retriggerIgnoresCycle || ignoreCycleBudget;
      return;
    }
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    this.scheduleAt(0, !ignoreCycleBudget);
  }

  stop(): void {
    this.running = false;
    this.stopRequested = true;
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private scheduleNext(delayMs: number): void {
    this.scheduleAt(delayMs, true);
  }

  /**
   * The single place pacing is enforced. Floors `delayMs` at whatever the intake
   * backoff — and, unless exempted, the cycle budget — still owes, so no caller
   * can schedule its way past either by asking for 0.
   */
  private scheduleAt(delayMs: number, respectCycleBudget: boolean): void {
    if (!this.running) {
      return;
    }
    let earliestMs: number = this.retryNotBeforeMs;
    if (respectCycleBudget && this.cycleNotBeforeMs > earliestMs) {
      earliestMs = this.cycleNotBeforeMs;
    }
    const owedMs: number = earliestMs - Date.now();
    const actualMs: number = owedMs > delayMs ? owedMs : delayMs;
    this.timerId = setTimeout(() => {
      this.timerId = -1; // this timer has fired — clearTimeout on it is a no-op
      this.drainOnce();
    }, actualMs);
  }

  private async drainOnce(): Promise<void> {
    if (!this.running || this.draining) {
      return;
    }
    this.draining = true;
    try {
      const batch: Batch | null = this.persistence.readNextBatch();
      if (batch === null) {
        // Idle tick — nothing to drain. Silent (was a debug log) to avoid per-tick spam.
        // An idle pass also ends the cycle: the next batch starts a fresh budget.
        this.currentDelayMs = this.baseDelayMs;
        this.cycleCount = 0;
        this.scheduleNext(this.baseDelayMs);
        return;
      }
      FlashcatLog.d(`drain: uploading batch ${batch.batchId} (${batch.eventCount} events)`);
      const status: UploadStatus = await this.uploader.upload(batch);
      // ALWAYS finalize the claimed batch, even if the scheduler was stopped
      // mid-upload — leaking it re-uploads a delivered batch on a later launch
      // (duplicates) or strands a failed one in claimed state.
      if (status === UploadStatus.SUCCESS || status === UploadStatus.DROP) {
        this.persistence.deleteBatch(batch.batchId);
        this.currentDelayMs = this.baseDelayMs;
        this.cycleCount += 1;
        if (this.cycleCount >= this.maxBatchesPerCycle) {
          // Cycle budget spent — yield the uplink for one interval instead of
          // draining the rest of a backlog back-to-back. cycleNotBeforeMs makes
          // that stick for force-flushes too, not just the timer path.
          this.cycleCount = 0;
          this.cycleNotBeforeMs = Date.now() + this.baseDelayMs;
          this.scheduleNext(this.baseDelayMs);
        } else {
          this.scheduleNext(0); // try the next batch immediately (no-op when stopped)
        }
      } else {
        this.persistence.restoreBatch(batch);
        // RETRY: keep the batch, back off (capped at 60s). A failed cycle starts
        // over — the backoff, not the budget, is what paces retries.
        this.cycleCount = 0;
        this.currentDelayMs = Math.min(this.currentDelayMs * 2, 60000);
        this.retryNotBeforeMs = Date.now() + this.currentDelayMs;
        this.scheduleNext(this.currentDelayMs);
      }
    } finally {
      this.draining = false;
      if (this.retrigger) {
        const ignoreCycleBudget: boolean = this.retriggerIgnoresCycle;
        this.retrigger = false;
        this.retriggerIgnoresCycle = false;
        // Coalesced force-flush that arrived mid-drain. Asking for 0 is safe: the
        // backoff and budget this drain just recorded are applied by scheduleAt.
        if (this.timerId !== -1) {
          clearTimeout(this.timerId);
          this.timerId = -1;
        }
        this.scheduleAt(0, !ignoreCycleBudget);
      }
    }
  }

  /**
   * Bounded drain used by WorkScheduler extension callbacks.
   *
   * @param maxBatches defaults to this scheduler's configured
   *   BatchProcessingLevel. It is deliberately the same bound the timer path
   *   uses: a constant here could not be lowered to damp a burst, nor raised to
   *   drain a backlog that would otherwise age out of retention.
   */
  async flushForWork(maxBatches?: number): Promise<void> {
    const limit: number = maxBatches ?? this.maxBatchesPerCycle;
    if (limit <= 0) {
      return;
    }
    for (let i: number = 0; i < limit; i += 1) {
      // Re-checked per iteration: a stop()/consent revocation that lands during
      // one batch's 30 s upload window must end the drain — not let the captured
      // loop keep claiming and shipping up to 19 more batches afterwards.
      if (this.stopRequested) {
        FlashcatLog.d('work.drain: scheduler stopped mid-flush, ending drain');
        return;
      }
      const drained: boolean = await this.flushOneForWork();
      if (!drained) {
        return;
      }
    }
  }

  /** One-shot drain retained for focused tests and small extension callbacks. */
  async flushOnceForWork(): Promise<void> {
    await this.flushForWork(1);
  }

  private async flushOneForWork(): Promise<boolean> {
    const batch: Batch | null = this.persistence.readNextBatch();
    if (batch === null) {
      return false;
    }
    FlashcatLog.d(`work.drain: uploading batch ${batch.batchId} (${batch.eventCount} events)`);
    const status: UploadStatus = await this.uploader.upload(batch);
    if (status === UploadStatus.SUCCESS || status === UploadStatus.DROP) {
      this.persistence.deleteBatch(batch.batchId);
      return true;
    } else {
      this.persistence.restoreBatch(batch);
      return false;
    }
  }
}
