import { common, bundleManager, ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { Configuration } from '../config/Configuration';
import { TrackingConsent } from '../privacy/TrackingConsent';
import { SdkCore } from '../api/SdkCore';
import { Feature, FeatureScope, FeatureEventReceiver, EventWriter, RUM_FEATURE_NAME } from '../api/feature/Feature';
import { FlashcatContext, UserInfo } from '../api/context/FlashcatContext';
import { ContextProvider } from './context/ContextProvider';
import { MessageBus } from './bus/MessageBus';
import { FilePersistenceStrategy } from './persistence/FilePersistenceStrategy';
import { CrashPendingStore, CRASH_STORAGE_TARGET } from './persistence/CrashPendingStore';
import { DataUploader } from './upload/DataUploader';
import { UploadScheduler } from './upload/UploadScheduler';
import { DeferredUploadWorkRegistrar, DeferredUploadWorkOptions } from './upload/DeferredUploadWorkRegistrar';
import { FlashcatLog } from './FlashcatLog';

const PREFERENCES_NAME: string = 'flashcat_sdk';
const CONSENT_KEY: string = 'tracking_consent';

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
  private readonly crashPendingStore: CrashPendingStore;
  private readonly features: Map<string, RegisteredFeature> = new Map<string, RegisteredFeature>();
  private readonly deferredUploadRegistrar: DeferredUploadWorkRegistrar = new DeferredUploadWorkRegistrar();
  private appStateCallback: ApplicationStateChangeCallback | null = null;
  private active: boolean = true;
  private readonly backgroundProcess: boolean;
  // Extension-process upload-only pipelines (no Feature object): built by
  // scanning the feature dirs the MAIN process left on disk, because no
  // feature is ever enabled in the extension — without these, flushAndWait
  // iterated an empty features map and deferred upload shipped nothing, ever.
  private readonly uploadPipelines: Array<UploadPipeline> = [];

  constructor(
    name: string,
    context: common.Context,
    configuration: Configuration,
    consent: TrackingConsent,
    backgroundProcess: boolean = false
  ) {
    this.name = name;
    this.context = context;
    this.configuration = configuration;
    this.backgroundProcess = backgroundProcess;
    const persisted: TrackingConsent | null = FlashcatCore.readPersistedConsent(context);
    if (backgroundProcess) {
      // Deferred-upload extension process: consent is READ-ONLY here. The
      // extension has no user in front of it, so it must act on the main
      // process's last persisted decision — never on its own literal, and
      // never write consent back (Preferences are per-process whole-file
      // caches: a write from this process could clobber a concurrent main-
      // process revocation). No persisted value means the main app never
      // initialized — do nothing.
      this.consent = persisted ?? TrackingConsent.NOT_GRANTED;
    } else if (persisted === TrackingConsent.NOT_GRANTED && consent !== TrackingConsent.NOT_GRANTED) {
      // Sticky revocation: a persisted NOT_GRANTED survives the constructor
      // literal until the app explicitly re-grants via setTrackingConsent —
      // an init literal alone must not resurrect refused tracking. All other
      // combinations trust the literal (the app is the consent authority;
      // Datadog-parity apps pass their own stored consent at init).
      FlashcatLog.d(`consent: persisted NOT_GRANTED overrides initial ${consent}`);
      this.consent = TrackingConsent.NOT_GRANTED;
    } else {
      this.consent = consent;
    }
    // Under NOT_GRANTED no durable device identifier may be written; the
    // background process never writes identity either (read-only rule above).
    this.contextProvider = new ContextProvider(
      context, configuration,
      this.consent !== TrackingConsent.NOT_GRANTED && !backgroundProcess);
    this.crashPendingStore = new CrashPendingStore(context, !backgroundProcess);
  }

  /** Called by Flashcat.initialize. Flush buffered events when the app backgrounds. */
  initialize(): void {
    FlashcatLog.setEnabled(this.configuration.verbose);
    this.bus.setReceiver(CRASH_STORAGE_TARGET, this.crashPendingStore);
    FlashcatLog.d(`initialize: instance="${this.name}" site=${this.configuration.site} `
      + `consent=${this.consent} background=${this.backgroundProcess}`);
    if (this.backgroundProcess) {
      // The extension is a consumer only: it never persists consent, never
      // (de)registers the deferred job, and needs no lifecycle observer.
      // It DOES need upload pipelines for the batches the main process wrote.
      this.discoverUploadPipelines();
      return;
    }
    FlashcatCore.persistConsent(this.context, this.consent);
    // Arm background delivery only under GRANTED: under PENDING/NOT_GRANTED there
    // is nothing uploadable, and the persisted job would keep waking the extension
    // process (across reboots) for a user who has not consented. The GRANTED
    // transition in setTrackingConsent re-arms it. The deregister is real even
    // when THIS process never registered (job persisted by an earlier launch).
    if (this.consent === TrackingConsent.GRANTED) {
      this.registerDeferredUploadWork();
    } else {
      this.deferredUploadRegistrar.deregister(this.deferredWorkOptions());
    }
    try {
      this.appStateCallback = {
        onApplicationForeground: () => {},
        onApplicationBackground: () => {
          this.flushAll();
        }
      };
      this.context.getApplicationContext().on('applicationStateChange', this.appStateCallback);
    } catch (_e) {
      this.appStateCallback = null;
      // Lifecycle hook unavailable — uploads still drain on the normal cadence.
    }
  }

  registerFeature(feature: Feature): void {
    if (this.features.has(feature.name)) {
      return; // already enabled — ignore the duplicate (avoids leaking a 2nd hook)
    }
    const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(this.context, feature.name);
    // Settle a pre-consent buffer left by an EARLIER launch. Without this, an
    // app that persisted the user's consent itself (init with GRANTED on launch
    // 2) leaves the launch-1 buffer orphaned forever — and under NOT_GRANTED
    // the denied data would be retained indefinitely.
    if (this.consent === TrackingConsent.GRANTED) {
      persistence.migratePending();
    } else if (this.consent === TrackingConsent.NOT_GRANTED) {
      persistence.wipeAll(); // sticky revocation: leftover batches are refused data
    }
    const uploader: DataUploader = new DataUploader(
      this.configuration,
      FlashcatCore.trackPathFor(feature.name),
      () => this.contextProvider.snapshot()
    );
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

  isActive(): boolean {
    return this.active;
  }

  setUserInfo(user: UserInfo): void {
    this.contextProvider.setUser(user);
  }

  clearUserInfo(): void {
    this.contextProvider.setUser({});
  }

  setTrackingConsent(consent: TrackingConsent): void {
    if (this.backgroundProcess) {
      FlashcatLog.e('setTrackingConsent ignored in the deferred-upload process (consent is read-only there)');
      return;
    }
    const previous: TrackingConsent = this.consent;
    this.consent = consent;
    if (previous === consent) {
      return;
    }
    FlashcatCore.persistConsent(this.context, consent);
    if (consent === TrackingConsent.GRANTED) {
      // Durable writes are now allowed: persist the in-memory anonymous id so the
      // device keeps one identity across launches instead of splitting on the
      // NOT_GRANTED -> GRANTED transition.
      this.contextProvider.persistIdentityNow();
      // Flush the pre-consent buffer into the upload dir, then start uploading.
      this.features.forEach((r: RegisteredFeature) => {
        r.persistence.migratePending();
        r.scheduler.start();
      });
      this.registerDeferredUploadWork(); // re-arm background delivery
    } else if (consent === TrackingConsent.NOT_GRANTED) {
      // Discard the pre-consent buffer AND the already-collected batches, stop
      // uploading, and cancel the persisted background job. Keeping collected
      // batches was pointless retention: revocation stops every drain, so the
      // refused user's data would sit on disk indefinitely.
      this.features.forEach((r: RegisteredFeature) => {
        r.persistence.wipeAll();
        r.scheduler.stop();
      });
      this.deferredUploadRegistrar.deregister(this.deferredWorkOptions());
    } else {
      // → PENDING: stop uploading; new events buffer separately until a decision.
      // The persisted background job is cancelled too — an extension wake-up has
      // nothing uploadable until the user decides.
      this.features.forEach((r: RegisteredFeature) => r.scheduler.stop());
      this.deferredUploadRegistrar.deregister(this.deferredWorkOptions());
    }
  }

  stop(): void {
    this.active = false;
    // Final view refresh before shutdown — without it the last view keeps the
    // time_spent of its last incidental write (0 for a quiet session). Skipped
    // under NOT_GRANTED where every write is dropped anyway.
    if (this.consent !== TrackingConsent.NOT_GRANTED) {
      this.bus.send(RUM_FEATURE_NAME, { 'type': 'keep_alive' } as Record<string, Object>);
    }
    this.features.forEach((r: RegisteredFeature) => {
      r.persistence.rollActive(); // close buffered events so they're recovered next launch
      r.scheduler.stop();
      r.feature.onStop();
    });
    this.features.clear();
    this.bus.removeReceiver(CRASH_STORAGE_TARGET);
    if (!this.backgroundProcess) {
      // persisted job must not outlive the SDK (no-op in the extension process)
      this.deferredUploadRegistrar.deregister(this.deferredWorkOptions());
    }
    // Tear down system subscriptions — a stop/re-initialize cycle must not
    // accumulate NetConnection registrations or keep flushing a dead core.
    this.contextProvider.stop();
    if (this.appStateCallback !== null) {
      try {
        this.context.getApplicationContext().off('applicationStateChange', this.appStateCallback);
      } catch (_e) {
        // Already gone.
      }
      this.appStateCallback = null;
    }
  }

  flush(): void {
    if (this.consent === TrackingConsent.NOT_GRANTED) {
      return; // every write is dropped — nothing to refresh or upload
    }
    // Let RUM emit a final view update (current time_spent) before we roll + upload,
    // so the session/view duration reflects real dwell time at backgrounding.
    // Sent under PENDING consent too: those writes land in the pending buffer
    // and migrate on GRANTED — they must carry the final time_spent as well.
    this.bus.send(RUM_FEATURE_NAME, { 'type': 'keep_alive' } as Record<string, Object>);
    if (this.consent !== TrackingConsent.GRANTED) {
      return;
    }
    this.features.forEach((r: RegisteredFeature) => {
      r.persistence.rollActive();
      r.scheduler.triggerNow();
    });
  }

  async flushAndWait(maxBatchesPerFeature: number = 20): Promise<void> {
    if (this.consent === TrackingConsent.NOT_GRANTED) {
      return;
    }
    this.bus.send(RUM_FEATURE_NAME, { 'type': 'keep_alive' } as Record<string, Object>);
    if (this.consent !== TrackingConsent.GRANTED) {
      return;
    }
    const drains: Array<Promise<void>> = [];
    this.features.forEach((r: RegisteredFeature) => {
      r.persistence.rollActive();
      drains.push(r.scheduler.flushForWork(maxBatchesPerFeature));
    });
    for (const pipeline of this.uploadPipelines) {
      drains.push(pipeline.scheduler.flushForWork(maxBatchesPerFeature));
    }
    for (const drain of drains) {
      await drain;
    }
  }

  /**
   * Extension process only: build an upload-only pipeline per feature dir the
   * main process left under files/flashcat/. Runs only under persisted GRANTED.
   */
  private discoverUploadPipelines(): void {
    if (this.consent !== TrackingConsent.GRANTED) {
      return;
    }
    try {
      const base: string = `${this.context.filesDir}/flashcat`;
      const names: string[] = fs.listFileSync(base);
      for (const name of names) {
        if (name === 'crash-pending') {
          continue; // not an upload dir (incident sidecars)
        }
        let isDir: boolean = false;
        try {
          isDir = fs.statSync(`${base}/${name}`).isDirectory();
        } catch (_e) {
          isDir = false;
        }
        if (!isDir) {
          continue;
        }
        const persistence: FilePersistenceStrategy = new FilePersistenceStrategy(this.context, name);
        const uploader: DataUploader = new DataUploader(
          this.configuration,
          FlashcatCore.trackPathFor(name),
          () => this.contextProvider.snapshot());
        const scheduler: UploadScheduler =
          new UploadScheduler(persistence, uploader, this.configuration.batchUploadFrequencyMs);
        this.uploadPipelines.push({ persistence, scheduler });
        FlashcatLog.d(`deferred: upload pipeline for feature dir "${name}"`);
      }
    } catch (_e) {
      // No feature dirs yet — nothing to deliver.
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
    this.deferredUploadRegistrar.register(this.deferredWorkOptions());
  }

  private deferredWorkOptions(): DeferredUploadWorkOptions {
    return {
      workId: this.configuration.deferredUploadWorkId,
      bundleName: this.bundleName(),
      abilityName: this.configuration.deferredUploadAbilityName,
      uploadOnWifiOnly: this.configuration.uploadOnWifiOnly,
      requiresCharging: this.configuration.deferredUploadRequiresCharging
    };
  }

  private static readPersistedConsent(context: common.Context): TrackingConsent | null {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const value: preferences.ValueType = prefs.getSync(CONSENT_KEY, '');
      if (value === TrackingConsent.GRANTED as string) {
        return TrackingConsent.GRANTED;
      }
      if (value === TrackingConsent.NOT_GRANTED as string) {
        return TrackingConsent.NOT_GRANTED;
      }
      if (value === TrackingConsent.PENDING as string) {
        return TrackingConsent.PENDING;
      }
      return null;
    } catch (_e) {
      return null;
    }
  }

  private static persistConsent(context: common.Context, consent: TrackingConsent): void {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      prefs.putSync(CONSENT_KEY, consent as string);
      prefs.flush((_err) => {
        // best-effort durability; worst case the next launch re-reads the old value
      });
    } catch (_e) {
      // best-effort
    }
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

interface UploadPipeline {
  persistence: FilePersistenceStrategy;
  scheduler: UploadScheduler;
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
