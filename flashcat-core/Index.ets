// Public API surface of @flashcatcloud/core.
// Anything not exported here is internal and may change without notice.

export { Flashcat } from './src/main/ets/Flashcat';
export { Configuration, ConfigurationBuilder } from './src/main/ets/config/Configuration';
export { FlashcatSite } from './src/main/ets/FlashcatSite';
export { TrackingConsent } from './src/main/ets/privacy/TrackingConsent';
export { SdkCore } from './src/main/ets/api/SdkCore';

// Feature SDK authoring surface — used by flashcat-rum / flashcat-logs / flashcat-trace,
// not by app developers directly.
export { Feature, FeatureScope, FeatureEventReceiver, EventWriter,
  RUM_FEATURE_NAME, LOGS_FEATURE_NAME, TRACE_FEATURE_NAME, CRASH_FEATURE_NAME } from './src/main/ets/api/feature/Feature';
export { FlashcatContext, DeviceInfo, UserInfo, NetworkInfo } from './src/main/ets/api/context/FlashcatContext';
export { DataWriter } from './src/main/ets/api/storage/DataWriter';
