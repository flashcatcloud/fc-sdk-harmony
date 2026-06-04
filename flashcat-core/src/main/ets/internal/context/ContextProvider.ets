import { common, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Configuration } from '../../config/Configuration';
import { FlashcatContext, DeviceInfo, UserInfo, NetworkInfo } from '../../api/context/FlashcatContext';

const SDK_VERSION: string = '0.1.0';
const SOURCE: string = 'harmony';

/**
 * Assembles the FlashcatContext attached to every event. Device info is read
 * synchronously at init; app version/bundle id is read asynchronously (best
 * effort) and backfilled. User and feature baggage are mutable.
 *
 * Network connectivity is left as a TODO subscription (not required for the
 * phase-1 View/Error events).
 */
export class ContextProvider {
  private readonly configuration: Configuration;
  private readonly device: DeviceInfo;
  private user: UserInfo = {};
  private network: NetworkInfo = { connectivity: 'unknown' };
  private readonly featureContext: Record<string, Record<string, Object>> = {};
  private appVersion: string = '0.0.0';
  private bundleId: string = '';

  constructor(context: common.Context, configuration: Configuration) {
    this.configuration = configuration;
    this.device = ContextProvider.readDeviceInfo();
    this.prepareAppInfo();
  }

  // (app info is read synchronously below so the earliest events — e.g. an
  // uncaught exception at startup — carry the real version/bundleId)

  private static readDeviceInfo(): DeviceInfo {
    return {
      brand: deviceInfo.brand,
      model: deviceInfo.productModel,
      osName: 'HarmonyOS',
      osVersion: deviceInfo.osFullName,
      apiVersion: deviceInfo.sdkApiVersion,
      deviceType: deviceInfo.deviceType
    };
  }

  /** Synchronous so the first events carry real app info (no startup race). */
  private prepareAppInfo(): void {
    const flags: number = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(flags);
      this.bundleId = info.name;
      this.appVersion = info.versionName;
    } catch (_err) {
      // Keep defaults; app info is best-effort.
    }
  }

  setUser(user: UserInfo): void {
    this.user = user;
  }

  updateFeatureContext(featureName: string, update: Record<string, Object>): void {
    const merged: Record<string, Object> = {};
    const existing: Record<string, Object> = this.featureContext[featureName] ?? {};
    for (const k of Object.keys(existing)) {
      merged[k] = existing[k];
    }
    for (const k of Object.keys(update)) {
      merged[k] = update[k];
    }
    this.featureContext[featureName] = merged;
  }

  getFeatureContext(featureName: string): Record<string, Object> {
    return this.featureContext[featureName] ?? {};
  }

  /** Snapshot the current context for event assembly. */
  snapshot(): FlashcatContext {
    return {
      env: this.configuration.env,
      variant: this.configuration.variant,
      service: this.configuration.service ?? this.bundleId,
      version: this.appVersion,
      bundleId: this.bundleId,
      source: SOURCE,
      sdkVersion: SDK_VERSION,
      device: this.device,
      user: this.user,
      network: this.network,
      featureContext: this.featureContext
    };
  }
}
