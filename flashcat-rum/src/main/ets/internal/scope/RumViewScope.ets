import { FeatureScope, FlashcatContext, EventWriter, SdkCore } from '@flashcatcloud/core';
import { RumScope, RumRawEvent } from './RumScope';
import { RumResourceScope } from './RumResourceScope';
import { RumEventAssembler } from '../assembly/RumEventAssembler';
import { writeMapped } from '../RumEventMapperHolder';

const MS_TO_NS: number = 1e6;
const MAX_PENDING_RESOURCES: number = 100;

/**
 * Tracks the lifetime of a single view (page): its action/error/resource counts
 * and time-spent. Emits a ViewEvent on start (document_version 1) and on each
 * update (final version when stopped) — `date` stays the view start, `time_spent`
 * and `document_version` advance. Also assembles ErrorEvents for errors raised
 * while it is active, and owns the in-flight RumResourceScopes.
 */
export class RumViewScope implements RumScope {
  private readonly featureScope: FeatureScope;
  private readonly core: SdkCore;
  private readonly applicationId: string;
  private readonly sessionId: string;
  private readonly key: string;
  private readonly viewName: string;
  private readonly viewId: string;
  private readonly startedAtMs: number;
  private readonly attributes: Record<string, Object>;
  private actionCount: number = 0;
  private errorCount: number = 0;
  private resourceCount: number = 0;
  private crashCount: number = 0;
  private documentVersion: number = 0;
  private maxTimeSpentNs: number = 0;
  private active: boolean = true;
  private readonly pendingResources: Map<string, RumResourceScope> = new Map<string, RumResourceScope>();

