import { FeatureScope, FlashcatContext, EventWriter, SdkCore, FlashcatLog } from '@flashcatcloud/core';
import { RumScope, RumRawEvent } from './RumScope';
import { RumResourceScope } from './RumResourceScope';
import { RumEventAssembler } from '../assembly/RumEventAssembler';
import { writeMapped } from '../RumEventMapperHolder';
import { DrawnConfiguration } from '../remoteconfig/RemoteConfigStore';
import { ViewVitals } from '../vitals/ViewVitals';
import { VitalsCollector } from '../vitals/VitalsCollector';

const MS_TO_NS: number = 1e6;
const MAX_PENDING_RESOURCES: number = 100;
// Android's DatadogDataConstraints.validateTimings: what a custom timing name may hold.
const TIMING_NAME_INVALID: RegExp = /[^a-zA-Z0-9\-_.@$]/g;

/**
 * Tracks the lifetime of a single view (page): its action/error/resource counts
 * and time-spent. Emits a ViewEvent on start (document_version 1) and on each
 * update (final version when stopped) — `date` stays the view start, `time_spent`
 * and `document_version` advance. Also assembles ErrorEvents for errors raised
 * while it is active, and owns the in-flight RumResourceScopes.
 */
export class RumViewScope implements RumScope {
  // While the monitor works through queued events, an action only marks its
  // view: the view document (a full rewrite per action otherwise) is written
  // once, when the slice ends, with the counts of every action in it.
  private static deferring: boolean = false;
  private static deferred: Set<RumViewScope> = new Set<RumViewScope>();

  static deferActionViewWrites(defer: boolean): void {
    RumViewScope.deferring = defer;
    if (defer) {
      return;
    }
    const views: RumViewScope[] = Array.from(RumViewScope.deferred);
    RumViewScope.deferred.clear();
    for (const view of views) {
      // One failing write must not cost the other views theirs, nor throw into a timer.
      try {
        if (view.deferredViewAtMs > 0) {
          view.writeViewEvent(view.deferredViewAtMs);
        }
      } catch (error) {
        FlashcatLog.e(`rum.view: deferred write failed: ${error instanceof Error ? error.message : 'error'}`);
      }
    }
  }

  private readonly featureScope: FeatureScope;
  private readonly core: SdkCore;
  private readonly applicationId: string;
  private readonly sessionId: string;
  private readonly key: string;
  private readonly viewName: string;
  private readonly viewId: string;
  private readonly startedAtMs: number;
  // The view's own attributes: those it started with, then what
  // addViewAttributes / removeViewAttributes changed while it was open.
  private readonly attributes: Map<string, Object> = new Map<string, Object>();
  // What this session was drawn under. Reported on the view document (the only
  // event type the backend builds session rows from), so a session can be
  // traced back to the settings that decided whether to keep it.
  private readonly draw: DrawnConfiguration | null;
  // Whether the session is kept only because it errors (`sessionOnError`).
  private readonly sampledForError: boolean;
  private actionCount: number = 0;
  // Timestamp of the latest action whose view write is deferred; 0 when none is.
  private deferredViewAtMs: number = 0;
  private errorCount: number = 0;
  private resourceCount: number = 0;
  private crashCount: number = 0;
  private longTaskCount: number = 0;
  private documentVersion: number = 0;
  private maxTimeSpentNs: number = 0;
  private active: boolean = true;
  // Wall-clock time the view was closed. Late writes on a closed view (draining
  // resource completions, crash marks) update counts but must NOT extend
  // time_spent past the close — the backend keeps the newest document, so an
  // extended write would credit post-navigation idle time as dwell time.
  private closedAtMs: number = 0;
  private readonly pendingResources: Map<string, RumResourceScope> = new Map<string, RumResourceScope>();
  // Memory, CPU and frames sampled while this view is open. Registered with the
  // collectors until the view closes; every document written carries what it holds then.
  private readonly vitals: ViewVitals = new ViewVitals();
  private readonly collector: VitalsCollector | null;
  // view.loading_time (ns from the view's start), absent until measured. A
  // value the host set wins over the SDK's own measurement of a router page.
  private loadingTimeNs: number | null = null;
  private loadingTimeManual: boolean = false;
  // view.custom_timings: name → ns from the view's start, in the order first added.
  private readonly customTimings: Map<string, number> = new Map<string, number>();

