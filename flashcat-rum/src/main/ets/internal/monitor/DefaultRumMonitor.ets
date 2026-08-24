import { SdkCore, FeatureScope } from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { RumMonitor } from '../../RumMonitor';
import { RumConfiguration } from '../../RumConfiguration';
import { RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from '../../RumTypes';
import { RumApplicationScope } from '../scope/RumApplicationScope';
import { RumRawEvent } from '../scope/RumScope';
import { RemoteConfigStore, RemoteConfigValues } from '../remoteconfig/RemoteConfigStore';
import { RemoteConfigController } from '../remoteconfig/RemoteConfigController';

const MS_TO_NS: number = 1e6;
// Periodically re-emit the active view so its time_spent (and the session
// duration the backend derives from it) stays current even without user
// interaction. 5 min matches Android's keep-alive; end-of-session accuracy
// does not depend on this cadence because expiry close, stop() and flush()
// all emit a final keep-alive at the precise last-activity timestamp.
const KEEP_ALIVE_MS: number = 5 * 60 * 1000;
// Timed actions: cap duration and prune abandoned entries. A startAction whose
// stopAction never comes (user navigated away mid-gesture) must not leak, and a
// later same-key stopAction must not report an hours-long loading_time.
const ACTION_MAX_DURATION_MS: number = 10 * 60 * 1000;
const MAX_ACTIVE_ACTIONS: number = 128;

class ActiveActionRecord {
  readonly startMs: number;
  readonly attributes?: Record<string, Object>;

  constructor(startMs: number, attributes?: Record<string, Object>) {
    this.startMs = startMs;
    this.attributes = attributes;
  }
}

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
  private readonly activeActions: Map<string, ActiveActionRecord> = new Map<string, ActiveActionRecord>();
  private keepAliveTimerId: number = -1;
  // Null unless the app opted into remote configuration.
  private readonly remoteConfig: RemoteConfigStore | null;
  private readonly controller: RemoteConfigController | null;

  constructor(
    core: SdkCore,
    featureScope: FeatureScope,
    configuration: RumConfiguration,
    remoteConfig: RemoteConfigStore | null = null,
    controller: RemoteConfigController | null = null
  ) {
    this.remoteConfig = remoteConfig;
    this.controller = controller;
    this.applicationScope = new RumApplicationScope(
      featureScope, core, configuration.applicationId, configuration.sessionSampleRate,
      remoteConfig, configuration.beforeSampling,
      controller === null ? null : (): void => controller.onSessionStarted());
    this.startKeepAlive();
  }

  /** Refresh the console's configuration if it is stale and the console allows
   * it — the core tells us the app came back to the foreground. */
  refreshRemoteConfig(): void {
    if (this.controller !== null) {
      this.controller.refreshIfStale();
    }
  }

  /** Stop keeping the console's configuration fresh (SDK stop). */
  stopRemoteConfig(): void {
    if (this.controller !== null) {
      this.controller.stop();
    }
  }

  setForcedSession(): void {
    this.applicationScope.forceSession(Date.now());
  }

  getRemoteConfig(): Record<string, Object> | null {
    if (this.remoteConfig === null) {
      return null;
    }
    const stored: RemoteConfigValues | null = this.remoteConfig.read();
    if (stored === null || stored.custom === null) {
      return null;
    }
    // Handed to the host application decoded: every other platform hands back a
    // dictionary, and leaving one of them to parse a string would make the same
    // console value cost more on HarmonyOS than anywhere else.
    return RemoteConfigStore.decodeCustom(stored.custom);
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
    if (this.activeActions.size >= MAX_ACTIVE_ACTIONS) {
      // Evict the oldest abandoned entry (Map preserves insertion order).
      const oldest: IterableIterator<string> = this.activeActions.keys();
      const first: IteratorResult<string> = oldest.next();
      if (!first.done) {
        this.activeActions.delete(first.value);
      }
    }
    this.activeActions.set(
      DefaultRumMonitor.actionKey(type, name), new ActiveActionRecord(Date.now(), attributes));
  }

  stopAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {
    const k: string = DefaultRumMonitor.actionKey(type, name);
    const record: ActiveActionRecord | undefined = this.activeActions.get(k);
    let durationNs: number = 0;
    let dateMs: number | undefined = undefined;
    let merged: Record<string, Object> | undefined = attributes;
    if (record !== undefined) {
      // Cap the measured duration: a stale entry from an abandoned gesture must
      // not surface as an hours-long action.
      const elapsedMs: number = Math.min(
        Math.max(0, Date.now() - record.startMs), ACTION_MAX_DURATION_MS);
      durationNs = elapsedMs * MS_TO_NS;
      dateMs = record.startMs; // the action happened when it STARTED
      merged = DefaultRumMonitor.mergeAttributes(record.attributes, attributes);
      this.activeActions.delete(k);
    }
    this.emitAction(type, name, durationNs, merged, dateMs);
  }

  private static mergeAttributes(
    base?: Record<string, Object>, extra?: Record<string, Object>
  ): Record<string, Object> | undefined {
    if (base === undefined) {
      return extra;
    }
    const merged: Record<string, Object> = {};
    for (const k of Object.keys(base)) {
      merged[k] = base[k];
    }
    if (extra !== undefined) {
      for (const k of Object.keys(extra)) {
        merged[k] = extra[k];
      }
    }
    return merged;
  }

  private emitAction(type: RumActionType, name: string, durationNs: number,
    attributes?: Record<string, Object>, dateMs?: number): void {
    const e: RumRawEvent = this.raw('addAction', attributes);
    if (dateMs !== undefined) {
      e.timestampMs = dateMs;
    }
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

  /**
   * Internal: a terminating crash was persisted for next-launch replay. Bump the
   * active view's error/crash counts now (only the crashing process can), so the
   * final view document feeds session_crash_count → crash-free rate. The error
   * event itself is written by the replay.
   */
  markCrash(): void {
    this.applicationScope.handleEvent({ kind: 'markCrash', attributes: {}, timestampMs: Date.now() });
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
    isCrash: boolean, handling: string, attributes?: Record<string, Object>, timestampMs?: number,
    countInView: boolean = true): void {
    const e: RumRawEvent = this.raw('addError', attributes);
    if (timestampMs !== undefined) {
      e.timestampMs = timestampMs;
    }
    e.errorMessage = message;
    e.errorSource = source as string;
    e.errorStack = stack;
    e.isCrash = isCrash;
    e.countInView = countInView;
    e.errorHandling = handling;
    this.applicationScope.handleEvent(e);
  }

  addAttribute(key: string, value: Object): void {
    this.globalAttributes.set(key, value);
  }

  removeAttribute(key: string): void {
    this.globalAttributes.delete(key);
  }

  getAttributes(): Record<string, Object> {
    const snapshot: Record<string, Object> = {};
    this.globalAttributes.forEach((v: Object, k: string) => {
      snapshot[k] = v;
    });
    return snapshot;
  }

  clearAttributes(): void {
    this.globalAttributes.clear();
  }

  getCurrentSessionId(callback: (sessionId: string | undefined) => void): void {
    callback(this.applicationScope.getCurrentSessionId());
  }

  stopSession(): void {
    this.applicationScope.stopCurrentSession(Date.now());
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
