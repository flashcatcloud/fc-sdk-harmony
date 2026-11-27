import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common, ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { TrackingConsent } from '../main/ets/privacy/TrackingConsent';
import { FlashcatCore } from '../main/ets/internal/FlashcatCore';
import { EventWriter, Feature, FeatureScope } from '../main/ets/api/feature/Feature';
import { FlashcatContext } from '../main/ets/api/context/FlashcatContext';
import { FilePersistenceStrategy, Batch } from '../main/ets/internal/persistence/FilePersistenceStrategy';

const QUOTA_BYTES: number = 4 * 1024 * 1024;
const FLUSH_BYTES: number = 64 * 1024;

let dirSeq: number = 0;

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

/** A context whose application-state callback the test can fire. */
class FakeApp {
  callback: ApplicationStateChangeCallback | null = null;
  readonly filesDir: string = `/tmp/flashcat-buffered-test-${Date.now()}-${dirSeq++}`;

  context(): common.Context {
    const ctx: Record<string, Object> = {
      'filesDir': this.filesDir,
      'getApplicationContext': (): Record<string, Object> => {
        return {
          'on': (type: string, callback: Object): number => {
            if (type === 'applicationStateChange') {
              this.callback = callback as ApplicationStateChangeCallback;
            }
            return 0;
          },
          'off': (): void => {}
        } as Record<string, Object>;
      }
    };
    return ctx as Object as common.Context;
  }
}

function calls(): Record<string, number> {
  return (fs as Object as Record<string, Object>)['calls'] as Record<string, number>;
}

function rumDir(filesDir: string): string {
  return `${filesDir}/flashcat/rum`;
}

/** Every event line on disk, batch files in name order. */
function diskLines(dir: string): string[] {
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir).filter((n: string) => n.startsWith('batch-')).sort();
  } catch (_e) {
    return [];
  }
  const lines: string[] = [];
  for (const n of names) {
    for (const l of fs.readTextSync(`${dir}/${n}`).split('\n')) {
      if (l.length > 0) {
        lines.push(l);
      }
    }
  }
  return lines;
}

function diskBytes(dir: string): number {
  let total: number = 0;
  for (const n of fs.listFileSync(dir)) {
    if (n.startsWith('batch-')) {
      total += fs.statSync(`${dir}/${n}`).size;
    }
  }
  return total;
}

function event(seq: number, pad: string = ''): string {
  return `{"type":"action","date":${Date.now()},"seq":${seq},"pad":"${pad}"}`;
}

function seqs(lines: string[]): number[] {
  return lines.map((l: string) => (JSON.parse(l) as Record<string, number>)['seq']);
}

/** Writes padded events until FLUSH_BYTES are buffered: the last write starts an asynchronous append. */
function startAnAppend(persistence: FilePersistenceStrategy, firstSeq: number): number {
  const pad: string = 'x'.repeat(1000);
  let seq: number = firstSeq;
  let bytes: number = 0;
  while (bytes < FLUSH_BYTES) {
    const line: string = event(seq, pad);
    persistence.write(line);
    bytes += line.length + 1;
    seq += 1;
  }
  return seq;
}

/**
 * Waits for the asynchronous append in flight, if any. rollActive writes what is
 * buffered but does not wait for an append already started, so the newest
 * lines may still be in one when it returns.
 */
async function appendSettled(persistence: FilePersistenceStrategy): Promise<void> {
  const fields: Record<string, Object> = persistence as Object as Record<string, Object>;
  for (let i: number = 0; i < 1000 && fields['appendingName'] !== null; i++) {
    await delay(1);
  }
}

/** Drains up to `max` batches, deleting each as an upload would; their lines in upload order. */
function drain(persistence: FilePersistenceStrategy, max: number): string[] {
  let drained: string[] = [];
  for (let i: number = 0; i < max; i++) {
    const batch: Batch | null = persistence.readNextBatch();
    if (batch === null) {
      break;
    }
    drained = drained.concat(batch.data.split('\n'));
    persistence.deleteBatch(batch.batchId);
  }
  return drained;
}

function range(n: number): number[] {
  const out: number[] = [];
  for (let i: number = 0; i < n; i++) {
    out.push(i);
  }
  return out;
}

/** The file API object, to make one of its calls fail. */
function fsApi(): Record<string, Object> {
  return fs as Object as Record<string, Object>;
}

