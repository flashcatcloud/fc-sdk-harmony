import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  Flashcat, Configuration, ConfigurationBuilder, FlashcatSite, TrackingConsent, UserInfo,
  UploadFrequency, BatchSize, BatchProcessingLevel
} from '@flashcatcloud/core';
import { FlashcatRum, RumConfigurationBuilder, GlobalRumMonitor, RumMonitor,
  BeforeSamplingContext } from '@flashcatcloud/rum';
import { FlashcatTrace, TraceConfigurationBuilder } from '@flashcatcloud/trace';
import { FlashcatCrash, CrashConfigurationBuilder, JsCrashPolicy } from '@flashcatcloud/crash';
import { DemoConfig, DemoConfigLoader } from './DemoConfig';

/**
 * Centralizes SDK setup for the demo so the UI stays declarative.
 *
 * NOTE on env switching: the real SDK initializes ONCE per process (ideally in
 * `AbilityStage.onCreate`). To let you compare prod vs. test, this demo defers
 * initialization to an explicit "Initialize SDK" button so you can pick the
 * environment first. After init the choice is locked for the process lifetime —
 * relaunch the app to switch. In a production app, call init in
 * `AbilityStage.onCreate` with a fixed environment.
 * Configure credentials in `resources/rawfile/demo_config.json` before testing.
 */
export class DemoSdk {
  private static initialized: boolean = false;
  private static envLabel: string = '(not initialized)';

  static isInitialized(): boolean {
    return DemoSdk.initialized;
  }

  static currentEnv(): string {
    return DemoSdk.envLabel;
  }

  /**
   * Initialize the SDK and enable RUM + Trace + Crash. Idempotent.
   * @param prod true → production site; false → staging
   * @param customEndpoint optional intake override (e.g. http://10.0.2.2:8080) for
   *        local capture/proxy debugging. Empty → use the site host.
   * @param recover true → opt into REPORT_AND_RECOVER for crash testing.
   */
  /**
   * @param pacing 'default' or 'low'. Upload pacing is fixed at initialize, so
   *   comparing settings means one app run per setting — hence a launch
   *   parameter rather than a runtime toggle.
   */
  /**
   * @param remoteConfig '' → off (init values rule); 'on' → read the console's
   *   configuration; 'vip' → same, plus a beforeSampling allow-list that keeps
   *   this device's sessions when the console's `custom.vip` names it.
   * @param initSampleRate the rate this build ships with. Deliberately not 100
   *   for the remote-configuration runs: the event reports the rate actually
   *   drawn with, so a distinctive init value is what proves which one won.
   */
  static init(context: common.Context, prod: boolean, customEndpoint: string,
    recover: boolean = false, trackErrors: boolean = true, pacing: string = 'demo',
    remoteConfig: string = '', initSampleRate: number = 100): void {
    if (DemoSdk.initialized) {
      return;
    }
    const demoConfig: DemoConfig = DemoConfigLoader.load(context);
    const missing: string[] = DemoConfigLoader.missingRequiredFields(demoConfig);
    if (missing.length > 0) {
      throw new Error(`Missing demo config fields: ${missing.join(', ')}. Edit resources/rawfile/${DemoConfigLoader.configFileName()}.`);
    }
    const site: FlashcatSite = prod ? FlashcatSite.CN : FlashcatSite.STAGING;
    const builder: ConfigurationBuilder = new ConfigurationBuilder(demoConfig.clientToken, prod ? 'prod' : 'staging')
      .setService(demoConfig.service)
      .useSite(site)
      .setVerbose(true);               // emit internal HiLog (tag "Flashcat")
    if (pacing === 'default') {
      builder.setUploadFrequency(UploadFrequency.AVERAGE)
        .setBatchSize(BatchSize.MEDIUM)
        .setBatchProcessingLevel(BatchProcessingLevel.MEDIUM);
    } else if (pacing === 'low') {
      // The combination recommended for an app with latency-sensitive requests
      // of its own on a narrow uplink.
      builder.setUploadFrequency(UploadFrequency.RARE)
        .setBatchSize(BatchSize.LARGE)
        .setBatchProcessingLevel(BatchProcessingLevel.LOW);
    } else {
      builder.setUploadFrequency(UploadFrequency.FREQUENT); // demo: see uploads sooner
    }
    if (customEndpoint.length > 0) {
      builder.setCustomEndpoint(customEndpoint);
    }
    Flashcat.initialize(context, builder.build(), TrackingConsent.GRANTED);

    const rumBuilder: RumConfigurationBuilder = new RumConfigurationBuilder(demoConfig.applicationId)
      .setSessionSampleRate(initSampleRate)
      .setTrackUserInteractions(true) // phase 2: auto TAP actions (A3)
      .setTrackNavigation(true)       // phase 2: auto View events on router push/pop (A1)
      .setTrackNetworkRequests(true)  // phase 2: auto Resource via FlashcatHttp wrapper (A2)
      .setTrackErrors(trackErrors)    // false → crash-only reporting (auto errors suppressed)
      .setEventMapper(DemoSdk.demoEventMapper); // phase 2 R3: PII scrubbing / drop
    if (remoteConfig.length > 0) {
      rumBuilder.setRemoteConfigurationEnabled(true);
    }
    if (remoteConfig === 'vip') {
      rumBuilder.setBeforeSampling(DemoSdk.vipAllowList);
    }
    FlashcatRum.enable(rumBuilder.build());
    FlashcatTrace.enable(new TraceConfigurationBuilder().setSampleRate(100).build());
    const crashBuilder: CrashConfigurationBuilder = new CrashConfigurationBuilder();
    if (recover) {
      crashBuilder.setJsCrashPolicy(JsCrashPolicy.REPORT_AND_RECOVER);
    }
    FlashcatCrash.enable(crashBuilder.build());

    DemoSdk.initialized = true;
    const host: string = customEndpoint.length > 0 ? customEndpoint : (prod ? 'browser.flashcat.cloud' : 'jira.flashcat.cloud');
    DemoSdk.envLabel = `${prod ? 'prod' : 'staging'} · ${host}` +
      (recover ? ' · crash recovery' : '');
  }

