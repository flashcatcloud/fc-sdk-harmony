import { SdkCore, FeatureScope } from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { RumMonitor } from '../../RumMonitor';
import { RumConfiguration } from '../../RumConfiguration';
import { RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from '../../RumTypes';
import { RumApplicationScope } from '../scope/RumApplicationScope';
import { RumRawEvent } from '../scope/RumScope';

const MS_TO_NS: number = 1e6;
// Periodically re-emit the active view so its time_spent (and the session
// duration the backend derives from it) stays current even without user
// interaction. Android uses 5 min; we use a finer cadence for tighter mobile
// session-duration accuracy. See RumViewScope keep-alive handling.
const KEEP_ALIVE_MS: number = 30 * 1000;

/**
 * Default RumMonitor. Translates the public API into RumRawEvents fed to the
 * application scope, which assembles + writes View / Action / Error / Resource
 * events. Equivalent to Android's DatadogRumMonitor.
 *
 * Emits ActionEvents (instantaneous via addAction; timed via start/stopAction)
 * and drives a keep-alive timer that refreshes the active view's time_spent.
 */
export class DefaultRumMonitor implements RumMonitor {
  private readonly applicationScope: RumApplicationScope;
  private readonly globalAttributes: Map<string, Object> = new Map<string, Object>();
  private readonly activeActions: Map<string, number> = new Map<string, number>(); // key → start ms
  private keepAliveTimerId: number = -1;

  constructor(core: SdkCore, featureScope: FeatureScope, configuration: RumConfiguration) {
    this.applicationScope = new RumApplicationScope(
      featureScope, core, configuration.applicationId, configuration.sessionSampleRate);
    this.startKeepAlive();
  }

  startView(key: string, name: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('startView', attributes);
    e.key = key;
    e.name = name;
    this.applicationScope.handleEvent(e);
  }

  stopView(key: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('stopView', attributes);
    e.key = key;
    this.applicationScope.handleEvent(e);
  }

  /** Instantaneous action — emits an ActionEvent with loading_time 0. */
  addAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {
    this.emitAction(type, name, 0, attributes);
  }

  /** Begin a timed action; stopAction emits the ActionEvent with the measured duration. */
  startAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {
    this.activeActions.set(DefaultRumMonitor.actionKey(type, name), Date.now());
  }

  stopAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {
    const k: string = DefaultRumMonitor.actionKey(type, name);
    const start: number | undefined = this.activeActions.get(k);
    let durationNs: number = 0;
    if (start !== undefined) {
      durationNs = Math.max(0, Date.now() - start) * MS_TO_NS;
      this.activeActions.delete(k);
    }
    this.emitAction(type, name, durationNs, attributes);
  }

  private emitAction(type: RumActionType, name: string, durationNs: number,
    attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('addAction', attributes);
    e.name = name;
    e.actionType = type as string;
    e.actionId = util.generateRandomUUID(true);
    e.actionDurationNs = durationNs;
    this.applicationScope.handleEvent(e);
  }

  private static actionKey(type: RumActionType, name: string): string {
    return `${type as string}/${name}`;
  }

  /** Re-emit the active view (keep its time_spent / the session duration current). */
  keepAlive(): void {
    this.applicationScope.handleEvent({ kind: 'keepAlive', attributes: {}, timestampMs: Date.now() });
  }

  private startKeepAlive(): void {
    this.keepAliveTimerId = setInterval(() => {
      this.keepAlive();
    }, KEEP_ALIVE_MS);
  }

  /** Stop the keep-alive timer. Called on SDK stop so the timer doesn't leak. */
  stopKeepAlive(): void {
    if (this.keepAliveTimerId !== -1) {
      clearInterval(this.keepAliveTimerId);
      this.keepAliveTimerId = -1;
    }
  }

  startResource(key: string, method: RumResourceMethod, url: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('startResource', attributes);
    e.key = key;
    e.method = method as string;
    e.url = url;
    this.applicationScope.handleEvent(e);
  }

  stopResource(key: string, statusCode: number, size: number, kind: RumResourceKind,
    attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('stopResource', attributes);
    e.key = key;
    e.statusCode = statusCode;
    e.sizeBytes = size;
    e.resourceKind = kind as string;
    this.applicationScope.handleEvent(e);
  }

  stopResourceWithError(key: string, message: string, statusCode?: number,
    attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('stopResourceWithError', attributes);
    e.key = key;
    e.errorMessage = message;
    e.statusCode = statusCode;
    this.applicationScope.handleEvent(e);
  }

  addError(message: string, source: RumErrorSource, stack?: string, attributes?: Record<string, Object>): void {
    this.reportError(message, source, stack, false, 'handled', attributes);
  }

  /** Internal: used by the unhandled-exception hook to flag errors as unhandled. */
  reportError(message: string, source: RumErrorSource, stack: string | undefined,
    isCrash: boolean, handling: string, attributes?: Record<string, Object>, timestampMs?: number): void {
    const e: RumRawEvent = this.raw('addError', attributes);
    if (timestampMs !== undefined) {
      e.timestampMs = timestampMs;
    }
    e.errorMessage = message;
    e.errorSource = source as string;
    e.errorStack = stack;
    e.isCrash = isCrash;
    e.errorHandling = handling;
    this.applicationScope.handleEvent(e);
  }

  addAttribute(key: string, value: Object): void {
    this.globalAttributes.set(key, value);
  }

  removeAttribute(key: string): void {
    this.globalAttributes.delete(key);
  }

  getCurrentSessionId(callback: (sessionId: string | undefined) => void): void {
    callback(this.applicationScope.getCurrentSessionId());
  }

  private raw(kind: string, attributes?: Record<string, Object>): RumRawEvent {
    const attrs: Record<string, Object> = {};
    this.globalAttributes.forEach((v: Object, k: string) => {
      attrs[k] = v;
    });
    if (attributes !== undefined) {
      for (const k of Object.keys(attributes)) {
        attrs[k] = attributes[k];
      }
    }
    return { kind, attributes: attrs, timestampMs: Date.now() };
  }
}
