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
  /** When true, the SDK emits internal HiLog (tag "Flashcat") for debugging. */
  readonly verbose: boolean;

  constructor(
    clientToken: string,
    env: string,
    variant: string,
    service: string | undefined,
    site: FlashcatSite,
    batchUploadFrequencyMs: number,
    verbose: boolean
  ) {
    this.clientToken = clientToken;
    this.env = env;
    this.variant = variant;
    this.service = service;
    this.site = site;
    this.batchUploadFrequencyMs = batchUploadFrequencyMs;
    this.verbose = verbose;
  }
}

export class ConfigurationBuilder {
  private readonly clientToken: string;
  private readonly env: string;
  private variant: string = '';
  private service: string | undefined = undefined;
  private site: FlashcatSite = FlashcatSite.CN;
  private batchUploadFrequencyMs: number = 5000;
  private verbose: boolean = false;

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

  /** Enable internal HiLog (tag "Flashcat") for debugging. Default false. */
  setVerbose(enabled: boolean): ConfigurationBuilder {
    this.verbose = enabled;
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
      this.verbose
    );
  }
}