  /** Identifies this device to the console's allow-list. */
  static readonly DEMO_USER_ID: string = 'harmony-e2e';

  /**
   * Demo beforeSampling hook: keep every session of a device the console named
   * in `custom.vip`, whatever rate the fleet is on. This is the shape a support
   * team uses — the console publishes the list, no app release involved.
   */
  static vipAllowList(context: BeforeSamplingContext): number | undefined {
    const custom: Record<string, Object> | null = context.custom;
    const listed: boolean = DemoSdk.isListed(custom, DemoSdk.DEMO_USER_ID);
    hilog.info(0x0000, 'FCRC', 'beforeSampling rate=%{public}s vipListed=%{public}s',
      `${context.sessionSampleRate}`, `${listed}`);
    return listed ? 100 : undefined;
  }

  private static isListed(custom: Record<string, Object> | null, id: string): boolean {
    if (custom === null) {
      return false;
    }
    const vip: Object | undefined = custom['vip'];
    if (!Array.isArray(vip)) {
      return false;
    }
    const entries: Array<Object> = vip as Array<Object>;
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i] === id) {
        return true;
      }
    }
    return false;
  }

  static monitor(): RumMonitor {
    return GlobalRumMonitor.get();
  }

  /**
   * Phase 2 R3 demo mapper. Two redactions you can verify in HiLog / NDJSON:
   * - resource events: strip the query string from `resource.url` (tokens, PII);
   * - action events whose target name contains "secret": dropped entirely (null).
   * Everything else passes through unchanged. Must never throw.
   */
  static demoEventMapper(event: Record<string, Object>): Record<string, Object> | null {
    const type: Object | undefined = event['type'];
    if (type === 'resource') {
      const res: Object | undefined = event['resource'];
      if (typeof res === 'object') {
        const r: Record<string, Object> = res as Record<string, Object>;
        const u: Object | undefined = r['url'];
        if (typeof u === 'string') {
          const q: number = u.indexOf('?');
          if (q >= 0) {
            r['url'] = u.substring(0, q);
          }
        }
      }
    } else if (type === 'action') {
      const action: Object | undefined = event['action'];
      if (typeof action === 'object') {
        const a: Record<string, Object> = action as Record<string, Object>;
        const target: Object | undefined = a['target'];
        if (typeof target === 'object') {
          const t: Record<string, Object> = target as Record<string, Object>;
          const name: Object | undefined = t['name'];
          if (typeof name === 'string' && name.indexOf('secret') >= 0) {
            return null; // drop secret-marked taps
          }
        }
      }
    }
    return event;
  }

  static setConsent(consent: TrackingConsent): void {
    if (DemoSdk.initialized) {
      Flashcat.setTrackingConsent(consent);
    }
  }

  static setUser(id: string, name: string, email: string): void {
    if (DemoSdk.initialized) {
      const user: UserInfo = { id, name, email };
      Flashcat.getInstance().setUserInfo(user);
    }
  }

  static clearUser(): void {
    if (DemoSdk.initialized) {
      Flashcat.getInstance().clearUserInfo();
    }
  }
}