  constructor(
    featureScope: FeatureScope,
    core: SdkCore,
    applicationId: string,
    sessionId: string,
    key: string,
    viewName: string,
    viewId: string,
    startedAtMs: number,
    attributes: Record<string, Object>
  ) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sessionId = sessionId;
    this.key = key;
    this.viewName = viewName;
    this.viewId = viewId;
    this.startedAtMs = startedAtMs;
    this.attributes = attributes;
    // Publish the active view so Logs/Trace can correlate.
    const update: Record<string, Object> = {};
    update['view.id'] = viewId;
    update['view.name'] = viewName;
    update['view.url'] = key;
    this.core.updateFeatureContext('rum', update);
    this.writeViewEvent(startedAtMs);
  }

  private viewAttributes(extra?: Record<string, Object>): Record<string, Object> {
    const attrs: Record<string, Object> = {};
    for (const k of Object.keys(this.attributes)) {
      attrs[k] = this.attributes[k];
    }
    if (extra !== undefined) {
      for (const k of Object.keys(extra)) {
        attrs[k] = extra[k];
      }
    }
    // Fallback only: a caller-supplied view.url (the nav tracker passes the real
    // route path) must win — clobbering it with the key turned every
    // auto-tracked view's URL into an opaque pageId, making views ungroupable.
    if (attrs['view.url'] === undefined) {
      attrs['view.url'] = this.key;
    }
    return attrs;
  }

  handleEvent(event: RumRawEvent): RumScope | null {
    switch (event.kind) {
      case 'stopView':
        if (event.key === this.key) {
          this.active = false;
          // In-flight resources are NOT dropped: the session keeps this scope in
          // its draining set until they settle (Android parity). Clearing them
          // here systematically lost exactly the slow and failing requests.
          this.writeViewEvent(event.timestampMs);
          this.clearViewContext();
          return null;
        }
        return this;
      case 'markCrash':
        // A crash is being persisted for next-launch replay: count it on this
        // view NOW (the crashing process is the only one that can), so
        // view.crash.count → session_crash_count → crash-free rate include it.
        // The error event itself is written by the replay, not here.
        this.errorCount += 1;
        this.crashCount += 1;
        this.writeViewEvent(event.timestampMs);
        return this;
      case 'addAction':
        this.actionCount += 1;
        this.writeAction(event);
        this.writeViewEvent(event.timestampMs);
        return this;
      case 'keepAlive':
        // Refresh time_spent without counting as a child event.
        if (this.active) {
          this.writeViewEvent(event.timestampMs);
        }
        return this;
      case 'addError':
        this.errorCount += 1;
        // A crash (is_crash) also bumps the view's crash count so the backend can
        // derive session_crash_count → crash-free rate. Freezes/app-hangs currently
        // arrive as is_crash too (distinguished by error.category); counting them
        // here keeps crash-free rate consistent with 崩溃次数 (= is_crash errors).
        if (event.isCrash === true) {
          this.crashCount += 1;
        }
        this.writeError(event);
        this.writeViewEvent(event.timestampMs);
        return this;
      case 'startResource': {
        const key: string = event.key ?? '';
        if (key !== '' && this.pendingResources.size < MAX_PENDING_RESOURCES) {
          this.pendingResources.set(key, new RumResourceScope(
            this.featureScope, this.applicationId, this.sessionId,
            this.viewId, this.viewName, this.key, event));
        }
        return this;
      }
      case 'stopResource': {
        const scope: RumResourceScope | undefined = this.pendingResources.get(event.key ?? '');
        if (scope !== undefined) {
          this.pendingResources.delete(event.key ?? '');
          scope.stop(event);
          this.resourceCount += 1;
          this.writeViewEvent(event.timestampMs);
        }
        return this;
      }
      case 'stopResourceWithError': {
        const scope: RumResourceScope | undefined = this.pendingResources.get(event.key ?? '');
        if (scope !== undefined) {
          this.pendingResources.delete(event.key ?? '');
          scope.stopWithError(event);
          this.errorCount += 1;
          this.writeViewEvent(event.timestampMs);
        }
        return this;
      }
      default:
        return this;
    }
  }

  /** Close this view (new view started, or session expired) and emit a final
   * event. In-flight resources stay pending — the session drains them. */
  forceStop(nowMs: number): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    this.writeViewEvent(nowMs);
    this.clearViewContext();
  }

  hasPendingResources(): boolean {
    return this.pendingResources.size > 0;
  }

  hasPendingResource(key: string): boolean {
    return this.pendingResources.has(key);
  }

  /**
   * Clear the published view identity once this view ends. The feature context
   * is merge-only, so without this a later crash (CrashFeature reads view.id at
   * crash time) would be stamped with a view from a session it doesn't belong to.
   */
  private clearViewContext(): void {
    const update: Record<string, Object> = {};
    update['view.id'] = '';
    update['view.name'] = '';
    update['view.url'] = '';
    this.core.updateFeatureContext('rum', update);
  }

  isActive(): boolean {
    return this.active;
  }

  getViewId(): string {
    return this.viewId;
  }

  getViewKey(): string {
    return this.key;
  }

  getViewName(): string {
    return this.viewName;
  }

  private writeViewEvent(nowMs: number): void {
    this.documentVersion += 1;
    // Monotonic per view: a backwards wall-clock jump (NTP correction, manual
    // change) must never shrink time_spent — the backend keeps the newest
    // document, so a clamped-to-0 write would permanently erase real dwell time.
    const timeSpentNs: number =
      Math.max(this.maxTimeSpentNs, Math.max(0, nowMs - this.startedAtMs) * MS_TO_NS);
    this.maxTimeSpentNs = timeSpentNs;
    const version: number = this.documentVersion;
    const actions: number = this.actionCount;
    const errors: number = this.errorCount;
    const resources: number = this.resourceCount;
    const crashes: number = this.crashCount;
    const isActive: boolean = this.active;
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.view(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        this.startedAtMs, timeSpentNs, actions, errors, resources, crashes, version, isActive, this.viewAttributes());
      writeMapped(writer, event, false);
    });
  }

  private writeAction(raw: RumRawEvent): void {
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.action(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.actionId ?? '', raw.actionType ?? 'custom', raw.name ?? '',
        raw.timestampMs, raw.actionDurationNs ?? 0, this.viewAttributes(raw.attributes));
      writeMapped(writer, event, false);
    });
  }

  private writeError(raw: RumRawEvent): void {
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.error(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.errorMessage ?? '', raw.errorSource ?? 'source', raw.errorStack,
        raw.isCrash ?? false, raw.errorHandling ?? 'handled', raw.timestampMs, this.viewAttributes(raw.attributes));
      // Error/crash events are force-flushed so they upload promptly (not after the
      // 5s/512KB batch threshold).
      writeMapped(writer, event, true);
    });
  }
}
