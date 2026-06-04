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

  constructor(
    clientToken: string,
    env: string,
    variant: string,
    service: string | undefined,
    site: FlashcatSite,
    batchUploadFrequencyMs: number
  ) {
    this.clientToken = clientToken;
    this.env = env;
    this.variant = variant;
    this.service = service;
    this.site = site;
    this.batchUploadFrequencyMs = batchUploadFrequencyMs;
  }
}

export class ConfigurationBuilder {
  private readonly clientToken: string;
  private readonly env: string;
  private variant: string = '';
  private service: string | undefined = undefined;
  private site: FlashcatSite = FlashcatSite.CN;
  private batchUploadFrequencyMs: number = 5000;

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

  build(): Configuration {
    return new Configuration(
      this.clientToken,
      this.env,
      this.variant,
      this.service,
      this.site,
      this.batchUploadFrequencyMs
    );
  }
}