class NoopFeature implements Feature {
  readonly name: string = 'rum';
  onInitialize(): void {}
  onStop(): void {}
}

function buildCore(app: FakeApp, consent: TrackingConsent = TrackingConsent.GRANTED): FlashcatCore {
  const core: FlashcatCore = new FlashcatCore(`bw-${dirSeq++}`, app.context(),
    new ConfigurationBuilder('token', 'prod').build(), consent, false);
  core.initialize();
  core.registerFeature(new NoopFeature());
  return core;
}

/** The persistence behind a core's feature. */
function persistenceOf(core: FlashcatCore, feature: string): FilePersistenceStrategy {
  const features: Map<string, Record<string, Object>> =
    (core as Object as Record<string, Object>)['features'] as Map<string, Record<string, Object>>;
  return (features.get(feature) as Record<string, Object>)['persistence'] as FilePersistenceStrategy;
}

function writeEvent(core: FlashcatCore, seq: number, forceFlush: boolean = false): boolean {
  const scope: FeatureScope | null = core.getFeature('rum');
  let written: boolean = false;
  if (scope !== null) {
    scope.withWriteContext((_context: FlashcatContext, writer: EventWriter) => {
      const e: Record<string, Object> = { 'type': 'action', 'date': Date.now(), 'seq': seq };
      written = writer.write(e, forceFlush);
    });
  }
  return written;
}

