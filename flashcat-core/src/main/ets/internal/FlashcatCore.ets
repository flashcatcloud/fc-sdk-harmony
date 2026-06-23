import { common, bundleManager } from '@kit.AbilityKit';
import { Configuration } from '../config/Configuration';
import { TrackingConsent } from '../privacy/TrackingConsent';
import { SdkCore } from '../api/SdkCore';
import { Feature, FeatureScope, FeatureEventReceiver, EventWriter, RUM_FEATURE_NAME } from '../api/feature/Feature';
import { FlashcatContext, UserInfo } from '../api/context/FlashcatContext';
import { ContextProvider } from './context/ContextProvider';
import { MessageBus } from './bus/MessageBus';
import { FilePersistenceStrategy } from './persistence/FilePersistenceStrategy';
import { DataUploader } from './upload/DataUploader';
import { UploadScheduler } from './upload/UploadScheduler';
import { DeferredUploadWorkRegistrar, DeferredUploadWorkOptions } from './upload/DeferredUploadWorkRegistrar';
import { FlashcatLog } from './FlashcatLog';

/**
 * Default SdkCore implementation. Owns the context provider, message bus, and the
 * per-feature storage → upload pipelines. Equivalent to Android's DatadogCore.
 */
export class FlashcatCore implements SdkCore {
  readonly name: string;
  private readonly context: common.Context;
  private readonly configuration: Configuration;
  private consent: TrackingConsent;

  private readonly contextProvider: ContextProvider;
  private readonly bus: MessageBus = new MessageBus();
  private readonly features: Map<string, RegisteredFeature> = new Map<string, RegisteredFeature>();
  private readonly deferredUploadRegistrar: DeferredUploadWorkRegistrar = new DeferredUploadWorkRegistrar();

  constructor(name: string, context: common.Context, configuration: Configuration, consent: TrackingConsent) {
    this.name = name;
    this.context = context;
    this.configuration = configuration;
    this.consent = consent;
    this.contextProvider = new ContextProvider(context, configuration);
  }

  /** Called by Flashcat.initialize. Flush buffered events when the app backgrounds. */
  initialize(): void {
    FlashcatLog.setEnabled(this.configuration.verbose);
    FlashcatLog.d(`initialize: instance="${this.name}" site=${this.configuration.site} consent=${this.consent}`);
    this.registerDeferredUploadWork();
    try {
      // Inline literal so its target type is the kit's ApplicationStateChangeCallback.
      this.context.getApplicationContext().on('applicationStateChange', {
        onApplicationForeground: () => {},
        onApplicationBackground: () => {
          this.flushAll();
        }
      });
      // NOTE: observer lives for the app/SDK lifetime; not removed on stop (rare).
    } catch (_e) {
      // Lifecycle hook unavailable — uploads still drain on the normal cadence.
    }
  }

  registerFeature(feature: Feature): void {
    if (this.features.has(feature.name)) {
      return; // already enabled — ignore the duplicate (avoids leaking a 2nd hook)
    }
    const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(this.context, feature.name);
    const uploader: DataUploader = new DataUploader(this.configuration, FlashcatCore.trackPathFor(feature.name));
    const scheduler: UploadScheduler =
      new UploadScheduler(persistence, uploader, this.configuration.batchUploadFrequencyMs);
    const scope: CoreFeatureScope = new CoreFeatureScope(
      this.contextProvider, this.bus, feature.name, persistence,
      () => this.consent, () => scheduler.triggerNow());

    this.features.set(feature.name, { feature, scope, scheduler, persistence });
    FlashcatLog.d(`registerFeature: ${feature.name}`);
    feature.onInitialize();
    if (this.consent === TrackingConsent.GRANTED) {
      scheduler.start();
    }
  }

  getFeature(featureName: string): FeatureScope | null {
    const registered: RegisteredFeature | undefined = this.features.get(featureName);
    return registered !== undefined ? registered.scope : null;
  }

  setEventReceiver(featureName: string, receiver: FeatureEventReceiver): void {
    this.bus.setReceiver(featureName, receiver);
  }

  removeEventReceiver(featureName: string): void {
    this.bus.removeReceiver(featureName);
  }

  updateFeatureContext(featureName: string, update: Record<string, Object>): void {
    this.contextProvider.updateFeatureContext(featureName, update);
  }

  getContext(): FlashcatContext {
    return this.contextProvider.snapshot();
  }

  getTrackingConsent(): TrackingConsent {
    return this.consent;
  }

  setUserInfo(user: UserInfo): void {
    this.contextProvider.setUser(user);
  }

  clearUserInfo(): void {
    this.contextProvider.setUser({});
  }

  setTrackingConsent(consent: TrackingConsent): void {
    const previous: TrackingConsent = this.consent;
    this.consent = consent;
    if (previous === consent) {
      return;
    }
    if (consent === TrackingConsent.GRANTED) {
      // Flush the pre-consent buffer into the upload dir, then start uploading.
      this.features.forEach((r: RegisteredFeature) => {
        r.persistence.migratePending();
        r.scheduler.start();
      });
    } else if (consent === TrackingConsent.NOT_GRANTED) {
      // Discard any pre-consent buffer and stop uploading.
      this.features.forEach((r: RegisteredFeature) => {
        r.persistence.wipePending();
        r.scheduler.stop();
      });
    } else {
      // → PENDING: stop uploading; new events buffer separately until a decision.
      this.features.forEach((r: RegisteredFeature) => r.scheduler.stop());
    }
  }

