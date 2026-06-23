import { FlashcatSite } from '../FlashcatSite';

/**
 * Immutable core SDK configuration. Built via {@link ConfigurationBuilder}.
 * Mirrors `Configuration.Builder(clientToken, env, variant, service)` on Android.
 */
export class Configuration {
  readonly clientToken: string;
  readonly env: string;
  readonly variant: string;
  readonly service: string | undefined;
  readonly site: FlashcatSite;
  readonly batchUploadFrequencyMs: number;
  readonly deferredUploadAbilityName: string;
  readonly deferredUploadWorkId: number;
  readonly uploadOnWifiOnly: boolean;
  readonly deferredUploadRequiresCharging: boolean;
  /** When true, the SDK emits internal HiLog (tag "Flashcat") for debugging. */
  readonly verbose: boolean;
  /**
   * Overrides the intake host (e.g. "http://10.0.2.2:8080" for a local capture
   * server / proxy during debugging). Empty → use {@link site}. The track path
   * (/api/v2/rum) is still appended.
   */
  readonly customEndpoint: string;

  constructor(
    clientToken: string,
    env: string,
    variant: string,
    service: string | undefined,
    site: FlashcatSite,
    batchUploadFrequencyMs: number,
    deferredUploadAbilityName: string,
    deferredUploadWorkId: number,
    uploadOnWifiOnly: boolean,
    deferredUploadRequiresCharging: boolean,
    verbose: boolean,
    customEndpoint: string
  ) {
    this.clientToken = clientToken;
    this.env = env;
    this.variant = variant;
    this.service = service;
    this.site = site;
    this.batchUploadFrequencyMs = batchUploadFrequencyMs;
    this.deferredUploadAbilityName = deferredUploadAbilityName;
    this.deferredUploadWorkId = deferredUploadWorkId;
    this.uploadOnWifiOnly = uploadOnWifiOnly;
    this.deferredUploadRequiresCharging = deferredUploadRequiresCharging;
    this.verbose = verbose;
    this.customEndpoint = customEndpoint;
  }
}

export class ConfigurationBuilder {
  private readonly clientToken: string;
  private readonly env: string;
  private variant: string = '';
  private service: string | undefined = undefined;
  private site: FlashcatSite = FlashcatSite.CN;
  private batchUploadFrequencyMs: number = 5000;
  private deferredUploadAbilityName: string = '';
  private deferredUploadWorkId: number = 71001;
  private uploadOnWifiOnly: boolean = false;
  private deferredUploadRequiresCharging: boolean = true;
  private verbose: boolean = false;
  private customEndpoint: string = '';

  constructor(clientToken: string, env: string) {
    this.clientToken = clientToken;
    this.env = env;
  }

  setVariant(variant: string): ConfigurationBuilder {
    this.variant = variant;
    return this;
  }

  setService(service: string): ConfigurationBuilder {
    this.service = service;
    return this;
  }

  useSite(site: FlashcatSite): ConfigurationBuilder {
    this.site = site;
    return this;
  }

  setBatchUploadFrequencyMs(frequencyMs: number): ConfigurationBuilder {
    this.batchUploadFrequencyMs = frequencyMs;
    return this;
  }

  /**
   * Enables system-backed deferred uploads. The app must declare a
   * WorkSchedulerExtensionAbility with this name and call SDK flush logic from it.
   */
  setDeferredUploadWork(abilityName: string, workId?: number): ConfigurationBuilder {
    this.deferredUploadAbilityName = abilityName;
    if (workId !== undefined) {
      this.deferredUploadWorkId = workId;
    }
    return this;
  }

  setUploadOnWifiOnly(enabled: boolean): ConfigurationBuilder {
    this.uploadOnWifiOnly = enabled;
    return this;
  }

  setDeferredUploadRequiresCharging(enabled: boolean): ConfigurationBuilder {
    this.deferredUploadRequiresCharging = enabled;
    return this;
  }

  /** Enable internal HiLog (tag "Flashcat") for debugging. Default false. */
  setVerbose(enabled: boolean): ConfigurationBuilder {
    this.verbose = enabled;
    return this;
  }

  /**
   * Override the intake host for local debugging, e.g. "http://10.0.2.2:8080"
   * (emulator → host loopback) pointed at a capture server / proxy. Empty → site.
   */
  setCustomEndpoint(endpoint: string): ConfigurationBuilder {
    this.customEndpoint = endpoint;
    return this;
  }

  build(): Configuration {
    return new Configuration(
      this.clientToken,
      this.env,
      this.variant,
      this.service,
      this.site,
      this.batchUploadFrequencyMs,
      this.deferredUploadAbilityName,
      this.deferredUploadWorkId,
      this.uploadOnWifiOnly,
      this.deferredUploadRequiresCharging,
      this.verbose,
      this.customEndpoint
    );
  }
}
