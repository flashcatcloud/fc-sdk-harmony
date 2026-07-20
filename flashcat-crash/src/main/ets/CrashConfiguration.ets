/** Policy applied to uncaught main-thread ArkTS exceptions. */
export enum JsCrashPolicy {
  /** Persist a crash incident synchronously, then restore platform exit semantics. */
  REPORT_THEN_EXIT = 'REPORT_THEN_EXIT',
  /** Phase 2: persist then restart. Phase 1 falls back to REPORT_THEN_EXIT. */
  REPORT_AND_RECOVER = 'REPORT_AND_RECOVER',
  /** Legacy behavior: report asynchronously and leave the process running. */
  OBSERVE_ONLY = 'OBSERVE_ONLY'
}

/**
 * Configuration for crash reporting. Built with {@link CrashConfigurationBuilder}.
 * Mirrors the RumConfiguration builder shape used elsewhere in this SDK.
 */
export class CrashConfiguration {
  /** Capture native (C/C++ .so) + ArkTS crashes via hiAppEvent APP_CRASH. Default true. */
  readonly trackCrashes: boolean;
  /** Capture app freezes (hiAppEvent APP_FREEZE / watchdog timeout). Default true. */
  readonly trackAppHangs: boolean;
  /** Percentage [0,100] of hiAppEvent crash/freeze events to report. Default 100. */
  readonly sampleRate: number;
  /** Behavior for uncaught main-thread ArkTS exceptions. Default REPORT_THEN_EXIT. */
  readonly jsCrashPolicy: JsCrashPolicy;

  constructor(
    trackCrashes: boolean,
    trackAppHangs: boolean,
    sampleRate: number,
    jsCrashPolicy: JsCrashPolicy = JsCrashPolicy.REPORT_THEN_EXIT
  ) {
    this.trackCrashes = trackCrashes;
    this.trackAppHangs = trackAppHangs;
    this.sampleRate = sampleRate;
    this.jsCrashPolicy = jsCrashPolicy;
  }
}

export class CrashConfigurationBuilder {
  private trackCrashes: boolean = true;
  private trackAppHangs: boolean = true;
  private sampleRate: number = 100;
  private jsCrashPolicy: JsCrashPolicy = JsCrashPolicy.REPORT_THEN_EXIT;

  setTrackCrashes(enabled: boolean): CrashConfigurationBuilder {
    this.trackCrashes = enabled;
    return this;
  }

  setTrackAppHangs(enabled: boolean): CrashConfigurationBuilder {
    this.trackAppHangs = enabled;
    return this;
  }

  /** Set the hiAppEvent report sample rate, clamped to [0,100]. Default 100. */
  setSampleRate(rate: number): CrashConfigurationBuilder {
    this.sampleRate = rate < 0 ? 0 : (rate > 100 ? 100 : rate);
    return this;
  }

  setJsCrashPolicy(policy: JsCrashPolicy): CrashConfigurationBuilder {
    this.jsCrashPolicy = policy;
    return this;
  }

  build(): CrashConfiguration {
    return new CrashConfiguration(
      this.trackCrashes,
      this.trackAppHangs,
      this.sampleRate,
      this.jsCrashPolicy);
  }
}
