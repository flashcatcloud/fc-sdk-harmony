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
  /**
   * How long the active batch file stays open before it is rolled (closed) and
   * becomes drainable. Larger windows pack more events per request, which both
   * cuts the number of uploads and compresses better (gzip has more to work
   * with) — the two things that reduce contention with the app's own traffic.
   *
   * Mirrors Android's `BatchSize` (SMALL/MEDIUM/LARGE), as a continuous value.
   *
   * Cross-process note: this also gates when the deferred-upload process may
   * claim a batch it did not create (a foreign batch is only safe to claim once
   * past the roll window). Both processes MUST be built from the same
   * Configuration — see `Flashcat.initializeForDeferredUpload`.
   */
  readonly batchWindowMs: number;
  /**
   * Upper bound on how many batches one upload cycle ships back-to-back before
   * waiting {@link batchUploadFrequencyMs} again. Without a bound, a backlog is
   * drained in one uninterrupted burst that starves the app's own requests of
   * upstream bandwidth.
   *
   * Mirrors Android's `BatchProcessingLevel` (LOW=1 / MEDIUM=10 / HIGH=100), as
   * a continuous value. Does not apply to the deferred-upload (WorkScheduler)
   * drain, which the system already schedules off the critical path.
   */
  readonly maxBatchesPerCycle: number;
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
    batchWindowMs: number,
    maxBatchesPerCycle: number,
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
    this.batchWindowMs = batchWindowMs;
    this.maxBatchesPerCycle = maxBatchesPerCycle;
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
  private batchWindowMs: number = 5000;
  private maxBatchesPerCycle: number = 10;
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
    // Floor at 1 s: 0 or a negative value would turn the upload scheduler's
    // idle tick into a setTimeout(0) hot loop (CPU/battery burn, no benefit).
    this.batchUploadFrequencyMs = Math.max(1000, frequencyMs);
    return this;
  }

  /**
   * How long the active batch stays open before it is rolled and becomes
   * drainable. Default 5 s; clamped to [1 s, 60 s].
   *
   * Raise it to pack more events per upload — fewer requests and a better gzip
   * ratio, so less upstream contention with the app's own traffic. The cost is
   * latency: an event can sit in the open batch for up to this long before it is
   * eligible to ship (`Flashcat.flush()` and backgrounding still roll it early).
   *
   * Must be identical in the deferred-upload process — see {@link Configuration#batchWindowMs}.
   */
  setBatchWindowMs(windowMs: number): ConfigurationBuilder {
    // Floor at 1 s for the same reason as the upload frequency, and because the
    // cross-process claim guard is derived from this window — a near-zero window
    // would let either process claim the other's still-active batch.
    // Cap at 60 s: past that, events linger long enough that a kill loses more
    // than the packing saves, and flush latency stops being explainable.
    this.batchWindowMs = Math.min(60000, Math.max(1000, windowMs));
    return this;
  }

  /**
   * Upper bound on batches shipped back-to-back per upload cycle. Default 10
   * (same as Android's `BatchProcessingLevel.MEDIUM`); floored at 1.
   *
   * Lower it to 1 to spread a backlog across cycles instead of emptying it in one
   * burst — the setting that matters when the app has latency-sensitive requests
   * of its own competing for a narrow uplink.
   */
  setMaxBatchesPerCycle(count: number): ConfigurationBuilder {
    // A cycle that ships zero batches never drains; floor at 1. Truncate so a
    // fractional value can't make the scheduler's counter comparison unreachable.
    this.maxBatchesPerCycle = Math.max(1, Math.floor(count));
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
      this.batchWindowMs,
      this.maxBatchesPerCycle,
      this.deferredUploadAbilityName,
      this.deferredUploadWorkId,
      this.uploadOnWifiOnly,
      this.deferredUploadRequiresCharging,
      this.verbose,
      this.customEndpoint
    );
  }
}
