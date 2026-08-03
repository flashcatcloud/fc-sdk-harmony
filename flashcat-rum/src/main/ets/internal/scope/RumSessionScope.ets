import { FeatureScope, FlashcatContext, EventWriter, SdkCore, FlashcatLog } from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { RumScope, RumRawEvent } from './RumScope';
import { RumViewScope } from './RumViewScope';
import { RumEventAssembler } from '../assembly/RumEventAssembler';
import { writeMapped } from '../RumEventMapperHolder';

const SESSION_INACTIVITY_MS: number = 15 * 60 * 1000;     // 15 min
const SESSION_MAX_DURATION_MS: number = 4 * 60 * 60 * 1000; // 4 h
// Closed views kept alive until their in-flight resources settle. Bounded so a
// leak of never-settling requests can't pin unbounded view scopes.
const MAX_DRAINING_VIEWS: number = 3;

/**
 * One user session. Owns the current view scope, applies the sampling decision,
 * and expires on inactivity / max-duration. Equivalent to Android's RumSessionScope.
 */
export class RumSessionScope implements RumScope {
  private readonly featureScope: FeatureScope;
  private readonly core: SdkCore;
  private readonly applicationId: string;
  private readonly sessionId: string;
  private readonly sampled: boolean;
  private readonly startedAtMs: number;
  private lastActivityMs: number;
  private lastKeepAliveMs: number = 0;
  private activeView: RumViewScope | null = null;
  // Last view this session started, so the parent can restart it in the
  // replacement session after expiry (Android/iOS parity). Without this, a
  // session renewed after the 15-min inactivity gap has no view at all: actions
  // and resources are silently dropped, errors go out viewless, and the backend
  // — which materializes session rows exclusively from view events — never
  // creates the session, so its duration reads as 0/missing.
  private lastViewKey: string | null = null;
  private lastViewName: string = '';
  private lastViewAttributes: Record<string, Object> = {};
  // Most recently closed view (regardless of pending resources): a crash landing
  // in the gap between stopView and the next startView is counted on it, so the
  // crash still reaches session_crash_count (derived from view docs only).
  private lastStoppedView: RumViewScope | null = null;
  // Closed/superseded views still owning in-flight resources — late responses
  // are routed here so the slow and failing requests (exactly the ones that
  // outlive a navigation) are not systematically lost.
  private readonly drainingViews: RumViewScope[] = [];

