import { FlashcatLog } from '@flashcatcloud/core';
import { process } from '@kit.ArkTS';

/**
 * Durable snapshot of the most recently written ViewEvent.
 *
 * Why this exists: a fault the SDK can observe in-process (an uncaught ArkTS
 * exception) snapshots its own RUM identity into the pending incident before
 * terminating. A fault it cannot — a native signal, a watchdog freeze — kills
 * the process with no chance to record anything, so on the next launch the
 * hiAppEvent replay carries no session or view at all. Attributing those to the
 * live (post-restart) session puts the crash in a session the user never
 * crashed in and leaves the real one reading crash-free.
 *
 * The fix mirrors the Android SDK's `lastViewEvent`: persist each ViewEvent as
 * it is written, then on replay rebuild the crash against that snapshot. Since
 * a ViewEvent is re-emitted after every action, error and resource, the file is
 * always within one document_version of the app's true final state.
 *
 * Writes are best-effort and must never disturb event delivery — a failing
 * snapshot degrades crash attribution, it does not drop data.
 *
 * The file also records the id of the process that wrote it. A fault reported on the
 * next launch belongs to that view only when it is that process's fault: a launch that
 * died before writing a view of its own (a crash before RUM started) leaves the file of
 * the run before it in place.
 *
 * Writes are coalesced: a view is re-emitted after every action, resource and
 * error, and rewriting the file each time cost the host a synchronous write per
 * event. The latest view lands at most WRITE_DELAY_MS later, and immediately
 * when the core flushes (background, explicit flush, pre-exit, stop) — the
 * moments a process is about to go away. A fault that kills the process without
 * warning loses at most that delay of view updates.
 *
 * Next to the view, the file holds the session the process is in (SessionRecord):
 * its id, whether it is collected and how it was drawn. A fault leaves no trace of
 * which session it happened in when no view of that session reached the file yet
 * (a fault during launch, or right after a session renewal) or when the session
 * writes no views at all (not sampled). The record says it: it is written at once,
 * not after the delay, whenever a session starts, ends or is thrown away, and the
 * first view of a session goes on file at once too. Only the views of the recorded
 * session are kept with it.
 */
const WRITE_DELAY_MS: number = 1000;

/** Writes the file; false when nothing was written (a refused consent allows no crash data on disk). */
export type LastViewWriter = (serialized: string) => boolean;
export type LastViewReader = () => string;
export type LastViewDeleter = () => void;

/** The session a process is in, as the next launch reads it back. */
export interface SessionRecord {
  id: string;
  /** Collected: drawn by the rate, forced, or kept on error. */
  sampled: boolean;
  /** Missed by the rate and kept only because it errors (`sessionOnError`). */
  sampledForError: boolean;
  /** The configuration it was drawn under (DrawnConfiguration). */
  rcVersion: number;
  sessionSampleRate: number;
  sessionOnError: boolean;
  /** When the session started, 0 when the file does not say. */
  startedAtMs: number;
  /** When the session ended (expiry noticed, stopSession), 0 while it runs. */
  endedAtMs: number;
}

/**
 * What the file says, and the process that wrote it (-1 when the file does not say).
 * `session` is null in a file of an earlier version, which held the view alone;
 * `view` is null when the recorded session has not written one.
 */
export interface LastView {
  view: Record<string, Object> | null;
  pid: number;
  session: SessionRecord | null;
  /** When the file was last written, 0 when it does not say. */
  writtenAtMs: number;
}

export class LastViewSnapshot {
  private static writer: LastViewWriter | null = null;
  private static reader: LastViewReader | null = null;
  private static deleter: LastViewDeleter | null = null;
  /** Whether anything of this process is on file. */
  private static onFile: boolean = false;
  /** The session of the view on file, '' when none is. */
  private static recordedSessionId: string = '';
  /** The session this process is in, null before the first one. */
  private static session: SessionRecord | null = null;
  /** The latest view not yet on file, and its pending write. */
  private static pending: Record<string, Object> | null = null;
  private static timerId: number = -1;
  /** The latest view recorded by this process, on file or not. */
  private static latest: Record<string, Object> | null = null;
  /** The last write was refused: what is on file is not what this process knows. */
  private static unwritten: boolean = false;

