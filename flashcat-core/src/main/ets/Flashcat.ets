import { common } from '@kit.AbilityKit';
import { Configuration } from './config/Configuration';
import { TrackingConsent } from './privacy/TrackingConsent';
import { SdkCore } from './api/SdkCore';
import { FlashcatCore } from './internal/FlashcatCore';
import { SdkCoreRegistry } from './internal/SdkCoreRegistry';
import { FlashcatLog } from './internal/FlashcatLog';

/**
 * Entry point of the FlashCat HarmonyOS SDK.
 *
 * Initialize ONCE, as early as possible — the recommended place is
 * `AbilityStage.onCreate` so auto-instrumentation (network, navigation, lifecycle)
 * is installed before app code runs. Then enable features:
 *
 * ```ets
 * // in AbilityStage.onCreate(context)
 * const config = new ConfigurationBuilder('<clientToken>', 'prod')
 *   .useSite(FlashcatSite.CN)
 *   .build();
 * Flashcat.initialize(context, config, TrackingConsent.GRANTED);
 * FlashcatRum.enable(new RumConfigurationBuilder('<applicationId>').build());
 * ```
 *
 * Mirrors `Datadog.initialize(...)` on the Android SDK.
 */
export class Flashcat {
  private static readonly registry: SdkCoreRegistry = new SdkCoreRegistry();

  /**
   * @param context an ability/application context (AbilityStage or UIAbility context)
   * @param configuration core configuration built via ConfigurationBuilder
   * @param consent initial tracking consent
   * @param instanceName optional name for a non-default instance (multi-instance support)
   * @returns the initialized SdkCore, or null if already initialized / invalid config
   */
  static initialize(
    context: common.Context,
    configuration: Configuration,
    consent: TrackingConsent,
    instanceName?: string
  ): SdkCore | null {
    const name: string = instanceName ?? SdkCoreRegistry.DEFAULT_INSTANCE_NAME;
    if (Flashcat.registry.has(name)) {
      // Already initialized — Android logs a warning and returns the existing core.
      return Flashcat.registry.get(name);
    }
    // Called from the host's startup path: a failure here leaves the app
    // without monitoring, never without the app.
    try {
      const core: FlashcatCore = new FlashcatCore(name, context, configuration, consent);
      core.initialize();
      Flashcat.registry.register(name, core);
      return core;
    } catch (error) {
      FlashcatLog.e(`initialize failed: ${Flashcat.errorText(error)}`);
      return null;
    }
  }

  /**
   * Initialize the SDK inside the deferred-upload WorkSchedulerExtensionAbility
   * process. Unlike `initialize`, this takes NO consent literal: the extension
   * acts only on the main process's last persisted consent decision (missing or
   * NOT_GRANTED → nothing is read, migrated, or uploaded) and never writes
   * consent, identity, or background-job registrations back — HarmonyOS
   * Preferences are per-process caches, so a write from this process could
   * clobber a concurrent main-process revocation.
   *
   * ```ets
   * // in MyUploadExtensionAbility.onWorkStart(workInfo)
   * Flashcat.initializeForDeferredUpload(this.context, buildConfig());
   * await Flashcat.flushAndWait();
   * ```
   */
  static initializeForDeferredUpload(
    context: common.Context,
    configuration: Configuration,
    instanceName?: string
  ): SdkCore | null {
    const name: string = instanceName ?? SdkCoreRegistry.DEFAULT_INSTANCE_NAME;
    if (Flashcat.registry.has(name)) {
      return Flashcat.registry.get(name);
    }
    const core: FlashcatCore =
      new FlashcatCore(name, context, configuration, TrackingConsent.NOT_GRANTED, true);
    core.initialize();
    Flashcat.registry.register(name, core);
    return core;
  }

  /** Retrieve a previously initialized instance. Throws if not initialized. */
  static getInstance(instanceName?: string): SdkCore {
    const name: string = instanceName ?? SdkCoreRegistry.DEFAULT_INSTANCE_NAME;
    const core: SdkCore | null = Flashcat.registry.get(name);
    if (core === null) {
      throw new Error(`Flashcat SDK instance "${name}" is not initialized. Call Flashcat.initialize first.`);
    }
    return core;
  }

  static isInitialized(instanceName?: string): boolean {
    return Flashcat.registry.has(instanceName ?? SdkCoreRegistry.DEFAULT_INSTANCE_NAME);
  }

  /** Sets the consent for the default (or named) instance. */
  static setTrackingConsent(consent: TrackingConsent, instanceName?: string): void {
    const core: FlashcatCore | null = Flashcat.coreOrLog('setTrackingConsent', instanceName);
    if (core === null) {
      return;
    }
    try {
      core.setTrackingConsent(consent);
    } catch (error) {
      FlashcatLog.e(`setTrackingConsent failed: ${Flashcat.errorText(error)}`);
    }
  }

  /** Rolls active batches and triggers upload for the default (or named) instance. */
  static flush(instanceName?: string): void {
    const core: FlashcatCore | null = Flashcat.coreOrLog('flush', instanceName);
    if (core === null) {
      return;
    }
    try {
      core.flush();
    } catch (error) {
      FlashcatLog.e(`flush failed: ${Flashcat.errorText(error)}`);
    }
  }

  /** Rolls active batches and waits for a bounded background drain. */
  static async flushAndWait(instanceName?: string): Promise<void> {
    const core: FlashcatCore | null = Flashcat.coreOrLog('flushAndWait', instanceName);
    if (core === null) {
      return;
    }
    try {
      await core.flushAndWait();
    } catch (error) {
      FlashcatLog.e(`flushAndWait failed: ${Flashcat.errorText(error)}`);
    }
  }

  /**
   * The instance a host-facing call acts on. A call made before initialize (or
   * after stopInstance) is a no-op the log explains — not an exception in the host.
   */
  private static coreOrLog(what: string, instanceName?: string): FlashcatCore | null {
    const core: SdkCore | null = Flashcat.registry.get(instanceName ?? SdkCoreRegistry.DEFAULT_INSTANCE_NAME);
    if (core === null) {
      FlashcatLog.e(`${what} ignored: the SDK instance is not initialized`);
      return null;
    }
    return core as FlashcatCore;
  }

  private static errorText(error: Object): string {
    return error instanceof Error ? error.message : 'error';
  }

  /** Stops and removes an instance, flushing pending data. */
  static stopInstance(instanceName?: string): void {
    const name: string = instanceName ?? SdkCoreRegistry.DEFAULT_INSTANCE_NAME;
    const core: SdkCore | null = Flashcat.registry.get(name);
    if (core !== null) {
      try {
        (core as FlashcatCore).stop();
      } catch (error) {
        FlashcatLog.e(`stopInstance failed: ${Flashcat.errorText(error)}`);
      }
      Flashcat.registry.unregister(name);
    }
  }
}
