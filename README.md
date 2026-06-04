# fc-sdk-harmony

FlashCat RUM / Logs / Trace SDK for **HarmonyOS NEXT** (HarmonyOS 5 / pure OpenHarmony, no AOSP layer).

> Status: **phase 1 implemented (uncompiled)**. The core pipeline (init → context → session →
> disk NDJSON batching → `text/plain` upload), RUM **View** + **Error** (manual + auto unhandled-error
> capture), and **Trace** (W3C `traceparent` generation + rcp interceptor + manual headers) are written
> against real HarmonyOS APIs. The HarmonyOS toolchain (DevEco / `hvigorw` / `ohpm`) is **not present in
> this dev environment**, so the code has **not been compiled or run** — see "Verify on device" below.
> Phase-1 plan: [`docs/PHASE-1.md`](docs/PHASE-1.md).

Unlike the other SDKs in this workspace, this is **not a fork** — neither Datadog nor Sentry ships
a HarmonyOS SDK. The architecture mirrors the FlashCat Android SDK (Datadog-derived shape), but all
code is HarmonyOS-native ArkTS. The de-facto reference designs in this space are **Aliyun ARMS**
(most complete) and **Tencent Bugly** (crash baseline). See [`docs/DESIGN.md`](docs/DESIGN.md) for the
market survey and the Android↔HarmonyOS reuse analysis.

## Packages

Each module ships as a **HAR** published to [ohpm](https://ohpm.openharmony.cn/) under `@flashcatcloud/*`.

| Module dir | Package | Role |
|------------|---------|------|
| `flashcat-core/` | `@flashcatcloud/core` | init, configuration, context, message bus, disk batching, batched upload |
| `flashcat-rum/`  | `@flashcatcloud/rum`  | sessions + **View** + **Error** events (App→Session→View scopes) |
| `flashcat-trace/` | `@flashcatcloud/trace` | W3C `traceparent` generation + rcp interceptor + manual `getHeaders()` |

Planned next: `@flashcatcloud/logs`, `@flashcatcloud/crash` (hiAppEvent JS/C++/Freeze), RUM Resource/network
events, auto navigation tracking, compile-time AOP network injection.

## Usage (target API)

```ets
// In AbilityStage.onCreate — initialize BEFORE app code.
import { Flashcat, ConfigurationBuilder, FlashcatSite, TrackingConsent } from '@flashcatcloud/core';
import { FlashcatRum, RumConfigurationBuilder, GlobalRumMonitor, RumErrorSource } from '@flashcatcloud/rum';
import { FlashcatTrace, TraceConfigurationBuilder } from '@flashcatcloud/trace';

const config = new ConfigurationBuilder('<clientToken>', 'prod')
  .useSite(FlashcatSite.CN)      // CN = production; FlashcatSite.STAGING = test
  .build();
Flashcat.initialize(this.context, config, TrackingConsent.GRANTED);

FlashcatRum.enable(new RumConfigurationBuilder('<applicationId>').setSessionSampleRate(100).build());
FlashcatTrace.enable(new TraceConfigurationBuilder().build());

// View
GlobalRumMonitor.get().startView('home', 'HomePage');
GlobalRumMonitor.get().stopView('home');

// Error — manual (uncaught ArkTS exceptions are captured automatically too)
GlobalRumMonitor.get().addError('checkout failed', RumErrorSource.SOURCE, err.stack);

// Trace — auto on an rcp session …
const session = rcp.createSession({ interceptors: [FlashcatTrace.interceptor()] });
// … or manual on any stack
const headers = FlashcatTrace.getHeaders();   // { traceparent: '00-…-…-01' }
```

## Verify on device (toolchain not in this env)

When opened in DevEco Studio / with `hvigorw` available, sanity-check these HarmonyOS API points
(written from docs, unverified by compiler): `bundleManager.getBundleInfoForSelf` flags + `versionName`;
`deviceInfo` field names; `@ohos.file.fs` (`openSync`/`writeSync`/`listFileSync`/`readTextSync`) modes;
`http.request` POST with `text/plain`; `errorManager.on('error', …)` observer shape; `rcp.Interceptor` /
`RequestContext.request.headers` mutation; `cryptoFramework.createRandom().generateRandomSync`.

## Layout

```
flashcat-core/
  Index.ets                        # public API barrel
  src/main/ets/
    Flashcat.ets                   # init entry  (≈ Datadog.initialize)
    config/Configuration.ets       # config builder
    FlashcatSite.ets               # CN / STAGING intake endpoints
    privacy/TrackingConsent.ets
    api/                           # SdkCore, Feature/FeatureScope/EventReceiver, context, DataWriter
    internal/
      FlashcatCore.ets             # SdkCore impl: ties context+bus+storage+upload per feature
      SdkCoreRegistry.ets          # named multi-instance registry
      bus/MessageBus.ets           # inter-feature messaging
      context/ContextProvider.ets  # device/app/user/network context
      persistence/FilePersistenceStrategy.ets  # NDJSON batch files
      upload/DataUploader.ets      # text/plain NDJSON POST to fc-rum
      upload/UploadScheduler.ets   # cadence + exponential backoff
flashcat-rum/
  Index.ets
  src/main/ets/
    FlashcatRum.ets                # enable entry (≈ Rum.enable)
    RumConfiguration.ets
    RumMonitor.ets                 # interface + GlobalRumMonitor (+ no-op)
    RumTypes.ets                   # action/error/resource enums
    internal/
      RumFeature.ets               # feature + crash-event receiver
      monitor/DefaultRumMonitor.ets
      scope/{RumScope,RumApplicationScope,RumSessionScope,RumViewScope}.ets
```

## Build (requires DevEco Studio / HarmonyOS toolchain)

Local consistency check (works in this dev environment):

```bash
node scripts/verify-phase1-consistency.mjs
```

```bash
ohpm install
hvigorw assembleHar          # build all HAR modules
hvigorw codeLinter           # ArkTS lint
# publish (when ready): ohpm publish flashcat-core/build/default/outputs/default/flashcat-core.har
```

> The HarmonyOS SDK + `hvigorw` are not present in this dev environment, so the build is not
> wired to CI here yet. See `CONTRIBUTING.md`.

## Backend

Events report to **fc-rum** (`~/workspace/flashcat/duty/server/fc-rum`). Intake expects **NDJSON with
`Content-Type: text/plain`**. Crash symbolication needs a HarmonyOS-specific artifact-upload path
(sourcemap + `nameCache.json` for ArkTS, symbol `.so` for native) — see `docs/DESIGN.md` §4.
