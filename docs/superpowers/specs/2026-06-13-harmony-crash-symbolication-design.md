# HarmonyOS SDK — Crash Reporting + Symbolication (Production Delivery)

> Design spec. Living document — after EACH round, the round's results are
> appended to "Round log" at the bottom so later rounds build on a documented
> foundation. Companion process doc: `docs/HANDOFF.md`.

Date: 2026-06-13
Status: APPROVED (direction); per-round results recorded as we go.

## Goal

Bring the FlashCat HarmonyOS NEXT (ArkTS) SDK to a **production-deliverable**
state for the four asks:

1. Verify everything with the local toolchain (DevEco/hvigor/ohpm), not just on paper.
2. Ship a full demo `entry` HAP so the user can manually verify on device/emulator.
3. Exception + crash reporting, **both native (C/C++ `.so`) and non-native (ArkTS/JS)**, plus app freeze.
4. Symbolication: client-side symbol-file upload + backend (fc-rum) parsing — fully implemented.

Bar: stable (must never re-crash the host app), secure (consent-gated, no
credential leakage, symbol-file ACL), and locally compiled + tested each round.

## Baseline (verified in code, 2026-06-13)

- Client phase-1 compiles locally and is feature-complete through:
  init → session → manual view → resource (+ W3C traceparent correlation) →
  ArkTS unhandled error (`errorManager.on('error')` in `RumFeature.ets`) →
  manual `addError` → NDJSON batches → `/api/v2/rum`.
- Toolchain present locally: `ohpm 6.1.2.268`, `hvigorw.js` under
  `~/Downloads/command-line-tools`, DevEco SDK at
  `/Applications/DevEco-Studio.app/Contents/sdk`. Build env vars in `docs/HANDOFF.md`.
- Backend `fc-rum` (`~/workspace/flashcat/sdk/server/fc-rum`) already symbolicates
  browser / android / android-native / ios / miniprogram via a `Processor`
  interface (`Upload`/`Find`/`Enrich`), per-platform `stack.Parse*`, an
  `elf_buildid` native path + `symbolicator.go`, and controllers in
  `cmd/server/controller/sourcemap/{upload,enrich,list}.go` that switch on
  `types.RumSourceType`. There is **no `harmony`** source type yet. Existing
  reference doc: `shared/fc-dev-docs/rum/android-ndk-symbolication-design.md`.

## Architecture

### Client

**`flashcat-crash` (new HAR module)** — mirrors Android's crash feature, enabled
via `FlashcatCrash.enable()` after `Flashcat.initialize`:
- Subscribes `hiAppEvent` watcher to system events:
  - `APP_CRASH` — carries ArkTS/JS **and** native C++ stacks (HiLog/FaultLogger backed).
  - `APP_FREEZE` — ANR-equivalent watchdog timeout.
- Keeps `errorManager.on('error')` (already in RUM) for live unhandled ArkTS errors.
- Crash kills the process, so crash payloads are written to a dedicated
  **`crash/` persistence dir** and uploaded **on next launch**. On the bus,
  `RumFeature` maps them to an `ErrorEvent` with `is_crash=true`, a per-type
  `error.source`, raw `error.stack`, plus HarmonyOS binary-image / arch metadata
  needed for native symbolication.
- Consent-gated (reuse existing PENDING/GRANTED buffering); every callback wrapped
  in try/catch + re-entrancy guard — the crash path must NEVER throw or re-crash.

**`entry/` demo HAP (new)** — full ArkUI app: environment switch
(test=`jira.flashcat.cloud` / prod=`browser.flashcat.cloud`), init in
`AbilityStage.onCreate`, buttons to trigger: start/stop view, manual addError,
throw ArkTS error, **native C++ crash** (ships a tiny NDK `.so` that derefs null),
**freeze**, and a traced network request. Enables real装真机 end-to-end verification.

**`flashcat-hvigor-plugin` (new build tooling)** — on assemble, collects:
- ArkTS `sourceMaps.map` + `nameCache.json` (release obfuscation deobfuscation).
- Native `.so` (unstripped, DWARF), keyed by ELF buildId.
  Uploads to fc-rum with `event.type = harmony_sourcemap` / `harmony_symbol_file`,
keyed by service+version (+ buildId for native). Mirrors the
fc-sdk-android-gradle-plugin upload contract.

### Backend (fc-rum)

- Add `SourceHarmony RumSourceType = "harmony"` to `types/rum.go` +
  `SupportedRumSourceTypes`.
- `HarmonyProcessor` — ArkTS sourcemap + nameCache deobfuscation (reuses the JS
  sourcemap machinery in `logic/sourcemap/javascript.go`).
- Native `.so` resolution — reuse the existing `elf_buildid` + `symbolicator.go`
  path (same proven route as Android NDK), not a HarmonyOS-only path.
- `stack.ParseHarmony` — parse the HarmonyOS crash stack format (ArkTS frames +
  native frames + binary images).
