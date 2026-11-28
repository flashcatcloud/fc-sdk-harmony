import { common, bundleManager } from '@kit.AbilityKit';
import { batteryInfo, commonEventManager, deviceInfo, power } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { connection } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { Configuration } from '../../config/Configuration';
import { FlashcatContext, DeviceInfo, UserInfo, NetworkInfo } from '../../api/context/FlashcatContext';
import { SDK_VERSION } from '../Version';

const SOURCE: string = 'harmony';
const PREFERENCES_NAME: string = 'flashcat_sdk';
const ANONYMOUS_ID_KEY: string = 'anonymous_id';
// Android parity (DefaultBatteryInfoProvider): the battery level is read at most once a minute.
const BATTERY_POLL_INTERVAL_MS: number = 60_000;
const POWER_SAVE_MODE_CHANGED: string = 'usual.event.POWER_SAVE_MODE_CHANGED';
const LOCALE_CHANGED: string = 'usual.event.LOCALE_CHANGED';
const TIMEZONE_CHANGED: string = 'usual.event.TIMEZONE_CHANGED';
// power.DevicePowerMode: power save (601), extreme power save (603), custom power save (650, API 20+).
const POWER_SAVING_MODES: number[] = [601, 603, 650];

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
  private buildVersion: string = '';
  private bundleId: string = '';
  private locales: string[] = [];
  private timeZone: string = '';
  private powerSavingMode: boolean | undefined = undefined;
  private batteryLevel: number | undefined = undefined;
  private batteryReadAtMs: number = Number.NEGATIVE_INFINITY;
  private readonly nowMs: () => number;
  private systemEvents: commonEventManager.CommonEventSubscriber | null = null;
  /** The device as built by deviceNow(); dropped when a locale, time zone, power mode or battery reading changes. */
  private deviceCache: DeviceInfo | null = null;

  constructor(context: common.Context, configuration: Configuration, persistIdentity: boolean = true,
    nowMs: () => number = (): number => Date.now()) {
    this.nowMs = nowMs;
    this.appContext = context;
    this.configuration = configuration;
    this.device = ContextProvider.readDeviceInfo();
    // Sync (like app info below) so the very first events — written before any
    // async init could settle — already carry the anonymous id.
    this.anonymousId = ContextProvider.loadOrCreateAnonymousId(context, persistIdentity);
    this.prepareAppInfo();
    this.readInitialNetwork();
    this.subscribeNetwork();
    this.readLocales();
    this.readTimeZone();
    this.readPowerSavingMode();
    this.subscribeSystemEvents();
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
    if (this.systemEvents !== null) {
      try {
        commonEventManager.unsubscribe(this.systemEvents, (_err) => {
          // Best-effort, like the network subscription.
        });
      } catch (_e) {
        // Already unsubscribed or unavailable.
      }
      this.systemEvents = null;
    }
  }

  /**
   * Power saving, language and time zone changes. Each one re-reads its value;
   * the battery level is polled instead (its event fires far too often).
   */
  private subscribeSystemEvents(): void {
    try {
      const subscriber: commonEventManager.CommonEventSubscriber = commonEventManager.createSubscriberSync({
        events: [POWER_SAVE_MODE_CHANGED, LOCALE_CHANGED, TIMEZONE_CHANGED]
      });
      commonEventManager.subscribe(subscriber, (err, data: commonEventManager.CommonEventData) => {
        // A system callback: nothing it does may raise in the host.
        try {
          if (err !== undefined && err !== null && err.code !== 0) {
            return;
          }
          this.onSystemEvent(data.event);
        } catch (_e) {
          // keep the previous values
        }
      });
      this.systemEvents = subscriber;
    } catch (_e) {
      // Not available: the values read at init stand.
    }
  }

  /** Re-reads what a delivered common event says has changed. */
  onSystemEvent(event: string): void {
    this.deviceCache = null;
    if (event === POWER_SAVE_MODE_CHANGED) {
      this.readPowerSavingMode();
    } else if (event === LOCALE_CHANGED) {
      this.readLocales();
    } else if (event === TIMEZONE_CHANGED) {
      this.readTimeZone();
    }
  }

  private readLocales(): void {
    try {
      const list: Array<string> = i18n.System.getPreferredLanguageList();
      this.locales = Array.isArray(list) ? list.filter((l: string) => typeof l === 'string' && l.length > 0) : [];
    } catch (_e) {
      this.locales = [];
    }
  }

  private readTimeZone(): void {
    try {
      const id: string = i18n.getTimeZone().getID();
      this.timeZone = typeof id === 'string' ? id : '';
    } catch (_e) {
      this.timeZone = '';
    }
  }

  private readPowerSavingMode(): void {
    try {
      const mode: number = power.getPowerMode() as number;
      this.powerSavingMode = typeof mode === 'number' ? POWER_SAVING_MODES.includes(mode) : undefined;
    } catch (_e) {
      this.powerSavingMode = undefined;
    }
  }

  /** The battery level, read again once the last reading is a minute old. */
  private currentBatteryLevel(): number | undefined {
    const now: number = this.nowMs();
    // abs: a wall clock set back must not stop the polling for good.
    if (Math.abs(now - this.batteryReadAtMs) >= BATTERY_POLL_INTERVAL_MS) {
      this.batteryReadAtMs = now;
      try {
        const soc: number = batteryInfo.batterySOC;
        if (typeof soc === 'number' && Number.isFinite(soc) && soc >= 0 && soc <= 100) {
          this.batteryLevel = soc / 100;
        }
      } catch (_e) {
        // keep the last reading, or none
      }
    }
    return this.batteryLevel;
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
      // Subscribe BEFORE register: registering first can miss the initial
      // sticky capability delivery (the snapshot covers it, but only until
      // the first change this handler would have caught).
      conn.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo) => {
        // A system callback: a malformed delivery must not raise in the host.
        try {
          this.network = {
            status: 'connected',
            interfaces: ContextProvider.interfacesFrom(info.netCap)
          };
        } catch (_e) {
          // keep the previous network state
        }
      });
      // Back from no network: the default network's capabilities are read
      // here, so events stop reporting not_connected without waiting for the
      // next capability change. A connection created without a specifier
      // only reports the default network.
      conn.on('netAvailable', (net: connection.NetHandle) => {
        try {
          this.network = ContextProvider.availableNetwork(net, this.network.interfaces);
        } catch (_e) {
          // keep the previous network state
        }
      });
      conn.on('netLost', (_net: connection.NetHandle) => {
        this.network = { status: 'not_connected', interfaces: [] };
      });
      conn.on('netUnavailable', () => {
        this.network = { status: 'not_connected', interfaces: [] };
      });
      conn.register((_err) => {
        // registration result is best-effort; callbacks simply won't fire on error
      });
      this.netConnection = conn;
    } catch (_e) {
      // subscription unavailable — the initial snapshot (or 'maybe') stands
    }
  }

  /** A network just came up; its interfaces when they can be read, else the last known ones. */
  private static availableNetwork(net: connection.NetHandle, lastInterfaces: string[]): NetworkInfo {
    try {
      return { status: 'connected', interfaces: ContextProvider.interfacesFrom(connection.getNetCapabilitiesSync(net)) };
    } catch (_e) {
      return { status: 'connected', interfaces: lastInterfaces };
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
      this.buildVersion = `${info.versionCode}`;
    } catch (_err) {
      // Keep defaults; app info is best-effort.
    }
  }

  setUser(user: UserInfo): void {
    // Untyped callers can pass null; every event reads the user's fields.
    this.user = user === null || user === undefined ? {} : user;
  }

  getUser(): UserInfo {
    return this.user;
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

  /**
   * The device as of now: what was read at init, plus the values that change.
   * Built once and shared by every snapshot until a system event or the
   * battery poll says a value changed; consumers copy what they hand on.
   */
  private deviceNow(): DeviceInfo {
    const batteryDue: boolean = Math.abs(this.nowMs() - this.batteryReadAtMs) >= BATTERY_POLL_INTERVAL_MS;
    if (this.deviceCache !== null && !batteryDue) {
      return this.deviceCache;
    }
    const device: DeviceInfo = {
      brand: this.device.brand,
      model: this.device.model,
      osName: this.device.osName,
      osVersion: this.device.osVersion,
      apiVersion: this.device.apiVersion,
      deviceType: this.device.deviceType
    };
    if (this.locales.length > 0) {
      device.locale = this.locales[0];
      device.locales = this.locales.slice();
    }
    if (this.timeZone.length > 0) {
      device.timeZone = this.timeZone;
    }
    const battery: number | undefined = this.currentBatteryLevel();
    if (battery !== undefined) {
      device.batteryLevel = battery;
    }
    if (this.powerSavingMode !== undefined) {
      device.powerSavingMode = this.powerSavingMode;
    }
    this.deviceCache = device;
    return device;
  }

  /** Snapshot the current context for event assembly. */
  snapshot(): FlashcatContext {
    return {
      env: this.configuration.env,
      variant: this.configuration.variant,
      service: this.configuration.service ?? this.bundleId,
      version: this.appVersion,
      buildVersion: this.buildVersion,
      bundleId: this.bundleId,
      source: SOURCE,
      sdkVersion: SDK_VERSION,
      device: this.deviceNow(),
      user: this.user,
      anonymousId: this.anonymousId,
      network: this.network,
      featureContext: this.featureContext
    };
  }
}
