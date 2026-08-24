import { Flashcat, SdkCore, FeatureScope, FlashcatContext, IntakeTarget,
  RUM_FEATURE_NAME, FlashcatLog } from '@flashcatcloud/core';
import { RumConfiguration } from './RumConfiguration';
import { GlobalRumMonitor } from './RumMonitor';
import { RumFeature } from './internal/RumFeature';
import { DefaultRumMonitor } from './internal/monitor/DefaultRumMonitor';
import { RumAutoInstrumentation } from './internal/RumAutoInstrumentation';
import { RumNavigationTracker, NavContext } from './internal/RumNavigationTracker';
import { RumEventMapperHolder } from './internal/RumEventMapperHolder';
import { RemoteConfigStore } from './internal/remoteconfig/RemoteConfigStore';
import { RemoteConfigController } from './internal/remoteconfig/RemoteConfigController';
import { HttpRemoteConfigFetcher, buildConfigUrl } from './internal/remoteconfig/RemoteConfigFetcher';

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
    // Install the event mapper (PII scrubbing / drop) BEFORE attaching the
    // monitor: attachMonitor synchronously triggers the pending-crash replay,
    // and a replayed crash error must pass through the mapper like any event.
    RumEventMapperHolder.configure(configuration.eventMapper);

    // Remote configuration is off unless the app asked for it, and everything
    // about it is best-effort: whatever fails here, RUM still collects with the
    // values this configuration was built with.
    let store: RemoteConfigStore | null = null;
    let controller: RemoteConfigController | null = null;
    if (configuration.remoteConfigurationEnabled) {
      try {
        const intake: IntakeTarget = core.getIntakeTarget();
        const context: FlashcatContext = core.getContext();
        store = new RemoteConfigStore(
          core, RemoteConfigStore.buildStoreKey(context, intake.host, configuration.applicationId));
        controller = new RemoteConfigController(
          store,
          new HttpRemoteConfigFetcher(`flashcat-sdk-harmony/${context.sdkVersion}`),
          buildConfigUrl(intake.host, intake.clientToken, context),
          configuration.sessionSampleRate,
          // Looked up when it fires rather than captured now: the monitor is
          // registered after this is built, and by the time a response comes
          // back it is there.
          (): void => GlobalRumMonitor.get().stopSession()
        );
      } catch (e) {
        // Whatever went wrong here, the app keeps collecting with the values it
        // was initialised with — never a reason to fail enable().
        store = null;
        controller = null;
        FlashcatLog.e(`rum.remoteconfig: not started (${e instanceof Error ? e.message : 'error'}); init values apply`);
      }
    }

    const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration, store, controller);
    feature.attachMonitor(monitor);
    GlobalRumMonitor.register(monitor);

    // Phase 2: make the auto-instrumentation toggles consultable by the tap /
    // navigation trackers. Inert unless the corresponding flag is enabled.
    RumAutoInstrumentation.configure(configuration);

    // Started only after the monitor is registered: the response may ask for the
    // session to be restarted, and that goes through the global monitor.
    if (controller !== null) {
      controller.start();
    }
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
   *
   * IMPORTANT: pair with `stopViewTracking(context)` in the ability's
   * onDestroy — the registry holds a strong reference per context, so
   * create/destroy churn without the stop call pins each dead context for the
   * lifetime of the RUM enablement.
   *
   * Covers `router`-based navigation only; `Navigation`/`NavDestination`-based
   * apps should call startView/stopView manually for now.
   */
  static startViewTracking(context: NavContext): void {
    RumNavigationTracker.attach(context);
  }

  /**
   * Stop automatic View tracking. With `context`, detaches only that context's
   * observer (call before an ability is destroyed); without, detaches all.
   */
  static stopViewTracking(context?: NavContext): void {
    if (context !== undefined) {
      RumNavigationTracker.detachContext(context);
    } else {
      RumNavigationTracker.detach();
    }
  }
}
