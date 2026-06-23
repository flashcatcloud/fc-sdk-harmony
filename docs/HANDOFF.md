# Handoff — RUM Resource Events (phase-1 completion)

> Living process doc. Updated after EVERY task so a fresh session (or another
> person) can resume losslessly. Plan with full code:
> `docs/superpowers/plans/2026-06-10-rum-resource-events.md`.

## Goal

Complete the phase-1 feature list for the HarmonyOS SDK:
App init → Session → manual View → **Resource (network + traceparent correlation)**
→ Error/Crash → local NDJSON batches → `/api/v2/rum` upload → platform aggregation
by Session/View/Resource/Error.

Everything except Resource already shipped in commits `7e4e59f`/`f87ff6b`/`d9bf5c4`.
This effort adds ResourceEvents, correlated to the injected W3C `traceparent` via
`_dd.trace_id`/`_dd.span_id`, reusing the existing message bus (Trace interceptor
→ RUM feature) — no new module, no inter-feature dependency.

## Task checklist

- [x] Task 1: Handoff log scaffolding (this file + plan)
- [x] Task 2: RumRawEvent resource fields + RumMonitor.stopResourceWithError
- [x] Task 3: RumEventAssembler.resource() + error() resource variant
- [x] Task 4: RumResourceScope (new file)
- [x] Task 5: RumViewScope integration + real resource counts
- [x] Task 6: DefaultRumMonitor resource methods
- [x] Task 7: RumFeature bus translation (network_request_* → monitor)
- [x] Task 8: TraceInterceptor reports resources + doc updates
- [x] Task 9: Wrap-up (device checklist, memory)

## Current state — ALL TASKS DONE + local toolchain verified (2026-06-11)

Phase-1 feature list is now code-complete and locally compiled with DevEco/hvigor:
init → session → manual view → **resource + traceparent correlation** → error →
NDJSON batches → /api/v2/rum. Commits `262d0aa..` on the default branch.

How resource tracking works end-to-end:
1. `FlashcatTrace.interceptor()` on an rcp session injects `traceparent`
   (consent-gated) and publishes `network_request_started/completed/failed`
   bus messages with a per-request UUID key (`TraceInterceptor.ets`).
2. `RumFeature.onReceive` translates them into
   `startResource` / `stopResource` / `stopResourceWithError` monitor calls,
   carrying trace ids as `_dd.trace_id`/`_dd.span_id` start attributes.
3. `RumViewScope` owns pending `RumResourceScope`s (cap 100, dropped on view
   stop); completion emits a ResourceEvent (`_dd.trace_id`/`_dd.span_id`,
   `resource.{id,type,url,method,status_code,size,duration}`), failure emits a
   `source:'network'` ErrorEvent with `error.resource`; view events now carry
   real `resource.count`.
Manual API works without the interceptor: `GlobalRumMonitor.get().startResource(...)`.

## Local verification

Toolchain used:
- `ohpm 6.1.2.268`
- `hvigor 6.24.2`
- `hdc 3.2.0d`
- DevEco Studio SDK at `/Applications/DevEco-Studio.app/Contents/sdk`

Verified commands:

```sh
export PATH="/Users/fiona/Downloads/command-line-tools/bin:/Users/fiona/Downloads/command-line-tools/ohpm/bin:/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export HOS_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export OHOS_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"

ohpm install
node /Users/fiona/Downloads/command-line-tools/hvigor/bin/hvigorw.js clean assembleHar --no-daemon --stacktrace
node /Users/fiona/Downloads/command-line-tools/hvigor/bin/hvigorw.js test --no-daemon --stacktrace
codelinter -c code-linter.json5 -f default -e error .
ohpm prepublish flashcat-core/build/default/outputs/default/flashcat_core.har --log_level info
ohpm prepublish flashcat-rum/build/default/outputs/default/flashcat_rum.har --log_level info
ohpm prepublish flashcat-trace/build/default/outputs/default/flashcat_trace.har --log_level info
```