- Wire `upload.go` / `enrich.go` / `list.go`; add model tables mirroring the
  android-native symbol table.

## Locked decisions

- Native crash capture = `hiAppEvent` subscription (official, stable) — NOT a
  custom signal handler in phase scope.
- Symbol upload trigger = hvigor plugin (build-time), mirroring the Android gradle plugin.
- Native `.so` symbolication reuses the existing `elf_buildid` + symbolicator path.
- Demo ships a real NDK `.so` so native symbolication resolves a real frame.
- `source = "harmony"`; intake unchanged (NDJSON + text/plain → `/api/v2/rum`).
- Crash events force-flushed; persisted to `crash/` and uploaded next launch.
- Everything consent-gated; crash callbacks never throw.

## Round plan (≈7 rounds, doc checkpoint after each)

Each round ends GREEN locally (hvigor assembleHar + test + codelinter, and `go
test` for fc-rum rounds) and appends its results to the Round log below.

- **R1 — Crash module (client) + local build.** `flashcat-crash`: hiAppEvent
  JS+native+freeze capture, `crash/` persistence, next-launch upload, bus →
  ErrorEvent mapping. Unit tests + hvigor green.
- **R2 — Demo HAP.** Full `entry` app incl. native-crash `.so`, env switch, all
  trigger buttons. Builds; documents the manual-verify script.
- **R3 — hvigor symbol-upload plugin.** Collect ArkTS map + nameCache + `.so`;
  upload contract; dry-run against a local/staging fc-rum.
- **R4 — fc-rum backend symbolication.** `SourceHarmony`, `HarmonyProcessor`,
  `stack.ParseHarmony`, native `.so` via elf_buildid, controllers + models, Go tests.
- **R5 — End-to-end + hardening.** Wire client↔backend; sampling, payload caps,
  retry/backoff, telemetry; e2e verification (device or local fc-rum).
- **R6 — Security & stability review.** Consent gating, no clientToken leakage,
  symbol-file ACL, crash-path re-entrancy/never-throw audit, fuzz the stack parser.
- **R7 — Release packaging + docs.** HAR ohpm prepublish dry-run, plugin publish
  flow, update workspace `CLAUDE.md` repo map, finalize `HANDOFF.md` + memory.

The user may compress/extend; rounds are checkpoints, not a contract.

## Round log

### Round 1 — `flashcat-crash` module (DONE, 2026-06-13, local build green)

**Shipped** (4th HAR module `@flashcatcloud/crash`, depends only on `core`):
- `CrashConfiguration` + builder (`trackCrashes`, `trackAppHangs`, both default true).
- `CrashEventMapper` — **pure** translation of a hiAppEvent `AppEventInfo.params`
  into a `crash_report` bus message. Unit-tested (4 cases: ArkTS crash, native
  crash w/ binary_images, freeze, missing-fields tolerance).
- `CrashFeature` — installs a `hiAppEvent.addWatcher` for `APP_CRASH` +
  `APP_FREEZE` (domain `OS`); `onReceive` maps each event and publishes it on the
  bus to RUM. Whole callback wrapped try/catch — crash reporting must never crash
  the host. `onStop` removes the watcher.
- `FlashcatCrash.enable(config)` — registers the feature against the core.
- RUM side: `RumFeature.onReceive` gains a `crash_report` branch →
  `monitor.reportError(message, source, stack, isCrash=true, 'unhandled', attrs)`.
  Native symbolication metadata extracted by a **pure** `RumFeature.crashAttributes`
  static (`_dd.crash.binary_images` / `_dd.crash.arch` / `_dd.crash.kind`),
  unit-tested (2 cases).

**Key design insight (simplifies vs. original spec):** `hiAppEvent` itself
persists the fault and **replays it on the next launch** via the watcher, so the
crash path needs NO custom `crash/` directory or cross-death persistence — the OS
provides durability. The original "write to crash/ dir, upload next launch" idea
is dropped. Live ArkTS errors still flow through the existing
`errorManager.on('error')` hook in RUM (unchanged).

**Bus contract (`crash_report`)** — see `CrashEventMapper`:
`{ type:'crash_report', target:'rum', message, stack, source:'source',
is_crash:true, crash_kind:'crash'|'freeze', binary_images:<json|''>, arch:<str|''> }`.

**Verified locally** (toolchain env in `docs/HANDOFF.md`):
`clean assembleHar` → all 4 HARs built; `test` → local unit-test pipeline green
(core/rum/trace/crash); `codelinter -e error` → "No defects found".

**Deferred to on-device** (cannot exercise hiAppEvent delivery without a device):
the real `AppEventInfo.params` field shape (`exception.name/message/stack`, native
`external_log`, arch/binary_images) must be confirmed against an actual
`APP_CRASH`/`APP_FREEZE`, and `CrashEventMapper` adjusted if the observed shape
differs. Tracked in the R1 plan's on-device checklist.

