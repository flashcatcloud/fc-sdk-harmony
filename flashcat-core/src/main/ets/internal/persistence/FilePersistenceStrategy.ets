import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FlashcatLog } from '../FlashcatLog';

const MAX_BATCH_BYTES: number = 512 * 1024;       // roll the active file past this size
const MAX_BATCH_AGE_MS: number = 5000;            // …or this age, so events don't linger
const MAX_TOTAL_BYTES: number = 4 * 1024 * 1024;  // disk quota per feature (oldest-evicted)
const MAX_BATCH_COUNT: number = 200;              // file-count quota per feature
const BATCH_PREFIX: string = 'batch-';
const BATCH_SUFFIX: string = '.ndjson';
const UPLOADING_SUFFIX: string = '.uploading';
const UPLOADING_RECOVERY_AGE_MS: number = 10 * 60 * 1000;
const PENDING_DIR: string = 'pending';
const PENDING_FILE: string = 'pending.ndjson';

export interface Batch {
  batchId: string;   // the file name
  originalBatchId?: string;
  data: string;      // NDJSON payload (one event per line)
  eventCount: number;
}

export interface UploadPersistence {
  readNextBatch(): Batch | null;
  deleteBatch(batchId: string): void;
  restoreBatch(batch: Batch): void;
}

/**
 * Disk-backed event batching, per feature. Granted events go to the main dir as
 * NDJSON batch files; the active file is rolled (closed) on size/age, or on demand
 * (forceFlush / flush). PENDING (pre-consent) events buffer in a separate `pending/`
 * file, migrated into the main dir on GRANTED or wiped on NOT_GRANTED. A disk quota
 * evicts the oldest batches. Mirrors Android's FilePersistenceStrategy + consent dirs.
 */
export class FilePersistenceStrategy implements UploadPersistence {
  private readonly rootDir: string;
  private readonly pendingDir: string;
  private activeName: string | null = null;   // basename of the active main batch file
  private activeCreatedMs: number = 0;
  private activeBytes: number = 0;
  private seq: number = 0;

  constructor(context: common.Context, featureName: string) {
    const filesDir: string = context.filesDir;
    this.rootDir = `${filesDir}/flashcat/${featureName}`;
    this.pendingDir = `${this.rootDir}/${PENDING_DIR}`;
    FlashcatLog.d(`persistence[${featureName}]: filesDir=${filesDir} rootDir=${this.rootDir}`);
    this.ensureDir(this.rootDir);
    this.restoreUploadingBatches();
  }

  private ensureDir(dir: string): void {
    // accessSync can THROW (not return false) when the path is missing on some
    // HarmonyOS versions, so never gate mkdir on it. Create recursively and treat
    // an "already exists" failure as success.
    let exists: boolean = false;
    try {
      exists = fs.accessSync(dir);
    } catch (_a) {
      exists = false;
    }
    if (exists) {
      return;
    }
    try {
      fs.mkdirSync(dir, true); // recursive: creates intermediate dirs too
    } catch (_e) {
      // Possibly created concurrently / already present — verify, else log.
      let ok: boolean = false;
      try {
        ok = fs.accessSync(dir);
      } catch (_v) {
        ok = false;
      }
      if (!ok) {
        FlashcatLog.e(`ensureDir failed for ${dir}`);
      }
    }
  }

  // ---- main (granted) writes ----

  /** Append one serialized event. When forceRoll, close the file immediately so it
   *  becomes drainable on the next scheduler tick (used for error/crash events). */
  write(serializedEvent: string, forceRoll: boolean = false): boolean {
    const line: string = serializedEvent + '\n';
    this.ensureDir(this.rootDir); // self-heal if the dir wasn't created at construction
    const now: number = Date.now();
    if (this.activeName === null || this.shouldRoll(now, line.length)) {
      this.openNewActive(now);
    }
    const name: string = this.activeName as string;
    const ok: boolean = FilePersistenceStrategy.append(`${this.rootDir}/${name}`, line);
    if (ok) {
      this.activeBytes += line.length;
    } else {
      this.activeName = null;
      this.activeBytes = 0;
    }
    FlashcatLog.d(`persist.write: ok=${ok} forceRoll=${forceRoll} batch=${name} dir=${this.rootDir}`);
    if (forceRoll) {
      this.activeName = null; // close so the just-written event is immediately drainable
    }
    return ok;
  }

