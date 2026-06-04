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

  constructor(featureScope: FeatureScope, core: SdkCore, applicationId: string, sampleRate: number) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sampleRate = sampleRate;
  }

  handleEvent(event: RumRawEvent): RumScope | null {
    if (this.session === null) {
      this.session = this.startNewSession(event.timestampMs);
    }
    const result: RumScope | null = this.session.handleEvent(event);
    if (result === null) {
      // Expired session — start a fresh one and replay the triggering event.
      this.session = this.startNewSession(event.timestampMs);
      this.session.handleEvent(event);
    }
    return this;
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
