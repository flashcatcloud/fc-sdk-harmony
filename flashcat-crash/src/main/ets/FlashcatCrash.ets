import { Flashcat, SdkCore, CRASH_FEATURE_NAME, FlashcatLog } from '@flashcatcloud/core';
import { CrashConfiguration } from './CrashConfiguration';
import { CrashFeature } from './internal/CrashFeature';

/**
 * Enables crash reporting (native + ArkTS crashes, plus app freezes).
 *
 * Call AFTER `Flashcat.initialize` and AFTER `FlashcatRum.enable` — crash events
 * are reported through the RUM feature's error pipeline. A fault from a previous
 * run is delivered by the OS on the next launch, so enabling early in
 * `AbilityStage.onCreate` ensures the watcher is installed before any replay.
 *
 * ```ets
 * FlashcatCrash.enable(new CrashConfigurationBuilder().build());
 * ```
 */
export class FlashcatCrash {
  static enable(configuration: CrashConfiguration, sdkCore?: SdkCore): void {
    const core: SdkCore = sdkCore ?? Flashcat.getInstance();
    if (core.getFeature(CRASH_FEATURE_NAME) !== null) {
      FlashcatLog.e('FlashcatCrash.enable ignored: crash reporting is already enabled for this instance');
      return;
    }
    core.registerFeature(new CrashFeature(core, configuration));
  }
}