  /** @internal wired by RumFeature.onInitialize to the core's crash storage. */
  static configure(writer: LastViewWriter, reader: LastViewReader, deleter: LastViewDeleter): void {
    LastViewSnapshot.writer = writer;
    LastViewSnapshot.reader = reader;
    LastViewSnapshot.deleter = deleter;
    LastViewSnapshot.clearState();
  }

  /** @internal cleared on SDK stop so a torn-down core is never written to. */
  static reset(): void {
    LastViewSnapshot.writer = null;
    LastViewSnapshot.reader = null;
    LastViewSnapshot.deleter = null;
    LastViewSnapshot.clearState();
  }

  private static clearState(): void {
    LastViewSnapshot.onFile = false;
    LastViewSnapshot.unwritten = false;
    LastViewSnapshot.recordedSessionId = '';
    LastViewSnapshot.session = null;
    LastViewSnapshot.cancelPending();
    LastViewSnapshot.latest = null;
  }

  /**
   * A session started: from now on a fault of this process is this session's. Written
   * at once, so a fault before its first view is not taken for the previous session's.
   */
  static startSession(session: SessionRecord): void {
    if (LastViewSnapshot.writer === null) {
      return;
    }
    LastViewSnapshot.session = session;
    LastViewSnapshot.cancelPending();
    LastViewSnapshot.latest = null;
    LastViewSnapshot.writeNow();
  }

  /** The session ended at `endedAtMs`: a later fault is not its own. Written at once. */
  static endSession(sessionId: string, endedAtMs: number): void {
    const session: SessionRecord | null = LastViewSnapshot.session;
    if (LastViewSnapshot.writer === null || session === null || session.id !== sessionId ||
      session.endedAtMs > 0) {
      return;
    }
    session.endedAtMs = endedAtMs;
    LastViewSnapshot.pending = null;
    LastViewSnapshot.writeNow(); // with the session's final view, if it wrote one
  }

  /**
   * Record an assembled ViewEvent. Called from the single write chokepoint, so
   * what lands here is exactly what was sent to the intake — including the
   * mapper's edits, which keeps a replayed crash consistent with the view the
   * backend already has. A view of another session than the recorded one (a
   * previous session's view settling a late request) is not kept.
   */
  static record(event: Record<string, Object>): void {
    if (LastViewSnapshot.writer === null) {
      return;
    }
    const session: SessionRecord | null = LastViewSnapshot.session;
    if (session !== null && LastViewSnapshot.sessionIdOf(event) !== session.id) {
      return;
    }
    // A failed write is retried by the next batched one, not by every update: a storage
    // that keeps failing costs one attempt per delay, not one per event.
    const first: boolean = session !== null && LastViewSnapshot.latest === null;
    LastViewSnapshot.pending = event;
    LastViewSnapshot.latest = event;
    if (first) {
      // The session's first view: until it is on file, a fault would be reported in a
      // view of its own instead of this one.
      LastViewSnapshot.flush();
      return;
    }
    if (LastViewSnapshot.timerId === -1) {
      LastViewSnapshot.timerId = setTimeout((): void => {
        LastViewSnapshot.timerId = -1;
        LastViewSnapshot.flush();
      }, WRITE_DELAY_MS);
    }
  }

  /**
   * Write the latest view now. The core's flush points call this. Nothing new, nothing
   * written: the file's time says when the session last changed its view, which is
   * what tells the next launch that a session went idle.
   */
  static flush(): void {
    const event: Record<string, Object> | null = LastViewSnapshot.pending;
    LastViewSnapshot.cancelPending();
    if (event === null) {
      return;
    }
    LastViewSnapshot.writeNow();
  }

