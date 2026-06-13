import { FilePersistenceStrategy, Batch } from '../persistence/FilePersistenceStrategy';
import { DataUploader, UploadStatus } from './DataUploader';
import { FlashcatLog } from '../FlashcatLog';

/**
 * Drains persisted batches to the uploader on a cadence, with exponential backoff
 * on RETRY. While the app is foregrounded this runs an in-process timer; for
 * deferred/retry-on-network delivery, back it with @ohos.resourceschedule.workScheduler.
 *
 * Mirrors Android's DataUploadScheduler + UploadRunnable (WorkManager-backed there).
 */
export class UploadScheduler {
  private readonly persistence: FilePersistenceStrategy;
  private readonly uploader: DataUploader;
  private readonly baseDelayMs: number;
  private currentDelayMs: number;
  private timerId: number = -1;
  private running: boolean = false;

  constructor(persistence: FilePersistenceStrategy, uploader: DataUploader, baseDelayMs: number) {
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
      this.drainOnce();
    }, delayMs);
  }

  private async drainOnce(): Promise<void> {
    if (!this.running) {
      return;
    }
    const batch: Batch | null = this.persistence.readNextBatch();
    if (batch === null) {
      // Idle tick — nothing to drain. Silent (was a debug log) to avoid per-tick spam.
      this.currentDelayMs = this.baseDelayMs;
      this.scheduleNext(this.baseDelayMs);
      return;
    }
    FlashcatLog.d(`drain: uploading batch ${batch.batchId} (${batch.eventCount} events)`);
    const status: UploadStatus = await this.uploader.upload(batch);
    if (!this.running) {
      return; // stopped while the upload was in flight
    }
    if (status === UploadStatus.SUCCESS || status === UploadStatus.DROP) {
      this.persistence.deleteBatch(batch.batchId);
      this.currentDelayMs = this.baseDelayMs;
      this.scheduleNext(0); // try the next batch immediately
    } else {
      // RETRY: keep the batch, back off (capped at 60s).
      this.currentDelayMs = Math.min(this.currentDelayMs * 2, 60000);
      this.scheduleNext(this.currentDelayMs);
    }
  }
}
