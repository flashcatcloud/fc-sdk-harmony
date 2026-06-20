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
