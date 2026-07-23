import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FeatureEventReceiver } from '../../api/feature/Feature';
import { FlashcatLog } from '../FlashcatLog';

export const CRASH_STORAGE_TARGET: string = '__flashcat_crash_storage';

const INCIDENT_PREFIX: string = 'incident-';
const INCIDENT_SUFFIX: string = '.json';
const CONSUMED_FILE: string = 'consumed.json';
const LOOP_FILE: string = 'loop.json';

/**
 * Core-owned synchronous crash storage. Feature modules intentionally do not
 * receive a HarmonyOS Context, so the crash feature reaches this store through
 * the existing synchronous MessageBus. Files live outside upload batches.
 */
export class CrashPendingStore implements FeatureEventReceiver {
  private readonly rootDir: string;

  constructor(context: common.Context) {
    this.rootDir = `${context.filesDir}/flashcat/crash-pending`;
  }

  onReceive(event: Record<string, Object>): void {
    const type: string = CrashPendingStore.stringValue(event['type']);
    if (type === 'crash_storage_write') {
      const incidentId: string = CrashPendingStore.safeId(
        CrashPendingStore.stringValue(event['incident_id']));
      const serialized: string = CrashPendingStore.stringValue(event['serialized']);
      event['success'] = this.writeIncident(incidentId, serialized);
    } else if (type === 'crash_storage_list') {
      event['files'] = this.readIncidents();
    } else if (type === 'crash_storage_delete') {
      this.deleteIncident(CrashPendingStore.stringValue(event['file_name']));
    } else if (type === 'crash_storage_read_consumed') {
      event['serialized'] = this.readConsumed();
    } else if (type === 'crash_storage_write_consumed') {
      event['success'] = this.writeFile(
        `${this.rootDir}/${CONSUMED_FILE}`,
        CrashPendingStore.stringValue(event['serialized']));
    } else if (type === 'crash_storage_read_loop') {
      event['serialized'] = this.readSidecar(LOOP_FILE);
    } else if (type === 'crash_storage_write_loop') {
      event['success'] = this.writeFile(
        `${this.rootDir}/${LOOP_FILE}`,
        CrashPendingStore.stringValue(event['serialized']));
    }
  }

  private writeIncident(incidentId: string, serialized: string): boolean {
    if (incidentId.length === 0 || serialized.length === 0) {
      return false;
    }
    this.ensureDir();
    return this.writeFile(
      `${this.rootDir}/${INCIDENT_PREFIX}${incidentId}${INCIDENT_SUFFIX}`,
      serialized);
  }

  private readIncidents(): Array<Record<string, Object>> {
    const records: Array<Record<string, Object>> = [];
    try {
      const names: string[] = fs.listFileSync(this.rootDir)
        .filter((name: string): boolean =>
          name.startsWith(INCIDENT_PREFIX) && name.endsWith(INCIDENT_SUFFIX))
        .sort();
      for (let i: number = 0; i < names.length; i++) {
        const name: string = names[i];
        let serialized: string = '';
        try {
          serialized = fs.readTextSync(`${this.rootDir}/${name}`);
        } catch (_error) {
          serialized = '';
        }
        records.push({ 'file_name': name, 'serialized': serialized });
      }
    } catch (_error) {
      return records;
    }
    return records;
  }

  private deleteIncident(fileName: string): void {
    if (!fileName.startsWith(INCIDENT_PREFIX) || !fileName.endsWith(INCIDENT_SUFFIX)) {
      return;
    }
    try {
      fs.unlinkSync(`${this.rootDir}/${fileName}`);
    } catch (_error) {
      // Already deleted or unavailable.
    }
  }

  private readConsumed(): string {
    return this.readSidecar(CONSUMED_FILE);
  }

  private readSidecar(fileName: string): string {
    try {
      return fs.readTextSync(`${this.rootDir}/${fileName}`);
    } catch (_error) {
      return '';
    }
  }

  private writeFile(path: string, content: string): boolean {
    this.ensureDir();
    try {
      const mode: number = fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE |
        fs.OpenMode.TRUNC | fs.OpenMode.SYNC;
      const file: fs.File = fs.openSync(path, mode);
      try {
        fs.writeSync(file.fd, content);
        fs.fsyncSync(file.fd);
        return true;
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      FlashcatLog.e(`crash.storage: synchronous write failed: ${CrashPendingStore.errorText(error)}`);
      return false;
    }
  }

  private ensureDir(): void {
    let exists: boolean = false;
    try {
      exists = fs.accessSync(this.rootDir);
    } catch (_error) {
      exists = false;
    }
    if (exists) {
      return;
    }
    try {
      fs.mkdirSync(this.rootDir, true);
    } catch (_error) {
      // A concurrent initializer may have created it; writes report real failures.
    }
  }

  private static safeId(value: string): string {
    for (let i: number = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      const valid: boolean = (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code === 45;
      if (!valid) {
        return '';
      }
    }
    return value;
  }

  private static stringValue(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private static errorText(value: Object): string {
    return value instanceof Error ? value.message : `${value}`;
  }
}
