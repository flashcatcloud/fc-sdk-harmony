import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FlashcatLog } from '../FlashcatLog';
import { BatchSize } from '../../config/Batching';

const MAX_BATCH_BYTES: number = 512 * 1024;       // roll the active file past this size (UTF-8 bytes)
// …or this age, so events don't linger. Fallback for direct construction only;
// every production caller passes Configuration.batchSize. Kept equal to the
// configured default so an omitted argument cannot silently change behaviour.
const DEFAULT_BATCH_AGE_MS: number = BatchSize.MEDIUM;
const MAX_TOTAL_BYTES: number = 4 * 1024 * 1024;  // disk quota per feature (oldest-evicted)
// File-count quota per feature: a sanity bound only. The byte quota is the one
// that binds — at 200 a device offline for half an hour hit the count with
// <1 MB on disk and started discarding its oldest events.
const MAX_BATCH_COUNT: number = 1000;
// Writes are buffered in memory and appended to the batch file together: a file
// open/write/close per event cost the main thread more than the rest of the
// write. A buffered line reaches disk at most FLUSH_DELAY_MS after it was
// written, or as soon as FLUSH_BYTES are waiting. Backgrounding, stop, crash
// records and force rolls write the buffer synchronously.
const FLUSH_DELAY_MS: number = 250;
const FLUSH_BYTES: number = 64 * 1024;
// Bound on memory when appends cannot keep up (a burst that never yields to the
// event loop): past it a write flushes synchronously.
const MAX_BUFFERED_BYTES: number = MAX_BATCH_BYTES;
// How often an idle drain looks for orphaned claims (they are recoverable only
// after UPLOADING_RECOVERY_AGE_MS anyway).
const CLAIM_RECOVERY_INTERVAL_MS: number = 60 * 1000;
// Batches older than this are deleted instead of uploaded: the intake discards
// events older than 24 h per-event (isDateOK) while still returning 2xx, so
// uploading them is silent loss plus wasted traffic. Kept below 24 h for margin.
const MAX_BATCH_RETENTION_MS: number = 23 * 60 * 60 * 1000;
// A single event may not exceed one batch — an oversized event would produce an
// undeliverable batch (intake body cap) that then gets DROPped whole.
export const MAX_EVENT_BYTES: number = MAX_BATCH_BYTES;
const BATCH_PREFIX: string = 'batch-';
const BATCH_SUFFIX: string = '.ndjson';
const UPLOADING_SUFFIX: string = '.uploading';
const UPLOADING_RECOVERY_AGE_MS: number = 10 * 60 * 1000;
// A batch created by ANOTHER process may still be that process's active file
// (appended without any cross-process lock). Owners never append to a file older
// than their roll window (shouldRoll opens a new one), so a foreign batch becomes
// safe to claim once it is past the roll age plus slack for an in-flight append.
//
// The window is per-process configuration, and the main process and the deferred
// upload extension build their Configuration independently — nothing makes the
// two agree. Deriving the guard from THIS instance's window therefore loses data
// whenever they diverge: a main process on LARGE is still appending to a batch an
// extension on SMALL already considers claimable, and the claim renames the file
// out from under it. So the guard uses the LARGEST window any process could have
// been configured with, which is safe for every combination. Only cross-process
// claims wait this long; a process always claims its own batches on its own
// window.
const FOREIGN_CLAIM_SLACK_MS: number = 2000;
const FOREIGN_CLAIM_MIN_AGE_MS: number = BatchSize.LARGE;
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

