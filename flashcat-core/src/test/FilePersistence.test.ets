import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FilePersistenceStrategy, Batch } from '../main/ets/internal/persistence/FilePersistenceStrategy';

let dirSeq: number = 0;

function fakeContext(): common.Context {
  const ctx: Record<string, Object> = {
    'filesDir': `/tmp/flashcat-persist-test-${Date.now()}-${dirSeq++}`
  };
  return ctx as Object as common.Context;
}

function eventLine(dateMs: number, marker: string): string {
  return `{"type":"view","date":${dateMs},"marker":"${marker}"}`;
}

function readAllBatches(persistence: FilePersistenceStrategy): string {
  let all: string = '';
  for (let i: number = 0; i < 50; i++) {
    const batch: Batch | null = persistence.readNextBatch();
    if (batch === null) {
      break;
    }
    all += batch.data + '\n';
    persistence.deleteBatch(batch.batchId);
  }
  return all;
}

function calls(): Record<string, number> {
  return (fs as Object as Record<string, Object>)['calls'] as Record<string, number>;
}

function batchCount(context: common.Context): number {
  const dir: string = `${(context as Object as Record<string, Object>)['filesDir'] as string}/flashcat/rum`;
  return fs.listFileSync(dir).filter((n: string) => n.endsWith('.ndjson')).length;
}

