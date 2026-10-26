import { FlashcatLog } from '@flashcatcloud/core';

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
 * Writes are coalesced: a view is re-emitted after every action, resource and
 * error, and rewriting the file each time cost the host a synchronous write per
 * event. The latest view lands at most WRITE_DELAY_MS later, and immediately
 * when the core flushes (background, explicit flush, pre-exit, stop) — the
 * moments a process is about to go away. A fault that kills the process without
 * warning loses at most that delay of view updates.
 */
const WRITE_DELAY_MS: number = 1000;

export type LastViewWriter = (serialized: string) => void;
export type LastViewReader = () => string;
export type LastViewDeleter = () => void;

export class LastViewSnapshot {
  private static writer: LastViewWriter | null = null;
  private static reader: LastViewReader | null = null;
  private static deleter: LastViewDeleter | null = null;
  /** The session of the view last recorded by this process, '' when none is on file. */
  private static recordedSessionId: string = '';
  /** The latest view not yet on file, and its pending write. */
  private static pending: Record<string, Object> | null = null;
  private static timerId: number = -1;

  /** @internal wired by RumFeature.onInitialize to the core's crash storage. */
  static configure(writer: LastViewWriter, reader: LastViewReader, deleter: LastViewDeleter): void {
    LastViewSnapshot.writer = writer;
    LastViewSnapshot.reader = reader;
    LastViewSnapshot.deleter = deleter;
    LastViewSnapshot.recordedSessionId = '';
    LastViewSnapshot.cancelPending();
  }

  /** @internal cleared on SDK stop so a torn-down core is never written to. */
  static reset(): void {
    LastViewSnapshot.writer = null;
    LastViewSnapshot.reader = null;
    LastViewSnapshot.deleter = null;
    LastViewSnapshot.recordedSessionId = '';
    LastViewSnapshot.cancelPending();
  }

  /**
   * Record an assembled ViewEvent. Called from the single write chokepoint, so
   * what lands here is exactly what was sent to the intake — including the
   * mapper's edits, which keeps a replayed crash consistent with the view the
   * backend already has.
   */
  static record(event: Record<string, Object>): void {
    if (LastViewSnapshot.writer === null) {
      return;
    }
    LastViewSnapshot.pending = event;
    if (LastViewSnapshot.timerId === -1) {
      LastViewSnapshot.timerId = setTimeout((): void => {
        LastViewSnapshot.timerId = -1;
        LastViewSnapshot.flush();
      }, WRITE_DELAY_MS);
    }
  }

  /** Write the latest view now. The core's flush points call this. */
  static flush(): void {
    if (LastViewSnapshot.timerId !== -1) {
      clearTimeout(LastViewSnapshot.timerId);
      LastViewSnapshot.timerId = -1;
    }
    const event: Record<string, Object> | null = LastViewSnapshot.pending;
    LastViewSnapshot.pending = null;
    const w: LastViewWriter | null = LastViewSnapshot.writer;
    if (event === null || w === null) {
      return;
    }
    try {
      w(JSON.stringify(event));
      LastViewSnapshot.recordedSessionId = LastViewSnapshot.sessionIdOf(event);
    } catch (e) {
      // Snapshotting is an optimisation for the NEXT launch; never let it
      // interfere with the event actually being delivered on this one.
      FlashcatLog.e(`rum.lastview: snapshot failed: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  /** Drop the queued view without writing it (consent refused). */
  static discardPending(): void {
    LastViewSnapshot.cancelPending();
  }

  private static cancelPending(): void {
    if (LastViewSnapshot.timerId !== -1) {
      clearTimeout(LastViewSnapshot.timerId);
      LastViewSnapshot.timerId = -1;
    }
    LastViewSnapshot.pending = null;
  }

  /**
   * Forget the snapshot if it describes `sessionId`. A session thrown away
   * without ever reaching the backend must not be rebuilt by a crash replayed
   * against its last view; the snapshot of any other session stays.
   */
  static invalidateFor(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    // A pending (not yet written) view of that session goes too.
    const pending: Record<string, Object> | null = LastViewSnapshot.pending;
    if (pending !== null && LastViewSnapshot.sessionIdOf(pending) === sessionId) {
      LastViewSnapshot.cancelPending();
    }
    if (LastViewSnapshot.recordedSessionId !== sessionId) {
      return;
    }
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
  static read(): Record<string, Object> | null {
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
      if (typeof parsed !== 'object' || Array.isArray(parsed)) {
        return null;
      }
      return parsed as Record<string, Object>;
    } catch (e) {
      FlashcatLog.e(`rum.lastview: snapshot unreadable: ${e instanceof Error ? e.message : `${e}`}`);
      return null;
    }
  }

  private static sessionIdOf(event: Record<string, Object>): string {
    const session: Object | undefined = event['session'];
    const id: Object | undefined = typeof session === 'object' && session !== null ?
      (session as Record<string, Object>)['id'] : undefined;
    return typeof id === 'string' ? id as string : '';
  }
}