  /** Write the session and its latest view now. */
  private static writeNow(): void {
    LastViewSnapshot.cancelPending();
    const w: LastViewWriter | null = LastViewSnapshot.writer;
    if (w === null) {
      return;
    }
    const record: Record<string, Object> = { 'pid': process.pid, 'written_at': Date.now() };
    const session: SessionRecord | null = LastViewSnapshot.session;
    if (session !== null) {
      record['session'] = {
        'id': session.id,
        'sampled': session.sampled,
        'sampled_for_error': session.sampledForError,
        'rc_version': session.rcVersion,
        'session_sample_rate': session.sessionSampleRate,
        'session_on_error': session.sessionOnError,
        'started_at': session.startedAtMs,
        'ended_at': session.endedAtMs
      } as Record<string, Object>;
    }
    const view: Record<string, Object> | null = LastViewSnapshot.latest;
    if (view !== null) {
      record['view'] = view;
    }
    try {
      if (!w(JSON.stringify(record))) {
        LastViewSnapshot.unwritten = true;
        return;
      }
      LastViewSnapshot.unwritten = false;
      LastViewSnapshot.onFile = true;
      LastViewSnapshot.recordedSessionId = view !== null ? LastViewSnapshot.sessionIdOf(view) : '';
    } catch (e) {
      // Snapshotting is an optimisation for the NEXT launch; never let it
      // interfere with the event actually being delivered on this one.
      FlashcatLog.e(`rum.lastview: snapshot failed: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  /** Consent was granted: what a refused consent kept off (or took off) the file goes on it now. */
  static consentGranted(): void {
    if (LastViewSnapshot.unwritten && LastViewSnapshot.writer !== null) {
      LastViewSnapshot.writeNow();
    }
  }

  /**
   * Consent refused: the queued view is dropped without being written, and the core
   * deletes the file. The session record goes back on it when consent is granted.
   */
  static discardPending(): void {
    LastViewSnapshot.cancelPending();
    LastViewSnapshot.latest = null;
    LastViewSnapshot.onFile = false;
    LastViewSnapshot.recordedSessionId = '';
    LastViewSnapshot.unwritten = LastViewSnapshot.session !== null;
  }

  /**
   * The host cleared all data and the core deleted the file. The views recorded
   * so far go with it; the session record is written again at once, so a fault
   * of the running session is still reported in it. The session's next view
   * goes on file as soon as it is recorded.
   */
  static cleared(): void {
    LastViewSnapshot.cancelPending();
    LastViewSnapshot.latest = null;
    LastViewSnapshot.onFile = false;
    LastViewSnapshot.recordedSessionId = '';
    if (LastViewSnapshot.session !== null && LastViewSnapshot.writer !== null) {
      LastViewSnapshot.writeNow();
    }
  }

  /**
   * The view the NEXT launch will read back if this process dies now: the latest one
   * recorded, whether or not its write has happened yet.
   */
  static current(): Record<string, Object> | null {
    return LastViewSnapshot.latest;
  }

  private static cancelPending(): void {
    if (LastViewSnapshot.timerId !== -1) {
      clearTimeout(LastViewSnapshot.timerId);
      LastViewSnapshot.timerId = -1;
    }
    LastViewSnapshot.pending = null;
  }

  /**
   * `sessionId` was thrown away without ever reaching the backend. A crash replayed
   * against its last view must not build it after all. When it is the recorded
   * session, the record says so — it is not collected, so a fault in it is not
   * reported — and its view goes; otherwise only a snapshot of that session's view is
   * forgotten, and the snapshot of any other session stays.
   */
  static invalidateFor(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    const session: SessionRecord | null = LastViewSnapshot.session;
    if (session !== null && session.id === sessionId) {
      session.sampled = false;
      LastViewSnapshot.latest = null;
      if (LastViewSnapshot.writer !== null) {
        LastViewSnapshot.writeNow();
      }
      return;
    }
    // A pending (not yet written) view of that session goes too.
    const pending: Record<string, Object> | null = LastViewSnapshot.pending;
    if (pending !== null && LastViewSnapshot.sessionIdOf(pending) === sessionId) {
      LastViewSnapshot.cancelPending();
    }
    const latest: Record<string, Object> | null = LastViewSnapshot.latest;
    if (latest !== null && LastViewSnapshot.sessionIdOf(latest) === sessionId) {
      LastViewSnapshot.latest = null;
    }
    if (!LastViewSnapshot.onFile || LastViewSnapshot.recordedSessionId !== sessionId) {
      return;
    }
    LastViewSnapshot.onFile = false;
    LastViewSnapshot.recordedSessionId = '';
    const d: LastViewDeleter | null = LastViewSnapshot.deleter;
    if (d === null) {
      return;
    }
    try {
      d();
    } catch (e) {
      FlashcatLog.e(`rum.lastview: snapshot delete failed: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  /** Read back the snapshot, or null when absent/corrupt. */
  static read(): LastView | null {
    const r: LastViewReader | null = LastViewSnapshot.reader;
    if (r === null) {
      return null;
    }
    try {
      const serialized: string = r();
      if (serialized.length === 0) {
        return null;
      }
      const parsed: Object = JSON.parse(serialized) as Object;
      if (!LastViewSnapshot.isRecord(parsed)) {
        return null;
      }
      const record: Record<string, Object> = parsed as Record<string, Object>;
      const view: Object | undefined = record['view'];
      const session: SessionRecord | null = LastViewSnapshot.parseSession(record['session']);
      if (!LastViewSnapshot.isRecord(view) && session === null) {
        return null; // neither a view nor a session (an older SDK's bare view): nothing usable
      }
      const pid: Object | undefined = record['pid'];
      const writtenAt: Object | undefined = record['written_at'];
      return {
        view: LastViewSnapshot.isRecord(view) ? view as Record<string, Object> : null,
        pid: typeof pid === 'number' ? pid : -1,
        session: session,
        writtenAtMs: typeof writtenAt === 'number' ? writtenAt : 0
      };
    } catch (e) {
      FlashcatLog.e(`rum.lastview: snapshot unreadable: ${e instanceof Error ? e.message : `${e}`}`);
      return null;
    }
  }

  private static parseSession(value: Object | undefined): SessionRecord | null {
    if (!LastViewSnapshot.isRecord(value)) {
      return null;
    }
    const record: Record<string, Object> = value as Record<string, Object>;
    const id: Object | undefined = record['id'];
    if (typeof id !== 'string' || id.length === 0 || typeof record['sampled'] !== 'boolean') {
      return null;
    }
    return {
      id: id,
      sampled: record['sampled'] === true,
      sampledForError: record['sampled_for_error'] === true,
      rcVersion: LastViewSnapshot.numberOr(record['rc_version'], 0),
      sessionSampleRate: LastViewSnapshot.numberOr(record['session_sample_rate'], 100),
      sessionOnError: record['session_on_error'] === true,
      startedAtMs: LastViewSnapshot.numberOr(record['started_at'], 0),
      endedAtMs: LastViewSnapshot.numberOr(record['ended_at'], 0)
    };
  }

  private static numberOr(value: Object | undefined, fallback: number): number {
    return typeof value === 'number' ? value : fallback;
  }

  private static isRecord(value: Object | undefined): boolean {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
  }

  private static sessionIdOf(event: Record<string, Object>): string {
    const session: Object | undefined = event['session'];
    const id: Object | undefined = typeof session === 'object' && session !== null ?
      (session as Record<string, Object>)['id'] : undefined;
    return typeof id === 'string' ? id as string : '';
  }
}
