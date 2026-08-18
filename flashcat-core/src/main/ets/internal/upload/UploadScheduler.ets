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
   * Wall-clock instant the current cycle yielded the uplink until, set when the
   * per-cycle budget is spent. Every scheduling path floors its delay at this —
   * a bound only honored by the timer path would be no bound at all, since a
   * force-flush stream re-enters the drain through triggerNow.
   */
  private cycleYieldUntilMs: number = 0;
  private timerId: number = -1;
  private running: boolean = false;
  private draining: boolean = false;      // a drainOnce (incl. its await) is in flight
  private retrigger: boolean = false;     // triggerNow arrived while draining
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
    this.cycleYieldUntilMs = 0;
    this.scheduleNext(this.baseDelayMs);
  }

  /** Drain as soon as possible (used after a forceFlush write / on background). */
  triggerNow(): void {
    if (!this.running) {
      return;
    }
    // While a drain is in flight (possibly awaiting a 30 s upload), do NOT start
    // a second chain — each force-flushed error used to spawn one, so N errors
    // while offline meant N parallel never-ending chains sharing one backoff.
    if (this.draining) {
      this.retrigger = true;
      return;
    }
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    // Ship at once — unless this cycle already spent its budget. Without the
    // floor, an app that force-flushes on every error (the usual pattern) would
    // drain a batch per error and never see the per-cycle bound at all.
    this.scheduleNext(this.yieldDelayMs());
  }

  /** Remaining wait owed to a spent cycle; 0 when the cycle has budget left. */
  private yieldDelayMs(): number {
    const remainingMs: number = this.cycleYieldUntilMs - Date.now();
    return remainingMs > 0 ? remainingMs : 0;
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
    if (!this.running) {
      return;
    }
    this.timerId = setTimeout(() => {
      this.timerId = -1; // this timer has fired — clearTimeout on it is a no-op
      this.drainOnce();
    }, delayMs);
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
          // draining the rest of a backlog back-to-back. cycleYieldUntilMs makes
          // that stick for force-flushes too, not just the timer path.
          this.cycleCount = 0;
          this.cycleYieldUntilMs = Date.now() + this.baseDelayMs;
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
        this.scheduleNext(this.currentDelayMs);
      }
    } finally {
      this.draining = false;
      if (this.retrigger) {
        this.retrigger = false;
        // Coalesced force-flush that arrived mid-drain. Honor whatever pacing this
        // drain just chose: draining at delay 0 after a RETRY would let every
        // force-flushed error reset the exponential backoff, hammering a failing
        // intake at the app's error rate — and after a spent cycle it would let a
        // steady error stream bypass the per-cycle bound entirely.
        if (this.timerId !== -1) {
          clearTimeout(this.timerId);
          this.timerId = -1;
        }
        const backoffMs: number = this.currentDelayMs > this.baseDelayMs ? this.currentDelayMs : 0;
        const yieldMs: number = this.yieldDelayMs();
        this.scheduleNext(backoffMs > yieldMs ? backoffMs : yieldMs);
      }
    }
  }

  /** Bounded drain used by WorkScheduler extension callbacks. */
  async flushForWork(maxBatches: number = 20): Promise<void> {
    if (maxBatches <= 0) {
      return;
    }
    for (let i: number = 0; i < maxBatches; i += 1) {
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