Notes:
- Run `assembleHar` and `test` as separate hvigor invocations. Combining them in one command can make generated `.test` intermediates interfere with HAR compilation.
- `@flashcatcloud/rum` and `@flashcatcloud/trace` declare `@flashcatcloud/core: "0.1.0"` for publishable manifests; the root `overrides` maps core to `file:./flashcat-core` for local multi-module builds.
- `ohpm prepublish` warns that HAR files contain source code. This is not a prepublish failure, but review the source-distribution policy before public registry release.
- ArkTS still warns on rcp syscap availability and the core HTTP permission in dependency compile output. The build and tests pass; on-device validation should confirm the intended target devices support the rcp APIs.

## Active effort (2026-06-13): Crash + Symbolication, multi-round

Driving spec: `docs/superpowers/specs/2026-06-13-harmony-crash-symbolication-design.md`
(7-round plan, Round log appended after each round). Per-round plans under
`docs/superpowers/plans/`.

- **Round 1 — DONE.** `flashcat-crash` module (hiAppEvent APP_CRASH native+ArkTS
  + APP_FREEZE → `crash_report` bus → RUM `is_crash` error). Local build/test/lint
  green. Key insight: hiAppEvent replays faults on next launch, so NO custom crash
  dir needed. Plan: `docs/superpowers/plans/2026-06-13-r1-crash-module.md`.
- **Round 2 — DONE.** `entry` demo HAP: prod/staging env switch, init+enable
  RUM/Trace/Crash, buttons for view/resource/network/manual-error/ArkTS-throw/
  native-crash(`libentry.so` SIGSEGV)/freeze, on-screen log. `assembleHap` +
  native CMake build + lint green. See `entry/README.md` for device verify.
- **Round 3 — DONE.** `hvigor-plugin/` (`@flashcatcloud/hvigor-plugin`, zero-dep
  Node/TS): collects ArkTS `sourceMaps.map`+`nameCache.json` + unstripped `.so`
  (build-id), uploads via `uploadFlashcatSymbols` task. 11 unit tests pass; build-id
  extraction cross-verified identical to fc-rum's Go extractor. Contract locked
  (origin `flashcat-hvigor-plugin`, types `harmony_sourcemap`/`harmony_symbol_file`).
- **Round 4 — DONE (cross-repo `sdk/server/fc-rum`, branch
  `feat/harmony-symbolication`, commit `afccf23`, NOT merged).** `SourceHarmony`
  + `stack.ParseHarmony` (ArkTS + native frames) + `HarmonyProcessor` (ArkTS via
  reused JS sourcemap infra; native via reused Android NDK pipeline) + upload/
  enrich/list routing on origin `flashcat-hvigor-plugin`. `go build` + 11 unit
  tests + vet green. Gap: store→symbolicate needs MySQL/MinIO/Symbolicator +
  real obfuscated artifacts → Round 5 staging.
- **Round 5 — DONE.** Hardening (crash payload caps 2k/50k/100k + sample rate) +
  `docs/E2E-RUNBOOK.md` for staging+device validation. Build/test/lint green. The
  actual on-device + backend e2e run is the user's step (env-blocked here).
- **Round 6 — DONE.** Security review (`docs/SECURITY-REVIEW.md`): consent
  gating / credential hygiene / account-scoped storage verified safe; hardened ELF
  parser (never-throw + bounds + 200-case fuzz) and ParseHarmony (>8KB line guard
  + Go fuzz). Plugin 12/12; fc-rum fuzz clean.
- **Round 7 — DONE (final).** Release packaging: all 4 HARs `ohpm prepublish`
  succeed; plugin `npm pack` clean + `prepublishOnly` build guard; `sdk/CLAUDE.md`
  repo map updated to include `fc-sdk-harmony/`.

## On-device verification — PARTIALLY DONE (2026-06-13)

