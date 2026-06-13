import { SdkCore, Feature, FeatureScope, CRASH_FEATURE_NAME, RUM_FEATURE_NAME } from '@flashcatcloud/core';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { CrashConfiguration } from '../CrashConfiguration';
import { CrashEventMapper } from './CrashEventMapper';

const WATCHER_NAME: string = 'flashcat_crash_watcher';

/**
 * Crash feature. Subscribes to hiAppEvent APP_CRASH (native C/C++ .so + ArkTS/JS)
 * and APP_FREEZE (watchdog). hiAppEvent persists the fault and replays it on the
 * NEXT launch, so cross-process-death durability is handled by the OS — no custom
 * crash directory is required.
 *
 * Each delivered event is mapped (pure {@link CrashEventMapper}) and published on
 * the inter-feature bus to the RUM feature, which writes it as an `is_crash` error
 * event (force-flushed). Equivalent role to Android's crash-reporting feature.
 *
 * The watcher callback runs on the next launch in a benign context (not the dying
 * process), but is still fully wrapped: crash reporting must never crash the host.
 */
export class CrashFeature implements Feature {
  readonly name: string = CRASH_FEATURE_NAME;
  private readonly core: SdkCore;
  private readonly configuration: CrashConfiguration;
  private watching: boolean = false;

  constructor(core: SdkCore, configuration: CrashConfiguration) {
    this.core = core;
    this.configuration = configuration;
  }

  onInitialize(): void {
    const names: string[] = [];
    if (this.configuration.trackCrashes) {
      names.push(hiAppEvent.event.APP_CRASH);
    }
    if (this.configuration.trackAppHangs) {
      names.push(hiAppEvent.event.APP_FREEZE);
    }
    if (names.length === 0) {
      return;
    }
    try {
      hiAppEvent.addWatcher({
        name: WATCHER_NAME,
        appEventFilters: [{ domain: hiAppEvent.domain.OS, names: names }],
        onReceive: (_domain: string, groups: Array<hiAppEvent.AppEventGroup>) => {
          this.handle(groups);
        }
      });
      this.watching = true;
    } catch (_e) {
      this.watching = false;
    }
  }

  private handle(groups: Array<hiAppEvent.AppEventGroup>): void {
    try {
      const rum: FeatureScope | null = this.core.getFeature(RUM_FEATURE_NAME);
      if (rum === null) {
        return; // RUM not enabled — nothing to report through.
      }
      for (const group of groups) {
        const isFreeze: boolean = group.name === hiAppEvent.event.APP_FREEZE;
        for (const info of group.appEventInfos) {
          if (!CrashFeature.sampled(this.configuration.sampleRate)) {
            continue;
          }
          const params: Record<string, Object> = info.params as Record<string, Object>;
          const ev: Record<string, Object> =
            isFreeze ? CrashEventMapper.fromAppFreeze(params) : CrashEventMapper.fromAppCrash(params);
          rum.sendEvent(ev);
        }
      }
    } catch (_e) {
      // Crash reporting must never crash the app.
    }
  }

  /** Sampling decision. 100 → always, 0 → never, else probabilistic. */
  static sampled(sampleRate: number): boolean {
    if (sampleRate >= 100) {
      return true;
    }
    if (sampleRate <= 0) {
      return false;
    }
    return Math.random() * 100 < sampleRate;
  }

  onStop(): void {
    if (this.watching) {
      try {
        hiAppEvent.removeWatcher({ name: WATCHER_NAME });
      } catch (_e) {
        // already removed
      }
      this.watching = false;
    }
  }
}
