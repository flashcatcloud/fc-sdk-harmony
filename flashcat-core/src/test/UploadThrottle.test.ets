import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Configuration, ConfigurationBuilder } from '../main/ets/config/Configuration';
import { BatchProcessingLevel, BatchSize, UploadFrequency } from '../main/ets/config/Batching';
import { Batch, FilePersistenceStrategy, UploadPersistence } from '../main/ets/internal/persistence/FilePersistenceStrategy';
import { UploadScheduler } from '../main/ets/internal/upload/UploadScheduler';
import { BatchUploader, UploadStatus } from '../main/ets/internal/upload/DataUploader';

let dirSeq: number = 0;

function fakeContext(): common.Context {
  const ctx: Record<string, Object> = {
    'filesDir': `/tmp/flashcat-throttle-test-${Date.now()}-${dirSeq++}`
  };
  return ctx as Object as common.Context;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

class TestBatch implements Batch {
  batchId: string;
  originalBatchId?: string;
  data: string;
  eventCount: number;

  constructor(batchId: string) {
    this.batchId = batchId;
    this.data = '{"type":"view"}';
    this.eventCount = 1;
  }
}

/** Hands out `count` batches, then reports idle. Records what was drained. */
class QueuePersistence implements UploadPersistence {
  private readonly batches: Array<Batch> = [];
  private index: number = 0;
  readonly deleted: Array<string> = [];

  constructor(count: number) {
    for (let i: number = 0; i < count; i++) {
      this.batches.push(new TestBatch(`batch-${i}.ndjson.uploading`));
    }
  }

  readNextBatch(): Batch | null {
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

  restoreBatch(_batch: Batch): void {
    // These tests only exercise the success path; nothing is ever restored.
  }
}

/** Succeeds after `latencyMs`, so a drain is observably in flight. */
class SlowUploader implements BatchUploader {
  private readonly latencyMs: number;

  constructor(latencyMs: number) {
    this.latencyMs = latencyMs;
  }

  async upload(_batch: Batch): Promise<UploadStatus> {
    await delay(this.latencyMs);
    return UploadStatus.SUCCESS;
  }
}

/** Counts attempts and always reports the given status. */
class CountingUploader implements BatchUploader {
  private readonly status: UploadStatus;
  private readonly latencyMs: number;
  attempts: number = 0;

  constructor(status: UploadStatus, latencyMs: number) {
    this.status = status;
    this.latencyMs = latencyMs;
  }

  async upload(_batch: Batch): Promise<UploadStatus> {
    this.attempts += 1;
    await delay(this.latencyMs);
    return this.status;
  }
}

/** Never runs dry, so a drain loop is bounded only by the scheduler. */
class EndlessPersistence implements UploadPersistence {
  private seq: number = 0;
  readonly deleted: Array<string> = [];

  readNextBatch(): Batch | null {
    this.seq += 1;
    return new TestBatch(`batch-${this.seq}.ndjson.uploading`);
  }

  deleteBatch(batchId: string): void {
    this.deleted.push(batchId);
  }

  restoreBatch(_batch: Batch): void {
  }
}

export default function uploadThrottleTests(): void {
  describe('UploadThrottleConfig', (): void => {
    it('enumValuesMatchTheOtherPlatforms',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Tuning advice is written once and applied on Android, iOS, Flutter and
        // HarmonyOS alike, so a case must mean the same quantity everywhere.
        // These are the values in the Android SDK's UploadFrequency, BatchSize
        // and BatchProcessingLevel. Drift here silently invalidates that advice.
        expect(UploadFrequency.FREQUENT as number).assertEqual(500);
        expect(UploadFrequency.AVERAGE as number).assertEqual(2000);
        expect(UploadFrequency.RARE as number).assertEqual(5000);

        expect(BatchSize.SMALL as number).assertEqual(3000);
        expect(BatchSize.MEDIUM as number).assertEqual(10000);
        expect(BatchSize.LARGE as number).assertEqual(35000);

        expect(BatchProcessingLevel.LOW as number).assertEqual(1);
        expect(BatchProcessingLevel.MEDIUM as number).assertEqual(20);
        expect(BatchProcessingLevel.HIGH as number).assertEqual(100);
      });

    it('defaultsMatchAndroidDefaultCoreConfig',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const config: Configuration = new ConfigurationBuilder('token', 'env').build();

        expect(config.uploadFrequency).assertEqual(UploadFrequency.AVERAGE);
        expect(config.batchSize).assertEqual(BatchSize.MEDIUM);
        expect(config.batchProcessingLevel).assertEqual(BatchProcessingLevel.MEDIUM);
      });

    it('buildsWithTheSettingsRecommendedForNarrowUplinks',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const config: Configuration = new ConfigurationBuilder('token', 'env')
          .setUploadFrequency(UploadFrequency.RARE)
          .setBatchSize(BatchSize.LARGE)
          .setBatchProcessingLevel(BatchProcessingLevel.LOW)
          .build();

        expect(config.uploadFrequency).assertEqual(UploadFrequency.RARE);
        expect(config.batchSize).assertEqual(BatchSize.LARGE);
        expect(config.batchProcessingLevel).assertEqual(BatchProcessingLevel.LOW);
      });
  });

  describe('UploadThrottleBatchWindow', (): void => {
    it('shortWindowMakesWrittenEventDrainableWithoutForceRoll',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // 1 ms window → once any real time has passed the active batch is past
        // its roll age, so the event drains without a forceRoll.
        const persistence: FilePersistenceStrategy =
          new FilePersistenceStrategy(fakeContext(), 'rum', 1);
        persistence.write('{"type":"view","date":1}', false);
        await delay(30);

        expect(persistence.readNextBatch() !== null).assertTrue();
      });

    it('foreignBatchIsNotClaimedOnThisProcessesShorterWindow',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Two processes, two independently built Configurations — nothing makes
        // them agree. This reader stands in for a deferred-upload process on a
        // short window; the batch on disk was written by a main process on a long
        // one, which may still be appending to it. Claiming it renames the file
        // out from under the writer and loses acknowledged events.
        const ctx: common.Context = fakeContext();
        const reader: FilePersistenceStrategy = new FilePersistenceStrategy(ctx, 'rum', 1);

        // 10 s old: far past this reader's own 1 ms + slack threshold, but well
        // inside the longest window a writer could have been configured with.
        const createdMs: number = Date.now() - 10000;
        const dir: string = `${(ctx as Object as Record<string, Object>)['filesDir'] as string}/flashcat/rum`;
        const file = fs.openSync(`${dir}/batch-${createdMs}-1-1.ndjson`,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        fs.writeSync(file.fd, '{"type":"view","date":1}\n');
        fs.closeSync(file);

        expect(reader.readNextBatch()).assertNull();
      });

    it('defaultWindowKeepsActiveBatchOpen',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // Identical write and identical elapsed time under the default window:
        // still open. The only difference is the configured window, so the roll
        // decision provably follows it rather than a constant.
        const persistence: FilePersistenceStrategy =
          new FilePersistenceStrategy(fakeContext(), 'rum');
        persistence.write('{"type":"view","date":1}', false);
        await delay(30);

        expect(persistence.readNextBatch()).assertNull();
      });
  });

  describe('UploadThrottleBackoff', (): void => {
    it('forceFlushDoesNotCancelRetryBackoff',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        // The intake is failing, so the scheduler doubles its delay each attempt.
        // An app that force-flushes on every error must not reset that: retrying
        // at the app's error rate turns a broken intake into a hammered one.
        const persistence = new EndlessPersistence();
        const uploader = new CountingUploader(UploadStatus.RETRY, 30);
        const scheduler = new UploadScheduler(persistence, uploader, 100, 10);

        scheduler.start();
        const pump: number = setInterval((): void => {
          scheduler.triggerNow();
        }, 20);
        await delay(800);
        clearInterval(pump);
        scheduler.stop();

        // Backoff schedule is ~100, 300, 700 ms — a handful of attempts. Pumping
        // 40 force-flushes into the same window must not add more.
        expect(uploader.attempts <= 5).assertTrue();
      });

    it('backgroundFlushAlsoHonoursRetryBackoff',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        // Backgrounding waives the cycle budget but NOT the backoff: the batch is
        // already durable on disk, so there is nothing to gain by hammering an
        // intake that is currently failing.
        const persistence = new EndlessPersistence();
        const uploader = new CountingUploader(UploadStatus.RETRY, 30);
        const scheduler = new UploadScheduler(persistence, uploader, 100, 10);

        scheduler.start();
        const pump: number = setInterval((): void => {
          scheduler.triggerNow(true);
        }, 20);
        await delay(800);
        clearInterval(pump);
        scheduler.stop();

        expect(uploader.attempts <= 5).assertTrue();
      });
  });

  describe('UploadThrottleBackgroundFlush', (): void => {
    it('backgroundFlushWaivesTheSpentCycleBudget',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        // Spend the budget (2 batches), then background. Once the process is
        // frozen the timer the budget imposes never fires, so the session's last
        // batch would sit on disk until the next launch.
        const persistence = new QueuePersistence(12);
        const scheduler = new UploadScheduler(persistence, new SlowUploader(30), 1500, 2);

        scheduler.start();
        scheduler.triggerNow();          // pull the first cycle forward
        await delay(200);                // budget spent by ~70 ms
        expect(persistence.deleted.length).assertEqual(2);

        scheduler.triggerNow(true);      // backgrounding
        await delay(300);
        scheduler.stop();

        expect(persistence.deleted.length > 2).assertTrue();
      });
  });

  describe('UploadThrottleCycleBound', (): void => {
    it('stopsAfterMaxBatchesPerCycleInsteadOfDrainingBacklog',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        const persistence = new QueuePersistence(12);
        const scheduler = new UploadScheduler(persistence, new SlowUploader(80), 600, 2);

        scheduler.start();
        // First cycle fires at 600 ms and spends its budget by ~760 ms; the next
        // is not due until ~1360 ms, so 1000 ms lands inside the gap.
        await delay(1000);
        scheduler.stop();

        expect(persistence.deleted.length).assertEqual(2);
      });

    it('drainsWholeBacklogWhenBudgetExceedsIt',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        // Control for the test above: same timing, budget larger than the backlog.
        const persistence = new QueuePersistence(4);
        const scheduler = new UploadScheduler(persistence, new SlowUploader(80), 600, 10);

        scheduler.start();
        await delay(1000);
        scheduler.stop();

        expect(persistence.deleted.length).assertEqual(4);
      });

    it('flushForWorkDefaultsToTheConfiguredProcessingLevel',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // The deferred/flush drains used to carry their own hard-coded bound, so
        // BatchProcessingLevel could neither damp nor drain them.
        const persistence = new QueuePersistence(12);
        const scheduler = new UploadScheduler(persistence, new SlowUploader(0), 5000, 3);

        await scheduler.flushForWork();

        expect(persistence.deleted.length).assertEqual(3);
      });

    it('forceFlushCannotBuyExtraBatchesWithinACycle',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        // A steady error stream force-flushes constantly. The first triggerNow
        // legitimately pulls the cycle forward (that is what force-flush is for),
        // so the cycle runs at ~25 ms and spends its 2-batch budget by ~185 ms.
        // Every later triggerNow — whether coalesced mid-drain or arriving while
        // the scheduler waits — must then be floored at the yield instant, so the
        // next cycle is not due until ~1685 ms. Unbounded, the pump would drain a
        // batch per upload and empty all 12 well before the 800 ms sample.
        const persistence = new QueuePersistence(12);
        const scheduler = new UploadScheduler(persistence, new SlowUploader(80), 1500, 2);

        scheduler.start();
        const pump: number = setInterval((): void => {
          scheduler.triggerNow();
        }, 25);
        await delay(800);
        clearInterval(pump);
        scheduler.stop();

        expect(persistence.deleted.length).assertEqual(2);
      });
  });
}
