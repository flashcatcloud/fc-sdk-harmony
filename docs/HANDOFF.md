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
- [ ] Task 2: RumRawEvent resource fields + RumMonitor.stopResourceWithError
- [ ] Task 3: RumEventAssembler.resource() + error() resource variant
- [ ] Task 4: RumResourceScope (new file)
- [ ] Task 5: RumViewScope integration + real resource counts
- [ ] Task 6: DefaultRumMonitor resource methods
- [ ] Task 7: RumFeature bus translation (network_request_* → monitor)
- [ ] Task 8: TraceInterceptor reports resources + doc updates
- [ ] Task 9: Wrap-up (device checklist, memory)

## Current state

Plan + handoff committed. No source files touched yet.

## Next step

Task 2: edit `flashcat-rum/src/main/ets/internal/scope/RumScope.ets` (add resource
fields to RumRawEvent) and `flashcat-rum/src/main/ets/RumMonitor.ets` (add
`stopResourceWithError` to interface + NoOp). Exact code is in the plan.

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
