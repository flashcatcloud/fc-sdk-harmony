/**
 * Configuration for crash reporting. Built with {@link CrashConfigurationBuilder}.
 * Mirrors the RumConfiguration builder shape used elsewhere in this SDK.
 */
export class CrashConfiguration {
  /** Capture native (C/C++ .so) + ArkTS crashes via hiAppEvent APP_CRASH. Default true. */
  readonly trackCrashes: boolean;
  /** Capture app freezes (hiAppEvent APP_FREEZE / watchdog timeout). Default true. */
  readonly trackAppHangs: boolean;

  constructor(trackCrashes: boolean, trackAppHangs: boolean) {
    this.trackCrashes = trackCrashes;
    this.trackAppHangs = trackAppHangs;
  }
}

export class CrashConfigurationBuilder {
  private trackCrashes: boolean = true;
  private trackAppHangs: boolean = true;

  setTrackCrashes(enabled: boolean): CrashConfigurationBuilder {
    this.trackCrashes = enabled;
    return this;
  }

  setTrackAppHangs(enabled: boolean): CrashConfigurationBuilder {
    this.trackAppHangs = enabled;
    return this;
  }

  build(): CrashConfiguration {
    return new CrashConfiguration(this.trackCrashes, this.trackAppHangs);
  }
}
