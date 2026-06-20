import { EventWriter, FlashcatLog } from '@flashcatcloud/core';
import { RumEventMapper } from '../RumTypes';

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
    writer.write(mapped, forceFlush);
  }
}
