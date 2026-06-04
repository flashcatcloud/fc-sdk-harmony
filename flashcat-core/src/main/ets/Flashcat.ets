import { common } from '@kit.AbilityKit';
import { Configuration } from './config/Configuration';
import { TrackingConsent } from './privacy/TrackingConsent';
import { SdkCore } from './api/SdkCore';
import { FlashcatCore } from './internal/FlashcatCore';
import { SdkCoreRegistry } from './internal/SdkCoreRegistry';

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
    const core: FlashcatCore = new FlashcatCore(name, context, configuration, consent);
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
    const core: SdkCore = Flashcat.getInstance(instanceName);
    (core as FlashcatCore).setTrackingConsent(consent);
  }

  /** Stops and removes an instance, flushing pending data. */
  static stopInstance(instanceName?: string): void {
    const name: string = instanceName ?? SdkCoreRegistry.DEFAULT_INSTANCE_NAME;
    const core: SdkCore | null = Flashcat.registry.get(name);
    if (core !== null) {
      (core as FlashcatCore).stop();
      Flashcat.registry.unregister(name);
    }
  }
}
