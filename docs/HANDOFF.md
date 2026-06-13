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
- **Round 6 — NEXT.** Security & stability review: consent gating audit, no
  clientToken leakage, symbol-file ACL, crash-path never-throw/re-entrancy audit,
  stack-parser fuzz.
- **Round 7.** Release packaging: HAR ohpm prepublish dry-run, plugin publish
  flow, update workspace CLAUDE.md repo map, finalize memory.
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
