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
  /** Keep the sessions `sessionSampleRate` misses when they report an error. Default false. */
  readonly sessionOnError: boolean;
  /** Send the once-a-day active-device beacon. Default true. */
  readonly trackActiveDevices: boolean;

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
    beforeSampling: BeforeSamplingCallback | null = null,
    sessionOnError: boolean = false,
    trackActiveDevices: boolean = true
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
    this.sessionOnError = sessionOnError;
    this.trackActiveDevices = trackActiveDevices;
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
  private sessionOnError: boolean = false;
  private trackActiveDevices: boolean = true;

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
   * Crash reporting is NOT affected: uncaught exceptions still follow the crash
   * policy and are reported as `is_crash` errors (persisted and replayed into
   * the crashed session, or reported live under `REPORT_AND_CONTINUE`; without
   * the crash module, reported live before the process exits). The one policy this does not hold for is
   * `OBSERVE_ONLY`, which reports an uncaught exception as a non-crash error:
   * with trackErrors=false it is not reported at all. Manual `addError` calls are
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
   * A published rate applies to the next session drawn. A decisive change
   * through zero or an immediate activation may end the current session;
   * sampling never changes within a session. Values already
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
   * new session is about to be drawn and when configuration arrives, with the
   * rate that would apply and the console's custom values. Keep the callback
   * lightweight, free of side effects and deterministic: it runs on the caller's
   * thread. Do not perform I/O or report RUM events from it. Reentrant events
   * and session operations are ignored until the callback returns. Return a rate
   * to override, or nothing to leave it alone. Typical use is an allow-list: keep every session of the handful of
   * users you are debugging while the fleet stays at a low rate.
   */
  setBeforeSampling(callback: BeforeSamplingCallback): RumConfigurationBuilder {
    this.beforeSampling = callback;
    return this;
  }

  /**
   * Also keep the sessions `sessionSampleRate` does not sample, but only those
   * that report an error. Default false.
   *
   * Such a session is collected in memory and none of its events is uploaded until it
   * reports an error of its own — one that survives the event mapper. Then the
   * minute leading up to that error (its views, and up to 200 actions, resources
   * and errors within 64 KiB, the least informative dropped first when there are
   * more) is uploaded, after a delay of up to 3 s that spreads out the uploads a
   * fleet-wide failure would otherwise send all at once, and the rest of the
   * session is collected normally. A session that ends without an error is
   * thrown away with everything it held, and nothing of it — not even a crash
   * replayed on the next launch — reaches the backend afterwards. An uncaught
   * ArkTS exception the event mapper keeps releases what was held at once,
   * before the process exits, with or without the crash feature; one the
   * mapper drops releases nothing and is not reported. A native crash or a
   * freeze, reported on the next launch, is delivered with the last view of
   * the session only — what was held in memory died with the process.
   *
   * Such sessions report a session sample rate of 0 and
   * `session.sampled_for_error: true`: each one stands for itself rather than
   * for `100 / rate` sessions. A rate the `beforeSampling` hook sets to 0 turns
   * this off for that session — 0 means never collect.
   *
   * With remote configuration enabled, the console's `sessionOnError` overrides
   * this value for the sessions drawn after it arrives.
   */
  setSessionOnError(enabled: boolean): RumConfigurationBuilder {
    this.sessionOnError = enabled;
    return this;
  }

  /**
   * Report that the app is in use: at most one beacon per local day per device,
   * user and app version. Default true.
   *
   * A small request of its own, sent straight away rather than with the event
   * batches, so that a session too short to upload its events still counts the
   * device as active that day. Sent when the app starts or returns to the
   * foreground, when tracking consent is granted and when a new user is set —
   * only while the app is in the foreground and consent is granted. It carries
   * the app, OS and device fields and the anonymous and user ids, nothing else,
   * and is sent regardless of session sampling. One that cannot be delivered is
   * kept and sent on a later launch, up to 72 hours after the app was used.
   */
  setTrackActiveDevices(enabled: boolean): RumConfigurationBuilder {
    this.trackActiveDevices = enabled;
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
      this.beforeSampling,
      this.sessionOnError,
      this.trackActiveDevices
    );
  }
}
