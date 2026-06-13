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

(empty — appended after each round)
