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
  // Wall-clock time the view was closed. Late writes on a closed view (draining
  // resource completions, crash marks) update counts but must NOT extend
  // time_spent past the close — the backend keeps the newest document, so an
  // extended write would credit post-navigation idle time as dwell time.
  private closedAtMs: number = 0;
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
    // Publish the active view so Logs/Trace/Crash can correlate. The URL is the
    // RESOLVED one (caller-supplied view.url, e.g. the nav tracker's route path),
    // not the opaque key — a crash incident snapshots this and must match the
    // view's own events for URL-based grouping.
    const update: Record<string, Object> = {};
    update['view.id'] = viewId;
    update['view.name'] = viewName;
    update['view.url'] = this.resolvedViewUrl();
    this.core.updateFeatureContext('rum', update);
    this.writeViewEvent(startedAtMs);
  }

  /** Caller-supplied view.url (real route path) wins over the opaque key. */
  private resolvedViewUrl(): string {
    const fromAttributes: Object | undefined = this.attributes['view.url'];
    if (typeof fromAttributes === 'string' && fromAttributes.length > 0) {
      return fromAttributes;
    }
    return this.key;
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
          this.closedAtMs = event.timestampMs;
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
        if (key !== '') {
          // Evict the OLDEST pending entry when full (Map preserves insertion
          // order): abandoned starts (caller dropped, key mismatch) must not
          // permanently saturate the cap on a long-lived view and silently
          // disable resource tracking for every later request.
          if (this.pendingResources.size >= MAX_PENDING_RESOURCES) {
            const oldest: string = this.pendingResources.keys().next().value as string;
            this.pendingResources.delete(oldest);
          }
          this.pendingResources.set(key, new RumResourceScope(
            this.featureScope, this.applicationId, this.sessionId,
            this.viewId, this.viewName, this.resolvedViewUrl(), event));
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
    this.closedAtMs = nowMs;
    this.writeViewEvent(nowMs);
    this.clearViewContext();
  }

  /**
   * Count a crash on this view WITHOUT writing a document — used when the crash
   * itself detects session expiry: the count must land in the final document the
   * imminent forceStop writes, not in one that resurrects the view afterwards.
   */
  countCrash(): void {
    this.errorCount += 1;
    this.crashCount += 1;
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
    // Once closed, time freezes at the close timestamp: late count updates
    // (draining resources, crash marks) must not extend dwell time.
    const clockMs: number = this.active || this.closedAtMs <= 0 ? nowMs : Math.min(nowMs, this.closedAtMs);
    // Monotonic per view: a backwards wall-clock jump (NTP correction, manual
    // change) must never shrink time_spent — the backend keeps the newest
    // document, so a clamped-to-0 write would permanently erase real dwell time.
    const timeSpentNs: number =
      Math.max(this.maxTimeSpentNs, Math.max(0, clockMs - this.startedAtMs) * MS_TO_NS);
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
