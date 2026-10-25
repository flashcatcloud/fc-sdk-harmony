import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { TrackingConsent } from '../main/ets/privacy/TrackingConsent';
import { FlashcatCore } from '../main/ets/internal/FlashcatCore';
import { EventWriter, Feature, FeatureScope } from '../main/ets/api/feature/Feature';
import { FlashcatContext } from '../main/ets/api/context/FlashcatContext';
import { Flashcat } from '../main/ets/Flashcat';
import { UploadScheduler } from '../main/ets/internal/upload/UploadScheduler';
import { UploadPersistence, Batch } from '../main/ets/internal/persistence/FilePersistenceStrategy';
import { BatchUploader, UploadStatus } from '../main/ets/internal/upload/DataUploader';

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

/** Storage whose first read throws (a transient file-system failure), then is empty. */
class FlakyPersistence implements UploadPersistence {
  reads: number = 0;
  readNextBatch(): Batch | null {
    this.reads += 1;
    if (this.reads === 1) {
      throw new Error('EIO');
    }
    return null;
  }
  deleteBatch(_batchId: string): void {}
  restoreBatch(_batch: Batch): void {}
}

/** Hands out one batch, then nothing; records what was handed back. */
class OneBatchPersistence implements UploadPersistence {
  private given: boolean = false;
  readonly restored: string[] = [];
  readNextBatch(): Batch | null {
    if (this.given) {
      return null;
    }
    this.given = true;
    return { batchId: 'b-1', data: '{}', eventCount: 1 } as Object as Batch;
  }
  deleteBatch(_batchId: string): void {}
  restoreBatch(batch: Batch): void {
    this.restored.push(batch.batchId);
  }
}

class ThrowingUploader implements BatchUploader {
  async upload(_batch: Batch): Promise<UploadStatus> {
    throw new Error('http unavailable');
  }
}

class NeverUploader implements BatchUploader {
  async upload(_batch: Batch): Promise<UploadStatus> {
    return UploadStatus.SUCCESS;
  }
}

let instanceSeq: number = 0;

function fakeContext(): common.Context {
  const ctx: Record<string, Object> = {
    'filesDir': `/tmp/flashcat-host-safety-test-${Date.now()}-${instanceSeq++}`,
    'getApplicationContext': (): Record<string, Object> => {
      return {
        'on': (): void => {},
        'off': (): void => {}
      } as Record<string, Object>;
    }
  };
  return ctx as Object as common.Context;
}

class NoopFeature implements Feature {
  readonly name: string = 'rum';
  onInitialize(): void {}
  onStop(): void {}
}

/** A feature that fails at start or at stop, and records whether it was stopped. */
class FaultyFeature implements Feature {
  readonly name: string;
  private readonly failInit: boolean;
  private readonly failStop: boolean;
  stopped: boolean = false;

  constructor(name: string, failInit: boolean, failStop: boolean) {
    this.name = name;
    this.failInit = failInit;
    this.failStop = failStop;
  }
  onInitialize(): void {
    if (this.failInit) {
      throw new Error('init failed');
    }
  }
  onStop(): void {
    this.stopped = true;
    if (this.failStop) {
      throw new Error('stop failed');
    }
  }
}

function write(core: FlashcatCore, event: Record<string, Object>): boolean {
  const scope: FeatureScope | null = core.getFeature('rum');
  let written: boolean = false;
  if (scope !== null) {
    scope.withWriteContext((_context: FlashcatContext, writer: EventWriter) => {
      written = writer.write(event);
    });
  }
  return written;
}

export default function hostSafetyTests(): void {
  describe('HostSafety', (): void => {
    it('anEventThatCannotBeSerializedIsDroppedNotThrown',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FlashcatCore = new FlashcatCore(`hs-${instanceSeq++}`, fakeContext(),
          new ConfigurationBuilder('token', 'prod').build(), TrackingConsent.GRANTED);
        core.initialize();
        core.registerFeature(new NoopFeature());
        // A host attribute holding a cycle: JSON.stringify throws on it.
        const cyclic: Record<string, Object> = {};
        cyclic['self'] = cyclic;
        let threw: boolean = false;
        let written: boolean = true;
        try {
          written = write(core, { 'type': 'action', 'context': cyclic });
        } catch (_e) {
          threw = true;
        }

        expect(threw).assertFalse();
        expect(written).assertFalse();
        // Negative control: an ordinary event is still written.
        expect(write(core, { 'type': 'action', 'context': { 'k': 'v' } })).assertTrue();
        core.stop();
      });

    it('hostCallsOnAnInstanceThatDoesNotExistAreNoOps',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        let threw: boolean = false;
        try {
          Flashcat.setTrackingConsent(TrackingConsent.GRANTED, 'never-initialized');
          Flashcat.flush('never-initialized');
          await Flashcat.flushAndWait('never-initialized');
          Flashcat.stopInstance('never-initialized');
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
      });

    it('aStoppedCoreAcceptsNoNewFeature',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FlashcatCore = new FlashcatCore(`hs-${instanceSeq++}`, fakeContext(),
          new ConfigurationBuilder('token', 'prod').build(), TrackingConsent.GRANTED);
        core.initialize();
        core.stop();
        core.registerFeature(new NoopFeature());
        expect(core.getFeature('rum') === null).assertTrue();
      });

    it('aFeatureThatFailsToStartOrStopNeverReachesTheHost',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FlashcatCore = new FlashcatCore(`hs-${instanceSeq++}`, fakeContext(),
          new ConfigurationBuilder('token', 'prod').build(), TrackingConsent.GRANTED);
        core.initialize();
        const failsToStop: FaultyFeature = new FaultyFeature('trace', false, true);
        const healthy: FaultyFeature = new FaultyFeature('crash', false, false);
        let threw: boolean = false;
        let registeredAfterFailedStart: boolean = false;
        try {
          core.registerFeature(new FaultyFeature('rum', true, false));
          // Kept registered: what it set up before failing stays consistent with it.
          registeredAfterFailedStart = core.getFeature('rum') !== null;
          core.registerFeature(failsToStop);
          core.registerFeature(healthy);
          core.stop();
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
        expect(registeredAfterFailedStart).assertTrue();
        expect(failsToStop.stopped).assertTrue();
        expect(healthy.stopped).assertTrue(); // stopped although an earlier feature failed
      });

    it('aClaimedBatchIsHandedBackWhenTheUploadThrows',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        const persistence: OneBatchPersistence = new OneBatchPersistence();
        const scheduler: UploadScheduler = new UploadScheduler(persistence, new ThrowingUploader(), 20, 10);
        scheduler.start();
        await delay(150);
        scheduler.stop();
        expect(persistence.restored.length).assertEqual(1);
      });

    it('aStorageFailureDoesNotEndTheUploadChain',
      TestType.FUNCTION | Size.MEDIUMTEST | Level.LEVEL0, async (): Promise<void> => {
        const persistence: FlakyPersistence = new FlakyPersistence();
        const scheduler: UploadScheduler = new UploadScheduler(persistence, new NeverUploader(), 20, 10);
        scheduler.start();
        await delay(300);
        scheduler.stop();
        // The first drain threw; later drains still ran.
        expect(persistence.reads >= 2).assertTrue();
      });
  });
}