  /** Close the active file so buffered events become drainable (flush on background/stop). */
  rollActive(): void {
    this.activeName = null;
  }

  private shouldRoll(now: number, incomingBytes: number): boolean {
    return (this.activeBytes + incomingBytes) > MAX_BATCH_BYTES
      || (now - this.activeCreatedMs) > MAX_BATCH_AGE_MS;
  }

  private openNewActive(now: number): void {
    this.enforceQuota();
    this.seq += 1;
    const rand: number = Math.floor(Math.random() * 1e6);
    this.activeName = `${BATCH_PREFIX}${now}-${this.seq}-${rand}${BATCH_SUFFIX}`;
    this.activeCreatedMs = now;
    this.activeBytes = 0;
  }

  // ---- pending (pre-consent) buffer ----

  writePending(serializedEvent: string): boolean {
    this.ensureDir(this.pendingDir);
    return FilePersistenceStrategy.append(`${this.pendingDir}/${PENDING_FILE}`, serializedEvent + '\n');
  }

  /** GRANTED transition: move buffered pending events into the main dir as a batch. */
  migratePending(): void {
    const path: string = `${this.pendingDir}/${PENDING_FILE}`;
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const data: string = fs.readTextSync(path);
      fs.unlinkSync(path);
      if (data.length > 0) {
        const now: number = Date.now();
        this.seq += 1;
        const rand: number = Math.floor(Math.random() * 1e6);
        const name: string = `${BATCH_PREFIX}${now}-${this.seq}-${rand}${BATCH_SUFFIX}`;
        FilePersistenceStrategy.append(`${this.rootDir}/${name}`, data.endsWith('\n') ? data : data + '\n');
      }
    } catch (_e) {
      // best-effort
    }
  }

  /** NOT_GRANTED transition: discard pre-consent buffer. */
  wipePending(): void {
    try {
      const path: string = `${this.pendingDir}/${PENDING_FILE}`;
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (_e) {
      // best-effort
    }
  }

  // ---- drain ----

  /** Oldest closed batch ready to upload; ages out the active file first if stale. */
  readNextBatch(): Batch | null {
    const now: number = Date.now();
    if (this.activeName !== null && (now - this.activeCreatedMs) > MAX_BATCH_AGE_MS) {
      this.activeName = null; // close so it's eligible in this same pass
    }
    const all: string[] = this.listBatches();
    const ready: string[] = all.filter((n: string) => n !== this.activeName);
    if (ready.length === 0) {
      return null; // idle — silent to avoid per-tick spam
    }
    const originalName: string = ready[0];
    const name: string = FilePersistenceStrategy.claimedName(originalName);
    try {
      fs.renameSync(`${this.rootDir}/${originalName}`, `${this.rootDir}/${name}`);
    } catch (_claimErr) {
      return null;
    }
    const path: string = `${this.rootDir}/${name}`;
    try {
      const data: string = fs.readTextSync(path);
      const trimmed: string = data.endsWith('\n') ? data.slice(0, data.length - 1) : data;
      if (trimmed.length === 0) {
        this.deleteBatch(name);
        return null;
      }
      const lines: string[] = trimmed.split('\n').filter((l: string) => l.length > 0);
      return { batchId: name, originalBatchId: originalName, data: lines.join('\n'), eventCount: lines.length };
    } catch (_e) {
      this.restoreBatch({ batchId: name, originalBatchId: originalName, data: '', eventCount: 0 });
      return null;
    }
  }

  deleteBatch(batchId: string): void {
    try {
      fs.unlinkSync(`${this.rootDir}/${batchId}`);
    } catch (_e) {
      // Already gone.
    }
  }

  restoreBatch(batch: Batch): void {
    const originalName: string = batch.originalBatchId ?? FilePersistenceStrategy.originalName(batch.batchId);
    if (originalName === batch.batchId) {
      return;
    }
    try {
      fs.renameSync(`${this.rootDir}/${batch.batchId}`, `${this.rootDir}/${originalName}`);
    } catch (_e) {
      // Already gone or restored.
    }
  }

  // ---- helpers ----

  private listBatches(): string[] {
    try {
      return fs.listFileSync(this.rootDir)
        .filter((n: string) => n.startsWith(BATCH_PREFIX) && n.endsWith(BATCH_SUFFIX))
        .sort();
    } catch (_e) {
      return [];
    }
  }

  private restoreUploadingBatches(): void {
    try {
      const names: string[] = fs.listFileSync(this.rootDir)
        .filter((n: string) => n.startsWith(BATCH_PREFIX) && n.endsWith(`${BATCH_SUFFIX}${UPLOADING_SUFFIX}`))
        .sort();
      const nowMs: number = Date.now();
      for (const name of names) {
        if (!FilePersistenceStrategy.shouldRestoreClaimedBatch(name, nowMs)) {
          continue;
        }
        const originalName: string = FilePersistenceStrategy.originalName(name);
        try {
          fs.renameSync(`${this.rootDir}/${name}`, `${this.rootDir}/${originalName}`);
        } catch (_e) {
          // best-effort recovery
        }
      }
    } catch (_e) {
      // best-effort recovery
    }
  }

  static shouldRestoreClaimedBatch(batchId: string, nowMs: number): boolean {
    if (!batchId.startsWith(BATCH_PREFIX) || !batchId.endsWith(`${BATCH_SUFFIX}${UPLOADING_SUFFIX}`)) {
      return false;
    }
    const start: number = BATCH_PREFIX.length;
    const end: number = batchId.indexOf('-', start);
    if (end <= start) {
      return false;
    }
    const startedAtMs: number = Number(batchId.slice(start, end));
    return startedAtMs > 0 && (nowMs - startedAtMs) >= UPLOADING_RECOVERY_AGE_MS;
  }

  private static claimedName(batchId: string): string {
    return batchId.endsWith(UPLOADING_SUFFIX) ? batchId : `${batchId}${UPLOADING_SUFFIX}`;
  }

  private static originalName(batchId: string): string {
    return batchId.endsWith(UPLOADING_SUFFIX)
      ? batchId.slice(0, batchId.length - UPLOADING_SUFFIX.length)
      : batchId;
  }

  /** Evict oldest batches when over the file-count or total-byte quota. */
  private enforceQuota(): void {
    let batches: string[] = this.listBatches();
    let total: number = 0;
    for (const n of batches) {
      total += FilePersistenceStrategy.sizeOf(`${this.rootDir}/${n}`);
    }
    let i: number = 0;
    while ((batches.length - i) > MAX_BATCH_COUNT || total > MAX_TOTAL_BYTES) {
      if (i >= batches.length) {
        break;
      }
      const victim: string = batches[i];
      total -= FilePersistenceStrategy.sizeOf(`${this.rootDir}/${victim}`);
      this.deleteBatch(victim);
      i += 1;
    }
  }

  private static append(path: string, content: string): boolean {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(file.fd, content);
        return true;
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      FlashcatLog.e(`append failed path=${path}: ${FilePersistenceStrategy.errorText(e)}`);
      return false;
    }
  }

  private static sizeOf(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (_e) {
      return 0;
    }
  }

  private static errorText(value: Object): string {
    if (value instanceof Error) {
      return value.message;
    }
    return `${value}`;
  }
}
