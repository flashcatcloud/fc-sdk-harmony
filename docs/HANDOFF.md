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

## Current state — ALL TASKS DONE (2026-06-10)

Phase-1 feature list is now code-complete (UNCOMPILED — no local toolchain):
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

## Next step

None for this effort. Follow-ups (separate efforts, NOT started):
- On-device verification (checklist below) — blocked on DevEco/hvigor/ohpm env.
- P2 schema alignment (deferred pending backend confirm): view.url should = key
  not name; `_dd.session.plan`; `source='harmony'` enum in fc-rum.
- Phase 2: crash via hiAppEvent, nav auto-tracking (UIObserver), compile-time
  AOP for http.createHttp, ActionEvents.

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

- **No hvigor/ohpm toolchain in this dev env** — nothing here compiles locally.
  Each task ends with an ArkTS self-check (no `{...}` spread, no bare `delete` on
  Record, no `any`, explicit Record<string, Object> event assembly) instead of a
  test run. On-device verification points accumulate in Task 9.
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