/** Lines written to a batch that are not on disk yet. */
interface BufferedAppend {
  name: string;
  createdMs: number;
  lines: string[];
  bytes: number;
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
  // Quota accounting without a directory scan per batch: bytes per batch file
  // (plain or claimed, buffered bytes included), scanned at construction, kept
  // from this instance's own writes and reconciled with the directory listing
  // of every drain. It can only over-count between drains (another process
  // deleted something), which evicts early — the safe direction.
  private sizes: Map<string, number> = new Map<string, number>();
  // Buffered lines in write order, one entry per batch file; the last one is
  // usually the active batch.
  private buffered: BufferedAppend[] = [];
  private bufferedBytes: number = 0;
  private flushTimer: number = -1;
  // The batch an asynchronous append is writing to; one at a time.
  private appendingName: string | null = null;
  // Bumped by wipeAll: an append in flight across it writes refused data,
  // which is deleted when it completes.
  private generation: number = 0;
  private claimsRecoveredMs: number = 0;
  private seq: number = 0;
  /** Roll window for the active batch; see Configuration.batchSize. */
  private readonly batchAgeMs: number;

  constructor(context: common.Context, featureName: string, batchAgeMs: number = DEFAULT_BATCH_AGE_MS) {
    this.batchAgeMs = batchAgeMs;
    const filesDir: string = context.filesDir;
    this.rootDir = `${filesDir}/flashcat/${featureName}`;
    this.pendingDir = `${this.rootDir}/${PENDING_DIR}`;
    FlashcatLog.d(`persistence[${featureName}]: filesDir=${filesDir} rootDir=${this.rootDir}`);
    this.ensureDir(this.rootDir);
    this.restoreUploadingBatches();
    this.rescanSizes();
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

  /**
   * Append one serialized event. The line is buffered in memory and reaches the
   * batch file with the next flush (FLUSH_DELAY_MS / FLUSH_BYTES), so true means
   * accepted, not yet on disk. When forceRoll, everything buffered is written
   * now and the file closed, so the event is drainable on the next scheduler
   * tick (used for error/crash events); the result then says whether it landed.
   */
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
    const now: number = Date.now();
    if (this.activeName === null || this.shouldRoll(now, lineBytes)) {
      this.openNewActive(now);
    }
    const name: string = this.activeName as string;
    this.buffer(name, line, lineBytes);
    if (forceRoll) {
      const ok: boolean = this.flushBuffered();
      this.activeName = null; // close so the just-written event is immediately drainable
      return ok;
    }
    if (this.bufferedBytes >= MAX_BUFFERED_BYTES) {
      this.flushBuffered();
    } else {
      this.scheduleFlush();
    }
    return true;
  }

  /** Write everything buffered and close the active file so its events become drainable (background/stop/flush). */
  rollActive(): void {
    this.flushBuffered();
    this.activeName = null;
  }

  /**
   * An owner never appends to a batch past its roll window: another process may
   * claim a batch that old. Buffered lines reach disk up to FLUSH_DELAY_MS after
   * they were written, so the active batch rolls that much early.
   */
  private shouldRoll(now: number, incomingBytes: number): boolean {
    return (this.activeBytes + incomingBytes) > MAX_BATCH_BYTES || this.activeExpired(now);
  }

  private activeExpired(now: number): boolean {
    return (now - this.activeCreatedMs) > this.batchAgeMs - FLUSH_DELAY_MS;
  }

  private openNewActive(now: number): void {
    this.activeName = this.newBatchName(now);
    this.activeCreatedMs = now;
    this.activeBytes = 0;
    this.sizes.set(this.activeName, 0);
  }

  /** A fresh batch name, owned by this instance; names sort in creation order (seq is padded). */
  private newBatchName(now: number): string {
    this.seq += 1;
    const rand: number = Math.floor(Math.random() * 1e6);
    const name: string = `${BATCH_PREFIX}${now}-${this.seq.toString().padStart(8, '0')}-${rand}${BATCH_SUFFIX}`;
    // Own batch: always safe for this instance to claim, whatever its age.
    this.ownNames.add(name);
    return name;
  }

  // ---- buffered appends ----

  private buffer(name: string, line: string, bytes: number): void {
    const last: BufferedAppend | undefined = this.buffered.length > 0
      ? this.buffered[this.buffered.length - 1] : undefined;
    if (last !== undefined && last.name === name) {
      last.lines.push(line);
      last.bytes += bytes;
    } else {
      this.buffered.push({ name: name, createdMs: this.activeCreatedMs, lines: [line], bytes: bytes });
    }
    this.bufferedBytes += bytes;
    this.activeBytes += bytes;
    this.sizes.set(name, (this.sizes.get(name) ?? 0) + bytes);
  }

