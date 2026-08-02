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

  constructor(featureScope: FeatureScope, core: SdkCore, applicationId: string, sampleRate: number) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sampleRate = sampleRate;
  }

  handleEvent(event: RumRawEvent): RumScope | null {
    if (this.session === null) {
      // A keep-alive carries no user intent — it must never start a session.
      if (event.kind === 'keepAlive') {
        return this;
      }
      this.session = this.startNewSession(event.timestampMs);
      this.maybeRestartExpiredView(this.session, event);
    }
    const result: RumScope | null = this.session.handleEvent(event);
    if (result === null) {
      this.rememberExpiredView(this.session);
      // Session expired. Don't recreate from a keep-alive — only a real event
      // starts the next session.
      if (event.kind === 'keepAlive') {
        this.session = null;
        return this;
      }
      this.session = this.startNewSession(event.timestampMs);
      this.maybeRestartExpiredView(this.session, event);
      this.session.handleEvent(event);
    }
    return this;
  }

  private rememberExpiredView(session: RumSessionScope): void {
    const key: string | null = session.getLastViewKey();
    if (key !== null) {
      this.lastExpiredViewKey = key;
      this.lastExpiredViewName = session.getLastViewName();
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
    const key: string | null = this.lastExpiredViewKey;
    const name: string = this.lastExpiredViewName;
    this.lastExpiredViewKey = null; // one-shot: consumed or superseded
    this.lastExpiredViewName = '';
    if (key === null) {
      return;
    }
    if (event.kind !== 'addAction' && event.kind !== 'addError'
      && event.kind !== 'startResource' && event.kind !== 'markCrash') {
      return;
    }
    const restart: RumRawEvent = {
      kind: 'startView',
      key: key,
      name: name,
      attributes: {},
      timestampMs: event.timestampMs
    };
    session.handleEvent(restart);
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
