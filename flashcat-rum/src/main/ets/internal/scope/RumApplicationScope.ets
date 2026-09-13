import { FeatureScope, SdkCore, FlashcatLog } from '@flashcatcloud/core';
import { RumScope, RumRawEvent } from './RumScope';
import { RumSessionScope } from './RumSessionScope';
import { RemoteConfigStore, RemoteConfigValues, DrawnConfiguration } from '../remoteconfig/RemoteConfigStore';
import { BeforeSamplingCallback, BeforeSamplingContext } from '../../RumTypes';

/** What a forced session reports: it is kept whatever the rates say, so it stands for itself. */
const FORCED_SAMPLE_RATE: number = 100;
/** The console asking for a change to reach the session that is already running. */
const ACTIVATION_IMMEDIATE: string = 'immediate';

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
  // The most recently ended session that still owns in-flight resources: late
  // completions are settled into it (correct session/view attribution) instead
  // of being dropped. Session teardown (stopSession, inactivity expiry, 4-h
  // renewal) used to discard every in-flight scope — a request 2 s old that
  // merely spanned the renewal boundary was lost.
  private drainingSession: RumSessionScope | null = null;
  // Null unless the app opted into remote configuration; then it is where the
  // rates the console published are read from at every draw.
  private readonly remoteConfig: RemoteConfigStore | null;
  private readonly beforeSampling: BeforeSamplingCallback | null;
  // Told after every draw, so the configuration is refreshed at the rhythm of
  // the sessions that read it.
  private readonly onSessionStarted: (() => void) | null;
  // Set through RumMonitor.setForcedSession, read at every draw from then on.
  // Process-lifetime, like the debugging decision it represents.
  private forced: boolean = false;
  // A deferred change need not match the running session's draw. Remember the
  // last resolved rate so republishing it cannot turn a deferral into a redraw.
  private lastResolvedRate: number | null = null;
  private invokingBeforeSampling: boolean = false;

  constructor(
    featureScope: FeatureScope,
    core: SdkCore,
    applicationId: string,
    sampleRate: number,
    remoteConfig: RemoteConfigStore | null = null,
    beforeSampling: BeforeSamplingCallback | null = null,
    onSessionStarted: (() => void) | null = null
  ) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sampleRate = sampleRate;
    this.remoteConfig = remoteConfig;
    this.beforeSampling = beforeSampling;
    this.onSessionStarted = onSessionStarted;
  }

  handleEvent(event: RumRawEvent): RumScope | null {
    if (this.invokingBeforeSampling) {
      return this;
    }
    // Late completions owned by an already-ended session settle into it.
    if ((event.kind === 'stopResource' || event.kind === 'stopResourceWithError')
      && this.drainingSession !== null
      && (this.session === null || !this.session.ownsResource(event.key ?? ''))
      && this.drainingSession.ownsResource(event.key ?? '')) {
      this.drainingSession.settleResource(event);
      if (!this.drainingSession.hasUnsettledResources()) {
        this.drainingSession = null; // fully drained — release the scope
      }
      return this;
    }
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
      // Clamp the mint time to now: a BACKDATED event (a timed action stamped
      // at its start) must not create a session in the past — the restarted
      // view's doc would date the session 20 min ago and the very next event
      // would instantly re-expire it, materializing a phantom ~0-duration
      // session row on the backend.
      const mintAtMs: number = Math.max(event.timestampMs, Date.now());
      this.session = this.startNewSession(mintAtMs);
      this.maybeRestartExpiredView(this.session, event, mintAtMs);
    }
    const result: RumScope | null = this.session.handleEvent(event);
    if (result === null) {
      this.rememberExpiredView(this.session);
      if (this.session.hasUnsettledResources()) {
        // Single slot: an older still-draining session is evicted (bounded by
        // design — its remaining completions are dropped, logged for triage).
        if (this.drainingSession !== null && this.drainingSession.hasUnsettledResources()) {
          FlashcatLog.d('rum.app: evicting still-draining session (single draining slot)');
        }
        this.drainingSession = this.session;
      }
      // Session expired. Same rule as above for the replacement session.
      if (!RumApplicationScope.startsUserActivity(event)) {
        // The completion that ITSELF detected the expiry must still settle —
        // the top-of-function draining gate ran before this session became the
        // draining one, so without this the event is silently lost (a request
        // spanning the inactivity gap, completing on resume).
        if ((event.kind === 'stopResource' || event.kind === 'stopResourceWithError')
          && this.drainingSession !== null
          && this.drainingSession.ownsResource(event.key ?? '')) {
          this.drainingSession.settleResource(event);
          if (!this.drainingSession.hasUnsettledResources()) {
            this.drainingSession = null;
          }
        }
        this.session = null;
        return this;
      }
      const replacementMintAtMs: number = Math.max(event.timestampMs, Date.now());
      this.session = this.startNewSession(replacementMintAtMs);
      this.maybeRestartExpiredView(this.session, event, replacementMintAtMs);
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
  private maybeRestartExpiredView(session: RumSessionScope, event: RumRawEvent, restartAtMs: number): void {
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
      timestampMs: restartAtMs
    };
    session.handleEvent(restart);
  }

  /**
   * RumMonitor.stopSession: end the current session immediately. The last view
   * is remembered so the next tracked event starts a fresh session and
   * restarts it there (same recovery path as inactivity expiry).
   */
  stopCurrentSession(nowMs: number): void {
    if (this.invokingBeforeSampling || this.session === null) {
      return;
    }
    this.rememberExpiredView(this.session);
    this.session.end(nowMs);
    if (this.session.hasUnsettledResources()) {
      this.drainingSession = this.session;
    }
    this.session = null;
  }

  getApplicationId(): string {
    return this.applicationId;
  }

  getCurrentSessionId(): string | undefined {
    return this.session?.getSessionId();
  }

  /**
   * Draws a new session under the settings that apply RIGHT NOW: what the
   * console published if anything, the init value otherwise, and finally
   * whatever the app's own hook says. Order matters — the hook is the last
   * word precisely so an allow-list can keep collecting a visitor the console's
   * rate would drop.
   */
  private startNewSession(nowMs: number): RumSessionScope {
    const stored: RemoteConfigValues | null = this.remoteConfig !== null ? this.remoteConfig.read() : null;
    const publishedRate: number | null = stored !== null ? stored.sessionSampleRate : null;
    const baseRate: number = publishedRate !== null ? publishedRate : this.sampleRate;
    const rate: number = this.askBeforeSampling(baseRate, stored);
    this.lastResolvedRate = rate;
    const version: number = stored !== null && stored.version !== null ? stored.version : 0;
    // Carried on every session, whether or not the app opted into remote
    // configuration: the backend weights a session by the rate it reports, and
    // a session that reports none is counted once — the same as an SDK too old
    // to say. The version is the part that is only meaningful when a
    // configuration decided the rate, and it is omitted when none did.
    //
    // A forced session reports neither the rate that would have dropped it nor
    // the version it ignored: it was not drawn by them. Reporting 3 there would
    // have the console weight one debugging visitor as thirty-three sessions.
    const draw: DrawnConfiguration = this.forced
      ? new DrawnConfiguration(0, FORCED_SAMPLE_RATE)
      : new DrawnConfiguration(version, rate);
    const session: RumSessionScope = new RumSessionScope(
      this.featureScope, this.core, this.applicationId, rate, nowMs, this.forced, draw);
    if (this.onSessionStarted !== null) {
      this.onSessionStarted();
    }
    return session;
  }

  /**
   * Asks the app's hook for the rate to draw with. Anything unusable — a throw,
   * a non-number, a rate outside 0..100 — leaves the incoming rate alone: a
   * mistake in the host application must never take a customer's collection
   * down with it.
   */
  private askBeforeSampling(rate: number, stored: RemoteConfigValues | null): number {
    const hook: BeforeSamplingCallback | null = this.beforeSampling;
    if (hook === null) {
      return rate;
    }
    // A hook may accidentally report a RUM event before the new session has
    // been assigned. Ignore reentrant events and session mutations until it
    // returns, rather than recursively drawing more sessions.
    this.invokingBeforeSampling = true;
    try {
      const custom: Record<string, Object> | null =
        stored !== null ? RemoteConfigStore.decodeCustom(stored.custom) : null;
      const context: BeforeSamplingContext = { sessionSampleRate: rate, custom: custom };
      const override: number | undefined = hook(context);
      if (override === undefined || typeof override !== 'number'
        || Number.isNaN(override) || override < 0 || override > 100) {
        return rate;
      }
      return override as number;
    } catch (e) {
      FlashcatLog.e(`rum.app: beforeSampling threw, keeping ${rate}: ${e instanceof Error ? e.message : 'error'}`);
      return rate;
    } finally {
      this.invokingBeforeSampling = false;
    }
  }

  /**
   * A configuration reached storage. The rates it carries apply to the NEXT
   * session drawn — a session already under way is never re-judged on a rate
   * that merely moved. It was drawn by a fair coin, and re-drawing it on every
   * publish would bias collection upward.
   *
   * Three changes do reach the running session. Two are about zero, and hold
   * whatever activation the console asked for:
   *
   * - Collection was off and is now on. Without this, an operator who has just
   *   switched a fleet on sees nothing at all from anyone already using the
   *   app, for as long as their sessions last: up to four hours, and nothing
   *   at all is indistinguishable from broken.
   * - Collection was on and is now off. That is an emergency stop, and an
   *   emergency stop that waits four hours is not one.
   *
   * The third is the console asking for `immediate`, which is a request to
   * re-decide the running session on any rate that really changed — the one
   * case where a move between two non-zero rates is worth a new draw. Even
   * then a replacement that still cannot collect anything is not worth the
   * view it costs, so a dark session is left alone when the new rate is zero.
   */
  onConfigurationChanged(activation: string, _before: number | null, after: number | null, nowMs: number): void {
    if (this.invokingBeforeSampling || this.session === null) {
      return; // the next event mints one, and it will draw under what just arrived
    }
    if (this.forced) {
      // Every replacement would be forced too, so ending this one buys the same
      // session back and costs the view the visitor is on.
      return;
    }
    const nextRate: number = after ?? this.sampleRate;
    // The hook has the last word on the rate that would apply, exactly as it
    // does at a draw, so an allow-list answers this question too. Asked only
    // here, and only once: this is an announcement, not a draw.
    const stored: RemoteConfigValues | null = this.remoteConfig !== null ? this.remoteConfig.read() : null;
    const resolvedRate: number = this.askBeforeSampling(nextRate, stored);
    const previousResolvedRate: number | null = this.lastResolvedRate;
    this.lastResolvedRate = resolvedRate;
    if (resolvedRate === previousResolvedRate || resolvedRate === this.session.getDrawnRate()) {
      return; // unchanged effective settings must not cause another draw
    }
    if (RumApplicationScope.shouldEndSession(
      this.session.isSampled(), this.session.getDrawnRate(), resolvedRate, activation)) {
      this.stopCurrentSession(nowMs);
    }
  }

  /**
   * Whether a change decides anything for the session running right now.
   *
   * `drawnRate` is what that session was actually drawn with, which is the only
   * way to tell a session that could never have been collected from one that
   * lost a fair draw: only the first is owed another chance when collection is
   * switched back on.
   */
  static shouldEndSession(sampled: boolean, drawnRate: number, nextRate: number, activation: string): boolean {
    if (sampled) {
      return nextRate === 0 || activation === ACTIVATION_IMMEDIATE;
    }
    // A dark session is worth replacing only by one that can collect something;
    // otherwise the replacement is just as dark and the visitor lost a view.
    return nextRate > 0 && (drawnRate === 0 || activation === ACTIVATION_IMMEDIATE);
  }

  /**
   * RumMonitor.setForcedSession: from here on every draw keeps the session. A
   * session already being collected keeps running — RUM cannot retro-collect
   * what a running session already dropped — while one that was not collected
   * ends now so a collected one starts in its place.
   */
  forceSession(nowMs: number): void {
    if (this.invokingBeforeSampling) {
      return;
    }
    this.forced = true;
    if (this.session !== null && this.session.isSampled()) {
      return; // already collecting — nothing to end
    }
    this.stopCurrentSession(nowMs);
  }

}
