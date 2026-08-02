import { UploadPersistence, Batch } from '../persistence/FilePersistenceStrategy';
import { BatchUploader, UploadStatus } from './DataUploader';
import { FlashcatLog } from '../FlashcatLog';

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
  private currentDelayMs: number;
  private timerId: number = -1;
  private running: boolean = false;
  private draining: boolean = false;      // a drainOnce (incl. its await) is in flight
  private retrigger: boolean = false;     // triggerNow arrived while draining

  constructor(persistence: UploadPersistence, uploader: BatchUploader, baseDelayMs: number) {
    this.persistence = persistence;
    this.uploader = uploader;
    this.baseDelayMs = baseDelayMs;
    this.currentDelayMs = baseDelayMs;
  }

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
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
    this.scheduleNext(0);
  }

  stop(): void {
    this.running = false;
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
        this.currentDelayMs = this.baseDelayMs;
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
        this.scheduleNext(0); // try the next batch immediately (no-op when stopped)
      } else {
        this.persistence.restoreBatch(batch);
        // RETRY: keep the batch, back off (capped at 60s).
        this.currentDelayMs = Math.min(this.currentDelayMs * 2, 60000);
        this.scheduleNext(this.currentDelayMs);
      }
    } finally {
      this.draining = false;
      if (this.retrigger) {
        this.retrigger = false;
        this.triggerNow(); // coalesced force-flush that arrived mid-drain
      }
    }
  }

  /** Bounded drain used by WorkScheduler extension callbacks. */
  async flushForWork(maxBatches: number = 20): Promise<void> {
    if (maxBatches <= 0) {
      return;
    }
    for (let i: number = 0; i < maxBatches; i += 1) {
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
