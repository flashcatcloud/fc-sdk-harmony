import { Feature, FeatureScope, FeatureEventReceiver } from './feature/Feature';
import { FlashcatContext, UserInfo } from './context/FlashcatContext';
import { TrackingConsent } from '../privacy/TrackingConsent';

/**
 * Where a feature that calls a NON-batch endpoint has to send its request, and
 * what identifies the caller there. Handed out separately from
 * {@link FlashcatContext} on purpose: the client token is a credential, and the
 * context is snapshotted into every event.
 */
export interface IntakeTarget {
  /** Intake host, honouring a configured custom endpoint. No trailing slash. */
  readonly host: string;
  readonly clientToken: string;
}

/**
 * The running SDK instance handed to features. Returned by
 * `Flashcat.initialize` / `Flashcat.getInstance`. Equivalent to Android's `SdkCore`.
 */
export interface SdkCore {
  readonly name: string;

  /** Register a feature (called by FlashcatRum.enable, FlashcatLogs.enable...). */
  registerFeature(feature: Feature): void;

  /** Look up a registered feature's scope, or null if not enabled. */
  getFeature(featureName: string): FeatureScope | null;

  /** Subscribe a receiver to bus messages targeted at `featureName`. */
  setEventReceiver(featureName: string, receiver: FeatureEventReceiver): void;
  removeEventReceiver(featureName: string): void;

  /** Merge feature-scoped baggage into the shared context (e.g. RUM view id). */
  updateFeatureContext(featureName: string, update: Record<string, Object>): void;

  /** Current context snapshot. */
  getContext(): FlashcatContext;

  /** Current tracking consent — features (e.g. Trace) must honor it. */
  getTrackingConsent(): TrackingConsent;

  /**
   * False once the instance has been stopped. Long-lived captures of a core
   * (e.g. an rcp interceptor built before a stop/re-initialize cycle) must
   * check this and stop injecting/reporting instead of acting on dead state.
   */
  isActive(): boolean;

  /**
   * Intake host + client token, for a feature that calls an endpoint of its own
   * (the RUM remote-configuration endpoint) rather than the batch pipeline.
   */
  getIntakeTarget(): IntakeTarget;

  /**
   * Small persistent settings store, shared by every feature and keyed by
   * whatever the caller passes. Feature modules receive no HarmonyOS Context of
   * their own, so anything they need across launches goes through the core.
   * Returns null when the key was never written or storage is unavailable —
   * a caller must behave as if it had never stored anything.
   */
  readSetting(key: string): string | null;

  /** Persist (or, with a null value, remove) one settings entry. Best-effort. */
  writeSetting(key: string, value: string | null): void;

  /** Set / clear the identified user. */
  setUserInfo(user: UserInfo): void;
  /** Clear the identified user (equivalent to setUserInfo({})). */
  clearUserInfo(): void;
}
