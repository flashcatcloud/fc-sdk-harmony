/**
 * Configuration for crash reporting. Built with {@link CrashConfigurationBuilder}.
 * Mirrors the RumConfiguration builder shape used elsewhere in this SDK.
 */
export class CrashConfiguration {
  /** Capture native (C/C++ .so) + ArkTS crashes via hiAppEvent APP_CRASH. Default true. */
  readonly trackCrashes: boolean;
  /** Capture app freezes (hiAppEvent APP_FREEZE / watchdog timeout). Default true. */
  readonly trackAppHangs: boolean;
  /** Percentage [0,100] of captured crashes/freezes to report. Default 100 (all). */
  readonly sampleRate: number;

  constructor(trackCrashes: boolean, trackAppHangs: boolean, sampleRate: number) {
    this.trackCrashes = trackCrashes;
    this.trackAppHangs = trackAppHangs;
    this.sampleRate = sampleRate;
  }
}

export class CrashConfigurationBuilder {
  private trackCrashes: boolean = true;
  private trackAppHangs: boolean = true;
  private sampleRate: number = 100;

  setTrackCrashes(enabled: boolean): CrashConfigurationBuilder {
    this.trackCrashes = enabled;
    return this;
  }

  setTrackAppHangs(enabled: boolean): CrashConfigurationBuilder {
    this.trackAppHangs = enabled;
    return this;
  }

  /** Set the crash report sample rate, clamped to [0,100]. Default 100. */
  setSampleRate(rate: number): CrashConfigurationBuilder {
    this.sampleRate = rate < 0 ? 0 : (rate > 100 ? 100 : rate);
    return this;
  }

  build(): CrashConfiguration {
    return new CrashConfiguration(this.trackCrashes, this.trackAppHangs, this.sampleRate);
  }
}
