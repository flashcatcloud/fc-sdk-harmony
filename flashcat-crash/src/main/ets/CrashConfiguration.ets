/** Policy applied to uncaught main-thread ArkTS exceptions. */
export enum JsCrashPolicy {
  /** Persist a crash incident synchronously, then restore platform exit semantics. */
  REPORT_THEN_EXIT = 'REPORT_THEN_EXIT',
  /** Persist synchronously, then restart unless crash-loop protection blocks it. */
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
  /** Number of crashes inside the loop window that blocks another restart. Default 3. */
  readonly crashLoopThreshold: number;
  /** Rolling window used to count recoverable crashes. Default 60 seconds. */
  readonly crashLoopWindowMs: number;
  /** Crash-free duration that resets persisted loop history. Default 5 minutes. */
  readonly crashLoopCooldownMs: number;

  constructor(
    trackCrashes: boolean,
    trackAppHangs: boolean,
    sampleRate: number,
    jsCrashPolicy: JsCrashPolicy = JsCrashPolicy.REPORT_THEN_EXIT,
    crashLoopThreshold: number = 3,
    crashLoopWindowMs: number = 60000,
    crashLoopCooldownMs: number = 300000
  ) {
    this.trackCrashes = trackCrashes;
    this.trackAppHangs = trackAppHangs;
    this.sampleRate = sampleRate;
    this.jsCrashPolicy = jsCrashPolicy;
    this.crashLoopThreshold = crashLoopThreshold;
    this.crashLoopWindowMs = crashLoopWindowMs;
    this.crashLoopCooldownMs = crashLoopCooldownMs;
  }
}

export class CrashConfigurationBuilder {
  private trackCrashes: boolean = true;
  private trackAppHangs: boolean = true;
  private sampleRate: number = 100;
  private jsCrashPolicy: JsCrashPolicy = JsCrashPolicy.REPORT_THEN_EXIT;
  private crashLoopThreshold: number = 3;
  private crashLoopWindowMs: number = 60000;
  private crashLoopCooldownMs: number = 300000;

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

  /**
   * The Nth crash inside the loop window is blocked from restarting, i.e. the
   * window allows at most N-1 recovery restarts. `1` therefore blocks the very
   * first crash — equivalent to disabling recovery restarts entirely: crashes
   * are still reported synchronously, but every one exits instead of restarting
   * and is never labeled crash.recovered.
   */
  setCrashLoopThreshold(threshold: number): CrashConfigurationBuilder {
    this.crashLoopThreshold = threshold < 1 ? 1 : threshold;
    return this;
  }

  setCrashLoopWindowMs(windowMs: number): CrashConfigurationBuilder {
    this.crashLoopWindowMs = windowMs < 1 ? 1 : windowMs;
    return this;
  }

  setCrashLoopCooldownMs(cooldownMs: number): CrashConfigurationBuilder {
    this.crashLoopCooldownMs = cooldownMs < 1 ? 1 : cooldownMs;
    return this;
  }

  build(): CrashConfiguration {
    return new CrashConfiguration(
      this.trackCrashes,
      this.trackAppHangs,
      this.sampleRate,
      this.jsCrashPolicy,
      this.crashLoopThreshold,
      this.crashLoopWindowMs,
      this.crashLoopCooldownMs);
  }
}
