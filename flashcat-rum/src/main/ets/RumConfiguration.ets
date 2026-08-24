import { RumEventMapper, BeforeSamplingCallback } from './RumTypes';

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
  readonly trackErrors: boolean;            // AUTO error capture (crashes unaffected)
  readonly eventMapper: RumEventMapper | null;  // phase 2 R3: PII scrubbing / drop
  /** Whether to read the sampling settings the console publishes. Default false. */
  readonly remoteConfigurationEnabled: boolean;
  readonly beforeSampling: BeforeSamplingCallback | null;

  constructor(
    applicationId: string,
    sessionSampleRate: number,
    trackUserInteractions: boolean,
    trackNavigation: boolean,
    trackNetworkRequests: boolean,
    trackFrustrations: boolean,
    eventMapper: RumEventMapper | null = null,
    trackErrors: boolean = true,
    remoteConfigurationEnabled: boolean = false,
    beforeSampling: BeforeSamplingCallback | null = null
  ) {
    this.applicationId = applicationId;
    this.sessionSampleRate = sessionSampleRate;
    this.trackUserInteractions = trackUserInteractions;
    this.trackNavigation = trackNavigation;
    this.trackNetworkRequests = trackNetworkRequests;
    this.trackFrustrations = trackFrustrations;
    this.trackErrors = trackErrors;
    this.eventMapper = eventMapper;
    this.remoteConfigurationEnabled = remoteConfigurationEnabled;
    this.beforeSampling = beforeSampling;
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
  private trackErrors: boolean = true;
  private eventMapper: RumEventMapper | null = null;
  private remoteConfigurationEnabled: boolean = false;
  private beforeSampling: BeforeSamplingCallback | null = null;

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

  /**
   * Enable/disable AUTOMATIC error capture (uncaught non-crash reports and
   * unhandled Promise rejections). Default true.
   *
   * Crash reporting is NOT affected: with the crash module enabled, uncaught
   * exceptions still follow the crash policy (persisted, counted, replayed as
   * `is_crash` errors into the crashed session). Manual `addError` calls are
   * the app's explicit intent and also remain delivered — use the event
   * mapper to drop those too if needed.
   */
  setTrackErrors(enabled: boolean): RumConfigurationBuilder {
    this.trackErrors = enabled;
    return this;
  }

  /**
   * Read the sampling settings published for this application in the console.
   * Default false — nothing is fetched, and every rate stays exactly what this
   * builder was given.
   *
   * A published rate applies to the NEXT session drawn, never to the one
   * running: a session is decided once, at its creation. Values already
   * fetched survive a restart, so the first session of a launch is drawn under
   * them; when nothing has ever been fetched, or the console has the feature
   * switched off, the init values apply.
   */
  setRemoteConfigurationEnabled(enabled: boolean): RumConfigurationBuilder {
    this.remoteConfigurationEnabled = enabled;
    return this;
  }

  /**
   * Have the last word on session sampling. Called synchronously each time a
   * new session is about to be drawn, with the rate that would apply and the
   * console's custom values; return a rate to override, or nothing to leave it
   * alone. Typical use is an allow-list: keep every session of the handful of
   * users you are debugging while the fleet stays at a low rate.
   */
  setBeforeSampling(callback: BeforeSamplingCallback): RumConfigurationBuilder {
    this.beforeSampling = callback;
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
      this.eventMapper,
      this.trackErrors,
      this.remoteConfigurationEnabled,
      this.beforeSampling
    );
  }
}
