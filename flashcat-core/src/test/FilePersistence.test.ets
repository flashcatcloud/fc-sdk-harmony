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
  });
}
