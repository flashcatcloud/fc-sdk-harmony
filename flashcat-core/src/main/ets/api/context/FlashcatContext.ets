/** Device characteristics, collected once at init and refreshed on change. */
export interface DeviceInfo {
  brand: string;          // e.g. "HUAWEI"
  model: string;          // marketing model
  osName: string;         // "HarmonyOS"
  osVersion: string;      // e.g. "5.0.0"
  apiVersion: number;     // SDK API level
  deviceType: string;     // phone / tablet / 2in1 / tv / wearable / car
}

/** Identified end user. All fields optional. */
export interface UserInfo {
  id?: string;
  name?: string;
  email?: string;
  extraInfo?: Record<string, Object>;
}

/** Current connectivity. */
export interface NetworkInfo {
  connectivity: string;  // wifi / cellular / ethernet / none
  carrierName?: string;
}

/**
 * The central context attached to every event. Assembled by the ContextProvider
 * and snapshotted per event. Equivalent to Android's `DatadogContext`.
 */
export interface FlashcatContext {
  // NOTE: the client token is intentionally NOT exposed here — it is a credential
  // and is used only by the uploader (from Configuration), never attached to events.
  env: string;
  variant: string;
  service: string;
  version: string;          // app version
  bundleId: string;         // app bundle identifier
  source: string;           // always "harmony"
  sdkVersion: string;
  device: DeviceInfo;
  user: UserInfo;
  network: NetworkInfo;
  // Per-feature mutable baggage (e.g. RUM publishes the active view/session here
  // so Logs and Trace can correlate). Keyed by feature name.
  featureContext: Record<string, Record<string, Object>>;
}
