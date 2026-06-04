import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { systemDateTime } from '@kit.BasicServicesKit';

const MAX_BATCH_BYTES: number = 512 * 1024;       // roll the active file past this size
const MAX_BATCH_AGE_MS: number = 5000;            // …or this age, so events don't linger
const MAX_TOTAL_BYTES: number = 4 * 1024 * 1024;  // disk quota per feature (oldest-evicted)
const MAX_BATCH_COUNT: number = 200;              // file-count quota per feature
const BATCH_PREFIX: string = 'batch-';
const BATCH_SUFFIX: string = '.ndjson';
const PENDING_DIR: string = 'pending';
const PENDING_FILE: string = 'pending.ndjson';

export interface Batch {
  batchId: string;   // the file name
  data: string;      // NDJSON payload (one event per line)
  eventCount: number;
}

/**
 * Disk-backed event batching, per feature. Granted events go to the main dir as
 * NDJSON batch files; the active file is rolled (closed) on size/age, or on demand
 * (forceFlush / flush). PENDING (pre-consent) events buffer in a separate `pending/`
 * file, migrated into the main dir on GRANTED or wiped on NOT_GRANTED. A disk quota
 * evicts the oldest batches. Mirrors Android's FilePersistenceStrategy + consent dirs.
 */
export class FilePersistenceStrategy {
  private readonly rootDir: string;
  private readonly pendingDir: string;
  private activeName: string | null = null;   // basename of the active main batch file
  private activeCreatedMs: number = 0;
  private activeBytes: number = 0;
  private seq: number = 0;

  constructor(context: common.Context, featureName: string) {
    this.rootDir = `${context.filesDir}/flashcat/${featureName}`;
    this.pendingDir = `${this.rootDir}/${PENDING_DIR}`;
    this.ensureDir(this.rootDir);
  }

  private ensureDir(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (_e) {
      // Storage unavailable — writes will no-op below.
    }
  }

  // ---- main (granted) writes ----

  /** Append one serialized event. When forceRoll, close the file immediately so it
   *  becomes drainable on the next scheduler tick (used for error/crash events). */
  write(serializedEvent: string, forceRoll: boolean = false): boolean {
    const line: string = serializedEvent + '\n';
    const now: number = systemDateTime.getTime();
    if (this.activeName === null || this.shouldRoll(now, line.length)) {
      this.openNewActive(now);
    }
    const name: string = this.activeName as string;
    const ok: boolean = FilePersistenceStrategy.append(`${this.rootDir}/${name}`, line);
    if (ok) {
      this.activeBytes += line.length;
    }
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
        const now: number = systemDateTime.getTime();
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
    const now: number = systemDateTime.getTime();
    if (this.activeName !== null && (now - this.activeCreatedMs) > MAX_BATCH_AGE_MS) {
      this.activeName = null; // close so it's eligible in this same pass
    }
    const ready: string[] = this.listBatches().filter((n: string) => n !== this.activeName);
    if (ready.length === 0) {
      return null;
    }
    const name: string = ready[0];
    const path: string = `${this.rootDir}/${name}`;
    try {
      const data: string = fs.readTextSync(path);
      const trimmed: string = data.endsWith('\n') ? data.slice(0, data.length - 1) : data;
      if (trimmed.length === 0) {
        this.deleteBatch(name);
        return null;
      }
      const lines: string[] = trimmed.split('\n').filter((l: string) => l.length > 0);
      return { batchId: name, data: lines.join('\n'), eventCount: lines.length };
    } catch (_e) {
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
    } catch (_e) {
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
}