  /** Starts a flush when enough is waiting, else makes sure one is due within FLUSH_DELAY_MS. */
  private scheduleFlush(): void {
    if (this.buffered.length === 0) {
      return;
    }
    if (this.bufferedBytes >= FLUSH_BYTES && this.appendingName === null) {
      this.flushAsync();
      return;
    }
    if (this.flushTimer === -1) {
      this.flushTimer = setTimeout(() => {
        this.flushTimer = -1;
        this.flushAsync();
      }, FLUSH_DELAY_MS);
    }
  }

  private cancelFlushTimer(): void {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
  }

  /**
   * Appends the oldest buffered batch with the asynchronous file API: one open,
   * one write of all its lines, one close. One append is in flight at a time;
   * its completion schedules the next.
   */
  private flushAsync(): void {
    if (this.appendingName !== null || this.buffered.length === 0) {
      return;
    }
    this.cancelFlushTimer();
    this.enforceQuota();
    const pending: BufferedAppend = this.buffered.shift() as BufferedAppend;
    this.bufferedBytes -= pending.bytes;
    const name: string = this.appendTarget(pending, Date.now());
    const path: string = `${this.rootDir}/${name}`;
    const content: string = pending.lines.join('');
    const generation: number = this.generation;
    this.appendingName = name;
    FilePersistenceStrategy.appendAsync(path, content).then((ok: boolean) => {
      this.appendingName = null;
      if (generation !== this.generation) {
        FilePersistenceStrategy.unlinkQuietly(path); // wiped meanwhile: refused data
      } else if (!ok) {
        this.healAndAppend(name, content, pending.bytes);
      }
      this.scheduleFlush();
    });
  }

  /**
   * Writes everything buffered now, synchronously — for backgrounding (the
   * process may be frozen or killed next), stop, consent changes, crash
   * records and force rolls. False when some line could not be written.
   * Lines already handed to an asynchronous append are not waited for: that
   * write is with the system already.
   */
  flushBuffered(): boolean {
    this.cancelFlushTimer();
    if (this.buffered.length === 0) {
      return true;
    }
    this.enforceQuota();
    const pendings: BufferedAppend[] = this.buffered;
    this.buffered = [];
    this.bufferedBytes = 0;
    const now: number = Date.now();
    let ok: boolean = true;
    for (const pending of pendings) {
      const name: string = this.appendTarget(pending, now);
      const content: string = pending.lines.join('');
      if (!FilePersistenceStrategy.append(`${this.rootDir}/${name}`, content)
        && !this.healAndAppend(name, content, pending.bytes)) {
        ok = false;
      }
    }
    return ok;
  }

  /**
   * The file a buffered batch's lines go to: its own, unless an append to it is
   * still in flight (it would land after these lines) or it is past its roll
   * window (another process may claim it). Then the lines open a new batch. In
   * the first case it is named after the batch it continues, so it sorts right
   * after it and before every batch opened since; in the second only a new
   * date keeps it from being claimed while it is written.
   */
  private appendTarget(pending: BufferedAppend, now: number): string {
    const expired: boolean = (now - pending.createdMs) > this.batchAgeMs;
    if (pending.name !== this.appendingName && !expired) {
      return pending.name;
    }
    let name: string;
    if (expired) {
      name = this.newBatchName(now);
    } else {
      // A letter sorts after the '.' of the suffix: `…-<rand>c<seq>.ndjson` follows `…-<rand>.ndjson`.
      this.seq += 1;
      name = `${pending.name.slice(0, pending.name.length - BATCH_SUFFIX.length)}c${this.seq}${BATCH_SUFFIX}`;
      this.ownNames.add(name);
    }
    this.sizes.set(name, pending.bytes);
    this.releaseBytes(pending.name, pending.bytes);
    if (pending.name === this.activeName) {
      this.activeName = null;
    }
    return name;
  }

