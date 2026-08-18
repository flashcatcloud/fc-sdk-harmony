import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { Configuration, ConfigurationBuilder } from '../main/ets/config/Configuration';
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

export default function uploadThrottleTests(): void {
  describe('UploadThrottleConfig', (): void => {
    it('defaultsMatchPreviousBehaviourAndAndroidParity',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const config: Configuration = new ConfigurationBuilder('token', 'env').build();

        // 5 s window is the value the roll constants shipped with before it
        // became configurable — defaults must not move under existing apps.
        expect(config.batchWindowMs).assertEqual(5000);
        // Android's BatchProcessingLevel.MEDIUM.
        expect(config.maxBatchesPerCycle).assertEqual(10);
      });

    it('clampsBatchWindowToSupportedRange',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A sub-second window would weaken the cross-process claim guard.
        expect(new ConfigurationBuilder('t', 'e').setBatchWindowMs(0).build().batchWindowMs)
          .assertEqual(1000);
        expect(new ConfigurationBuilder('t', 'e').setBatchWindowMs(-1).build().batchWindowMs)
          .assertEqual(1000);
        expect(new ConfigurationBuilder('t', 'e').setBatchWindowMs(35000).build().batchWindowMs)
          .assertEqual(35000);
        expect(new ConfigurationBuilder('t', 'e').setBatchWindowMs(600000).build().batchWindowMs)
          .assertEqual(60000);
      });

    it('clampsMaxBatchesPerCycleToWholeNumbersAboveZero',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // 0 would mean a cycle that never drains anything.
        expect(new ConfigurationBuilder('t', 'e').setMaxBatchesPerCycle(0).build().maxBatchesPerCycle)
          .assertEqual(1);
        expect(new ConfigurationBuilder('t', 'e').setMaxBatchesPerCycle(-5).build().maxBatchesPerCycle)
          .assertEqual(1);
        // Truncated: a fractional bound can never be reached by an integer counter.
        expect(new ConfigurationBuilder('t', 'e').setMaxBatchesPerCycle(3.7).build().maxBatchesPerCycle)
          .assertEqual(3);
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

    it('defaultWindowKeepsActiveBatchOpen',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // Identical write and identical elapsed time under the default 5 s
        // window: still open. The only difference is the configured window, so
        // the roll decision provably follows it rather than a constant.
        const persistence: FilePersistenceStrategy =
          new FilePersistenceStrategy(fakeContext(), 'rum');
        persistence.write('{"type":"view","date":1}', false);
        await delay(30);

        expect(persistence.readNextBatch()).assertNull();
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