Ran the demo on a **local emulator** and confirmed the full upload chain works:
`upload: POST /api/v2/rum -> 202` for view/error/resource batches (real
`batch-<epochms>-…` filenames, NDJSON to `/api/v2/rum`).

Two real bugs were found + fixed during this (commit on dev):
1. `systemDateTime.getTime()` returned `0` on the runtime → batches never aged,
   event `date`=0. Switched persistence + monitor to `Date.now()`.
2. `ensureDir` swallowed `fs.accessSync`'s throw-on-missing → dir never created →
   writes + `listFileSync` failed (`onDisk=0`). Made `ensureDir` robust + self-heal.

**Hard-won environment lesson (don't repeat):** the DevEco **Previewer stubs all
native kit APIs** (fs/time/network/hiAppEvent) — the SDK CANNOT run there; it shows
`getTime()=0`, `onDisk=0`, no uploads. Use a **local emulator** (macOS-ARM/Windows;
needs a Huawei **real-name** account, effectively China-mainland identity) or a
**real device**. Verbose SDK logging: `ConfigurationBuilder.setVerbose(true)` →
HiLog tag `Flashcat` (domain 0xF1A7).

Still NOT verified on-device (needs a real device, not just emulator):
- native `.so` crash + freeze delivery via `hiAppEvent` and next-launch replay;
- end-to-end symbolication (needs the hvigor plugin to upload symbols to a fc-rum
  with the `feat/harmony-symbolication` branch + the real obfuscated artifacts).

## Phase 2 implementation started (2026-06-14): auto-instrumentation M1+M2 + R3

Driving doc: `docs/PHASE-2-PLAN.md` (see its Revision log "Implementation pass").
Implemented + locally build/lint-verified (assembleHar all modules + assembleHap
demo + codelinter all "No defects"; unit tests added in
`flashcat-rum/src/test/Phase2AutoInstrumentation.test.ets` +
`flashcat-trace/src/test/List.test.ets`, compile-clean):

- **A3 tap auto-tracking** — `flashcat-rum/.../internal/RumAutoInstrumentation.ets`
  (`trackTap`, gated by `trackUserInteractions`); `FlashcatRum.trackTap`. Demo `btn`
  builder + sub-pages route every tap through it. Log: `rum.tap: auto action tap`.
- **A1 navigation auto-tracking** — `RumNavigationTracker.ets` on
  `uiObserver.on('routerPageUpdate', context, cb)`; ON_PAGE_SHOW→startView,
  ON_PAGE_HIDE→stopView; key=pageId→path→index, name=name→last path segment.
  `FlashcatRum.startViewTracking(context)` (demo calls with `this.getUIContext()`).
  Demo gains `pages/PageDetail.ets` + `pages/PageSettings.ets` (registered in
  `main_pages.json`). Log: `rum.nav: auto startView/stopView`.
- **A2 network auto-capture** — `flashcat-trace/.../FlashcatHttp.ets` wraps
  `@ohos.net.http`; reuses refactored bus publishers
  (`publishResourceStarted/Completed/Failed`, now exported from TraceInterceptor);
  consent + `firstPartyHosts`-gated traceparent (`TraceConfiguration.firstPartyHosts`
  + `isFirstParty`). Demo "Auto HTTP GET/POST" buttons use it with NO interceptor.
- **R3 event mappers** — `RumEventMapper` type (RumTypes), `RumEventMapperHolder.ets`
  + `writeMapped(writer,event,force)` swapped in at all 6 `writer.write` sites
  (RumViewScope×3, RumResourceScope×2, RumSessionScope×1). Never-throw: a throwing
  mapper passes the event through unmodified. `RumConfigurationBuilder.setEventMapper`.
  Demo mapper scrubs `resource.url` query strings + drops taps whose target contains
  "secret". Log: `rum.mapper: dropped event type=...`.

**Live on-device acceptance — DONE (2026-06-14, "Pura 90" emulator).** Drove the
demo via `docs/phase2-acceptance.sh` (uitest dumpLayout + uinput) and confirmed in
HiLog (tag Flashcat, domain 0xF1A7):
- **A1**: `rum.nav: auto stopView`/`auto startView` for the full Home→Detail→Settings
  →back→Home stack, stop-before-start ordering, names/paths mapped
  (`pages/PageDetail`/`pages/PageSettings`/`pages/Index`).
- **A3**: `rum.tap: auto action tap target="…"` for home + sub-page buttons.
- **R3**: `rum.mapper: dropped event type=action` for the "secret" taps; URL scrub
  confirmed (`https://httpbingo.org/get?token=SECRET123&u=1` → `…/get`).
- **A2**: `write: type=resource` from `FlashcatHttp` with NO interceptor wiring.
- **Upload**: repeated `upload: POST /api/v2/rum -> 202`.

Toolchain notes for the live loop (hard-won this session):
- The freshly cold-booted emulator **accepts the unsigned CLI HAP**:
  `hdc install -r entry/build/.../entry-default-unsigned.hap` — no DevEco signing
  needed. Launch the AVD headless via
  `"/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator" -hvd "Pura 90"`
  (AVD is named **"Pura 90"**, data under `~/.Huawei/Emulator/deployed/`).
- `hdc shell "uinput -T -c X Y"` MUST be quoted as one arg (unquoted → "parameter
  error"). Tap the *smallest non-zero-bounds* node for a button (its inner Text node
  reports `[0,0]`). `force-stop` before driving so the Scroll starts at the top
  (off-screen buttons report `[0,0]`). The app's el2 sandbox dir is not reliably
  shell-readable, so verify scrub via a HiLog probe, not by catting the batch file.
- Still NOT run on-device: the hypium unit-test *assertions* (compile-clean; they
  execute in a device test runtime, not host) — separate from this demo acceptance.

## Phase 2 M3 — SDK-side production hardening complete (2026-06-23)

Driving doc: `docs/PHASE-2-PLAN.md` (see "M3 implementation pass"). This completes
the SDK-side M3 scope needed before M4; real-device WorkScheduler quota/latency
behavior still needs final device acceptance.

- **R1 schema alignment** — RUM assembly now emits `view.url` from the view key/path
  instead of display name, populates `_dd.session.plan=1`, preserves
  `source:"harmony"`, and keeps viewless ErrorEvents viewless while viewed errors
  include the corrected `view.url`. Covered by
  `flashcat-rum/src/test/SchemaAlignment.test.ets`. Full `rum-events-format`
  codegen remains an OQ-5 hardening follow-up, not an M4 blocker.
- **R2 deferred upload plumbing** — core config adds
  `setDeferredUploadWork(abilityName, workId?)`, `setUploadOnWifiOnly`, and
  `setDeferredUploadRequiresCharging`; initialization registers WorkScheduler
  idempotently when configured. Upload drains now claim batches by renaming to
  `*.uploading`, delete on success/drop, restore on retry, and only recover stale
  claimed files after a 10-minute window to avoid foreground/background duplicate
  POSTs. `Flashcat.flushAndWait()` is the awaitable entrypoint for a host
  `WorkSchedulerExtensionAbility`.
- **R3 mappers** — unchanged from the 2026-06-14 pass and still complete.

Minimal host-side WorkScheduler shape for R2 validation:

```ets
const config = new ConfigurationBuilder('<clientToken>', 'prod')
  .setDeferredUploadWork('FlashcatUploadWorkAbility', 71001)
  .setUploadOnWifiOnly(false)
  .setDeferredUploadRequiresCharging(true)
  .build();

// In the app's WorkSchedulerExtensionAbility callback, after normal SDK init:
await Flashcat.flushAndWait();
```

Local verification added for M3:
- `flashcat-core/src/test/DeferredUpload.test.ets`
- `flashcat-rum/src/test/SchemaAlignment.test.ets`
- `hvigorw test --no-daemon --stacktrace` passes.

Scope note: SDK self-telemetry, Logs, Feature Flags, Session Replay are explicitly
OUT of phase 2 (see PHASE-2-PLAN "Scope decisions"). Current release train is M4
crash/symbolication verification, then M6 release/publish. M5 Vitals/WebView is
deferred to the next version iteration and should not block the first package
release.

## ALL 7 ROUNDS COMPLETE (phase 1) — remaining work is the user's

Everything is implemented and locally green (build/test/lint/fuzz). The only
open step is on-device + staging validation per `docs/E2E-RUNBOOK.md`, then:
1. confirm/adjust `CrashEventMapper` to the real hiAppEvent `params` shape,
2. merge fc-rum `feat/harmony-symbolication` (commit `afccf23`+),
3. publish the 4 HARs to ohpm and `@flashcatcloud/hvigor-plugin` to npm.
  (`SourceHarmony`, `HarmonyProcessor`, `stack.ParseHarmony`) → e2e + hardening →
  security review → release packaging.

## Earlier phase-1 follow-ups (still open)
- P2 schema alignment (deferred pending backend confirm): view.url should = key
  not name; `_dd.session.plan`; `source='harmony'` enum in fc-rum.
- Phase 2: nav auto-tracking (UIObserver), compile-time AOP for http.createHttp,
  ActionEvents. (Crash via hiAppEvent — now DONE in Round 1.)

## On-device verification checklist (first DevEco session)

API points never compiled — verify each:
- [ ] rcp shapes: `context.request.url.toString()`, `request.method`,
      `response.statusCode`, `response.body?.byteLength` (streamed responses may
      have undefined body → size 0), catch-param works with `instanceof Error`.
- [ ] `traceparent` header actually on the wire (proxy/charles), format
      `00-{32hex}-{16hex}-01`.
- [ ] NDJSON batch file contains a `"type":"resource"` line whose
      `_dd.trace_id` matches the injected header, with plausible `duration` (ns)
      and `view.id` of the active view.
- [ ] ViewEvent `view.resource.count` increments after each completed request.
- [ ] Failed request (airplane mode / bad host) → `"type":"error"` line with
      `error.source:"network"` + `error.resource.{method,status_code,url}`,
      force-flushed.
- [ ] Resource before any `startView` is silently dropped (expected).
- [ ] >100 concurrent in-flight requests in one view: 101st+ ignored (expected).
- [ ] fc-rum ingest accepts the batch at `/api/v2/rum` (NDJSON, text/plain) and
      the platform aggregates by Session / View / Resource / Error.
- [ ] Earlier phase-1 verify points in plan/memory (bundleManager, deviceInfo,
      @ohos.file.fs, errorManager, cryptoFramework) still apply.

## Gotchas / context a fresh session needs

- Local CLI compilation is available via DevEco Studio + command-line tools. Keep
  the ArkTS constraints in mind (no `{...}` spread, no bare `delete` on Record,
  no `any`, explicit `Record<string, Object>` event assembly), but run hvigor
  before handoff/release.
- Repo is local-only (no remote); commits go straight onto the default branch,
  same as the previous five commits.
- Decisions already locked (don't relitigate — rationale in the plan header):
  interceptor = opt-in (RumConfiguration.trackNetworkRequests stays inert);
  viewless resources dropped; pending resources dropped on view stop; max 100
  pending/view; failed request → network ErrorEvent not ResourceEvent; rcp kind
  = `native`; unknown verbs → GET.
- Android reference for event shape: `fc-sdk-android/.../RumResourceScope.kt`
  (`sendResource` ~line 216): `_dd.trace_id`/`_dd.span_id` arrive as internal
  attributes on startResource and are stripped into the event's `_dd`.
