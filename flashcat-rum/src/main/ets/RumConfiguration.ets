import { RumEventMapper } from './RumTypes';

/**
 * RUM feature configuration. Built via {@link RumConfigurationBuilder}.
 * Mirrors `RumConfiguration.Builder(applicationId)` on Android.
 */
export class RumConfiguration {
  readonly applicationId: string;
  readonly sessionSampleRate: number;       // 0..100
  readonly trackUserInteractions: boolean;
  readonly trackNavigation: boolean;        // auto page tracking via UIObserver
  readonly trackNetworkRequests: boolean;   // auto resource tracking
  readonly trackFrustrations: boolean;
  readonly eventMapper: RumEventMapper | null;  // phase 2 R3: PII scrubbing / drop

  constructor(
    applicationId: string,
    sessionSampleRate: number,
    trackUserInteractions: boolean,
    trackNavigation: boolean,
    trackNetworkRequests: boolean,
    trackFrustrations: boolean,
    eventMapper: RumEventMapper | null = null
  ) {
    this.applicationId = applicationId;
    this.sessionSampleRate = sessionSampleRate;
    this.trackUserInteractions = trackUserInteractions;
    this.trackNavigation = trackNavigation;
    this.trackNetworkRequests = trackNetworkRequests;
    this.trackFrustrations = trackFrustrations;
    this.eventMapper = eventMapper;
  }
}

export class RumConfigurationBuilder {
  private readonly applicationId: string;
  private sessionSampleRate: number = 100;
  // Auto-instrumentation toggles are INERT in phase 1 (no nav/interaction/network
  // tracking yet) — default off so the config surface doesn't over-promise. They are
  // wired in phase 2; until then only manual startView/stopView/addError work.
  private trackUserInteractions: boolean = false;
  private trackNavigation: boolean = false;
  private trackNetworkRequests: boolean = false;
  private trackFrustrations: boolean = false;
  private eventMapper: RumEventMapper | null = null;

  constructor(applicationId: string) {
    this.applicationId = applicationId;
  }

  setSessionSampleRate(rate: number): RumConfigurationBuilder {
    this.sessionSampleRate = rate;
    return this;
  }

  setTrackUserInteractions(enabled: boolean): RumConfigurationBuilder {
    this.trackUserInteractions = enabled;
    return this;
  }

  setTrackNavigation(enabled: boolean): RumConfigurationBuilder {
    this.trackNavigation = enabled;
    return this;
  }

  setTrackNetworkRequests(enabled: boolean): RumConfigurationBuilder {
    this.trackNetworkRequests = enabled;
    return this;
  }

  /**
   * @deprecated NOT YET IMPLEMENTED — accepted for Android-parity source
   * compatibility only. Frustration signals (rage tap / error tap) are not
   * detected on HarmonyOS yet; enabling this has no effect.
   */
  setTrackFrustrations(enabled: boolean): RumConfigurationBuilder {
    this.trackFrustrations = enabled;
    return this;
  }

  /**
   * Phase 2 R3: set an event mapper to redact/drop View/Action/Error/Resource
   * events before upload. Return a modified event, or `null` to drop it. Must be
   * cheap and must not throw (a throwing mapper is contained).
   */
  setEventMapper(mapper: RumEventMapper): RumConfigurationBuilder {
    this.eventMapper = mapper;
    return this;
  }

  build(): RumConfiguration {
    return new RumConfiguration(
      this.applicationId,
      this.sessionSampleRate,
      this.trackUserInteractions,
      this.trackNavigation,
      this.trackNetworkRequests,
      this.trackFrustrations,
      this.eventMapper
    );
  }
}
