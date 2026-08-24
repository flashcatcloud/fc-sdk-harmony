import { RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from './RumTypes';

/**
 * Manual RUM instrumentation API. Obtain via `GlobalRumMonitor.get()`.
 * Mirrors Android's `RumMonitor`. Auto-instrumentation (navigation/network)
 * drives the same methods internally.
 */
export interface RumMonitor {
  startView(key: string, name: string, attributes?: Record<string, Object>): void;
  stopView(key: string, attributes?: Record<string, Object>): void;

  addAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void;
  startAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void;
  stopAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void;

  /**
   * `key` MUST be unique per request (e.g. a UUID) — reusing a key while an
   * earlier request with the same key is still in flight cross-attributes the
   * two completions (wrong durations and view attribution for both).
   */
  startResource(key: string, method: RumResourceMethod, url: string, attributes?: Record<string, Object>): void;
  stopResource(key: string, statusCode: number, size: number, kind: RumResourceKind,
    attributes?: Record<string, Object>): void;
  /** Report the resource as failed: emits a `source: network` error event instead. */
  stopResourceWithError(key: string, message: string, statusCode?: number,
    attributes?: Record<string, Object>): void;

  addError(message: string, source: RumErrorSource, stack?: string, attributes?: Record<string, Object>): void;

  addAttribute(key: string, value: Object): void;
  removeAttribute(key: string): void;
  /** Snapshot of the global attributes attached to every event. */
  getAttributes(): Record<string, Object>;
  /** Remove ALL global attributes. */
  clearAttributes(): void;

  getCurrentSessionId(callback: (sessionId: string | undefined) => void): void;

  /**
   * Force the session to be collected regardless of the configured sample
   * rates. Call it when your own code decides a visitor needs debugging (an
   * allow-list, a support flow). A session that was not being collected ends
   * and a collected one starts in its place; a session already collected keeps
   * running, and calling again while the forced session runs does nothing. The
   * forced state lasts for the process lifetime — decide again on each launch.
   */
  setForcedSession(): void;

  /**
   * Read the custom values published for this application in the console. The
   * SDK delivers them verbatim and never interprets them — what a value means
   * is entirely up to your own code (a debug allow-list to pair with
   * {@link setForcedSession}, a feature toggle). Values are cached across
   * launches; null when remote configuration is off or nothing is published.
   */
  getRemoteConfig(): Record<string, Object> | null;

  /**
   * End the current session immediately (e.g. on logout). The active view is
   * closed with its final time_spent; the next tracked event starts a fresh
   * session and restarts the last view in it.
   */
  stopSession(): void;
}

/** No-op fallback used before RUM is enabled. */
class NoOpRumMonitor implements RumMonitor {
  startView(key: string, name: string, attributes?: Record<string, Object>): void {}
  stopView(key: string, attributes?: Record<string, Object>): void {}
  addAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {}
  startAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {}
  stopAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {}
  startResource(key: string, method: RumResourceMethod, url: string, attributes?: Record<string, Object>): void {}
  stopResource(key: string, statusCode: number, size: number, kind: RumResourceKind,
    attributes?: Record<string, Object>): void {}
  stopResourceWithError(key: string, message: string, statusCode?: number,
    attributes?: Record<string, Object>): void {}
  addError(message: string, source: RumErrorSource, stack?: string, attributes?: Record<string, Object>): void {}
  addAttribute(key: string, value: Object): void {}
  removeAttribute(key: string): void {}
  getAttributes(): Record<string, Object> {
    return {};
  }
  clearAttributes(): void {}
  getCurrentSessionId(callback: (sessionId: string | undefined) => void): void {
    callback(undefined);
  }
  stopSession(): void {}
  setForcedSession(): void {}
  getRemoteConfig(): Record<string, Object> | null {
    return null;
  }
}

/**
 * Holds the active RumMonitor. Set by FlashcatRum.enable; a no-op monitor is
 * returned before enable so call sites never crash.
 */
export class GlobalRumMonitor {
  private static monitor: RumMonitor = new NoOpRumMonitor();

  static get(): RumMonitor {
    return GlobalRumMonitor.monitor;
  }

  /** @internal set by FlashcatRum.enable */
  static register(monitor: RumMonitor): void {
    GlobalRumMonitor.monitor = monitor;
  }

  /** @internal */
  static reset(): void {
    GlobalRumMonitor.monitor = new NoOpRumMonitor();
  }
}