  /** Self-heal a directory removed underneath us, then try the append once more; on failure the lines are lost. */
  private healAndAppend(name: string, content: string, bytes: number): boolean {
    this.ensureDir(this.rootDir);
    if (FilePersistenceStrategy.append(`${this.rootDir}/${name}`, content)) {
      return true;
    }
    this.releaseBytes(name, bytes);
    if (name === this.activeName) {
      this.activeName = null;
      this.activeBytes = 0;
    }
    return false;
  }

  /** Bytes accounted to `name` that will not be on disk under it. */
  private releaseBytes(name: string, bytes: number): void {
    const left: number = (this.sizes.get(name) ?? 0) - bytes;
    if (left > 0 || name === this.appendingName) {
      this.sizes.set(name, left > 0 ? left : 0);
      return;
    }
    // Nothing of it landed: no batch to account for or to claim.
    this.sizes.delete(name);
    this.ownNames.delete(name);
  }

  /** Lines for `name` are buffered or being appended: it is not complete on disk. */
  private hasUnwritten(name: string): boolean {
    if (name === this.appendingName) {
      return true;
    }
    for (const pending of this.buffered) {
      if (pending.name === name) {
        return true;
      }
    }
    return false;
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
    // Own batch: without this the foreign-claim age gate blocks the migrated
    // batch from our own drain for the roll-age window.
    const name: string = this.newBatchName(Date.now());
    const content: string = lines.join('\n') + '\n';
    if (FilePersistenceStrategy.append(`${this.rootDir}/${name}`, content)) {
      this.sizes.set(name, FilePersistenceStrategy.utf8Length(content));
    }
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
    this.cancelFlushTimer();
    this.buffered = [];
    this.bufferedBytes = 0;
    this.generation += 1;
    this.activeName = null;
    this.activeBytes = 0;
    this.ownNames.clear();
    this.sizes.clear(); // every batch goes: nothing left to account for
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
    if (this.activeName !== null && this.activeExpired(now)) {
      this.activeName = null; // close so it's eligible once its buffered lines are written
    }
    // Recover stale claims during the process's lifetime, not only at
    // construction — an orphaned .uploading file (process killed mid-upload)
    // must become drainable without waiting for a cold start. A claim is only
    // recoverable after UPLOADING_RECOVERY_AGE_MS, so once a minute is enough.
    if (now - this.claimsRecoveredMs >= CLAIM_RECOVERY_INTERVAL_MS) {
      this.claimsRecoveredMs = now;
      this.restoreUploadingBatches();
    }
    const listed: string[] | null = this.listBatchFiles();
    if (listed === null) {
      return null;
    }
    this.reconcileSizes(listed);
    const ready: string[] = listed
      .filter((n: string) => n.endsWith(BATCH_SUFFIX) && n !== this.activeName && !this.hasUnwritten(n))
      .sort();
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
      const foreignClaimAgeMs: number = (this.batchAgeMs > FOREIGN_CLAIM_MIN_AGE_MS
        ? this.batchAgeMs : FOREIGN_CLAIM_MIN_AGE_MS) + FOREIGN_CLAIM_SLACK_MS;
      if (!this.ownNames.has(originalName)
        && createdMs > 0 && (now - createdMs) <= foreignClaimAgeMs) {
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
    // A claimed batch is accounted under its original name.
    this.sizes.delete(batchId);
    this.sizes.delete(FilePersistenceStrategy.originalName(batchId));
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

  /** Batch files on disk, plain and claimed; null when the directory cannot be listed. */
  private listBatchFiles(): string[] | null {
    try {
      return fs.listFileSync(this.rootDir).filter((n: string) => n.startsWith(BATCH_PREFIX)
        && (n.endsWith(BATCH_SUFFIX) || n.endsWith(UPLOADING_SUFFIX)));
    } catch (_e) {
      return null;
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
    if (!this.overQuota()) {
      return;
    }
    // About to delete undelivered data: count from the directory, not from
    // accounting another process may have made stale (it uploads and deletes
    // batches too).
    this.rescanSizes();
    if (!this.overQuota()) {
      return;
    }
    let total: number = 0;
    const batches: string[] = [];
    this.sizes.forEach((bytes: number, name: string) => {
      total += bytes;
      // The active batch is never a victim: it holds the newest events. Nor is
      // one with lines still to be written: they would recreate it.
      if (name.endsWith(BATCH_SUFFIX) && name !== this.activeName && !this.hasUnwritten(name)) {
        batches.push(name);
      }
    });
    batches.sort(); // names start with the creation time: oldest first
    let i: number = 0;
    while ((batches.length - i) > MAX_BATCH_COUNT || total > MAX_TOTAL_BYTES) {
      if (i >= batches.length) {
        break;
      }
      const victim: string = batches[i];
      total -= this.sizes.get(victim) ?? 0;
      this.deleteBatch(victim);
      i += 1;
    }
  }

  private overQuota(): boolean {
    let total: number = 0;
    let count: number = 0;
    this.sizes.forEach((bytes: number, name: string) => {
      total += bytes;
      if (name.endsWith(BATCH_SUFFIX)) {
        count += 1;
      }
    });
    return count > MAX_BATCH_COUNT || total > MAX_TOTAL_BYTES;
  }

  /** Rebuild the per-batch byte map from the directory. */
  private rescanSizes(): void {
    const names: string[] | null = this.listBatchFiles();
    if (names !== null) {
      this.reconcileSizes(names); // a directory that cannot be listed keeps what we had
    }
  }

  /**
   * Rebuild the per-batch byte map from a directory listing. Sizes this
   * instance already knows (its own writes) are kept; only files it has not
   * seen — the other process's, or claims — are stat'ed. Batches with lines
   * not written yet stay accounted though they may not exist yet. Claimed
   * (.uploading) files count toward the byte total but are never eviction
   * victims (they may be mid-upload).
   */
  private reconcileSizes(names: string[]): void {
    const next: Map<string, number> = new Map<string, number>();
    for (const n of names) {
      // A claim keeps the size its batch had under the original name.
      const known: number | undefined = this.sizes.get(n) ??
        (n.endsWith(UPLOADING_SUFFIX) ? this.sizes.get(FilePersistenceStrategy.originalName(n)) : undefined);
      next.set(n, known !== undefined ? known : FilePersistenceStrategy.sizeOf(`${this.rootDir}/${n}`));
    }
    this.sizes.forEach((bytes: number, name: string) => {
      if (!next.has(name) && (name === this.activeName || this.hasUnwritten(name))) {
        next.set(name, bytes);
      }
    });
    this.sizes = next;
  }

  /**
   * UTF-8 byte length of a string (what lands on disk / on the wire). Native:
   * a per-character JS loop here was the largest single cost of a write. A
   * valid surrogate pair counts 4 bytes; a lone surrogate counts 3, the
   * replacement character the encoder emits for it.
   */
  static utf8Length(s: string): number {
    return buffer.byteLength(s, 'utf-8');
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

  /** Like append, with the Promise API. A failed close does not fail it: the content was written. */
  private static async appendAsync(path: string, content: string): Promise<boolean> {
    let file: fs.File;
    try {
      file = await fs.open(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    } catch (e) {
      FlashcatLog.e(`append failed path=${path}: ${FilePersistenceStrategy.errorText(e)}`);
      return false;
    }
    let ok: boolean = false;
    try {
      await fs.write(file.fd, content);
      ok = true;
    } catch (e) {
      FlashcatLog.e(`append failed path=${path}: ${FilePersistenceStrategy.errorText(e)}`);
    }
    try {
      await fs.close(file);
    } catch (_e) {
      // The descriptor is gone either way.
    }
    return ok;
  }

  private static unlinkQuietly(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (_e) {
      // Already gone.
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
