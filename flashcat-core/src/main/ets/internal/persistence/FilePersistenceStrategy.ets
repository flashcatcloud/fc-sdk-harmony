import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FlashcatLog } from '../FlashcatLog';

const MAX_BATCH_BYTES: number = 512 * 1024;       // roll the active file past this size (UTF-8 bytes)
const MAX_BATCH_AGE_MS: number = 5000;            // …or this age, so events don't linger
const MAX_TOTAL_BYTES: number = 4 * 1024 * 1024;  // disk quota per feature (oldest-evicted)
const MAX_BATCH_COUNT: number = 200;              // file-count quota per feature
// Batches older than this are deleted instead of uploaded: the intake discards
// events older than 24 h per-event (isDateOK) while still returning 2xx, so
// uploading them is silent loss plus wasted traffic. Kept below 24 h for margin.
const MAX_BATCH_RETENTION_MS: number = 23 * 60 * 60 * 1000;
// A single event may not exceed one batch — an oversized event would produce an
// undeliverable batch (intake body cap) that then gets DROPped whole.
const MAX_EVENT_BYTES: number = MAX_BATCH_BYTES;
const BATCH_PREFIX: string = 'batch-';
const BATCH_SUFFIX: string = '.ndjson';
const UPLOADING_SUFFIX: string = '.uploading';
const UPLOADING_RECOVERY_AGE_MS: number = 10 * 60 * 1000;
// A batch created by ANOTHER process may still be that process's active file
// (appended without any cross-process lock). Owners never append to a file older
// than MAX_BATCH_AGE_MS (shouldRoll opens a new one), so a foreign batch becomes
// safe to claim once it is past the roll age plus slack for an in-flight append.
const FOREIGN_CLAIM_SLACK_MS: number = 2000;
const PENDING_DIR: string = 'pending';
const PENDING_FILE: string = 'pending.ndjson';
// The pre-consent buffer is a single append-only file; without a cap an app that
// stays PENDING grows it without limit (keep-alive alone is ~240 KB/h).
const MAX_PENDING_BYTES: number = 4 * 1024 * 1024;

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
  // Batch files THIS instance created: always safe to claim regardless of age
  // (their roll state is known locally). Bounded by the file-count quota.
  private readonly ownNames: Set<string> = new Set<string>();
  private pendingBytes: number = -1;          // -1 = not yet read from disk
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
    // Account in UTF-8 bytes (what actually lands on disk / on the wire), not
    // UTF-16 code units — for CJK content the difference is ~3× and pushed real
    // batch sizes past the intake body cap.
    const lineBytes: number = FilePersistenceStrategy.utf8Length(line);
    if (lineBytes > MAX_EVENT_BYTES) {
      FlashcatLog.e(`persist.write: dropped oversized event (${lineBytes} bytes > ${MAX_EVENT_BYTES})`);
      return false;
    }
    this.ensureDir(this.rootDir); // self-heal if the dir wasn't created at construction
    const now: number = Date.now();
    if (this.activeName === null || this.shouldRoll(now, lineBytes)) {
      this.openNewActive(now);
    }
    const name: string = this.activeName as string;
    const ok: boolean = FilePersistenceStrategy.append(`${this.rootDir}/${name}`, line);
    if (ok) {
      this.activeBytes += lineBytes;
    } else {
      this.ownNames.delete(name); // the file may not exist — don't track it
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
    this.ownNames.add(this.activeName);
  }

  // ---- pending (pre-consent) buffer ----

  writePending(serializedEvent: string): boolean {
    this.ensureDir(this.pendingDir);
    const line: string = serializedEvent + '\n';
    const lineBytes: number = FilePersistenceStrategy.utf8Length(line);
    if (lineBytes > MAX_EVENT_BYTES) {
      return false;
    }
    const path: string = `${this.pendingDir}/${PENDING_FILE}`;
    if (this.pendingBytes < 0) {
      this.pendingBytes = FilePersistenceStrategy.sizeOf(path); // lazy init from disk
    }
    if (this.pendingBytes + lineBytes > MAX_PENDING_BYTES) {
      // Evict the OLDEST half. Dropping the incoming write kept the stalest
      // data (which the intake will discard as >24 h anyway) and lost exactly
      // the events that would still be deliverable on a late GRANT.
      this.trimPendingOldest(path);
      if (this.pendingBytes + lineBytes > MAX_PENDING_BYTES) {
        return false; // single line larger than half the cap — give up
      }
    }
    const ok: boolean = FilePersistenceStrategy.append(path, line);
    if (ok) {
      this.pendingBytes += lineBytes;
    }
    return ok;
  }

  /**
   * GRANTED transition: move buffered pending events into the main dir, split
   * into normally-sized batches (one giant batch would exceed the intake body
   * cap and be DROPped whole). Batches are written BEFORE the pending file is
   * unlinked, so a crash mid-migration duplicates at most, never loses.
   */
  migratePending(): void {
    const path: string = `${this.pendingDir}/${PENDING_FILE}`;
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const data: string = fs.readTextSync(path);
      if (data.length > 0) {
        // Age-filter: migrated batches are named with TODAY's timestamp, so the
        // 23 h batch age-out can never catch stale pending events — and the
        // intake 2xx-discards >24 h events. Uploading them is pure waste.
        const cutoffMs: number = Date.now() - MAX_BATCH_RETENTION_MS;
        const lines: string[] = data.split('\n')
          .filter((l: string) => l.length > 0)
          .filter((l: string) => {
            const dateMs: number = FilePersistenceStrategy.eventDateMs(l);
            return dateMs === 0 || dateMs >= cutoffMs; // unparseable → keep
          });
        let chunk: string[] = [];
        let chunkBytes: number = 0;
        for (const l of lines) {
          const bytes: number = FilePersistenceStrategy.utf8Length(l) + 1;
          if (chunk.length > 0 && chunkBytes + bytes > MAX_BATCH_BYTES) {
            this.writeMigratedBatch(chunk);
            chunk = [];
            chunkBytes = 0;
          }
          chunk.push(l);
          chunkBytes += bytes;
        }
        if (chunk.length > 0) {
          this.writeMigratedBatch(chunk);
        }
      }
      FilePersistenceStrategy.removeOrTruncate(path);
      this.pendingBytes = 0;
    } catch (_e) {
      // best-effort
    }
  }

  /**
   * The migrated batches are already written when this runs, so the pending
   * file MUST not survive with content: a failed unlink would re-migrate every
   * event on the next GRANTED settle (unbounded duplication). Fall back to
   * truncating in place when the unlink itself fails.
   */
  private static removeOrTruncate(path: string): void {
    try {
      fs.unlinkSync(path);
      return;
    } catch (_unlinkErr) {
      // fall through to truncate
    }
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.closeSync(file);
    } catch (_truncErr) {
      FlashcatLog.e('persist.migrate: pending file could not be removed or truncated');
    }
  }

  private writeMigratedBatch(lines: string[]): void {
    this.enforceQuota(); // migration must not bypass the per-feature disk cap
    const now: number = Date.now();
    this.seq += 1;
    const rand: number = Math.floor(Math.random() * 1e6);
    const name: string = `${BATCH_PREFIX}${now}-${this.seq}-${rand}${BATCH_SUFFIX}`;
    FilePersistenceStrategy.append(`${this.rootDir}/${name}`, lines.join('\n') + '\n');
  }

  /** Rewrite the pending file keeping only the newer half of its lines. */
  private trimPendingOldest(path: string): void {
    try {
      const data: string = fs.readTextSync(path);
      const lines: string[] = data.split('\n').filter((l: string) => l.length > 0);
      const kept: string[] = lines.slice(Math.ceil(lines.length / 2));
      const content: string = kept.length > 0 ? kept.join('\n') + '\n' : '';
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC | fs.OpenMode.CREATE);
      try {
        if (content.length > 0) {
          fs.writeSync(file.fd, content);
        }
      } finally {
        fs.closeSync(file);
      }
      this.pendingBytes = FilePersistenceStrategy.utf8Length(content);
    } catch (_e) {
      // best-effort — the size guard above still prevents unbounded growth
    }
  }

  /** Extract the event's epoch-ms `date` without a full JSON parse; 0 = unknown. */
  private static eventDateMs(line: string): number {
    const marker: string = '"date":';
    const at: number = line.indexOf(marker);
    if (at < 0) {
      return 0;
    }
    let i: number = at + marker.length;
    while (i < line.length && line.charCodeAt(i) === 32) {
      i += 1;
    }
    let value: number = 0;
    let digits: number = 0;
    while (i < line.length) {
      const c: number = line.charCodeAt(i);
      if (c < 48 || c > 57) {
        break;
      }
      value = value * 10 + (c - 48);
      digits += 1;
      i += 1;
    }
    return digits > 0 ? value : 0;
  }

  /** NOT_GRANTED transition: discard pre-consent buffer. */
  wipePending(): void {
    try {
      const path: string = `${this.pendingDir}/${PENDING_FILE}`;
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      this.pendingBytes = 0;
    } catch (_e) {
      // best-effort
    }
  }

  /**
   * NOT_GRANTED transition: discard EVERYTHING — the pre-consent buffer and the
   * already-collected batches. The schedulers stop on revocation and even the
   * 23 h age-out runs only from a drain, so without this the refused user's
   * data sat on disk indefinitely.
   */
  wipeAll(): void {
    this.wipePending();
    this.activeName = null;
    this.activeBytes = 0;
    this.ownNames.clear();
    try {
      const names: string[] = fs.listFileSync(this.rootDir)
        .filter((n: string) => n.startsWith(BATCH_PREFIX)
          && (n.endsWith(BATCH_SUFFIX) || n.endsWith(UPLOADING_SUFFIX)));
      for (const name of names) {
        try {
          fs.unlinkSync(`${this.rootDir}/${name}`);
        } catch (_e) {
          // best-effort
        }
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
    // Recover stale claims on every drain pass, not only at construction — an
    // orphaned .uploading file (process killed mid-upload) must become drainable
    // within this process's lifetime, not only on some later cold start.
    this.restoreUploadingBatches();
    const all: string[] = this.listBatches();
    const ready: string[] = all.filter((n: string) => n !== this.activeName);
    for (const originalName of ready) {
      // Age out batches the intake would silently discard per-event anyway.
      const createdMs: number = FilePersistenceStrategy.batchCreatedMs(originalName);
      if (createdMs > 0 && (now - createdMs) > MAX_BATCH_RETENTION_MS) {
        this.deleteBatch(originalName);
        continue;
      }
      // Never claim what may be the OTHER process's active file — its owner
      // appends with no cross-process lock, and claiming it silently loses
      // acknowledged writes (or clobbers them on a later restore).
      if (!this.ownNames.has(originalName)
        && createdMs > 0 && (now - createdMs) <= MAX_BATCH_AGE_MS + FOREIGN_CLAIM_SLACK_MS) {
        continue;
      }
      // The claim carries its own timestamp so stale-claim recovery is keyed on
      // when the upload STARTED, not when the batch was created — otherwise a
      // live upload of an old batch gets stolen by the other process.
      const name: string = FilePersistenceStrategy.claimedName(originalName, now);
      try {
        fs.renameSync(`${this.rootDir}/${originalName}`, `${this.rootDir}/${name}`);
      } catch (_claimErr) {
        continue; // lost the claim race — try the next candidate, don't abort the drain
      }
      const path: string = `${this.rootDir}/${name}`;
      try {
        const data: string = fs.readTextSync(path);
        const lines: string[] = FilePersistenceStrategy.completeLines(data);
        if (lines.length === 0) {
          this.deleteBatch(name);
          continue;
        }
        return { batchId: name, originalBatchId: originalName, data: lines.join('\n'), eventCount: lines.length };
      } catch (_e) {
        this.restoreBatch({ batchId: name, originalBatchId: originalName, data: '', eventCount: 0 });
        continue;
      }
    }
    return null; // idle — silent to avoid per-tick spam
  }

  /**
   * Splits batch data into complete NDJSON lines, dropping a torn trailing
   * fragment (process killed mid-append). Shipping the fragment would make the
   * intake reject the whole request and DROP up to 512 KB of good events.
   */
  static completeLines(data: string): string[] {
    const lines: string[] = data.split('\n').filter((l: string) => l.length > 0);
    if (lines.length === 0) {
      return lines;
    }
    if (!data.endsWith('\n')) {
      const last: string = lines[lines.length - 1];
      let torn: boolean = true;
      try {
        JSON.parse(last);
        torn = false;
      } catch (_e) {
        torn = true;
      }
      if (torn) {
        lines.pop();
      }
    }
    return lines;
  }

  deleteBatch(batchId: string): void {
    this.ownNames.delete(FilePersistenceStrategy.originalName(batchId));
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
      fs.renameSync(`${this.rootDir}/${batch.batchId}`, `${this.rootDir}/${this.restoreTargetName(originalName)}`);
    } catch (_e) {
      // Already gone or restored.
    }
  }

  /**
   * Restore destination that never clobbers an existing file: if the original
   * path was recreated in the meantime (defensive — the foreign-claim age gate
   * should prevent it), restore under a fresh unique name instead of renaming
   * over live data.
   */
  private restoreTargetName(originalName: string): string {
    let exists: boolean = false;
    try {
      exists = fs.accessSync(`${this.rootDir}/${originalName}`);
    } catch (_e) {
      exists = false;
    }
    if (!exists) {
      return originalName;
    }
    const stem: string = originalName.slice(0, originalName.length - BATCH_SUFFIX.length);
    return `${stem}-r${Date.now()}${BATCH_SUFFIX}`;
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
        .filter((n: string) => n.startsWith(BATCH_PREFIX) && n.endsWith(UPLOADING_SUFFIX))
        .sort();
      const nowMs: number = Date.now();
      for (const name of names) {
        if (!FilePersistenceStrategy.shouldRestoreClaimedBatch(name, nowMs)) {
          continue;
        }
        const originalName: string = FilePersistenceStrategy.originalName(name);
        try {
          fs.renameSync(`${this.rootDir}/${name}`, `${this.rootDir}/${this.restoreTargetName(originalName)}`);
        } catch (_e) {
          // best-effort recovery
        }
      }
    } catch (_e) {
      // best-effort recovery
    }
  }

  /**
   * A claimed batch is restorable once its CLAIM is stale. The claim timestamp
   * is embedded in the claimed name (`….ndjson.<claimedAtMs>.uploading`); for
   * legacy claims without one (`….ndjson.uploading`), fall back to the batch
   * creation timestamp. Keying recovery on creation time let a live upload of
   * an old batch be stolen by the other process and double-ingested.
   */
  static shouldRestoreClaimedBatch(batchId: string, nowMs: number): boolean {
    if (!batchId.startsWith(BATCH_PREFIX) || !batchId.endsWith(UPLOADING_SUFFIX)) {
      return false;
    }
    const claimedAtMs: number = FilePersistenceStrategy.claimTimestampMs(batchId);
    if (claimedAtMs > 0) {
      return (nowMs - claimedAtMs) >= UPLOADING_RECOVERY_AGE_MS;
    }
    const startedAtMs: number = FilePersistenceStrategy.batchCreatedMs(batchId);
    return startedAtMs > 0 && (nowMs - startedAtMs) >= UPLOADING_RECOVERY_AGE_MS;
  }

  /** Claim timestamp from `….ndjson.<claimedAtMs>.uploading`, or 0 for legacy names. */
  private static claimTimestampMs(batchId: string): number {
    if (!batchId.endsWith(UPLOADING_SUFFIX)) {
      return 0;
    }
    const withoutSuffix: string = batchId.slice(0, batchId.length - UPLOADING_SUFFIX.length);
    if (withoutSuffix.endsWith(BATCH_SUFFIX)) {
      return 0; // legacy claim: no timestamp segment
    }
    const dot: number = withoutSuffix.lastIndexOf('.');
    if (dot <= 0 || !withoutSuffix.substring(0, dot).endsWith(BATCH_SUFFIX)) {
      return 0;
    }
    const ts: number = Number(withoutSuffix.substring(dot + 1));
    return Number.isFinite(ts) && ts > 0 ? ts : 0;
  }

  /** Batch creation timestamp parsed from `batch-<createdMs>-…`. */
  private static batchCreatedMs(batchId: string): number {
    if (!batchId.startsWith(BATCH_PREFIX)) {
      return 0;
    }
    const start: number = BATCH_PREFIX.length;
    const end: number = batchId.indexOf('-', start);
    if (end <= start) {
      return 0;
    }
    const ts: number = Number(batchId.slice(start, end));
    return Number.isFinite(ts) && ts > 0 ? ts : 0;
  }

  private static claimedName(batchId: string, claimedAtMs: number): string {
    return batchId.endsWith(UPLOADING_SUFFIX)
      ? batchId
      : `${batchId}.${claimedAtMs}${UPLOADING_SUFFIX}`;
  }

  private static originalName(batchId: string): string {
    let name: string = batchId;
    if (name.endsWith(UPLOADING_SUFFIX)) {
      name = name.slice(0, name.length - UPLOADING_SUFFIX.length);
    }
    if (!name.endsWith(BATCH_SUFFIX)) {
      // strip the claim timestamp segment (".<claimedAtMs>")
      const dot: number = name.lastIndexOf('.');
      if (dot > 0 && name.substring(0, dot).endsWith(BATCH_SUFFIX)) {
        name = name.substring(0, dot);
      }
    }
    return name;
  }

  /**
   * Evict oldest batches when over the file-count or total-byte quota. Claimed
   * (.uploading) files count toward the byte total — otherwise orphaned claims
   * would sit outside every quota — but are never eviction victims themselves
   * (they may be mid-upload; stale ones are first restored to plain batches by
   * restoreUploadingBatches and evicted on a later pass).
   */
  private enforceQuota(): void {
    const batches: string[] = this.listBatches();
    let total: number = 0;
    try {
      const claimed: string[] = fs.listFileSync(this.rootDir)
        .filter((n: string) => n.startsWith(BATCH_PREFIX) && n.endsWith(UPLOADING_SUFFIX));
      for (const n of claimed) {
        total += FilePersistenceStrategy.sizeOf(`${this.rootDir}/${n}`);
      }
    } catch (_e) {
      // quota check is best-effort
    }
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

  /** UTF-8 byte length of a string (what lands on disk / on the wire). */
  static utf8Length(s: string): number {
    let bytes: number = 0;
    for (let i: number = 0; i < s.length; i++) {
      const code: number = s.charCodeAt(i);
      if (code < 0x80) {
        bytes += 1;
      } else if (code < 0x800) {
        bytes += 2;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        const next: number = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
        if (next >= 0xDC00 && next <= 0xDFFF) {
          bytes += 4; // valid surrogate pair → one 4-byte code point
          i += 1;
        } else {
          bytes += 3; // lone high surrogate → encoder emits a 3-byte replacement
        }
      } else {
        bytes += 3;
      }
    }
    return bytes;
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
