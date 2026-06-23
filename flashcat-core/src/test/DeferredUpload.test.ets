import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import {
  DeferredUploadWorkRegistrar,
  DeferredUploadWorkOptions,
  DeferredUploadWorkSchedulerClient
} from '../main/ets/internal/upload/DeferredUploadWorkRegistrar';
import { Batch, FilePersistenceStrategy, UploadPersistence } from '../main/ets/internal/persistence/FilePersistenceStrategy';
import { UploadScheduler } from '../main/ets/internal/upload/UploadScheduler';
import { BatchUploader, UploadStatus } from '../main/ets/internal/upload/DataUploader';

const STALE_UPLOADING_MS: number = 11 * 60 * 1000;

class RecordingWorkClient implements DeferredUploadWorkSchedulerClient {
  readonly started: Array<workScheduler.WorkInfo> = [];

  startWork(work: workScheduler.WorkInfo): boolean {
    this.started.push(work);
    return true;
  }
}

class RejectingThenRecordingWorkClient implements DeferredUploadWorkSchedulerClient {
  readonly started: Array<workScheduler.WorkInfo> = [];

  startWork(work: workScheduler.WorkInfo): boolean {
    this.started.push(work);
    return this.started.length > 1;
  }
}

class TestBatch implements Batch {
  batchId: string;
  originalBatchId?: string;
  data: string;
  eventCount: number;

  constructor(batchId: string, originalBatchId: string, data: string, eventCount: number) {
    this.batchId = batchId;
    this.originalBatchId = originalBatchId;
    this.data = data;
    this.eventCount = eventCount;
  }
}

class FakePersistence implements UploadPersistence {
  readonly batch: Batch;
  deleted: string = '';
  restored: string = '';
  reads: number = 0;

  constructor(batch: Batch) {
    this.batch = batch;
  }

  readNextBatch(): Batch | null {
    this.reads += 1;
    return this.reads === 1 ? this.batch : null;
  }

  deleteBatch(batchId: string): void {
    this.deleted = batchId;
  }

  restoreBatch(batch: Batch): void {
    this.restored = batch.originalBatchId ?? batch.batchId;
  }
}

class QueuePersistence implements UploadPersistence {
  private readonly batches: Array<Batch>;
  private index: number = 0;
  readCount: number = 0;
  readonly deleted: Array<string> = [];
  readonly restored: Array<string> = [];

  constructor(batches: Array<Batch>) {
    this.batches = batches;
  }

  readNextBatch(): Batch | null {
    this.readCount += 1;
    if (this.index >= this.batches.length) {
      return null;
    }
    const batch: Batch = this.batches[this.index];
    this.index += 1;
    return batch;
  }

  deleteBatch(batchId: string): void {
    this.deleted.push(batchId);
  }

  restoreBatch(batch: Batch): void {
    this.restored.push(batch.originalBatchId ?? batch.batchId);
  }
}

class FakeUploader implements BatchUploader {
  readonly status: UploadStatus;

  constructor(status: UploadStatus) {
    this.status = status;
  }

  upload(_batch: Batch): Promise<UploadStatus> {
    return Promise.resolve(this.status);
  }
}