export default function bufferedWritesTests(): void {
  describe('BufferedWrites', (): void => {
    it('aWriteReturnsWithoutTouchingTheFileSystem',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const before: Record<string, number> = JSON.parse(JSON.stringify(calls())) as Record<string, number>;
        for (let i: number = 0; i < 20; i++) {
          expect(persistence.write(event(i))).assertTrue();
        }
        const after: Record<string, number> = calls();
        for (const key of Object.keys(before)) {
          expect(`${key}=${after[key]}`).assertEqual(`${key}=${before[key]}`);
        }
        expect(diskLines(rumDir(app.filesDir)).length).assertEqual(0);
        persistence.wipeAll();
      });

    it('bufferedEventsReachDiskAfterTheFlushDelayInOrder',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        for (let i: number = 0; i < 5; i++) {
          persistence.write(event(i));
        }
        await delay(100);
        expect(diskLines(rumDir(app.filesDir)).length).assertEqual(0); // the delay has not passed
        await delay(300);
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1,2,3,4]');
        // One open for the five lines, not one per line.
        const files: string[] = fs.listFileSync(rumDir(app.filesDir));
        expect(files.length).assertEqual(1);
      });

    it('enoughBufferedBytesFlushWithoutWaitingForTheDelay',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const pad: string = 'x'.repeat(1000);
        const opens: number = calls()['open'];
        let count: number = 0;
        let bytes: number = 0;
        while (bytes < FLUSH_BYTES) {
          const line: string = event(count, pad);
          persistence.write(line);
          bytes += line.length + 1;
          count += 1;
        }
        expect(calls()['open'] - opens).assertEqual(1); // started by the write itself
        await delay(30);
        expect(diskLines(rumDir(app.filesDir)).length).assertEqual(count);
        persistence.wipeAll();
      });

    it('rollActiveWritesTheBufferBeforeItReturns',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        for (let i: number = 0; i < 5; i++) {
          persistence.write(event(i));
        }
        persistence.rollActive();
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1,2,3,4]');
        const batch: Batch | null = persistence.readNextBatch();
        expect(batch !== null && batch.eventCount === 5).assertTrue();
      });

    it('aForceRollWritesTheBufferedEventsFirst',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        persistence.write(event(0));
        persistence.write(event(1));
        expect(persistence.write(event(2), true)).assertTrue();
        // On disk before write returned, in order, and the batch is closed.
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1,2]');
        const batch: Batch | null = persistence.readNextBatch();
        expect(batch !== null && batch.eventCount === 3).assertTrue();
      });

    it('aSynchronousFlushDuringAnAppendKeepsTheOrder',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const pad: string = 'x'.repeat(1000);
        let seq: number = 0;
        while (seq * 1000 < FLUSH_BYTES) {
          persistence.write(event(seq, pad)); // the last one starts an append
          seq += 1;
        }
        persistence.write(event(seq));
        persistence.write(event(seq + 1));
        persistence.rollActive(); // while the append is still in flight
        await delay(30);
        const expected: number[] = [];
        for (let i: number = 0; i < seq + 2; i++) {
          expected.push(i);
        }
        let drained: string[] = [];
        for (let i: number = 0; i < 5; i++) {
          const batch: Batch | null = persistence.readNextBatch();
          if (batch === null) {
            break;
          }
          drained = drained.concat(batch.data.split('\n'));
          persistence.deleteBatch(batch.batchId);
        }
        expect(JSON.stringify(seqs(drained))).assertEqual(JSON.stringify(expected));
      });

    it('linesRedirectedFromAnAppendInFlightStillDrainBeforeLaterBatches',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const pad: string = 'x'.repeat(1000);
        let seq: number = 0;
        let bytes: number = 0;
        while (bytes < FLUSH_BYTES) {
          const line: string = event(seq, pad);
          persistence.write(line); // the last one starts an append to the first batch
          bytes += line.length + 1;
          seq += 1;
        }
        persistence.write(event(seq)); // same batch, behind the append in flight
        seq += 1;
        persistence.write(event(seq, 'y'.repeat(460 * 1024))); // rolls on size: a second batch
        seq += 1;
        persistence.rollActive();
        await delay(30);
        let drained: string[] = [];
        for (let i: number = 0; i < 5; i++) {
          const batch: Batch | null = persistence.readNextBatch();
          if (batch === null) {
            break;
          }
          drained = drained.concat(batch.data.split('\n'));
          persistence.deleteBatch(batch.batchId);
        }
        const expected: number[] = [];
        for (let i: number = 0; i < seq; i++) {
          expected.push(i);
        }
        expect(JSON.stringify(seqs(drained))).assertEqual(JSON.stringify(expected));
      });

    it('wipeAllDiscardsTheBufferAndAnAppendInFlight',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const pad: string = 'x'.repeat(1000);
        for (let i: number = 0; i * 1000 < FLUSH_BYTES; i++) {
          persistence.write(event(i, pad)); // the last one starts an append
        }
        persistence.write(event(-1)); // buffered behind it
        persistence.wipeAll();
        await delay(400);
        expect(diskLines(rumDir(app.filesDir)).length).assertEqual(0);
      });

    it('aWipeWhileCollectingGoesOnKeepsOnlyTheEventsWrittenAfterIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // Any wipe of the collected data (not only a consent revocation) runs
        // wipeAll; collection may go on right after it, as when the app clears
        // its data and keeps tracking.
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const pad: string = 'x'.repeat(1000);
        let bytes: number = 0;
        for (let i: number = 0; bytes < FLUSH_BYTES; i++) {
          const line: string = event(i, pad);
          persistence.write(line); // the last one starts an append
          bytes += line.length + 1;
        }
        persistence.write(event(-1)); // buffered behind it
        persistence.wipeAll();
        persistence.write(event(1000));
        persistence.write(event(1001));
        await delay(400);
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[1000,1001]');
        persistence.rollActive();
        const batch: Batch | null = persistence.readNextBatch();
        expect(batch !== null && batch.eventCount === 2).assertTrue();
      });

    it('theQuotaIsNeverExceededByMoreThanOneFlush',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const pad: string = 'x'.repeat(1000);
        let seq: number = 0;
        let worst: number = 0;
        // 6 MB, flushed 64 KB at a time.
        for (let round: number = 0; round < 96; round++) {
          for (let i: number = 0; i < 64; i++) {
            persistence.write(event(seq, pad));
            seq += 1;
          }
          await delay(2);
          const bytes: number = diskBytes(rumDir(app.filesDir));
          worst = bytes > worst ? bytes : worst;
        }
        persistence.rollActive();
        await appendSettled(persistence); // the newest lines may be in it
        worst = Math.max(worst, diskBytes(rumDir(app.filesDir)));
        expect(worst > QUOTA_BYTES - 600 * 1024).assertTrue(); // it did fill up
        expect(worst <= QUOTA_BYTES + FLUSH_BYTES + 2048).assertTrue();
        // Oldest evicted, newest kept.
        const lines: number[] = seqs(diskLines(rumDir(app.filesDir)));
        expect(lines[lines.length - 1]).assertEqual(seq - 1);
        expect(lines.indexOf(0)).assertEqual(-1);
      });

    it('backgroundingWritesTheBufferBeforeTheCallbackReturns',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const core: FlashcatCore = buildCore(app);
        for (let i: number = 0; i < 5; i++) {
          expect(writeEvent(core, i)).assertTrue();
        }
        expect(diskLines(rumDir(app.filesDir)).length).assertEqual(0); // buffered
        (app.callback as ApplicationStateChangeCallback).onApplicationBackground();
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1,2,3,4]');
        core.stop();
      });

    it('aCrashRecordIsWrittenAfterTheBufferedEvents',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const core: FlashcatCore = buildCore(app);
        writeEvent(core, 0);
        writeEvent(core, 1);
        const scope: FeatureScope = core.getFeature('rum') as FeatureScope;
        let onDiskAtCrashWrite: number = -1;
        const command: Record<string, Object> = {
          'type': 'crash_storage_write',
          'target': '__flashcat_crash_storage',
          'incident_id': 'incident-1',
          'serialized': '{"incident":1}',
          'success': false
        };
        scope.sendEvent(command);
        onDiskAtCrashWrite = diskLines(rumDir(app.filesDir)).length;
        expect(command['success'] === true).assertTrue();
        expect(onDiskAtCrashWrite).assertEqual(2);
        core.stop();
      });

    it('aForceFlushedEventIsOnDiskBeforeTheWriteReturns',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const core: FlashcatCore = buildCore(app);
        writeEvent(core, 0);
        expect(writeEvent(core, 1, true)).assertTrue();
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1]');
        core.stop();
      });

    it('revokingConsentDiscardsBufferedEvents',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const core: FlashcatCore = buildCore(app);
        writeEvent(core, 0);
        writeEvent(core, 1);
        core.setTrackingConsent(TrackingConsent.NOT_GRANTED);
        await delay(400);
        expect(diskLines(rumDir(app.filesDir)).length).assertEqual(0);
        core.stop();
      });

    it('switchingToPendingWritesTheGrantedBuffer',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const core: FlashcatCore = buildCore(app);
        writeEvent(core, 0);
        core.setTrackingConsent(TrackingConsent.PENDING);
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0]');
        core.stop();
      });

    it('stopWritesTheBuffer',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const core: FlashcatCore = buildCore(app);
        writeEvent(core, 0);
        writeEvent(core, 1);
        core.stop();
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1]');
      });

    it('aBatchWrittenDuringAnAppendIsNotUploadedBeforeTheBatchBeingAppended',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // The intake keeps the view update that arrives last: an older update
        // uploaded after a newer one overwrites it. The older one is in the
        // append in flight; the newer one is force-flushed (as an error is)
        // into a continuation batch while that append still runs.
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        let seq: number = startAnAppend(persistence, 0); // ends with the older update
        expect(persistence.write(event(seq), true)).assertTrue(); // the newer one, on disk at once
        seq += 1;
        // A force flush triggers a drain right away, the append still in flight.
        let uploaded: string[] = drain(persistence, 1);
        await delay(30);
        uploaded = uploaded.concat(drain(persistence, 5));
        expect(JSON.stringify(seqs(uploaded))).assertEqual(JSON.stringify(range(seq)));
      });

    it('aBatchRolledDuringAnAppendIsNotUploadedBeforeTheBatchBeingAppended',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        let seq: number = startAnAppend(persistence, 0);
        persistence.write(event(seq, 'y'.repeat(460 * 1024))); // rolls on size: a new batch
        seq += 1;
        persistence.rollActive(); // the new batch is complete on disk, the first one is not
        let uploaded: string[] = drain(persistence, 1);
        await delay(30);
        uploaded = uploaded.concat(drain(persistence, 5));
        expect(JSON.stringify(seqs(uploaded))).assertEqual(JSON.stringify(range(seq)));
      });

    it('aThrowingAppendCompletionStillFlushesWhatIsBufferedBehindIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const api: Record<string, Object> = fsApi();
        const open: Object = api['open'];
        let failOpens: number = 1;
        // The first open fails late: the flush timer armed by the write behind
        // it fires while the append is still in flight, and does nothing.
        api['open'] = (p: string, mode: number): Promise<Object> => failOpens-- > 0
          ? delay(400).then((): Promise<Object> => Promise.reject(new Error('EIO')))
          : (open as (p: string, mode: number) => Promise<Object>)(p, mode);
        // The retry after the failed open throws.
        (persistence as Object as Record<string, Object>)['healAndAppend'] = (): boolean => {
          throw new Error('heal failed');
        };
        let seq: number = 0;
        try {
          seq = startAnAppend(persistence, 0);
          persistence.write(event(seq)); // buffered behind the failing append
          // No further write: only the completion can schedule its flush.
          await delay(1000);
        } finally {
          api['open'] = open;
        }
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual(`[${seq}]`);
        persistence.wipeAll();
      });

    it('aWriteThatFailedPartWayIsNotWrittenTwice',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const api: Record<string, Object> = fsApi();
        const write: Object = api['write'];
        // The content lands, then the write reports an error.
        api['write'] = (fd: number, content: string): Promise<Object> =>
          (write as (fd: number, content: string) => Promise<Object>)(fd, content)
            .then((): Promise<Object> => Promise.reject(new Error('EIO')));
        let seq: number = 0;
        try {
          seq = startAnAppend(persistence, 0);
          await delay(30);
        } finally {
          api['write'] = write;
        }
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual(JSON.stringify(range(seq)));
        persistence.wipeAll();
      });

    it('afterStopNothingIsScheduledAndAWriteGoesToDiskAtOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        let seq: number = startAnAppend(persistence, 0);
        persistence.write(event(seq)); // buffered behind the append, flush timer armed
        seq += 1;
        persistence.stop(); // while the append is in flight
        const fields: Record<string, Object> = persistence as Object as Record<string, Object>;
        expect(fields['flushTimer'] as number).assertEqual(-1);
        await delay(30); // the append completes
        expect(fields['flushTimer'] as number).assertEqual(-1);
        expect(persistence.write(event(seq))).assertTrue();
        seq += 1;
        expect(fields['flushTimer'] as number).assertEqual(-1);
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual(JSON.stringify(range(seq)));
      });

    it('aSynchronousWriteThatFailedPartWayIsNotWrittenTwice',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const api: Record<string, Object> = fsApi();
        const writeSync: Object = api['writeSync'];
        persistence.write(event(0));
        // The content lands, then the write reports an error.
        api['writeSync'] = (fd: number, content: string): number => {
          (writeSync as (fd: number, content: string) => number)(fd, content);
          throw new Error('EIO');
        };
        try {
          expect(persistence.write(event(1), true)).assertFalse();
        } finally {
          api['writeSync'] = writeSync;
        }
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1]');
        persistence.wipeAll();
      });

    it('aSynchronousWriteWhoseCloseFailsCountsAsWritten',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const api: Record<string, Object> = fsApi();
        const closeSync: Object = api['closeSync'];
        persistence.write(event(0));
        api['closeSync'] = (file: Object): void => {
          (closeSync as (file: Object) => void)(file);
          throw new Error('EIO');
        };
        try {
          expect(persistence.write(event(1), true)).assertTrue();
        } finally {
          api['closeSync'] = closeSync;
        }
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1]');
        persistence.wipeAll();
      });

    it('aSynchronousWriteThatCouldNotOpenIsRetriedOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const app: FakeApp = new FakeApp();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(app.context(), 'rum');
        const api: Record<string, Object> = fsApi();
        const openSync: Object = api['openSync'];
        let opens: number = 0;
        persistence.write(event(0));
        // The directory is removed underneath: the open fails until it is recreated.
        fs.rmdirSync(rumDir(app.filesDir));
        api['openSync'] = (p: string, mode: number): Object => {
          opens += 1;
          return (openSync as (p: string, mode: number) => Object)(p, mode);
        };
        try {
          expect(persistence.write(event(1), true)).assertTrue();
        } finally {
          api['openSync'] = openSync;
        }
        expect(opens).assertEqual(2);
        expect(JSON.stringify(seqs(diskLines(rumDir(app.filesDir))))).assertEqual('[0,1]');
        persistence.wipeAll();
      });

    it('preConsentEventsUploadBeforeEventsWrittenAfterTheGrant',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The intake keeps the view update that arrives last: v1, written while
        // consent was pending, must not arrive after v2, written after the grant.
        const app: FakeApp = new FakeApp();
        const core: FlashcatCore = buildCore(app);
        writeEvent(core, 0); // granted: opens the active batch
        core.setTrackingConsent(TrackingConsent.PENDING);
        writeEvent(core, 1); // v1, pre-consent
        core.setTrackingConsent(TrackingConsent.GRANTED);
        writeEvent(core, 2); // v2
        const persistence: FilePersistenceStrategy = persistenceOf(core, 'rum');
        core.stop();
        expect(JSON.stringify(seqs(drain(persistence, 10)))).assertEqual('[0,1,2]');
      });
  });
}