  constructor(
    featureScope: FeatureScope,
    core: SdkCore,
    applicationId: string,
    sessionId: string,
    key: string,
    viewName: string,
    viewId: string,
    startedAtMs: number,
    attributes: Record<string, Object>,
    draw: DrawnConfiguration | null = null,
    sampledForError: boolean = false,
    collector: VitalsCollector | null = null
  ) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sessionId = sessionId;
    this.key = key;
    this.viewName = viewName;
    this.viewId = viewId;
    this.startedAtMs = startedAtMs;
    // A copy: the session keeps the start attributes to restart the view in a
    // later session, and attributes added to this view must not go with them.
    for (const k of Object.keys(attributes)) {
      this.attributes.set(k, attributes[k]);
    }
    this.draw = draw;
    this.sampledForError = sampledForError;
    this.collector = collector;
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
    // Last: a view whose opening failed above is never assigned anywhere, so
    // nothing would unregister it, and it would keep the samplers running.
    if (collector !== null) {
      collector.register(this.vitals);
    }
  }

  /** Caller-supplied view.url (real route path) wins over the opaque key. */
  resolvedViewUrl(): string {
    const fromAttributes: Object | undefined = this.attributes.get('view.url');
    if (typeof fromAttributes === 'string' && fromAttributes.length > 0) {
      return fromAttributes;
    }
    return this.key;
  }

  private viewAttributes(extra?: Record<string, Object>): Record<string, Object> {
    const attrs: Record<string, Object> = {};
    this.attributes.forEach((v: Object, k: string) => {
      attrs[k] = v;
    });
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
          this.stopSampling();
          // In-flight resources are NOT dropped: the session keeps this scope in
          // its draining set until they settle (Android parity). Clearing them
          // here systematically lost exactly the slow and failing requests.
          this.writeViewEvent(event.timestampMs);
          this.clearViewContext();
          return null;
        }
        return this;
      case 'addTiming':
        // Only the open view gets here (the session routes nothing else to a
        // closed one): a stopped view takes no timing, as on Android.
        // At least 1 ns, as on Android: a timing at the view's start is still sent.
        this.customTimings.set(RumViewScope.timingName(event.name ?? ''),
          Math.max(1, Math.max(0, event.timestampMs - this.startedAtMs) * MS_TO_NS));
        this.writeViewUpdate(event.timestampMs);
        return this;
      // Only the open view gets these (the session routes nothing else to a
      // closed one). Android parity: no document of their own; the next one
      // carries the change.
      case 'addViewAttributes':
        for (const k of Object.keys(event.attributes)) {
          this.attributes.set(k, event.attributes[k]);
        }
        return this;
      case 'removeViewAttributes':
        for (const k of event.attributeKeys ?? []) {
          this.attributes.delete(k);
        }
        return this;
      case 'addViewLoadingTime':
        if (this.takeLoadingTime(event)) {
          this.writeViewEvent(event.timestampMs);
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
        this.writeViewUpdate(event.timestampMs);
        return this;
      case 'operationStep':
        // Counted nowhere on the view; the view document is refreshed, as Android does.
        this.writeOperationStep(event);
        this.writeViewUpdate(event.timestampMs);
        return this;
      case 'addLongTask':
        if (!this.active) {
          return this; // seen after the view closed: it belongs to no view
        }
        this.longTaskCount += 1;
        this.writeLongTask(event);
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
        // derive session_crash_count → crash-free rate. Only crashes the process
        // lives through report here; a freeze is reported by the next launch and
        // never counts as a crash (RumFeature).
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
          scope.stop(event, this.viewAttributes());
          this.resourceCount += 1;
          this.writeViewEvent(event.timestampMs);
        }
        return this;
      }
      case 'stopResourceWithError': {
        const scope: RumResourceScope | undefined = this.pendingResources.get(event.key ?? '');
        if (scope !== undefined) {
          this.pendingResources.delete(event.key ?? '');
          scope.stopWithError(event, this.viewAttributes());
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
    this.stopSampling();
    this.writeViewEvent(nowMs);
    this.clearViewContext();
  }

  /**
   * Android's `addViewLoadingTime(overwrite)`: the time from the view's start
   * to now (the session hands it to the open view only); once a manual value
   * is set, only an overwriting call replaces it. The SDK's measurement of a
   * router page applies to that page only, and only while nothing has been set.
   */
  private takeLoadingTime(event: RumRawEvent): boolean {
    if (event.loadingTimeAuto === true) {
      if (event.key !== this.key || this.loadingTimeNs !== null) {
        return false;
      }
    } else if (this.loadingTimeManual && event.overwrite !== true) {
      FlashcatLog.usage(`addViewLoadingTime ignored: view "${this.viewName}" already has one; pass overwrite to replace it`);
      return false;
    }
    this.loadingTimeNs = Math.max(0, event.timestampMs - this.startedAtMs) * MS_TO_NS;
    this.loadingTimeManual = event.loadingTimeAuto !== true;
    return true;
  }

  /** A custom timing's name as Android sends it: invalid characters become `_`. */
  private static timingName(name: string): string {
    const sanitized: string = name.replace(TIMING_NAME_INVALID, '_');
    if (sanitized !== name) {
      FlashcatLog.usage(`addTiming: name "${name}" was modified to "${sanitized}" to match the constraints`);
    }
    return sanitized;
  }

  /** The view is closed: later samples belong to the next view. What it holds
   * stays, so late writes (draining resources) still carry it. */
  private stopSampling(): void {
    if (this.collector !== null) {
      this.collector.unregister(this.vitals);
    }
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
    // This document carries every count so far: a deferred write is no longer due.
    this.deferredViewAtMs = 0;
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
    const vitalFields: Record<string, Object> = this.vitals.toFields(timeSpentNs);
    if (this.loadingTimeNs !== null) {
      vitalFields['loading_time'] = this.loadingTimeNs;
    }
    if (this.customTimings.size > 0) {
      const timings: Record<string, Object> = {};
      this.customTimings.forEach((ns: number, timing: string) => {
        timings[timing] = ns;
      });
      vitalFields['custom_timings'] = timings;
    }
    const longTask: Record<string, Object> = {};
    longTask['count'] = this.longTaskCount;
    vitalFields['long_task'] = longTask;
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.view(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        this.startedAtMs, timeSpentNs, actions, errors, resources, crashes, version, isActive,
        this.viewAttributes(), this.draw, this.sampledForError, vitalFields);
      writeMapped(writer, event, false);
    });
  }

  /** Refresh the view document now, or once the queue drain ends when writes are deferred. */
  private writeViewUpdate(atMs: number): void {
    if (RumViewScope.deferring) {
      this.deferredViewAtMs = Math.max(this.deferredViewAtMs, atMs);
      RumViewScope.deferred.add(this);
    } else {
      this.writeViewEvent(atMs);
    }
  }

  private writeOperationStep(raw: RumRawEvent): void {
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.operationStep(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.name ?? '', raw.operationKey, raw.operationStepType ?? 'start', raw.operationFailureReason,
        raw.timestampMs, this.viewAttributes(raw.attributes), this.draw, this.sampledForError);
      writeMapped(writer, event, false);
    });
  }

  private writeLongTask(raw: RumRawEvent): void {
    // The frame is reported once its work is done: its start is when it was seen
    // minus its UI work (close to, not exactly, when the frame began).
    const durationNs: number = Math.round(raw.longTaskDurationNs ?? 0);
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.longTask(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.timestampMs - Math.round(durationNs / MS_TO_NS), durationNs, this.viewAttributes(raw.attributes));
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
    const attributes: Record<string, Object> = this.viewAttributes(raw.attributes);
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.error(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.errorMessage ?? '', raw.errorSource ?? 'source', raw.errorStack,
        raw.isCrash ?? false, raw.errorHandling ?? 'handled', raw.timestampMs,
        raw.isCrash === true ? RumEventAssembler.withSessionSampled(attributes, !this.sampledForError) : attributes);
      // Error/crash events are force-flushed so they upload promptly (not after the
      // 5s/512KB batch threshold).
      writeMapped(writer, event, true);
    });
  }
}