  constructor(
    featureScope: FeatureScope,
    core: SdkCore,
    applicationId: string,
    sampleRate: number,
    startedAtMs: number
  ) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sessionId = util.generateRandomUUID(true);
    this.startedAtMs = startedAtMs;
    this.lastActivityMs = startedAtMs;
    this.sampled = RumSessionScope.decideSampling(sampleRate);
    const update: Record<string, Object> = {};
    update['session.id'] = this.sessionId;
    update['session.sampled'] = this.sampled;
    this.core.updateFeatureContext('rum', update);
  }

  handleEvent(event: RumRawEvent): RumScope | null {
    if (this.isExpired(event.timestampMs)) {
      // Close the open view before discarding the session, so its final state is
      // sent. Close it at the last observed-alive time, NOT at the detecting
      // event's time: after a background gap the detecting event can be hours
      // later, and stamping it would credit the whole idle gap to the view
      // (a 5-min visit reads as 4 h of time_spent).
      if (this.activeView !== null) {
        const closeAtMs: number = Math.max(this.lastActivityMs, this.lastKeepAliveMs);
        // A crash that itself detects the expiry belongs to THIS session (the
        // incident snapshot already carries this session/view id): count it in
        // the final document, not in a phantom replacement session.
        if (event.kind === 'markCrash') {
          this.activeView.countCrash();
        }
        this.activeView.forceStop(closeAtMs);
        this.activeView = null;
      }
      // Un-publish the session identity so a crash in the gap before the next
      // session isn't attributed to this dead one (the context is merge-only).
      const cleared: Record<string, Object> = {};
      cleared['session.id'] = '';
      this.core.updateFeatureContext('rum', cleared);
      return null; // parent starts a fresh session and replays the event
    }

    // Keep-alive only refreshes the active view's time_spent; it must NOT count as
    // activity (else inactivity expiry never fires) and must not start a view.
    if (event.kind === 'keepAlive') {
      this.lastKeepAliveMs = event.timestampMs;
      if (this.sampled && this.activeView !== null) {
        this.activeView.handleEvent(event);
      }
      return this;
    }

    // Monotonic: a backdated event (e.g. a timed action stamped at its START
    // time) must never move last-activity backwards — that would make the very
    // next event read as a >15-min gap and force-expire a healthy session.
    this.lastActivityMs = Math.max(this.lastActivityMs, event.timestampMs);

    if (!this.sampled) {
      return this; // session dropped — track lifecycle but emit nothing
    }

    if (event.kind === 'startView') {
      // A new view supersedes the current one — stop the old view first.
      if (this.activeView !== null) {
        this.activeView.forceStop(event.timestampMs);
        this.retireView(this.activeView);
      }
      this.lastViewKey = event.key ?? '';
      this.lastViewName = event.name ?? '';
      this.lastViewAttributes = event.attributes;
      const viewId: string = util.generateRandomUUID(true);
      this.activeView = new RumViewScope(
        this.featureScope, this.core, this.applicationId, this.sessionId,
        event.key ?? '', event.name ?? '', viewId, event.timestampMs, event.attributes);
      return this;
    }

    // Late resource completions may belong to an already-closed view held in
    // the draining set — route by ownership, not blindly to the active view.
    if (event.kind === 'stopResource' || event.kind === 'stopResourceWithError') {
      const resourceKey: string = event.key ?? '';
      if (this.activeView !== null && this.activeView.hasPendingResource(resourceKey)) {
        this.activeView.handleEvent(event);
      } else {
        this.dispatchToDrainingViews(event, resourceKey);
      }
      return this;
    }

    if (this.activeView !== null) {
      const result: RumScope | null = this.activeView.handleEvent(event);
      if (result === null) {
        this.retireView(this.activeView);
        this.activeView = null;
      }
    } else if (event.kind === 'markCrash') {
      // Crash in the gap between stopView and the next startView: count it on
      // the most recently closed view (an extra document version with frozen
      // time_spent) — otherwise the crash reaches the error list but never
      // session_crash_count, which the backend derives from view docs only.
      if (this.lastStoppedView !== null) {
        this.lastStoppedView.handleEvent(event);
      } else {
        FlashcatLog.d('rum.session: markCrash with no view — crash not counted in any view document');
      }
    } else if (event.kind === 'addError') {
      this.writeViewlessError(event); // error before any view started
    } else if (event.kind === 'addAction' || event.kind === 'startResource') {
      // Surfaced so integrators can see why their data is missing — previously
      // these were dropped with no trace at any log level.
      FlashcatLog.d(`rum.session: dropped viewless ${event.kind} — no active view (missing startView?)`);
    }
    return this;
  }

  /** Keep a closed view alive (bounded) while it still owns in-flight resources,
   *  and remember it as the most recently closed view for crash counting. */
  private retireView(view: RumViewScope): void {
    this.lastStoppedView = view;
    if (!view.hasPendingResources()) {
      return;
    }
    this.drainingViews.push(view);
    while (this.drainingViews.length > MAX_DRAINING_VIEWS) {
      this.drainingViews.shift();
    }
  }

  private dispatchToDrainingViews(event: RumRawEvent, resourceKey: string): void {
    for (let i: number = 0; i < this.drainingViews.length; i++) {
      const view: RumViewScope = this.drainingViews[i];
      if (view.hasPendingResource(resourceKey)) {
        view.handleEvent(event);
        if (!view.hasPendingResources()) {
          this.drainingViews.splice(i, 1); // fully drained — release the scope
        }
        return;
      }
    }
    FlashcatLog.d('rum.session: dropped resource completion for unknown key');
  }

  getSessionId(): string {
    return this.sessionId;
  }

  getLastViewKey(): string | null {
    return this.lastViewKey;
  }

  getLastViewName(): string {
    return this.lastViewName;
  }

  getLastViewAttributes(): Record<string, Object> {
    return this.lastViewAttributes;
  }

  isSampled(): boolean {
    return this.sampled;
  }

  private writeViewlessError(raw: RumRawEvent): void {
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.error(
        context, this.applicationId, this.sessionId, undefined, undefined,
        raw.errorMessage ?? '', raw.errorSource ?? 'source', raw.errorStack,
        raw.isCrash ?? false, raw.errorHandling ?? 'handled', raw.timestampMs, raw.attributes);
      writeMapped(writer, event, true);
    });
  }

  private isExpired(nowMs: number): boolean {
    return (nowMs - this.lastActivityMs) >= SESSION_INACTIVITY_MS
      || (nowMs - this.startedAtMs) >= SESSION_MAX_DURATION_MS;
  }

  private static decideSampling(sampleRate: number): boolean {
    // Per-session coin flip (sampleRate is 0..100). Independent per session.
    if (sampleRate >= 100) {
      return true;
    }
    if (sampleRate <= 0) {
      return false;
    }
    return (Math.random() * 100) < sampleRate;
  }
}