**Native-crash readiness:** the mapper already carries `binary_images` + `arch`
through to `_dd.crash.*`, so when Round 4 adds the backend symbolicator the native
metadata is already on the error event. Round 2's demo will ship a real NDK `.so`
to produce a genuine native frame.

### Round 2 — `entry` demo HAP (DONE, 2026-06-13, local build green)

**Shipped** (new `entry` HAP module + AppScope app metadata):
- `AppScope/app.json5` gained `icon`/`label` + `AppScope/resources` (icon PNG,
  app_name string) so the project builds as an app, not just HARs.
- `entry/` module: `EntryAbility` (loads single page), `pages/Index.ets` — the
  verification UI, and `common/DemoSdk.ets` — idempotent init that enables
  RUM + Trace + Crash and exposes a prod/staging environment switch (locked at
  init; relaunch to change).
- **Native crash trigger**: `entry/src/main/cpp/napi_init.cpp` exposes
  `triggerNativeCrash()` (null-deref → SIGSEGV in `libentry.so`) + a benign
  `add()`, with `CMakeLists.txt` and typed `libentry.so` d.ts. This produces a
  real native frame for symbolication (R4).
- `Index.ets` buttons: env toggle, Initialize, Start/Stop View, Fire Traced
  Network Request (rcp + `FlashcatTrace.interceptor()`), Add Manual Error, Throw
  Unhandled ArkTS Error (async `setTimeout` throw), Trigger Native Crash, Trigger
  App Freeze (8s main-thread block), plus an on-screen event log.
- `entry/README.md`: device setup (signing + credential placeholders), CLI build,
  per-button telemetry table, and a device verification checklist.

**Verified locally:** `assembleHap` → `CompileArkTS` ✅, native CMake/Ninja build
→ `libentry.so` (arm64-v8a) ✅ (unstripped DWARF copy under
`entry/build/.../intermediates/cmake/.../obj/arm64-v8a/libentry.so` — the exact
artifact R3's plugin uploads), unsigned HAP produced, `codelinter` → "No defects".
Signing/running on a device is the user's step (DevEco automatic signing).

**Credentials:** `DemoSdk.ets` ships `REPLACE_WITH_*` placeholders — the user must
fill client token + application id before running. (No real tokens committed.)

### Round 3 — `@flashcatcloud/hvigor-plugin` (DONE, 2026-06-13, tested + cross-verified)

**Shipped** (new `hvigor-plugin/` Node/TS package, **zero runtime deps** — uses
Node ≥18 built-in `fetch`/`FormData`):
- `src/elf.ts` — `extractElfBuildId(Buffer)`: parses the `.note.gnu.build-id` ELF
  note, mirroring fc-rum's `logic/sourcemap/elf_buildid.go`.
- `src/collect.ts` — `collectArktsSourcemap` (finds `sourceMaps.map`, prefers the
  `outputs` copy, + optional `nameCache.json`) and `collectNativeSymbols` (finds
  UNSTRIPPED `.so` under `intermediates/cmake/.../obj/<abi>`, skips system libs +
  stripped copies, extracts build-id, maps ABI→arch).
- `src/upload.ts` — event metadata builders + multipart POST. Defines the
  **upload contract** (see below).
- `src/index.ts` — `uploadAll(buildDir, cfg, log)` orchestration; never throws (a
  symbol-upload failure must not fail the app build).
- `src/plugin.ts` — `flashcatSymbolUploadPlugin(options)`: registers an
  `uploadFlashcatSymbols` hvigor task (postDependencies assembleHap/assembleHar),
  opt-in via `enabled` / `FLASHCAT_UPLOAD`. Models only the minimal hvigor API so
  the package type-checks without depending on `@ohos/hvigor`.
- `README.md` documents usage + the contract; `test/` has 11 unit tests.

**Upload contract (locks R4 backend):** `POST {endpoint}/sourcemap/upload`,
multipart, headers `DD-API-KEY` (auth → account), `DD-EVP-ORIGIN:
flashcat-hvigor-plugin` (routes to the HarmonyOS handler),
`DD-EVP-ORIGIN-VERSION`.
- ArkTS: `event={type:'harmony_sourcemap',service,version,cli_version}` +
  `source_map` file + optional `name_cache` file.
- Native: one request per `.so`,
  `event={type:'harmony_symbol_file',service,version,arch,lib_name,build_id}` +
  `symbol_file` (unstripped `.so`). `arch`∈{arm64,arm,x64,x86}.

**Verified locally:** `node --experimental-strip-types --test` → **11/11 pass**,
incl. extracting a real GNU build-id from an arm64 `.so` fixture and the
collection rules. **Cross-impl check:** the plugin and fc-rum's Go extractor
produce the IDENTICAL build-id (`d7b6e463…`) for the same `.so` — guaranteeing the
client-uploaded `build_id` matches the server lookup key.

**R4 inputs ready:** origin `flashcat-hvigor-plugin`, event types
`harmony_sourcemap` / `harmony_symbol_file`, and the exact form fields above are
what the backend must route + parse.
