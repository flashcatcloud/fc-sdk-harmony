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
 */
export type LastViewWriter = (serialized: string) => void;
export type LastViewReader = () => string;

export class LastViewSnapshot {
  private static writer: LastViewWriter | null = null;
  private static reader: LastViewReader | null = null;

  /** @internal wired by RumFeature.onInitialize to the core's crash storage. */
  static configure(writer: LastViewWriter, reader: LastViewReader): void {
    LastViewSnapshot.writer = writer;
    LastViewSnapshot.reader = reader;
  }

  /** @internal cleared on SDK stop so a torn-down core is never written to. */
  static reset(): void {
    LastViewSnapshot.writer = null;
    LastViewSnapshot.reader = null;
  }

  /**
   * Record an assembled ViewEvent. Called from the single write chokepoint, so
   * what lands here is exactly what was sent to the intake — including the
   * mapper's edits, which keeps a replayed crash consistent with the view the
   * backend already has.
   */
  static record(event: Record<string, Object>): void {
    const w: LastViewWriter | null = LastViewSnapshot.writer;
    if (w === null) {
      return;
    }
    try {
      w(JSON.stringify(event));
    } catch (e) {
      // Snapshotting is an optimisation for the NEXT launch; never let it
      // interfere with the event actually being delivered on this one.
      FlashcatLog.e(`rum.lastview: snapshot failed: ${e instanceof Error ? e.message : `${e}`}`);
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
}
