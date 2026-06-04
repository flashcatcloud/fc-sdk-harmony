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

  startResource(key: string, method: RumResourceMethod, url: string, attributes?: Record<string, Object>): void;
  stopResource(key: string, statusCode: number, size: number, kind: RumResourceKind,
    attributes?: Record<string, Object>): void;

  addError(message: string, source: RumErrorSource, stack?: string, attributes?: Record<string, Object>): void;

  addAttribute(key: string, value: Object): void;
  removeAttribute(key: string): void;

  getCurrentSessionId(callback: (sessionId: string | undefined) => void): void;
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
  addError(message: string, source: RumErrorSource, stack?: string, attributes?: Record<string, Object>): void {}
  addAttribute(key: string, value: Object): void {}
  removeAttribute(key: string): void {}
  getCurrentSessionId(callback: (sessionId: string | undefined) => void): void {
    callback(undefined);
  }
}
