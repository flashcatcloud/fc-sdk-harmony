import { FeatureScope, FlashcatContext, EventWriter, SdkCore } from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { RumScope, RumRawEvent } from './RumScope';
import { RumViewScope } from './RumViewScope';
import { RumEventAssembler } from '../assembly/RumEventAssembler';
import { writeMapped } from '../RumEventMapperHolder';

const SESSION_INACTIVITY_MS: number = 15 * 60 * 1000;     // 15 min
const SESSION_MAX_DURATION_MS: number = 4 * 60 * 60 * 1000; // 4 h

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
  private activeView: RumViewScope | null = null;
  // View that was active when this session expired, so the parent can restart
  // it in the replacement session (Android/iOS parity). Without this, a session
  // renewed after the 15-min inactivity gap has no view at all: actions and
  // resources are silently dropped, errors go out viewless, and the backend —
  // which materializes session rows exclusively from view events — never
  // creates the session, so its duration reads as 0/missing.
  private expiredViewKey: string | null = null;
  private expiredViewName: string | null = null;

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
      // Close the open view before discarding the session, so its final state is sent.
      if (this.activeView !== null) {
        this.expiredViewKey = this.activeView.getViewKey();
        this.expiredViewName = this.activeView.getViewName();
        this.activeView.forceStop(event.timestampMs);
        this.activeView = null;
      }
      return null; // parent starts a fresh session and replays the event
    }

    // Keep-alive only refreshes the active view's time_spent; it must NOT count as
    // activity (else inactivity expiry never fires) and must not start a view.
    if (event.kind === 'keepAlive') {
      if (this.sampled && this.activeView !== null) {
        this.activeView.handleEvent(event);
      }
      return this;
    }

    this.lastActivityMs = event.timestampMs;

    if (!this.sampled) {
      return this; // session dropped — track lifecycle but emit nothing
    }

    if (event.kind === 'startView') {
      // A new view supersedes the current one — stop the old view first.
      if (this.activeView !== null) {
        this.activeView.forceStop(event.timestampMs);
      }
      const viewId: string = util.generateRandomUUID(true);
      this.activeView = new RumViewScope(
        this.featureScope, this.core, this.applicationId, this.sessionId,
        event.key ?? '', event.name ?? '', viewId, event.timestampMs, event.attributes);
      return this;
    }

    if (this.activeView !== null) {
      const result: RumScope | null = this.activeView.handleEvent(event);
      if (result === null) {
        this.activeView = null;
      }
    } else if (event.kind === 'addError') {
      this.writeViewlessError(event); // error before any view started
    }
    return this;
  }

  getSessionId(): string {
    return this.sessionId;
  }

  getExpiredViewKey(): string | null {
    return this.expiredViewKey;
  }

  getExpiredViewName(): string | null {
    return this.expiredViewName;
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
