# FlashCat HarmonyOS SDK — Phase 2 Plan

> Planning doc. Phase 1 is delivered (see `docs/HANDOFF.md` and
> `docs/superpowers/specs/2026-06-13-harmony-crash-symbolication-design.md`).
> Phase 2 turns the manual, single-platform-parity SDK into an
> **auto-instrumenting, production-grade** one, closing the gaps below.
> Reference shape throughout: the Datadog Android SDK (`fc-sdk-android`).
>
> Living document — refined over multiple rounds; see the **Revision log** at the
> bottom. Per-item structure: *What & why · Design · Config · Tasks · Acceptance ·
> Risks · Upstream ref* so each item is independently executable.

Date: 2026-06-13
Status: DRAFT (direction set; scope locked — see "Scope decisions" below)

---

## Phase 1 recap (shipped)

- **Core**: `Flashcat.initialize` → context provider → message bus → disk NDJSON
  batching → backed-off upload (`/api/v2/rum`); tracking consent
  (GRANTED/PENDING/NOT_GRANTED); verbose HiLog + `setCustomEndpoint` for local debug.
- **RUM**: App→Session→View scopes; **manual** View, **manual** Action (emits
  ActionEvents + timed start/stop), Error, Resource; view keep-alive (30s + on
  background) for accurate session duration.
- **Trace**: W3C `traceparent` generation + rcp interceptor (opt-in) + manual
  `getHeaders()`; RUM↔APM correlation via `_dd.trace_id`/`_dd.span_id`.
- **Crash**: `hiAppEvent` APP_CRASH (native `.so` + ArkTS/JS) + APP_FREEZE →
  `is_crash` RUM error; payload caps; sampling.
- **Symbolication**: `@flashcatcloud/hvigor-plugin` uploads ArkTS sourcemaps +
  native `.so`; fc-rum `HarmonyProcessor` + `ParseHarmony` (PR #85 → dev, branch
  `feat/harmony-symbolication`, commit `afccf23`, NOT merged).
- **Demo**: `entry` HAP with env switch + per-telemetry buttons; verified on
  emulator (`/api/v2/rum -> 202`).

**The defining limitation of phase 1: almost everything is manual.** The app must
call `startView`/`stopView`, wire the rcp interceptor, and call `addAction`. Phase
2's headline is **auto-instrumentation**.

---

## Scope decisions (locked for Phase 2)

This plan deliberately narrows the original roadmap. The following are **explicitly
OUT of Phase 2 scope** and are recorded here so milestones, the config surface, and
acceptance gates do not silently re-absorb them:

| Dropped item | Status | Rationale / when revisited |
|---|---|---|
| **SDK telemetry / self-monitoring** | OUT (deferred) | Internal health counters are valuable but not on the critical path to a drop-in, production SDK. Revisit once auto-instrumentation + release are done and we have field volume worth observing. Tracked in "Deferred / parking lot". |
| **Logs module** (`flashcat-logs`) | OUT | No product demand for a separate Logger API on HarmonyOS yet; RUM errors + resources cover the near-term need. The message bus already supports log↔RUM correlation if/when added. |
| **Feature flags** | OUT | Flag-evaluation tracking has no consumer on HarmonyOS today. |
| **Session Replay** | OUT | Heavy (ArkUI snapshotting + privacy masking); high cost, no committed product demand. Explicitly out — not "later". |

Everything else from the original roadmap stays **IN** and is detailed below.
Removing these four sharpens Phase 2 to: *auto-instrumentation → production
hardening → crash/symbolication sign-off → vitals → release.*

---

## Phase 2 work items (IN scope)

Priority bands: **P0** = the headline (auto-instrumentation), **P1** = production
robustness + crash completeness, **P2** = vitals/webview + release. IDs are stable
references used by the milestone table.

### P0 — Auto-instrumentation (the headline)

> **Shared design for P0.** All three trackers follow the same lifecycle contract so
> they compose cleanly:
> - **Attach on enable, detach on disable.** Each tracker registers its
>   observer/wrapper when its config toggle is on at `RUM.enable()`, and removes it on
>   teardown. Registration is idempotent (guard against double-attach when the SDK is
>   re-enabled or multiple windows exist).
> - **Consent-gated, never-throw.** Trackers route through the existing
>   PENDING/GRANTED buffering and wrap every system callback in try/catch — an
>   auto-instrumentation bug must never crash the host app or the SDK.
> - **Manual API stays authoritative.** Auto events and manual `startView`/
>   `addAction`/interceptor calls share one code path; when both fire for the same
>   thing, de-dup by key (view route, request id) so we never double-count.
> - **Ordering vs. session.** A tracker may fire before `RUM.enable()` finishes or
>   before a session exists; events with no active session are dropped (matching the
>   phase-1 "resource before startView is dropped" rule), not queued indefinitely.

