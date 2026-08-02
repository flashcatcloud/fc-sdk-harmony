import { common, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { Configuration } from '../../config/Configuration';
import { FlashcatContext, DeviceInfo, UserInfo, NetworkInfo } from '../../api/context/FlashcatContext';
import { SDK_VERSION } from '../Version';

const SOURCE: string = 'harmony';
const PREFERENCES_NAME: string = 'flashcat_sdk';
const ANONYMOUS_ID_KEY: string = 'anonymous_id';

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
  private readonly anonymousId: string;
  private user: UserInfo = {};
  private network: NetworkInfo = { connectivity: 'unknown' };
  private readonly featureContext: Record<string, Record<string, Object>> = {};
  private appVersion: string = '0.0.0';
  private bundleId: string = '';

  constructor(context: common.Context, configuration: Configuration) {
    this.configuration = configuration;
    this.device = ContextProvider.readDeviceInfo();
    // Sync (like app info below) so the very first events — written before any
    // async init could settle — already carry the anonymous id.
    this.anonymousId = ContextProvider.loadOrCreateAnonymousId(context);
    this.prepareAppInfo();
  }

  /**
   * Loads the persisted anonymous device id, generating + persisting one on
   * first launch. Uses the synchronous Preferences API: an async read would race
   * the first view event (written synchronously during RUM enable/startView) and
   * ship it with an empty identity.
   */
  private static loadOrCreateAnonymousId(context: common.Context): string {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const existing: preferences.ValueType = prefs.getSync(ANONYMOUS_ID_KEY, '');
      if (typeof existing === 'string' && existing.length > 0) {
        return existing;
      }
      const generated: string = util.generateRandomUUID(true);
      prefs.putSync(ANONYMOUS_ID_KEY, generated);
      prefs.flush((_err) => {
        // Durability is best-effort: on flush failure the id regenerates next
        // launch, which only splits the device identity — never blocks events.
      });
      return generated;
    } catch (_e) {
      // Preferences unavailable — degrade to a per-process id (still non-empty).
      return util.generateRandomUUID(true);
    }
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
      anonymousId: this.anonymousId,
      network: this.network,
      featureContext: this.featureContext
    };
  }
}
