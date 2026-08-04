import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FeatureEventReceiver } from '../../api/feature/Feature';
import { FlashcatLog } from '../FlashcatLog';

export const CRASH_STORAGE_TARGET: string = '__flashcat_crash_storage';

const INCIDENT_PREFIX: string = 'incident-';
const INCIDENT_SUFFIX: string = '.json';
const CONSUMED_FILE: string = 'consumed.json';
const LOOP_FILE: string = 'loop.json';
// Snapshot of the most recently written ViewEvent. Faults the SDK cannot
// observe in-process (native crashes, freezes) carry no RUM identity of their
// own, so on the next launch this is the only record of which session/view the
// app was in when it died. Mirrors the Android SDK's `lastViewEvent`.
const LAST_VIEW_FILE: string = 'last-view.json';
const TMP_SUFFIX: string = '.tmp';
// A ViewEvent is re-emitted on every action/error/resource, so this file is
// rewritten far more often than the other sidecars. Cap it so a pathological
// context payload cannot bloat the crash dir.
const MAX_LAST_VIEW_BYTES: number = 256 * 1024;
// Cap on pending incident files. Unreplayed incidents accumulate when the RUM
// feature is never enabled (or delivery keeps failing) — without a cap the dir
// grows by one file per crash forever. Oldest are evicted first (name sort =
// UUID order, but eviction only triggers in pathological no-replay setups).
const MAX_PENDING_INCIDENTS: number = 32;

/**
 * Core-owned synchronous crash storage. Feature modules intentionally do not
 * receive a HarmonyOS Context, so the crash feature reaches this store through
 * the existing synchronous MessageBus. Files live outside upload batches.
 */
export class CrashPendingStore implements FeatureEventReceiver {
  private readonly rootDir: string;

  constructor(context: common.Context, sweepOrphans: boolean = true) {
    this.rootDir = `${context.filesDir}/flashcat/crash-pending`;
    // Only the MAIN process sweeps: the extension process shares this dir, and
    // its sweep could unlink a tmp file the main process is writing at crash
    // time (the "no write in flight" invariant is process-local).
    if (sweepOrphans) {
      this.sweepTmpOrphans();
    }
  }

  /**
   * Delete `*.tmp` files left by a kill between the atomic write's tmp-write
   * and rename — the crash path runs writes precisely while the process is
   * being torn down, incident tmp names carry a UUID, and every reader filters
   * on `.json`, so without this sweep each such kill leaks a file forever.
   * At construction time no write of ours is in flight, so any tmp is orphaned.
   */
  private sweepTmpOrphans(): void {
    try {
      const names: string[] = fs.listFileSync(this.rootDir)
        .filter((name: string): boolean => name.endsWith(TMP_SUFFIX));
      for (const name of names) {
        try {
          fs.unlinkSync(`${this.rootDir}/${name}`);
        } catch (_e) {
          // best-effort
        }
      }
    } catch (_e) {
      // directory may not exist yet
    }
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
    } else if (type === 'crash_storage_write_last_view') {
      event['success'] = this.writeLastView(
        CrashPendingStore.stringValue(event['serialized']));
    } else if (type === 'crash_storage_read_last_view') {
      event['serialized'] = this.readSidecar(LAST_VIEW_FILE);
    }
  }

  /**
   * Persist the latest ViewEvent. Deliberately NOT the atomic fsync path the
   * other sidecars use: this runs on every view write (i.e. after every action,
   * error and resource), and an fsync per event would put disk latency on the
   * hot path. Losing the newest snapshot to a hard kill is acceptable — the
   * previous one is at most one document_version behind, and a stale snapshot
   * still attributes the crash to the right session and view.
   */
  private writeLastView(serialized: string): boolean {
    if (serialized.length === 0 || serialized.length > MAX_LAST_VIEW_BYTES) {
      return false;
    }
    this.ensureDir();
    const path: string = `${this.rootDir}/${LAST_VIEW_FILE}`;
    try {
      const mode: number = fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
      const file: fs.File = fs.openSync(path, mode);
      try {
        fs.writeSync(file.fd, serialized);
        return true;
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      FlashcatLog.e(`crash.storage: last-view write failed: ${CrashPendingStore.errorText(error)}`);
      return false;
    }
  }

  private writeIncident(incidentId: string, serialized: string): boolean {
    if (incidentId.length === 0 || serialized.length === 0) {
      return false;
    }
    this.ensureDir();
    this.enforceIncidentQuota();
    return this.writeFile(
      `${this.rootDir}/${INCIDENT_PREFIX}${incidentId}${INCIDENT_SUFFIX}`,
      serialized);
  }

  /** Evict oldest incident files so the dir stays bounded when replay never runs. */
  private enforceIncidentQuota(): void {
    try {
      const names: string[] = fs.listFileSync(this.rootDir)
        .filter((name: string): boolean =>
          name.startsWith(INCIDENT_PREFIX) && name.endsWith(INCIDENT_SUFFIX))
        .sort();
      for (let i: number = 0; i <= names.length - MAX_PENDING_INCIDENTS; i++) {
        try {
          fs.unlinkSync(`${this.rootDir}/${names[i]}`);
        } catch (_e) {
          // best-effort
        }
      }
    } catch (_e) {
      // best-effort
    }
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
    // Validate the id segment too — prefix/suffix checks alone let a crafted
    // "incident-../../x.json" escape rootDir.
    const id: string = fileName.substring(
      INCIDENT_PREFIX.length, fileName.length - INCIDENT_SUFFIX.length);
    if (id.length === 0 || CrashPendingStore.safeId(id).length === 0) {
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

  /**
   * Atomic write: temp file + fsync + rename. TRUNC-in-place emptied the target
   * before the new content landed, so a kill mid-write reset the file — for
   * loop.json that resets the crash-loop guard exactly when it's needed (the
   * write happens on the crash path right before process exit), letting a
   * boot-crash restart loop run unbounded.
   */
  private writeFile(path: string, content: string): boolean {
    this.ensureDir();
    const tmpPath: string = `${path}.tmp`;
    try {
      const mode: number = fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE |
        fs.OpenMode.TRUNC | fs.OpenMode.SYNC;
      const file: fs.File = fs.openSync(tmpPath, mode);
      try {
        fs.writeSync(file.fd, content);
        fs.fsyncSync(file.fd);
      } finally {
        fs.closeSync(file);
      }
      fs.renameSync(tmpPath, path);
      return true;
    } catch (error) {
      FlashcatLog.e(`crash.storage: synchronous write failed: ${CrashPendingStore.errorText(error)}`);
      try {
        fs.unlinkSync(tmpPath);
      } catch (_cleanup) {
        // best-effort temp cleanup
      }
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