#### A1. Navigation auto-tracking → auto View events

- **What & why**: Eliminate manual `startView`/`stopView`. Each page push/pop should
  emit start/stopView automatically, so apps get a correct view tree (and accurate
  session duration) drop-in.
- **Design**:
  - Hook `UIObserver.on('navDestinationSwitch', ...)` (the `@ohos.arkui.observer`
    API) for `Navigation`/`NavDestination` route changes — the modern routing model.
  - Also cover the legacy `router` (`@ohos.router`) page stack via
    `UIObserver.on('routerPageUpdate', ...)` so apps not yet on `Navigation` still
    get views. (See Open question OQ-2 for the supported-set decision.)
  - Map route **name → `view.name`**, route **path → `view.url`** (note: `view.url`
    is the dedup key — see schema item R1).
  - Drive the existing App→Session→View scope machinery; a switch = stopView(old)
    then startView(new) **in that order** so `time_spent` of the old view closes on
    the switch timestamp before the new one opens. Honor the 30s keep-alive already
    in place (a quick A→B→A bounce should not orphan view A's resources).
  - **Multi-window / multi-ability**: attach the observer to the foreground
    ability's `UIContext`; if the app has multiple windows, track the focused one and
    treat window-focus changes like background/foreground (don't emit phantom views
    for a backgrounded window).
- **Config**: `trackNavigation` (already reserved, currently inert) becomes live;
  add `viewNamePredicate?: (route) => string` for custom naming. Manual
  `startView`/`stopView` remains as a fallback / for non-routed surfaces.
- **Tasks**:
  - [ ] `RumNavigationTracker` (new) subscribing to `UIObserver` on SDK enable.
  - [ ] Resolve the active `UIContext`/window to attach the observer (app may have
        multiple windows — pick the foreground ability's context).
  - [ ] Route → view mapping + predicate hook.
  - [ ] Wire `trackNavigation` to attach/detach the tracker; flip the builder default
        decision (default ON vs opt-in — see OQ-4).
  - [ ] Unit tests with a faked observer emitting switch events.
- **Acceptance**: With `trackNavigation(true)` and **no** manual view calls, pushing
  3 pages then popping 1 yields 3 ViewEvents with correct `view.name`/`view.url`,
  correct `time_spent`, and `view.id` continuity for resources/actions/errors
  occurring on each page.
- **Risks**: multi-window / multi-ability context resolution; `router` vs
  `Navigation` coexistence; observer firing before SDK enable (buffer or ignore).
- **Upstream ref**: `NavigationViewTrackingStrategy` in `fc-sdk-android`.

#### A2. Network auto-capture (no manual interceptor)

- **What & why**: Today resources only appear if the app wires
  `FlashcatTrace.interceptor()` onto an rcp session. Phase 2: emit Resource events +
  inject `traceparent` automatically, for both `@ohos.net.http` (`http.createHttp`)
  and `rcp`, with zero app wiring.
- **Design** — two candidate mechanisms (decide in OQ-1):
  - **(a) Compile-time AOP** via a hvigor plugin bytecode/AST transform that wraps
    `http.createHttp()` and rcp session creation. Seamless for apps; heavier to
    build/maintain and must track ArkTS compiler internals.
  - **(b) Provided drop-in wrappers** — `FlashcatHttp.createHttp()` /
    `FlashcatRcp.createSession()` that apps import instead of the platform symbol.
    One-line opt-in, far cheaper to build, but not literally zero-wiring.
  - **Recommendation**: ship **(b) wrappers first** (fast, low risk, unblocks
    M2), evaluate **(a)** as a follow-on if "zero-wiring" proves to be a real
    adoption blocker. Reuse the existing bus messages
    (`network_request_started/completed/failed`) so RUM assembly is unchanged.
- **Config**: `trackNetworkRequests` (reserved, inert) becomes live; add
  `firstPartyHosts?: string[]` to scope `traceparent` injection (don't leak trace
  headers to third parties); `traceSampleRate?`.
- **Tasks**:
  - [ ] `http.createHttp` wrapper: time request, read method/url/status/size, emit
        bus messages, inject `traceparent` for first-party hosts.
  - [ ] rcp wrapper consolidating the existing interceptor behind the same surface.
  - [ ] `firstPartyHosts` matcher (exact + subdomain).
  - [ ] (If AOP chosen) hvigor transform + a sample app proving zero-wiring.
  - [ ] Tests for header injection, first-party gating, size/duration capture.
- **Acceptance**: An app doing a `http.createHttp().request(...)` with the wrapper (no
  interceptor wiring) produces a ResourceEvent with correct
  `resource.{method,url,status_code,size,duration}` and `_dd.trace_id` matching a
  `traceparent` only present on first-party hosts.
- **Capture points to verify on device** (`@ohos.net.http`, never compiled yet):
  `httpRequest.request(url, options, cb)` — url is the first arg (options has no
  url), `options.method`, response `responseCode`, `header['content-length']` or
  `result` byteLength for size, `performanceTiming` if exposed for precise duration.
  Inject `traceparent` into `options.header`. rcp shapes are already listed in
  HANDOFF's on-device checklist.
- **Risks**: streamed responses → undefined body length (size 0, already a known
  gotcha); `http.createHttp` instance reuse (one `HttpRequest` issuing many
  `request` calls — key per call, not per instance); double-counting if both wrapper
  and manual interceptor wrap the same call (de-dup by request key, prefer the
  outermost); third-party `traceparent` leakage (gated by `firstPartyHosts`).
- **Upstream ref**: Datadog Android OkHttp `DatadogInterceptor` + `firstPartyHosts`.

#### A3. User-interaction (Action) auto-tracking → tap Actions

- **What & why**: Auto-emit `addAction(TAP, target)` on user taps so apps get the
  interaction timeline (and frustration signals later) without manual `addAction`.
- **Design**:
  - HarmonyOS has no global gesture interceptor equivalent to Android's
    `Window.Callback`. Options (decide in OQ-3): a provided `@Component`/builder
    wrapper that apps apply, an `onClick`-aware higher-order component, or an AOP
    transform over `.onClick(...)`. **Recommendation**: provide a lightweight
    `flashcatTap(target)` modifier/wrapper + keep manual `addAction` as the primary,
    documented path; full auto-AOP gated behind demand.
  - Target-name resolution: prefer a dev-supplied annotation/id, fall back to the
    component's accessibility text, then a stable type+index label.
- **Config**: `trackUserInteractions` (reserved, inert) governs auto-tap; manual API
  stays as fallback.
- **Tasks**:
  - [ ] Tap modifier/wrapper that calls `addAction(TAP, resolvedTarget)`.
  - [ ] Target-name resolution strategy + override hook.
  - [ ] Tests for naming precedence.
- **Acceptance**: A tap on a labelled button emits one ActionEvent with
  `action.type=tap`, a stable `action.target.name`, and correct `view.id`.
- **Risks**: stable target naming across recompositions; debouncing duplicate
  events; no global hook means coverage depends on app applying the wrapper —
  document this honestly.
- **Upstream ref**: `DatadogGesturesTracker`.

### P1 — Production robustness

#### R1. rum-events-format schema integration (pays down phase-1 debt)

- **What & why**: Phase 1 hand-assembles events. Wire the shared schema + model
  generation so event shape is authoritative and drift-proof; fix deferred schema
  bugs in one pass.
- **Design**: adopt the `rum-events-format` submodule already used by
  browser/miniprogram (or a HarmonyOS-tailored subset — see OQ-5) + a codegen step
  in the build to produce ArkTS event models; replace hand-assembled `Record`
  builders in `internal/assembly`.
- **Deferred schema fixes to land here**:
  - `view.url` = the dedup **key**, not the name (aligns with A1 mapping).
  - `_dd.session.plan` populated.
  - `source` enum includes `harmony` (backend side already done in PR #85).
  - ErrorEvent requires a `view` object; viewless errors omit it correctly.
- **Config**: none (internal).
- **Tasks**:
  - [ ] Add submodule + generation script (mirror browser `rum-events-format:sync`).
  - [ ] Generate ArkTS models respecting ArkTS constraints (no `any`, explicit
        `Record<string, Object>`).
  - [ ] Migrate assemblers to generated types; delete hand-rolled shapes.
  - [ ] Land the 4 deferred fixes + update tests.
- **Acceptance**: Generated models compile under ArkTS; existing NDJSON output is
  byte-compatible (or intentionally corrected) and fc-rum ingest still aggregates by
  Session/View/Resource/Error; `view.url` now carries the path.
- **Risks**: ArkTS can't consume the TS-generated types directly — codegen may need a
  HarmonyOS emitter; submodule adds a build dependency.
- **Codegen approach (decide in OQ-5)**: the schema is JSON Schema; browser/iOS each
  run a language-specific generator. For ArkTS the realistic options are (a) a small
  HarmonyOS emitter (JSON Schema → ArkTS classes honoring `Record<string, Object>` +
  no `any`/spread), or (b) generate plain TS interfaces and hand-maintain thin ArkTS
  adapters. **Leaning (a)** — a one-time emitter beats perpetual hand-sync. Keep the
  generated output checked in (reviewable diffs) and the generator in the build, not
  required at consumer build time.
- **Cross-repo coordination**: the `source='harmony'` enum value already landed
  backend-side (PR #85); this item just makes the client emit the schema-correct
  shape. Land it before C-items so symbolicated events match the final schema.
- **Upstream ref**: browser-sdk `rum-events-format:sync`; iOS `rum-models-generate`.

#### R2. Offline / network-aware deferred upload

- **What & why**: Today upload is an in-process foreground timer; pending batches die
  with the process and ignore network/charging state. Back the scheduler with the
  system so batches survive death and upload when conditions are good.
- **Design**: integrate `@ohos.resourceschedule.workScheduler` — register a deferred
  task gated on `NETWORK_TYPE_ANY`/charging that flushes pending NDJSON batches;
  keep the foreground timer as the fast path when the app is alive.
- **Config**: `uploadFrequency?` / `batchProcessingLevel?`-style knob (Android
  parity), `uploadOnWifiOnly?`.
- **Tasks**:
  - [ ] WorkScheduler registration + constraints; idempotent (don't double-register).
  - [ ] Background flush entrypoint reusing the existing batch reader/uploader.
  - [ ] Respect consent + sampling on deferred flush.
  - [ ] Tests around constraint mapping + dedupe with foreground timer.
- **Acceptance**: kill the app with pending batches, restore network → batches upload
  via the scheduled work; no duplicate uploads when foreground + scheduled overlap.
- **Concurrency / idempotency**: the foreground timer and the scheduled work can both
  scan the batch dir. Claim a batch before upload (rename to `*.uploading` or an
  advisory lock file) so the two uploaders never POST the same NDJSON; on success
  delete, on failure restore for retry/backoff. Reuse the existing
  `Date.now()`-based aging (HANDOFF: `getTime()` returned 0 on-runtime — do **not**
  reintroduce `systemDateTime.getTime()` for batch timestamps).
- **Risks**: HarmonyOS background-execution quotas/limits (work may be deferred long
  or coalesced); battery-policy violations if constraints are too loose; WorkScheduler
  callback runs in a constrained context — keep the flush short and resumable.
- **Upstream ref**: Android WorkManager `UploadWorker`.

#### R3. Event mappers (PII scrubbing / redaction)

- **What & why**: Compliance-critical. Let apps redact/drop events (URLs, user
  fields, error messages) before upload.
- **Design**: `RumEventMapper`-style hooks invoked in the assembly→upload path,
  per event type, returning a mutated event or `null` (drop). Mirror Android's
  `rumEventMapper`. (No `LogEventMapper` — Logs is out of scope.)
- **Config**: `setEventMapper(...)` on the RUM config builder (per-type or a
  discriminated single hook).
- **Tasks**:
  - [ ] Mapper interface + invocation site (after assembly, before persist/upload).
  - [ ] Per-type wiring (View/Action/Resource/Error); drop semantics; null-safety so
        a throwing mapper never drops the SDK.
  - [ ] Tests: redaction applied, drop honored, exceptions contained.
- **Acceptance**: a mapper that strips query strings from `resource.url` and drops
  errors matching a pattern is reflected in the NDJSON output, and a throwing mapper
  is swallowed (event passes through unmodified + logged).
- **Risks**: mappers run hot — keep cheap; mutating generated models under ArkTS
  immutability constraints (generated models from R1 may be `readonly` — define the
  mapper contract as *return a new/modified event object*, not in-place mutation, to
  stay ArkTS-legal). **Ordering vs. R3↔R1**: the mapper must run on the
  schema-correct event, so land R1 first (or define mappers against the generated
  models from the start) to avoid re-plumbing the invocation site.
- **Upstream ref**: `RumEventMapper` / `EventMapper<T>`.

### P1 — Crash & symbolication completeness

> **Cross-repo gate.** C1 is backend work on `sdk/server/fc-rum` branch
> `feat/harmony-symbolication` (commit `afccf23`, not merged). Do C1 **on that branch**
> and deploy it to **staging** before C2's device sign-off — otherwise there's no
> symbolicating backend to validate against. Sequence: C1 (backend) → deploy staging
> → C2 (device e2e) → merge `feat/harmony-symbolication` once C2 is green. C3/C4 are
> independent and can land alongside.

#### C1. `nameCache.json` application in fc-rum symbolication

- **What & why**: `nameCache.json` is uploaded + stored but not applied; ArkTS
  function names stay obfuscated when the sourcemap `names` field is insufficient.
- **Design**: in `HarmonyProcessor`, apply the obfuscated→original identifier map
  from `nameCache.json` as a second pass after sourcemap resolution.
- **Tasks**:
  - [ ] Load + index nameCache alongside the sourcemap in enrich.
  - [ ] Apply mapping to resolved frame identifiers; precedence vs sourcemap `names`.
  - [ ] Unit test with a real obfuscated artifact pair.
- **Acceptance**: a frame whose `names`-resolved identifier is still obfuscated gets
  its original name from nameCache in the enriched stack.
- **Risks**: cross-repo (`sdk/server/fc-rum`, branch `feat/harmony-symbolication`);
  needs real obfuscated artifacts.

#### C2. On-device crash validation + harmony native symbol listing

- **What & why**: The one gap the emulator/Previewer can't cover — real native crash
  → symbolication on a real device; plus surface harmony native symbols in the
  console "uploaded symbols" list.
- **Design**: run `docs/E2E-RUNBOOK.md` on a real device with real obfuscated
  artifacts against a fc-rum carrying `feat/harmony-symbolication`; add harmony to
  the symbol-listing UI/source-type switch.
- **Tasks**:
  - [ ] Device run: native `.so` SIGSEGV + freeze → next-launch replay → ingest.
  - [ ] Verify symbolicated frames (ArkTS + native) end-to-end.
  - [ ] List harmony native symbols in the console.
  - [ ] Confirm/adjust `CrashEventMapper` to the real hiAppEvent `params` shape.
- **Acceptance**: a device-reproduced native crash appears symbolicated in the
  console, with its uploaded `.so`/sourcemap visible in the symbols list.
- **Risks**: needs a real HarmonyOS device + Huawei real-name account; backend branch
  must be deployed to staging.

#### C3. App freeze / ANR detail

- **What & why**: Richer freeze stacks beyond a bare `APP_FREEZE` marker.
- **Design**: enrich freeze reports with main-thread sampling; consider a watchdog
  beyond `APP_FREEZE`. Keep the never-re-crash bar.
- **Tasks**:
  - [ ] Capture richer main-thread stack at freeze time.
  - [ ] Optional watchdog evaluation (gate behind evidence it adds signal).
- **Acceptance**: freeze events carry an actionable main-thread stack.
- **Risks**: sampling overhead; watchdog stability risk.

#### C4. (Eval) signal-handler native crash

- **What & why**: Only if `hiAppEvent` APP_CRASH proves insufficient for some C/C++
  signals.
- **Design**: evaluate a signal handler; **gate behind evidence** — high stability
  risk (must never destabilize the host app). Default: do nothing unless C2 surfaces
  a concrete gap.
- **Acceptance**: a documented decision (implement / not needed) backed by device
  evidence.

### P2 — Vitals & WebView

#### V1. Vitals / performance

- **What & why**: CPU, memory, FPS/refresh-rate, slow + frozen frames; **app launch
  time** (cold/warm/hot, TTID/TTFD); **view loading time**. Aligns with fc-rum's
  `feat/vital-app-launch-field-meta` branch.
- **Design**: sample CPU/memory via `@ohos.hidebug` (`getPss`/`getCpuUsage` or
  equivalent); frame timing via the ArkUI frame callback / `displaySync`; launch
  timing from `AbilityStage`/`UIAbility` lifecycle timestamps. Attach as `view.*`
  vital fields. Launch-type definitions (HarmonyOS):
  - **cold** = process create → first frame rendered (no warm process existed).
  - **warm** = process alive, ability/page recreated → first frame.
  - **hot** = ability resumed from background → first frame.
  Take the start timestamp as early as possible (`AbilityStage.onCreate`) and the end
  at the first `displaySync`/frame callback after the root page mounts.
- **Backend alignment**: fc-rum has `feat/vital-app-launch-field-meta` — confirm the
  exact field names/units (ns vs ms, TTID vs TTFD) against that branch **before**
  emitting, so the client doesn't ship a field the backend names differently.
- **Config**: `trackVitals?`, `trackFrustrations` (already reserved) for frozen
  frames.
- **Tasks**:
  - [ ] Launch-time capture (cold/warm/hot) → view + session fields aligned with the
        fc-rum branch's field meta.
  - [ ] Per-view CPU/memory min/max/avg sampling.
  - [ ] Frame timing → slow/frozen frame counts + refresh-rate awareness.
- **Acceptance**: ViewEvents carry plausible launch/loading/frame vitals matching the
  backend field schema.
- **Risks**: refresh-rate-aware frame thresholds (90/120Hz); hidebug API availability;
  sampling cost.
- **Upstream ref**: Datadog `VitalMonitor`, `JankStatsActivityLifecycleListener`.

#### V2. Long tasks

- **What & why**: Main-thread long-task events, distinct from freeze.
- **Design**: detect main-thread blocks over a threshold (frame-callback gap or
  microtask timing) → `long_task` RUM event.
- **Config**: `longTaskThresholdMs?`.
- **Acceptance**: a deliberate 200ms main-thread block emits one `long_task` event.
- **Risks**: ArkTS lacks a direct long-task API — derive from frame gaps; avoid false
  positives during legitimate heavy frames.

#### V3. WebView tracking

- **What & why**: Correlate RUM inside the ArkUI `Web` component with the native
  session.
- **Design**: the ArkUI `Web` component exposes a native↔JS bridge via
  `javaScriptProxy` (inject a native object) + `runJavaScript`/`onMessage`. Inject a
  small bridge object the browser-SDK detects (the browser-sdk
  `allowedTracingUrls`/webview-bridge contract) so child browser RUM events adopt the
  native `session.id`/`view.id` instead of starting their own session. Reuse the
  browser-sdk webview allowlist pattern.
- **Config**: `webViewTracking` allowlist of origins (only inject the bridge for
  allowlisted origins — never expose the native bridge to arbitrary third-party web
  content).
- **Acceptance**: a page in the `Web` component (loaded from an allowlisted origin,
  running the browser SDK) produces browser RUM events stitched to the native session;
  a non-allowlisted origin gets no bridge.
- **Risks**: the browser-SDK webview-bridge contract must support a HarmonyOS host
  (vs. iOS/Android `WKWebView`/`WebView`); `javaScriptProxy` security surface — keep
  the injected API minimal and origin-gated.
- **Upstream ref**: Datadog WebView tracking + browser-sdk webview bridge.

### P2 — Release & ecosystem

#### E1. Publish

- **What & why**: Ship HARs to ohpm (`@flashcatcloud/core|rum|trace|crash`) + the
  hvigor plugin to npm.
- **Design**: semver + changelog + CI pipeline (build + test + lint + api-surface
  guard). Resolve the "HAR contains source" policy (the `ohpm prepublish` warning)
  before public release — this is a **forced decision**, not optional: either accept
  source-in-HAR (ohpm's default; matches how most ohpm packages ship and keeps ArkTS
  consumable) and document it, or strip/obfuscate sources and verify the HAR still
  links. Default recommendation: **accept source-in-HAR** (it is a warning, not an
  error; the SDK is internal-friendly and ArkTS consumers benefit), document the
  decision in NOTICE/README. The four HARs declare cross-deps
  (`@flashcatcloud/rum|trace` depend on `core: "0.1.0"`); publish **core first**, then
  rum/trace/crash, so the version pin resolves at publish time.
- **Tasks**:
  - [ ] CI pipeline (assembleHar + test + codelinter + api-surface).
  - [ ] Versioning/changelog convention.
  - [ ] Source-distribution policy decision.
  - [ ] Publish dry-run → publish.
- **Acceptance**: `ohpm publish` of all 4 HARs + `npm publish` of the plugin from CI,
  green pipeline.
- **Risks**: source-in-HAR policy; ohpm registry credentials/ACL.

#### E2. API-surface guard

- **What & why**: Lock the public API so breaking changes are caught (like iOS
  `api-surface-verify`).
- **Design**: snapshot the public API of the 4 HARs; CI fails on undeclared change.
- **Acceptance**: a deliberate public-signature change fails CI until the surface
  file is updated.
- **Upstream ref**: iOS `make api-surface-verify`.

#### E3. Docs

- **What & why**: Integration guide, migration notes (manual → auto), per-feature
  how-tos.
- **Tasks**:
  - [ ] Integration/quickstart.
  - [ ] Phase-1→2 migration (auto-instrumentation opt-in, config changes).
  - [ ] Per-feature how-tos (nav, network, actions, crash, vitals).
- **Acceptance**: a new integrator can enable RUM + auto-instrumentation from docs
  alone.

---

## Milestones

Revised for the locked scope (no telemetry / Logs / flags / replay). Each milestone
ships independently and keeps build/test/lint green; **on-device verification on a
real HarmonyOS device** (not the Previewer — see HANDOFF) gates each.

- **M1 — Auto-instrumentation core**: A1 (nav→views) + A3 (tap→actions). Biggest
  product value; makes the SDK "drop-in".
- **M2 — Network AOP**: A2. Auto resources + trace without app wiring.
- **M3 — Production hardening**: R1 (schema) + R2 (deferred upload) + R3 (mappers).
- **M4 — Crash/symbolication completeness**: C1–C4 + on-device sign-off.
- **M5 — Vitals + WebView**: V1–V3.
- **M6 — Release**: E1–E3.

**Dependencies & parallelism:**
- **M1 and M2 are independent** of each other (nav/tap vs. network) — can run in
  parallel by different owners.
- **M3's R1 (schema) should precede M4** so symbolicated crash events carry the
  schema-correct `view`/`source` shape (avoid re-emitting after the schema lands).
- **R3 (mappers) depends on R1** (map over generated models — see R3 risks).
- **M4's C2 depends on C1 + a staging deploy** of `feat/harmony-symbolication`
  (cross-repo gate above).
- **M6 (release) is last** — E2 (api-surface guard) should be stood up *early* though,
  even if publishing waits, so M1–M5 changes don't silently break the public surface.
- **Critical path to "drop-in GA":** M1 → M2 → M3 → M6. M4/M5 can trail GA as point
  releases if device/backend sign-off slips.

---

## Definition of Done (every milestone)

A milestone is not "done" until **all** of these hold — these are the gates phase 1
taught us matter (see HANDOFF's hard-won lessons):

1. **Build/test/lint green** locally: `hvigorw assembleHar` + `hvigorw test` (run
   separately — combining corrupts HAR intermediates) + `codelinter` clean.
2. **On-device verified** on a real HarmonyOS device — **not the Previewer**, which
   stubs all native kit APIs (fs/time/network/hiAppEvent) and silently no-ops the SDK.
   Emulator is acceptable for non-native paths; native crash/symbolication needs a
   real device.
3. **Public API surface unchanged or explicitly updated** (E2 guard, once it exists).
4. **Consent + never-throw preserved**: new code paths route through
   PENDING/GRANTED buffering and cannot crash the host app.
5. **Tests added for high-risk surface** (public API, config, event/schema shape,
   sampling, session/lifecycle) per the workspace working rules.
6. **HANDOFF.md + this Revision log updated** so a fresh session can resume losslessly.

## Top cross-cutting risks (consolidated)

Per-item risks live with each item; these are the few that span the whole phase and
deserve standing attention.

| # | Risk | Affects | Severity | Mitigation |
|---|---|---|---|---|
| X1 | **ArkTS API shapes unverified at author time** — Previewer can't exercise native kit; many APIs (UIObserver, http, hidebug, workScheduler, javaScriptProxy) compile but are untested. | A1–A3, R2, V1, V3 | High | Device-verify each milestone (DoD #2); keep an on-device checklist per item (HANDOFF pattern). |
| X2 | **Never re-crash the host app** — auto-instrumentation + crash paths run in user space; a tracker bug must not take down the app. | All P0, C1–C4 | High | try/catch + re-entrancy guards on every callback (P0 shared design); the phase-1 crash-path discipline. |
| X3 | **Cross-repo coupling with fc-rum** — schema enum, vital field meta, harmony symbolication all live in `sdk/server/fc-rum`; client can ship a shape the backend names differently. | R1, C1–C2, V1 | Med | Confirm field names/units against the named fc-rum branches *before* emitting; land backend first where there's a hard dependency. |
| X4 | **Background-execution limits** — HarmonyOS may defer/coalesce WorkScheduler work or penalize battery; deferred upload may lag. | R2 | Med | Conservative constraints; keep foreground timer as fast path; document expected latency. |
| X5 | **Auto vs. manual double-counting** — overlapping auto + manual instrumentation inflates events. | A1–A3 | Med | Single shared code path + de-dup by key (view route / request id); manual stays authoritative. |
| X6 | **Privacy/leakage** — `traceparent` to third parties, native bridge to untrusted web origins, PII in events. | A2, V3, R3 | Med | `firstPartyHosts` gating; origin-allowlisted webview bridge; event mappers for redaction; consent gating throughout. |

---

## Open questions (decide before the milestone that needs them)

- **OQ-1 (M2) — AOP toolchain**: hvigor compile-time transform vs. provided
  `http`/`rcp` wrappers. *Leaning: wrappers first, AOP only if zero-wiring is a real
  adoption blocker.*
- **OQ-2 (M1) — Navigation API coverage**: `Navigation`/`navDestination` only, or
  also legacy `router`? *Leaning: cover both, document the supported set.*
- **OQ-3 (M1) — Tap-target naming**: id vs accessibility text vs dev annotation for a
  stable `action.target.name`. *Leaning: annotation > a11y text > type+index.*
- **OQ-4 (M1) — Auto-instrumentation defaults**: ship `trackNavigation` /
  `trackUserInteractions` / `trackNetworkRequests` defaulting ON or opt-in? *Leaning:
  opt-in for the first release, flip to ON once field-validated.*
- **OQ-5 (M3) — Schema source of truth**: same `rum-events-format` submodule as
  browser/miniprogram, or a HarmonyOS-tailored subset. *Leaning: shared submodule
  with a HarmonyOS codegen emitter.*

---

## Deferred / parking lot (not Phase 2)

- **SDK telemetry / self-monitoring** — internal counters (events dropped by
  consent/quota/sampling, upload failures, batch sizes). Revisit post-release.
- **Logs module**, **Feature flags**, **Session Replay** — see "Scope decisions".

---

## Revision log

- **Round 1 (2026-06-13)** — Restructured the roadmap into an executable plan:
  added the **Scope decisions** table dropping telemetry / Logs / feature flags /
  session replay; renumbered items into stable IDs (A/R/C/V/E); gave every in-scope
  item a *What·Design·Config·Tasks·Acceptance·Risks·Ref* skeleton; revised milestones
  to the narrowed scope; added a parking lot for deferred work.
- **Round 2 (2026-06-13)** — Deepened **P0**: added the *Shared design for P0*
  contract (attach/detach lifecycle, consent + never-throw, manual-API de-dup,
  ordering-vs-session); enriched A1 with stop-before-start `time_spent` and
  multi-window/ability context resolution; added A2 `@ohos.net.http` capture points
  + sharpened the per-call (not per-instance) de-dup and `traceparent`-leak risks.
- **Round 3 (2026-06-13)** — Deepened **P1**: R1 codegen approach (HarmonyOS JSON-
  Schema emitter, checked-in output) + cross-repo `source='harmony'` note; R2 batch
  claim/lock idempotency + the `Date.now()` (not `systemDateTime.getTime()`) aging
  reminder; R3 ArkTS-legal "return new object" mapper contract + R1-before-R3
  ordering. Added the **crash cross-repo gate** (C1 backend on
  `feat/harmony-symbolication` → staging → C2 device → merge).
- **Round 4 (2026-06-13)** — Deepened **P2 + release**: V1 cold/warm/hot launch
  definitions + fc-rum `feat/vital-app-launch-field-meta` field alignment; V3 concrete
  `javaScriptProxy`/`onMessage` bridge + origin-gating security; E1 forced
  source-in-HAR decision + core-first publish order. Added **Milestone
  dependencies & parallelism** (M1∥M2, R1→M4, R3→R1, C2 gate, early api-surface guard,
  critical path M1→M2→M3→M6).
- **Implementation pass (2026-06-14)** — Began executing the plan. **M1 + M2 + R3
  implemented** and build/lint-verified locally (assembleHar all modules +
  assembleHap demo + codelinter all green; unit tests added, compile-clean):
  - **A3 tap auto-tracking** — `RumAutoInstrumentation.trackTap` gated by
    `trackUserInteractions`; `FlashcatRum.trackTap`; demo routes every button tap
    through it.
  - **A1 navigation auto-tracking** — `RumNavigationTracker` on
    `uiObserver.on('routerPageUpdate')` → auto start/stopView (ON_PAGE_SHOW/HIDE);
    `FlashcatRum.startViewTracking(context)`; demo gains PageDetail/PageSettings
    router pages.
  - **A2 network auto-capture** — `FlashcatHttp` wrapper over `@ohos.net.http`
    reusing the trace bus publishers; consent + `firstPartyHosts`-gated traceparent;
    demo buttons (no interceptor wiring).
  - **R3 event mappers** — `RumEventMapper` + `RumEventMapperHolder` + `writeMapped`
    at all 6 scope write sites (never-throw containment); `setEventMapper`; demo
    redacts resource-url query strings + drops "secret" taps.
  **Live on-device acceptance DONE** (Pura 90 emulator, `docs/phase2-acceptance.sh`):
  HiLog confirmed A1 auto start/stopView across the full nav stack, A3 auto tap
  actions, R3 mapper drop + URL scrub, A2 `FlashcatHttp` auto resources with no
  interceptor, and repeated `POST /api/v2/rum -> 202`. Still pending: the on-device
  hypium assertion run (tests compile-clean; assertions execute in a device test
  runtime). M4/M5/M6 not yet started.
- **Round 5 (2026-06-13)** — Cross-cutting + self-review pass: added a
  **Definition of Done** gate (build/test/lint green, real-device verify not
  Previewer, api-surface, consent/never-throw, tests, HANDOFF update) and a
  consolidated **Top cross-cutting risks** register (X1–X6: unverified ArkTS APIs,
  never-re-crash, fc-rum coupling, background limits, auto/manual double-count,
  privacy/leakage) with severity + mitigation. Verified internal consistency of item
  IDs, milestone mapping, and OQ references end-to-end.
