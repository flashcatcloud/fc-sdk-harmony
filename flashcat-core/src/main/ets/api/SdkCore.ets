import { Feature, FeatureScope, FeatureEventReceiver } from './feature/Feature';
import { FlashcatContext, UserInfo } from './context/FlashcatContext';
import { TrackingConsent } from '../privacy/TrackingConsent';

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

  /** Set / clear the identified user. */
  setUserInfo(user: UserInfo): void;
  /** Clear the identified user (equivalent to setUserInfo({})). */
  clearUserInfo(): void;
}
