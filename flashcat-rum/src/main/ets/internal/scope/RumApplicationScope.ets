import { FeatureScope, SdkCore } from '@flashcatcloud/core';
import { RumScope, RumRawEvent } from './RumScope';
import { RumSessionScope } from './RumSessionScope';

/**
 * Root of the RUM scope tree. Creates and replaces sessions as they expire.
 * Equivalent to Android's RumApplicationScope.
 */
export class RumApplicationScope implements RumScope {
  private readonly featureScope: FeatureScope;
  private readonly core: SdkCore;
  private readonly applicationId: string;
  private readonly sampleRate: number;
  private session: RumSessionScope | null = null;
  // View active when the previous session expired, restarted (once) in the
  // replacement session. Held here — not on the session — because a session
  // discarded on a keep-alive is replaced only later, by the next real event.
  private lastExpiredViewKey: string | null = null;
  private lastExpiredViewName: string = '';
  private lastExpiredViewAttributes: Record<string, Object> = {};

  constructor(featureScope: FeatureScope, core: SdkCore, applicationId: string, sampleRate: number) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sampleRate = sampleRate;
  }

  handleEvent(event: RumRawEvent): RumScope | null {
    if (this.session === null) {
      // Only events that carry NEW user intent may mint a session:
      // - keepAlive carries none.
      // - markCrash belongs to the PREVIOUS session (the persisted incident
      //   already snapshots its ids) — a fresh session here would count the
      //   crash in a phantom session the replayed error never joins.
      // - stop-type events merely close out something from a dead session; a
      //   session minted for them emits zero view documents (invisible to the
      //   backend) yet publishes its session.id — a ghost that swallows
      //   subsequent activity and mis-stamps crash snapshots.
      if (!RumApplicationScope.startsUserActivity(event)) {
        return this;
      }
      this.session = this.startNewSession(event.timestampMs);
      this.maybeRestartExpiredView(this.session, event);
    }
    const result: RumScope | null = this.session.handleEvent(event);
    if (result === null) {
      this.rememberExpiredView(this.session);
      // Session expired. Same rule as above for the replacement session.
      if (!RumApplicationScope.startsUserActivity(event)) {
        this.session = null;
        return this;
      }
      this.session = this.startNewSession(event.timestampMs);
      this.maybeRestartExpiredView(this.session, event);
      this.session.handleEvent(event);
    }
    return this;
  }

  private static startsUserActivity(event: RumRawEvent): boolean {
    return event.kind !== 'keepAlive' && event.kind !== 'markCrash'
      && event.kind !== 'stopView' && event.kind !== 'stopResource'
      && event.kind !== 'stopResourceWithError';
  }

  private rememberExpiredView(session: RumSessionScope): void {
    const key: string | null = session.getLastViewKey();
    if (key !== null) {
      this.lastExpiredViewKey = key;
      this.lastExpiredViewName = session.getLastViewName();
      this.lastExpiredViewAttributes = session.getLastViewAttributes();
    }
  }

  /**
   * Restart the previous session's last view in the replacement session
   * (Datadog Android/iOS parity). Without this, a renewed session has no view:
   * actions/resources are silently dropped, errors go out viewless, and the
   * backend — which materializes session rows exclusively from view events —
   * never creates the session, so its duration reads as 0/missing.
   *
   * Only events that represent NEW user activity warrant a restart. A
   * startView brings its own view, and a stopView / stopResource* merely closes
   * out something from the dead session — restarting for those would let the
   * act of leaving manufacture a phantom zero-duration session.
   */
  private maybeRestartExpiredView(session: RumSessionScope, event: RumRawEvent): void {
    if (event.kind !== 'addAction' && event.kind !== 'addError'
      && event.kind !== 'startResource') {
      // NOT consumed: a non-qualifying event must not burn the remembered view,
      // or the next qualifying event finds nothing to restart.
      return;
    }
    const key: string | null = this.lastExpiredViewKey;
    const name: string = this.lastExpiredViewName;
    const attributes: Record<string, Object> = this.lastExpiredViewAttributes;
    this.lastExpiredViewKey = null; // one-shot: consumed
    this.lastExpiredViewName = '';
    this.lastExpiredViewAttributes = {};
    if (key === null) {
      return;
    }
    // Restart with the ORIGINAL start attributes — they carry the resolved
    // view.url (route path); an empty set would regress the restarted
    // incarnation to the opaque pageId and split URL grouping.
    const restart: RumRawEvent = {
      kind: 'startView',
      key: key,
      name: name,
      attributes: attributes,
      timestampMs: event.timestampMs
    };
    session.handleEvent(restart);
  }

  /**
   * RumMonitor.stopSession: end the current session immediately. The last view
   * is remembered so the next tracked event starts a fresh session and
   * restarts it there (same recovery path as inactivity expiry).
   */
  stopCurrentSession(nowMs: number): void {
    if (this.session === null) {
      return;
    }
    this.rememberExpiredView(this.session);
    this.session.end(nowMs);
    this.session = null;
  }

  getApplicationId(): string {
    return this.applicationId;
  }

  getCurrentSessionId(): string | undefined {
    return this.session?.getSessionId();
  }

  private startNewSession(nowMs: number): RumSessionScope {
    return new RumSessionScope(this.featureScope, this.core, this.applicationId, this.sampleRate, nowMs);
  }
}
