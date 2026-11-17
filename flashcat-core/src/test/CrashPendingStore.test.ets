import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { CrashPendingStore } from '../main/ets/internal/persistence/CrashPendingStore';

let seq: number = 0;

function storeIn(dir: string): CrashPendingStore {
  return new CrashPendingStore({ 'filesDir': dir } as Object as common.Context, false);
}

function command(store: CrashPendingStore, fields: Record<string, Object>): Record<string, Object> {
  store.onReceive(fields);
  return fields;
}

function writeLastView(store: CrashPendingStore, serialized: string): boolean {
  return command(store, { 'type': 'crash_storage_write_last_view', 'serialized': serialized })['success'] === true;
}

function readLastView(store: CrashPendingStore): string {
  return command(store, { 'type': 'crash_storage_read_last_view' })['serialized'] as string;
}

export default function crashPendingStoreTests(): void {
  describe('CrashPendingStore', (): void => {
    it('aLastViewWriteReplacesTheFileWholeOrNotAtAll',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const filesDir: string = `/tmp/flashcat-crash-store-test-${Date.now()}-${seq++}`;
        const store: CrashPendingStore = storeIn(filesDir);
        expect(writeLastView(store, '{"pid":1,"session":{"id":"a","sampled":true}}')).assertTrue();
        // The write cannot complete (here: its temp file cannot be created, as when the
        // process dies between the two steps): the file on disk is still the whole earlier
        // one, never a truncated one the next launch could not parse.
        const tmp: string = `${filesDir}/flashcat/crash-pending/last-view.json.tmp`;
        fs.mkdirSync(tmp);
        expect(writeLastView(store, '{"pid":1,"session":{"id":"b","sampled":true}}')).assertFalse();
        expect(readLastView(store)).assertEqual('{"pid":1,"session":{"id":"a","sampled":true}}');
        // Negative control: once it can, the write lands, whole, and leaves no temp file.
        fs.rmdirSync(tmp);
        expect(writeLastView(store, '{"pid":1,"session":{"id":"b","sampled":true}}')).assertTrue();
        expect(readLastView(store)).assertEqual('{"pid":1,"session":{"id":"b","sampled":true}}');
        expect(fs.accessSync(tmp)).assertFalse();
      });
  });
}
