import { EventWriter, FlashcatLog } from '@flashcatcloud/core';
import { RumEventMapper } from '../RumTypes';
import { LastViewSnapshot } from './LastViewSnapshot';

/**
 * Phase-2 R3: holds the app-supplied {@link RumEventMapper} and applies it at the
 * single chokepoint just before an assembled event is handed to the writer. This
 * is where PII scrubbing / redaction / drop happens.
 *
 * Never-throw contract: a mapper that throws must NOT drop the SDK — the original
 * event is passed through unmodified and the failure is logged. A mapper that
 * returns `null` intentionally drops the event.
 */
export class RumEventMapperHolder {
  private static mapper: RumEventMapper | null = null;
  /** The mapper is running: an event it causes (it called the SDK) is not mapped again. */
  private static applying: boolean = false;

  /** @internal set by FlashcatRum.enable from RumConfiguration.eventMapper. */
  static configure(mapper: RumEventMapper | null): void {
    RumEventMapperHolder.mapper = mapper;
  }

  /** @internal cleared on SDK stop. */
  static reset(): void {
    RumEventMapperHolder.mapper = null;
  }

  /**
   * Apply the mapper. Returns the (possibly modified) event, or `null` if the
   * mapper dropped it. With no mapper configured, returns the event unchanged.
   */
  static apply(event: Record<string, Object>): Record<string, Object> | null {
    const m: RumEventMapper | null = RumEventMapperHolder.mapper;
    if (m === null) {
      return event;
    }
    if (RumEventMapperHolder.applying) {
      // The mapper reported into the SDK. Mapping that event would run the
      // mapper again, and every run reports another — the host never gets
      // control back. Writing it unmapped would skip the app's redaction. It is
      // dropped, as beforeSampling ignores the events its hook causes.
      const type: Object | undefined = event['type'];
      FlashcatLog.e(`rum.mapper: dropped event type=${typeof type === 'string' ? type : '?'} reported from inside the mapper`);
      return null;
    }
    RumEventMapperHolder.applying = true;
    try {
      const result: Record<string, Object> | null = m(event);
      if (result === null) {
        const type: Object | undefined = event['type'];
        FlashcatLog.d(`rum.mapper: dropped event type=${typeof type === 'string' ? type : '?'}`);
        return null;
      }
      return result;
    } catch (e) {
      // A mapper bug must never drop the SDK — pass the event through unmodified.
      FlashcatLog.e(`rum.mapper: threw, passing event through: ${e instanceof Error ? e.message : `${e}`}`);
      return event;
    } finally {
      RumEventMapperHolder.applying = false;
    }
  }
}

/**
 * Map-then-write: the single helper every RUM scope uses instead of calling
 * `writer.write` directly, so the mapper applies uniformly to View / Action /
 * Error / Resource events.
 */
export function writeMapped(writer: EventWriter, event: Record<string, Object>, forceFlush: boolean): void {
  const mapped: Record<string, Object> | null = RumEventMapperHolder.apply(event);
  if (mapped !== null) {
    const written: boolean = writer.write(mapped, forceFlush);
    // Snapshot the view AFTER a successful write: the snapshot's job is to
    // describe the last view the backend actually holds, so that a crash
    // replayed against it lines up with an existing document rather than
    // resurrecting one the intake never saw.
    if (written && mapped['type'] === 'view') {
      LastViewSnapshot.record(mapped);
    }
  }
}
