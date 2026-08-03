import { common, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
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
 * effort) and backfilled. User and feature baggage are mutable. Network
 * connectivity is snapshotted at init and kept fresh via a NetConnection
 * subscription (best-effort; requires ohos.permission.GET_NETWORK_INFO).
 */
export class ContextProvider {
  private readonly appContext: common.Context;
  private readonly configuration: Configuration;
  private readonly device: DeviceInfo;
  private readonly anonymousId: string;
  private user: UserInfo = {};
  private network: NetworkInfo = { status: 'maybe', interfaces: [] };
  private netConnection: connection.NetConnection | null = null;
  private readonly featureContext: Record<string, Record<string, Object>> = {};
  private appVersion: string = '0.0.0';
  private bundleId: string = '';

  constructor(context: common.Context, configuration: Configuration, persistIdentity: boolean = true) {
    this.appContext = context;
    this.configuration = configuration;
    this.device = ContextProvider.readDeviceInfo();
    // Sync (like app info below) so the very first events — written before any
    // async init could settle — already carry the anonymous id.
    this.anonymousId = ContextProvider.loadOrCreateAnonymousId(context, persistIdentity);
    this.prepareAppInfo();
    this.readInitialNetwork();
    this.subscribeNetwork();
  }

  /**
   * NOT_GRANTED -> GRANTED transition: durably persist the current in-memory
   * anonymous id (generated without persistence at construction) so the device
   * keeps a single identity across launches instead of splitting on the grant.
   */
  persistIdentityNow(): void {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(this.appContext, { name: PREFERENCES_NAME });
      const existing: preferences.ValueType = prefs.getSync(ANONYMOUS_ID_KEY, '');
      if (typeof existing === 'string' && existing.length > 0) {
        return; // already persisted (normal GRANTED-at-init path)
      }
      prefs.putSync(ANONYMOUS_ID_KEY, this.anonymousId);
      prefs.flush((_err) => {
        // Best-effort durability, same as loadOrCreateAnonymousId.
      });
    } catch (_e) {
      // Preferences unavailable — the per-process id stands.
    }
  }

  /** Tears down system subscriptions so a stopped core can be collected. */
  stop(): void {
    if (this.netConnection !== null) {
      try {
        this.netConnection.unregister((_err) => {
          // Best-effort; the subscription dies with the process otherwise.
        });
      } catch (_e) {
        // Already unregistered or unavailable.
      }
      this.netConnection = null;
    }
  }

  /**
   * Best-effort connectivity. Requires ohos.permission.GET_NETWORK_INFO; when
   * the host app lacks it every call throws and the context stays at
   * status 'maybe' (the schema's "unknown" value) — never a crash.
   */
  private readInitialNetwork(): void {
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      if (net === undefined || net.netId === 0) {
        this.network = { status: 'not_connected', interfaces: [] };
        return;
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
      this.network = { status: 'connected', interfaces: ContextProvider.interfacesFrom(caps) };
    } catch (_e) {
      // permission missing or API unavailable — keep 'maybe'
    }
  }

  private subscribeNetwork(): void {
    try {
      const conn: connection.NetConnection = connection.createNetConnection();
      conn.register((_err) => {
        // registration result is best-effort; callbacks simply won't fire on error
      });
      conn.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo) => {
        this.network = {
          status: 'connected',
          interfaces: ContextProvider.interfacesFrom(info.netCap)
        };
      });
      conn.on('netLost', (_net: connection.NetHandle) => {
        this.network = { status: 'not_connected', interfaces: [] };
      });
      conn.on('netUnavailable', () => {
        this.network = { status: 'not_connected', interfaces: [] };
      });
      this.netConnection = conn;
    } catch (_e) {
      // subscription unavailable — the initial snapshot (or 'maybe') stands
    }
  }

  private static interfacesFrom(caps: connection.NetCapabilities): string[] {
    const interfaces: string[] = [];
    const bearers: connection.NetBearType[] = caps.bearerTypes ?? [];
    for (let i: number = 0; i < bearers.length; i++) {
      const bearer: connection.NetBearType = bearers[i];
      if (bearer === connection.NetBearType.BEARER_WIFI) {
        interfaces.push('wifi');
      } else if (bearer === connection.NetBearType.BEARER_CELLULAR) {
        interfaces.push('cellular');
      } else if (bearer === connection.NetBearType.BEARER_ETHERNET) {
        interfaces.push('ethernet');
      } else {
        interfaces.push('other');
      }
    }
    return interfaces;
  }

  /**
   * Loads the persisted anonymous device id, generating + persisting one on
   * first launch. Uses the synchronous Preferences API: an async read would race
   * the first view event (written synchronously during RUM enable/startView) and
   * ship it with an empty identity. When persistence is not allowed (tracking
   * consent NOT_GRANTED), no durable identifier is written — a per-process id
   * is used instead.
   */
  private static loadOrCreateAnonymousId(context: common.Context, persistIdentity: boolean): string {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const existing: preferences.ValueType = prefs.getSync(ANONYMOUS_ID_KEY, '');
      if (typeof existing === 'string' && existing.length > 0) {
        return existing;
      }
      const generated: string = util.generateRandomUUID(true);
      if (persistIdentity) {
        prefs.putSync(ANONYMOUS_ID_KEY, generated);
        prefs.flush((_err) => {
          // Durability is best-effort: on flush failure the id regenerates next
          // launch, which only splits the device identity — never blocks events.
        });
      }
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
