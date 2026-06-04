import { Flashcat, SdkCore, FeatureScope, RUM_FEATURE_NAME } from '@flashcatcloud/core';
import { RumConfiguration } from './RumConfiguration';
import { GlobalRumMonitor } from './RumMonitor';
import { RumFeature } from './internal/RumFeature';
import { DefaultRumMonitor } from './internal/monitor/DefaultRumMonitor';

/**
 * Enables Real User Monitoring. Call after `Flashcat.initialize`.
 *
 * ```ets
 * FlashcatRum.enable(new RumConfigurationBuilder('<applicationId>')
 *   .setSessionSampleRate(100)
 *   .build());
 * ```
 *
 * Mirrors `Rum.enable(rumConfiguration, sdkCore)` on Android.
 */
export class FlashcatRum {
  static enable(configuration: RumConfiguration, sdkCore?: SdkCore): void {
    const core: SdkCore = sdkCore ?? Flashcat.getInstance();

    const feature: RumFeature = new RumFeature(core, configuration);
    core.registerFeature(feature);

    const scope: FeatureScope | null = core.getFeature(RUM_FEATURE_NAME);
    if (scope === null) {
      return; // registration failed
    }
    const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
    feature.attachMonitor(monitor);
    GlobalRumMonitor.register(monitor);
  }
}
