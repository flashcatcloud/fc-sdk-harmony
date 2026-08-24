/** Mirrors the RUM enums from the Android SDK / rum-events-format. */

/**
 * Event mapper (phase 2 R3): inspect/redact/drop an assembled RUM event before it
 * is persisted and uploaded. Receives the event as a `Record<string, Object>`
 * (it carries a `type` field: `view` | `action` | `error` | `resource`). Return:
 * - the same or a modified record to keep it (e.g. scrub a URL or user field), or
 * - `null` to drop the event entirely.
 * Mappers must be cheap and must not throw — a throwing mapper is contained and
 * the original event passes through unmodified. Mirrors Android's `RumEventMapper`.
 */
export type RumEventMapper = (event: Record<string, Object>) => Record<string, Object> | null;

/**
 * What the SDK is about to draw a new session with, handed to
 * {@link BeforeSamplingCallback}: the rate that would apply (the console's
 * where it published one, the init value where it did not) and the console's
 * custom values, decoded.
 */
export interface BeforeSamplingContext {
  /** 0..100. */
  readonly sessionSampleRate: number;
  /** The console's custom bag, or null when nothing is published. */
  readonly custom: Record<string, Object> | null;
}

/**
 * The application's last word on session sampling, called synchronously each
 * time a new session is about to be drawn. Return a rate to override — 100
 * always collects, 0 never does — or `undefined` to leave the incoming rate
 * alone. Runs inside session creation, so it must be fast and synchronous; a
 * throw or an out-of-range value is ignored. A session already under way is
 * never re-decided.
 */
export type BeforeSamplingCallback = (context: BeforeSamplingContext) => number | undefined;

export enum RumActionType {
  TAP = 'tap',
  SCROLL = 'scroll',
  SWIPE = 'swipe',
  CLICK = 'click',
  BACK = 'back',
  CUSTOM = 'custom'
}

export enum RumErrorSource {
  NETWORK = 'network',
  SOURCE = 'source',     // ArkTS / JS runtime error
  CONSOLE = 'console',
  WEBVIEW = 'webview',
  AGENT = 'agent',
  CUSTOM = 'custom'
}

export enum RumResourceKind {
  IMAGE = 'image',
  XHR = 'xhr',
  FETCH = 'fetch',
  FONT = 'font',
  CSS = 'css',
  JS = 'js',
  MEDIA = 'media',
  NATIVE = 'native',
  OTHER = 'other'
}

export enum RumResourceMethod {
  GET = 'GET',
  POST = 'POST',
  PUT = 'PUT',
  DELETE = 'DELETE',
  HEAD = 'HEAD',
  PATCH = 'PATCH'
}