export default function filePersistenceTests(): void {
  describe('FilePersistence', (): void => {
    it('migrationDropsEventsOlderThanRetentionWindow',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const persistence: FilePersistenceStrategy =
          new FilePersistenceStrategy(fakeContext(), 'rum');
        const staleMs: number = Date.now() - 30 * 60 * 60 * 1000; // 30 h old
        const freshMs: number = Date.now() - 60 * 1000;

        expect(persistence.writePending(eventLine(staleMs, 'stale'))).assertTrue();
        expect(persistence.writePending(eventLine(freshMs, 'fresh'))).assertTrue();
        persistence.migratePending();

        const uploaded: string = readAllBatches(persistence);
        // The intake silently discards >24 h events — migrating them is waste.
        expect(uploaded.indexOf('stale')).assertEqual(-1);
        expect(uploaded.indexOf('fresh') >= 0).assertTrue();
      });

    it('fullPendingBufferEvictsOldestHalfNotNewWrites',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const persistence: FilePersistenceStrategy =
          new FilePersistenceStrategy(fakeContext(), 'rum');
        // ~1 KB per line; the 4 MB cap needs ~4100 lines to trip.
        const filler: string = 'x'.repeat(1000);
        const total: number = 4200;
        for (let i: number = 0; i < total; i++) {
          persistence.writePending(`{"type":"view","date":${Date.now()},"seq":${i},"pad":"${filler}"}`);
        }
        persistence.migratePending();
        const uploaded: string = readAllBatches(persistence);
        // The NEWEST write must have survived; the very first must be gone.
        expect(uploaded.indexOf(`"seq":${total - 1},`) >= 0).assertTrue();
        expect(uploaded.indexOf('"seq":0,')).assertEqual(-1);
      });

    it('wipeAllRemovesCollectedBatchesAndPending',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const ctx: common.Context = fakeContext();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(ctx, 'rum');
        persistence.write(eventLine(Date.now(), 'collected'), true);
        persistence.writePending(eventLine(Date.now(), 'buffered'));

        persistence.wipeAll();

        expect(persistence.readNextBatch()).assertNull();
        persistence.migratePending();
        expect(persistence.readNextBatch()).assertNull();
      });

    it('tornTrailingLineIsDroppedNotShipped',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const ctx: common.Context = fakeContext();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(ctx, 'rum');
        persistence.write(eventLine(Date.now(), 'good'), true);

        // Simulate a mid-append kill: raw partial JSON without trailing newline.
        const dir: string = `${(ctx as Object as Record<string, Object>)['filesDir'] as string}/flashcat/rum`;
        const names: string[] = fs.listFileSync(dir)
          .filter((n: string) => n.endsWith('.ndjson'));
        const file = fs.openSync(`${dir}/${names[0]}`,
          fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
        fs.writeSync(file.fd, '{"type":"view","date":123,"torn');
        fs.closeSync(file);

        const batch: Batch | null = persistence.readNextBatch();
        expect(batch !== null).assertTrue();
        if (batch !== null) {
          expect(batch.data.indexOf('good') >= 0).assertTrue();
          expect(batch.data.indexOf('torn')).assertEqual(-1);
        }
      });

    it('theByteQuotaBindsNotTheFileCount',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Offline, small batches pile up: 300 of them hold far less than the
        // byte quota and must all be kept (a 200-file cap used to evict them).
        const context: common.Context = fakeContext();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(context, 'rum');
        for (let i: number = 0; i < 300; i++) {
          persistence.write(eventLine(Date.now(), `e${i}`), true);
        }
        expect(batchCount(context)).assertEqual(300);
      });

    it('theByteQuotaStillEvictsTheOldestBatches',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const context: common.Context = fakeContext();
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(context, 'rum');
        const big: string = 'x'.repeat(400 * 1024);
        for (let i: number = 0; i < 14; i++) { // ~5.6 MB written, quota 4 MB
          persistence.write(`{"marker":"m${i}","pad":"${big}"}`, true);
        }
        const kept: string = readAllBatches(persistence);
        expect(kept.indexOf('"m0"')).assertEqual(-1); // the oldest went
        expect(kept.indexOf('"m13"') >= 0).assertTrue(); // the newest stayed
      });

    it('openingABatchDoesNotRescanTheDirectory',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(fakeContext(), 'rum');
        persistence.write(eventLine(Date.now(), 'first'), true); // first quota pass scans once
        const before: Record<string, number> = { 'list': calls()['listFileSync'], 'stat': calls()['statSync'],
          'access': calls()['accessSync'] };
        for (let i: number = 0; i < 200; i++) {
          persistence.write(eventLine(Date.now(), `e${i}`), true); // each opens a new batch
        }
        expect(calls()['statSync'] - before['stat']).assertEqual(0);
        expect(calls()['listFileSync'] - before['list']).assertEqual(0);
        expect(calls()['accessSync'] - before['access']).assertEqual(0); // no dir check per write
      });

    it('filesAnotherProcessDeletedStopCountingAfterTheRescan',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const context: common.Context = fakeContext();
        const dir: string = `${(context as Object as Record<string, Object>)['filesDir'] as string}/flashcat/rum`;
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(context, 'rum');
        for (let i: number = 0; i < 5; i++) {
          persistence.write(eventLine(Date.now(), `keep${i}`), true); // oldest, small
        }
        const keep: string[] = fs.listFileSync(dir);
        const big: string = 'x'.repeat(400 * 1024);
        for (let i: number = 0; i < 9; i++) { // + 3.6 MB, still under the 4 MB quota
          persistence.write(`{"marker":"old${i}","pad":"${big}"}`, true);
        }
        // The deferred-upload process uploads and deletes the big ones.
        for (const n of fs.listFileSync(dir)) {
          if (keep.indexOf(n) < 0) {
            fs.unlinkSync(`${dir}/${n}`);
          }
        }
        const realNow: () => number = Date.now;
        Date.now = (): number => realNow() + 61 * 1000; // past the rescan interval
        try {
          for (let i: number = 0; i < 9; i++) {
            persistence.write(`{"marker":"new${i}","pad":"${big}"}`, true);
          }
        } finally {
          Date.now = realNow;
        }
        // Stale accounting would count 7.2 MB and evict the small, still
        // undelivered batches to make room.
        const left: string[] = fs.listFileSync(dir);
        for (const n of keep) {
          expect(left.indexOf(n) >= 0).assertTrue();
        }
      });

    it('anIdleDrainLooksForOrphanedClaimsAtMostOncePerMinute',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(fakeContext(), 'rum');
        persistence.readNextBatch();
        const before: number = calls()['listFileSync'];
        for (let i: number = 0; i < 10; i++) {
          expect(persistence.readNextBatch()).assertNull();
        }
        // One listing per idle pass (the batch list), not two.
        expect(calls()['listFileSync'] - before).assertEqual(10);
      });
  });
}
