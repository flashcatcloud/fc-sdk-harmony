import { Flashcat, SdkCore, FeatureScope, RUM_FEATURE_NAME, FlashcatLog } from '@flashcatcloud/core';
import { RumConfiguration } from './RumConfiguration';
import { GlobalRumMonitor } from './RumMonitor';
import { RumFeature } from './internal/RumFeature';
import { DefaultRumMonitor } from './internal/monitor/DefaultRumMonitor';
import { RumAutoInstrumentation } from './internal/RumAutoInstrumentation';
import { RumNavigationTracker, NavContext } from './internal/RumNavigationTracker';
import { RumEventMapperHolder } from './internal/RumEventMapperHolder';

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

    // Idempotency guard (Android parity: "RUM feature is already enabled").
    // registerFeature silently ignores a duplicate, but proceeding here would
    // build a SECOND application scope + keep-alive timer attached to an orphan
    // feature: events split across two sessions, and the orphan's timer is
    // never stopped by onStop — it would keep writing after SDK stop, forever.
    if (core.getFeature(RUM_FEATURE_NAME) !== null) {
      FlashcatLog.e('FlashcatRum.enable ignored: RUM is already enabled for this instance');
      return;
    }

    const feature: RumFeature = new RumFeature(core, configuration);
    core.registerFeature(feature);

    const scope: FeatureScope | null = core.getFeature(RUM_FEATURE_NAME);
    if (scope === null) {
      return; // registration failed
    }
    const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
    feature.attachMonitor(monitor);
    GlobalRumMonitor.register(monitor);

    // Phase 2: make the auto-instrumentation toggles consultable by the tap /
    // navigation trackers. Inert unless the corresponding flag is enabled.
    RumAutoInstrumentation.configure(configuration);
    // Phase 2 R3: install the event mapper (PII scrubbing / drop), if any.
    RumEventMapperHolder.configure(configuration.eventMapper);
  }

  /**
   * Auto-record a TAP action on `target`. No-op unless RUM is enabled with
   * `setTrackUserInteractions(true)`. Wrap a component's `onClick` (or one shared
   * click handler) with this to capture the interaction timeline without a manual
   * `addAction` per component.
   */
  static trackTap(target: string, attributes?: Record<string, Object>): void {
    RumAutoInstrumentation.trackTap(target, attributes);
  }

  /**
   * Start automatic View tracking for `router` navigation, scoped to `context`
   * (a UIAbilityContext or a UIContext from UI land). Each page show/hide then
   * emits start/stopView automatically. No-op unless RUM is enabled with
   * `setTrackNavigation(true)`. Idempotent.
   */
  static startViewTracking(context: NavContext): void {
    RumNavigationTracker.attach(context);
  }

  /** Stop automatic View tracking (detach the navigation observer). */
  static stopViewTracking(): void {
    RumNavigationTracker.detach();
  }
}
