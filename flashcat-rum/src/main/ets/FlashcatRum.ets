import { Flashcat, SdkCore, FeatureScope, FlashcatContext, IntakeTarget,
  RUM_FEATURE_NAME, FlashcatLog } from '@flashcatcloud/core';
import { RumConfiguration } from './RumConfiguration';
import { GlobalRumMonitor } from './RumMonitor';
import { RumFeature } from './internal/RumFeature';
import { DefaultRumMonitor } from './internal/monitor/DefaultRumMonitor';
import { RumAutoInstrumentation } from './internal/RumAutoInstrumentation';
import { RumNavigationTracker, NavContext } from './internal/RumNavigationTracker';
import { RumEventMapperHolder } from './internal/RumEventMapperHolder';
import { RemoteConfigStore, RemoteConfigValues } from './internal/remoteconfig/RemoteConfigStore';
import { RemoteConfigController } from './internal/remoteconfig/RemoteConfigController';
import { HttpRemoteConfigFetcher, buildConfigUrl } from './internal/remoteconfig/RemoteConfigFetcher';
import { ResourceSampler } from './internal/vitals/ResourceSampler';
import { systemResourceReaders } from './internal/vitals/SystemResourceReaders';
import { FrameObserver } from './internal/vitals/FrameObserver';
import { systemFrameSources } from './internal/vitals/SystemFrameSources';
import { VitalsCollectors } from './internal/vitals/VitalsCollector';
import { VitalsUpdateFrequency, vitalsPeriodMs } from './VitalsUpdateFrequency';
import { AppLaunchTracker, AppLaunchSink, StartupType } from './internal/startup/AppLaunchTracker';
import { systemFrameHooks, systemProcessAgeMs } from './internal/startup/SystemLaunchHooks';
import { APP_LAUNCH_TTID, APP_LAUNCH_TTFD } from './internal/assembly/RumEventAssembler';

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
  // The frames of every context passed to startViewTracking; one per enable.
  private static frames: FrameObserver | null = null;

  static enable(configuration: RumConfiguration, sdkCore?: SdkCore): void {
    // Called from the host's startup path (and possibly before initialize): a
    // failure leaves the app without RUM, never without the app.
    try {
      FlashcatRum.doEnable(configuration, sdkCore);
    } catch (error) {
      FlashcatLog.usage(`FlashcatRum.enable failed: ${error instanceof Error ? error.message : 'error'}`);
    }
  }

  private static doEnable(configuration: RumConfiguration, sdkCore?: SdkCore): void {
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
    // Assigned a few lines below, and only ever read when a response comes
    // back — by which time it is there. The controller has to exist first
    // because the monitor owns it.
    let monitorRef: DefaultRumMonitor | null = null;
    let collectorsRef: VitalsCollectors | null = null;
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
          (activation: string, before: number | null, after: number | null): void => {
            try {
              if (monitorRef !== null) {
                monitorRef.onRemoteConfigurationChanged(activation, before, after);
              }
            } finally {
              // A published frequency applies at once, not at the next session,
              // and not only when the session side took the change cleanly.
              if (collectorsRef !== null) {
                collectorsRef.refreshPeriod();
              }
            }
          }
        );
      } catch (e) {
        // Whatever went wrong here, the app keeps collecting with the values it
        // was initialised with — never a reason to fail enable().
        store = null;
        controller = null;
        FlashcatLog.e(`rum.remoteconfig: not started (${e instanceof Error ? e.message : 'error'}); init values apply`);
      }
    }

    const periodOf: () => number = FlashcatRum.vitalsPeriodOf(configuration, store);
    const apiVersion: number = core.getContext().device.apiVersion;
    const frames: FrameObserver = new FrameObserver(systemFrameSources(apiVersion), periodOf);
    const collectors: VitalsCollectors = new VitalsCollectors([
      new ResourceSampler(systemResourceReaders(apiVersion), periodOf), frames]);
    collectorsRef = collectors;
    // What it measures goes through the monitor, so it lands in whatever
    // session and view are current, under their sampling.
    const launchSink: AppLaunchSink = {
      initialDisplay: (type: StartupType, startMs: number, durationNs: number, atMs: number): void => {
        if (monitorRef !== null) {
          monitorRef.reportAppLaunch(APP_LAUNCH_TTID, type, startMs, durationNs, atMs);
        }
      },
      fullDisplay: (type: StartupType, startMs: number, durationNs: number, atMs: number): void => {
        if (monitorRef !== null) {
          monitorRef.reportAppLaunch(APP_LAUNCH_TTFD, type, startMs, durationNs, atMs);
        }
      },
      viewLoaded: (viewKey: string, atMs: number): void => {
        if (monitorRef !== null) {
          monitorRef.addAutoViewLoadingTime(viewKey, atMs);
        }
      }
    };
    const launch: AppLaunchTracker =
      new AppLaunchTracker(launchSink, systemFrameHooks(apiVersion), systemProcessAgeMs);
    const monitor: DefaultRumMonitor =
      new DefaultRumMonitor(core, scope, configuration, store, controller, collectors, launch);
    monitorRef = monitor;
    feature.attachMonitor(monitor, collectors, launch);
    FlashcatRum.frames = frames;
    RumNavigationTracker.configureLaunch(launch);
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

  /** The sampling period of the console's published frequency, when there is
   * one, over the init value; 0 (`NEVER`) also turns frame observation off. */
  private static vitalsPeriodOf(configuration: RumConfiguration, store: RemoteConfigStore | null): () => number {
    return (): number => {
      const stored: RemoteConfigValues | null = store === null ? null : store.read();
      const frequency: VitalsUpdateFrequency =
        stored !== null && stored.vitalsUpdateFrequency !== null
          ? stored.vitalsUpdateFrequency : configuration.vitalsUpdateFrequency;
      return vitalsPeriodMs(frequency);
    };
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
   * emits start/stopView automatically, and each shown page's first frame sets
   * its `view.loading_time`. Router tracking is a no-op unless RUM is enabled
   * with `setTrackNavigation(true)`. Idempotent.
   *
   * Call it in every app, router-based or not: app launch timing (time to
   * initial display, cold / warm / hot) ends at the first frame drawn, and
   * this is where the SDK hooks frames — whatever `setTrackNavigation` says.
   * Call it in the first page's `aboutToAppear`, with `this.getUIContext()`,
   * so the hook is in place before that page's first frame; a launch whose
   * first frame was missed is not reported. Launch timing does not depend on
   * `VitalsUpdateFrequency`: `NEVER` does not turn it off.
   *
   * IMPORTANT: pair with `stopViewTracking(context)` in the ability's
   * onDestroy — the registry holds a strong reference per context, so
   * create/destroy churn without the stop call pins each dead context for the
   * lifetime of the RUM enablement.
   *
   * Covers `router`-based navigation only; `Navigation`/`NavDestination`-based
   * apps should call startView/stopView manually for now.
   *
   * This is also where views start measuring the frames `context`'s window
   * draws (`view.refresh_rate_*`, `view.slow_frame` / `view.frozen_frame`,
   * `view.slow_frames_rate`, `view.freeze_rate`), whether or not navigation is
   * tracked automatically; `VitalsUpdateFrequency.NEVER` turns it off. On API
   * 22+ every redraw counts; on API 12–21 only frames drawn while a list or
   * other scrollable moves. A host driving its own animation with
   * `displaySync` or `postFrameCallback` makes the system report frames that
   * redrew nothing, which raises the frame rate RUM reports.
   */
  static startViewTracking(context: NavContext): void {
    RumNavigationTracker.attach(context);
    if (FlashcatRum.frames !== null) {
      FlashcatRum.frames.attach(context);
    }
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
    if (FlashcatRum.frames !== null) {
      FlashcatRum.frames.detach(context);
    }
  }
}