export default function deferredUploadTests(): void {
  describe('DeferredUploadWorkRegistrar', (): void => {
    it('configurationBuilderEnablesDeferredUpload', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const config = new ConfigurationBuilder('token', 'prod')
        .setDeferredUploadWork('FlashcatUploadWorkAbility', 1001)
        .setUploadOnWifiOnly(true)
        .setDeferredUploadRequiresCharging(false)
        .build();

      expect(config.deferredUploadAbilityName).assertEqual('FlashcatUploadWorkAbility');
      expect(config.deferredUploadWorkId).assertEqual(1001);
      expect(config.uploadOnWifiOnly).assertEqual(true);
      expect(config.deferredUploadRequiresCharging).assertEqual(false);
    });

    it('buildsWifiOnlyChargingWorkInfo', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const options: DeferredUploadWorkOptions = {
        workId: 1001,
        bundleName: 'com.example.demo',
        abilityName: 'FlashcatUploadWorkAbility',
        uploadOnWifiOnly: true,
        requiresCharging: true
      };
      const work = DeferredUploadWorkRegistrar.workInfoFor(options);

      expect(work.workId).assertEqual(1001);
      expect(work.bundleName).assertEqual('com.example.demo');
      expect(work.abilityName).assertEqual('FlashcatUploadWorkAbility');
      expect(work.networkType).assertEqual(workScheduler.NetworkType.NETWORK_TYPE_WIFI);
      expect(work.isCharging).assertEqual(true);
      expect(work.isPersisted).assertEqual(true);
    });

    it('registersOnlyOnce', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const client = new RecordingWorkClient();
      const registrar = new DeferredUploadWorkRegistrar(client);
      const options: DeferredUploadWorkOptions = {
        workId: 1001,
        bundleName: 'com.example.demo',
        abilityName: 'FlashcatUploadWorkAbility',
        uploadOnWifiOnly: false,
        requiresCharging: true
      };

      registrar.register(options);
      registrar.register(options);

      expect(client.started.length).assertEqual(1);
      expect(client.started[0].networkType).assertEqual(workScheduler.NetworkType.NETWORK_TYPE_ANY);
    });

    it('doesNotMarkRejectedRegistrationAsComplete', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const client = new RejectingThenRecordingWorkClient();
      const registrar = new DeferredUploadWorkRegistrar(client);
      const options: DeferredUploadWorkOptions = {
        workId: 1001,
        bundleName: 'com.example.demo',
        abilityName: 'FlashcatUploadWorkAbility',
        uploadOnWifiOnly: false,
        requiresCharging: true
      };

      registrar.register(options);
      registrar.register(options);

      expect(client.started.length).assertEqual(2);
    });
  });

  describe('UploadSchedulerClaims', (): void => {
    it('restoresClaimedBatchOnRetry', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const batch: Batch = new TestBatch('batch-1.ndjson.uploading', 'batch-1.ndjson', '{"type":"view"}', 1);
      const persistence = new FakePersistence(batch);
      const uploader: BatchUploader = new FakeUploader(UploadStatus.RETRY);
      const scheduler = new UploadScheduler(persistence, uploader, 5000);

      await scheduler.flushOnceForWork();

      expect(persistence.restored).assertEqual('batch-1.ndjson');
      expect(persistence.deleted).assertEqual('');
    });

    it('deletesClaimedBatchOnSuccess', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const batch: Batch = new TestBatch('batch-1.ndjson.uploading', 'batch-1.ndjson', '{"type":"view"}', 1);
      const persistence = new FakePersistence(batch);
      const uploader: BatchUploader = new FakeUploader(UploadStatus.SUCCESS);
      const scheduler = new UploadScheduler(persistence, uploader, 5000);

      await scheduler.flushOnceForWork();

      expect(persistence.deleted).assertEqual('batch-1.ndjson.uploading');
      expect(persistence.restored).assertEqual('');
    });

    it('drainsMultipleClaimedBatchesForWork', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const batches: Array<Batch> = [
        new TestBatch('batch-1.ndjson.uploading', 'batch-1.ndjson', '{"type":"view"}', 1),
        new TestBatch('batch-2.ndjson.uploading', 'batch-2.ndjson', '{"type":"error"}', 1)
      ];
      const persistence = new QueuePersistence(batches);
      const uploader: BatchUploader = new FakeUploader(UploadStatus.SUCCESS);
      const scheduler = new UploadScheduler(persistence, uploader, 5000);

      await scheduler.flushForWork(10);

      expect(persistence.deleted.length).assertEqual(2);
      expect(persistence.deleted[0]).assertEqual('batch-1.ndjson.uploading');
      expect(persistence.deleted[1]).assertEqual('batch-2.ndjson.uploading');
      expect(persistence.restored.length).assertEqual(0);
    });

    it('stopsWorkDrainAfterRetry', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const batches: Array<Batch> = [
        new TestBatch('batch-1.ndjson.uploading', 'batch-1.ndjson', '{"type":"view"}', 1),
        new TestBatch('batch-2.ndjson.uploading', 'batch-2.ndjson', '{"type":"error"}', 1)
      ];
      const persistence = new QueuePersistence(batches);
      const uploader: BatchUploader = new FakeUploader(UploadStatus.RETRY);
      const scheduler = new UploadScheduler(persistence, uploader, 5000);

      await scheduler.flushForWork(10);

      expect(persistence.readCount).assertEqual(1);
      expect(persistence.restored.length).assertEqual(1);
      expect(persistence.deleted.length).assertEqual(0);
    });

    it('keepsFreshClaimedBatchLocked', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const nowMs: number = Date.now();
      const batchName: string = `batch-${nowMs}-1-1.ndjson.uploading`;

      expect(FilePersistenceStrategy.shouldRestoreClaimedBatch(batchName, nowMs + 1000)).assertFalse();
    });

    it('restoresOnlyStaleClaimedBatch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const nowMs: number = Date.now();
      const staleStartedAtMs: number = nowMs - STALE_UPLOADING_MS;
      const staleName: string = `batch-${staleStartedAtMs}-1-1.ndjson.uploading`;
      const ordinaryName: string = `batch-${nowMs}-1-1.ndjson`;

      expect(FilePersistenceStrategy.shouldRestoreClaimedBatch(staleName, nowMs)).assertTrue();
      expect(FilePersistenceStrategy.shouldRestoreClaimedBatch(ordinaryName, nowMs + STALE_UPLOADING_MS)).assertFalse();
    });
  });
}
