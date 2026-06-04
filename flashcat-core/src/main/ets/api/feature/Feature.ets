import { FlashcatContext } from '../context/FlashcatContext';

/** Well-known feature names registered against the core. */
export const RUM_FEATURE_NAME = 'rum';
export const LOGS_FEATURE_NAME = 'logs';
export const TRACE_FEATURE_NAME = 'trace';
export const CRASH_FEATURE_NAME = 'crash';

/**
 * A pluggable SDK feature (RUM, Logs, Trace, Crash...). Registered against the
 * core after `Flashcat.initialize`. Mirrors Android's `Feature` interface.
 */
export interface Feature {
  readonly name: string;
  /** Called when the feature is registered. Install instrumentation here. */
  onInitialize(): void;
  /** Called on SDK stop. Tear down instrumentation and flush. */
  onStop(): void;
}

/**
 * Listener for messages on the inter-feature bus. e.g. the RUM feature registers
 * a receiver to consume crash events published by the Crash feature.
 */
export interface FeatureEventReceiver {
  onReceive(event: Record<string, Object>): void;
}

/**
 * Writes an assembled event into the feature's storage→upload pipeline. The core
 * implementation serializes the event to one NDJSON line and persists it
 * (subject to tracking consent). Returns false if the event was dropped.
 */
export interface EventWriter {
  /**
   * @param forceFlush when true (e.g. error/crash events), the event is persisted
   * and its batch is rolled + an immediate upload is triggered, instead of waiting
   * for the size/age threshold.
   */
  write(event: Record<string, Object>, forceFlush?: boolean): boolean;
}

/**
 * Per-feature handle returned by the core. Lets a feature read context + write
 * events, and publish messages onto the inter-feature bus.
 */
export interface FeatureScope {
  /** Snapshot the current context and obtain the writer to emit events. */
  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void;
  /** Publish a message onto the inter-feature bus (routed by `event.target`). */
  sendEvent(event: Record<string, Object>): void;
}