  stop(): void {
    this.features.forEach((r: RegisteredFeature) => {
      r.persistence.rollActive(); // close buffered events so they're recovered next launch
      r.scheduler.stop();
      r.feature.onStop();
    });
    this.features.clear();
  }

  flush(): void {
    if (this.consent !== TrackingConsent.GRANTED) {
      return;
    }
    // Let RUM emit a final view update (current time_spent) before we roll + upload,
    // so the session/view duration reflects real dwell time at backgrounding.
    this.bus.send(RUM_FEATURE_NAME, { 'type': 'keep_alive' } as Record<string, Object>);
    this.features.forEach((r: RegisteredFeature) => {
      r.persistence.rollActive();
      r.scheduler.triggerNow();
    });
  }

  async flushAndWait(maxBatchesPerFeature: number = 20): Promise<void> {
    if (this.consent !== TrackingConsent.GRANTED) {
      return;
    }
    this.bus.send(RUM_FEATURE_NAME, { 'type': 'keep_alive' } as Record<string, Object>);
    const drains: Array<Promise<void>> = [];
    this.features.forEach((r: RegisteredFeature) => {
      r.persistence.rollActive();
      drains.push(r.scheduler.flushForWork(maxBatchesPerFeature));
    });
    for (const drain of drains) {
      await drain;
    }
  }

  private flushAll(): void {
    this.flush();
  }

  private static trackPathFor(featureName: string): string {
    // Phase 1: RUM (views + errors) goes to the rum track. Other features map 1:1.
    return featureName === RUM_FEATURE_NAME ? '/api/v2/rum' : `/api/v2/${featureName}`;
  }

  private registerDeferredUploadWork(): void {
    if (this.configuration.deferredUploadAbilityName.length === 0) {
      return;
    }
    const options: DeferredUploadWorkOptions = {
      workId: this.configuration.deferredUploadWorkId,
      bundleName: this.bundleName(),
      abilityName: this.configuration.deferredUploadAbilityName,
      uploadOnWifiOnly: this.configuration.uploadOnWifiOnly,
      requiresCharging: this.configuration.deferredUploadRequiresCharging
    };
    this.deferredUploadRegistrar.register(options);
  }

  private bundleName(): string {
    const flags: number = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(flags);
      return info.name;
    } catch (_err) {
      return '';
    }
  }
}

interface RegisteredFeature {
  feature: Feature;
  scope: CoreFeatureScope;
  scheduler: UploadScheduler;
  persistence: FilePersistenceStrategy;
}

/** FeatureScope bound to one feature's context + persistence + bus. */
class CoreFeatureScope implements FeatureScope {
  private readonly contextProvider: ContextProvider;
  private readonly bus: MessageBus;
  private readonly featureName: string;
  private readonly writer: EventWriter;

  constructor(
    contextProvider: ContextProvider,
    bus: MessageBus,
    featureName: string,
    persistence: FilePersistenceStrategy,
    consentSupplier: () => TrackingConsent,
    flushTrigger: () => void
  ) {
    this.contextProvider = contextProvider;
    this.bus = bus;
    this.featureName = featureName;
    this.writer = new PersistenceEventWriter(persistence, consentSupplier, flushTrigger);
  }

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    callback(this.contextProvider.snapshot(), this.writer);
  }

  sendEvent(event: Record<string, Object>): void {
    const target: Object | undefined = event['target'];
    this.bus.send(typeof target === 'string' ? target : this.featureName, event);
  }
}

/**
 * EventWriter that serializes to NDJSON and persists, gated by tracking consent:
 *   GRANTED → main dir (+ optional force-flush); PENDING → pending buffer; NOT_GRANTED → drop.
 */
class PersistenceEventWriter implements EventWriter {
  private readonly persistence: FilePersistenceStrategy;
  private readonly consentSupplier: () => TrackingConsent;
  private readonly flushTrigger: () => void;

  constructor(
    persistence: FilePersistenceStrategy,
    consentSupplier: () => TrackingConsent,
    flushTrigger: () => void
  ) {
    this.persistence = persistence;
    this.consentSupplier = consentSupplier;
    this.flushTrigger = flushTrigger;
  }

  write(event: Record<string, Object>, forceFlush?: boolean): boolean {
    const consent: TrackingConsent = this.consentSupplier();
    const eventType: Object | undefined = event['type'];
    FlashcatLog.d(`write: type=${typeof eventType === 'string' ? eventType : '?'} consent=${consent} forceFlush=${forceFlush === true}`);
    if (consent === TrackingConsent.NOT_GRANTED) {
      return false;
    }
    const line: string = JSON.stringify(event);
    if (consent === TrackingConsent.PENDING) {
      return this.persistence.writePending(line);
    }
    const force: boolean = forceFlush === true;
    const ok: boolean = this.persistence.write(line, force);
    if (ok && force) {
      this.flushTrigger();
    }
    return ok;
  }
}
