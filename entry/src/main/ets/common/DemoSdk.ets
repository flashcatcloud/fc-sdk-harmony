import { common } from '@kit.AbilityKit';
import {
  Flashcat, Configuration, ConfigurationBuilder, FlashcatSite, TrackingConsent
} from '@flashcatcloud/core';
import { FlashcatRum, RumConfigurationBuilder, GlobalRumMonitor, RumMonitor } from '@flashcatcloud/rum';
import { FlashcatTrace, TraceConfigurationBuilder } from '@flashcatcloud/trace';
import { FlashcatCrash, CrashConfigurationBuilder } from '@flashcatcloud/crash';

/**
 * Centralizes SDK setup for the demo so the UI stays declarative.
 *
 * NOTE on env switching: the real SDK initializes ONCE per process (ideally in
 * `AbilityStage.onCreate`). To let you compare prod vs. test, this demo defers
 * initialization to an explicit "Initialize SDK" button so you can pick the
 * environment first. After init the choice is locked for the process lifetime —
 * relaunch the app to switch. In a production app, call init in
 * `AbilityStage.onCreate` with a fixed environment.
 *
 * !!! Replace these placeholder credentials with your own before testing. !!!
 */
const DEMO_CLIENT_TOKEN: string = '511b5df774d45cceb5f8d5a328ec5da1131';
const DEMO_APPLICATION_ID: string = 'm3SvJwengBynqVJvWTeVBk';
const DEMO_SERVICE: string = 'flashcat-harmony-demo';

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
   * @param prod true → production site (browser.flashcat.cloud); false → staging (jira.flashcat.cloud)
   */
  static init(context: common.Context, prod: boolean): void {
    if (DemoSdk.initialized) {
      return;
    }
    const site: FlashcatSite = prod ? FlashcatSite.CN : FlashcatSite.STAGING;
    const config: Configuration = new ConfigurationBuilder(DEMO_CLIENT_TOKEN, prod ? 'prod' : 'staging')
      .setService(DEMO_SERVICE)
      .useSite(site)
      .setVerbose(true) // demo: emit internal HiLog (tag "Flashcat") so you can watch init/write/upload
      .build();
    Flashcat.initialize(context, config, TrackingConsent.GRANTED);

    FlashcatRum.enable(new RumConfigurationBuilder(DEMO_APPLICATION_ID)
      .setSessionSampleRate(100)
      .build());
    FlashcatTrace.enable(new TraceConfigurationBuilder().setSampleRate(100).build());
    FlashcatCrash.enable(new CrashConfigurationBuilder().build());

    DemoSdk.initialized = true;
    DemoSdk.envLabel = prod ? 'prod · browser.flashcat.cloud' : 'staging · jira.flashcat.cloud';
  }

  static monitor(): RumMonitor {
    return GlobalRumMonitor.get();
  }
}
