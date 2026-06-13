# FlashCat HarmonyOS SDK — Phase 2 Roadmap

> Planning doc. Phase 1 is delivered (see `docs/HANDOFF.md` and
> `docs/superpowers/specs/2026-06-13-harmony-crash-symbolication-design.md`).
> Phase 2 turns the manual, single-platform-parity SDK into an
> auto-instrumenting, production-grade one, closing the gaps below.
> Reference shape throughout: the Datadog Android SDK (`fc-sdk-android`).

Date: 2026-06-13

---

## Phase 1 recap (shipped)

- **Core**: `Flashcat.initialize` → context provider → message bus → disk NDJSON
  batching → backed-off upload (`/api/v2/rum`); tracking consent
  (GRANTED/PENDING/NOT_GRANTED); verbose HiLog + `setCustomEndpoint` for local debug.
- **RUM**: App→Session→View scopes; **manual** View, **manual** Action (now emits
  ActionEvents + timed start/stop), Error, Resource; view keep-alive (30s + on
  background) for accurate session duration.
- **Trace**: W3C `traceparent` generation + rcp interceptor (opt-in) + manual
  `getHeaders()`; RUM↔APM correlation via `_dd.trace_id`/`_dd.span_id`.
- **Crash**: `hiAppEvent` APP_CRASH (native `.so` + ArkTS/JS) + APP_FREEZE →
  `is_crash` RUM error; payload caps; sampling.
- **Symbolication**: `@flashcatcloud/hvigor-plugin` uploads ArkTS sourcemaps +
  native `.so`; fc-rum `HarmonyProcessor` + `ParseHarmony` (PR #85 → dev).
- **Demo**: `entry` HAP with env switch + per-telemetry buttons; verified on
  emulator (`/api/v2/rum -> 202`).

**The defining limitation of phase 1: almost everything is manual.** The app must
call `startView`/`stopView`, wire the rcp interceptor, and call `addAction`. Phase
2's headline is **auto-instrumentation**.

---

## Phase 2 themes (prioritized)

### P0 — Auto-instrumentation (the headline)

1. **Navigation auto-tracking** → auto View events.
   - Hook `UIObserver` `navDestinationSwitch` (Navigation) + router page lifecycle
     so each page push/pop emits start/stopView automatically — no manual
     `startView`. Map route name → `view.name`, route path → `view.url`.
   - Config: `trackViews`/`viewNamePredicate`. Android ref: `NavigationViewTrackingStrategy`.
2. **Network auto-capture (no manual interceptor)**.
   - **Compile-time AOP** over `http.createHttp` / `@ohos.net.http` and `rcp` (the
     `trackNetworkRequests` toggle is already reserved). Auto-emit Resource events +
     inject `traceparent`, so apps get resources without wiring the interceptor.
   - Decide AOP toolchain (hvigor plugin bytecode transform vs. a provided wrapper).
3. **User-interaction (Action) auto-tracking**.
   - Detect taps/clicks on ArkUI components → auto `addAction(TAP, target)`. Needs a
     target-name resolution strategy (component id/text). Android ref:
     `DatadogGesturesTracker`. Keep manual API as the fallback.

### P1 — Production robustness

4. **rum-events-format schema integration** (pays down phase-1 debt).
   - Wire the schema submodule + model generation; replace hand-assembled events.
   - Fix the deferred schema items: `view.url` = key (not name); `_dd.session.plan`;
     `source` enum includes `harmony` (done backend-side in PR #85); ErrorEvent
     requires a `view` object (viewless errors omit it).
5. **Offline / network-aware deferred upload**.
   - Back the upload scheduler with `@ohos.resourceschedule.workScheduler` so pending
     batches survive process death and upload on network availability / charging,
     instead of only the in-process foreground timer. Android ref: WorkManager.
6. **Event mappers (PII scrubbing / redaction)**.
   - `RumEventMapper` / `LogEventMapper`-style hooks letting apps redact or drop
     events (URLs, user fields, error messages) before upload. Compliance-critical.
7. **SDK telemetry / self-monitoring**.
   - Internal counters (events dropped by consent/quota/sampling, upload failures,
     batch sizes) emitted as telemetry so SDK health is observable.

### P1 — Crash & symbolication completeness

8. **nameCache.json application** in fc-rum symbolication.
   - Currently stored but not applied; apply obfuscated→original identifier mapping
     for ArkTS function names when the sourcemap `names` field is insufficient.
9. **On-device crash validation + harmony native symbol listing**.
   - Validate the full native-crash → symbolication loop on a real device with real
     obfuscated artifacts (the one gap the emulator/Previewer can't cover); surface
     harmony native symbols in the console "uploaded symbols" list.
10. **App freeze / ANR detail** — richer freeze stacks + main-thread sampling;
    consider a watchdog beyond `APP_FREEZE`.
11. **(Eval) signal-handler native crash** — only if `hiAppEvent` APP_CRASH proves
    insufficient for some C/C++ signals. High stability risk; gate behind evidence.

### P2 — New feature modules

12. **Logs** (`flashcat-logs` module) — Logger API → `/api/v2/logs`, log↔RUM
    correlation via shared context (the bus already supports it).
13. **Vitals / performance** — CPU, memory, FPS / refresh-rate, slow + frozen
    frames; **app launch time** (cold/warm/hot, TTID/TTFD); **view loading time**.
    (Note: fc-rum already has a `feat/vital-app-launch-field-meta` branch — align.)
14. **Long tasks** — main-thread long-task events (distinct from freeze).
15. **WebView tracking** — correlate RUM inside the `Web` component with the native
    session (inject the browser-SDK bridge).
16. **Feature flags** — flag-evaluation tracking attached to views/events.
17. **(Later) Session Replay** — heavy (ArkUI snapshotting + privacy masking);
    scope only if there's product demand.

### P2 — Release & ecosystem

18. **Publish** — HARs to ohpm (`@flashcatcloud/core|rum|trace|crash`) + the hvigor
    plugin to npm; semver, changelog, and a CI pipeline (build + test + lint + api
    surface guard). Resolve the "HAR contains source" policy before public release.
19. **API-surface guard** — lock the public API (like iOS `api-surface-verify`) so
    breaking changes are caught.
20. **Docs** — integration guide, migration notes, per-feature how-tos.

---

## Suggested milestones

- **M1 — Auto-instrumentation core**: P0 #1 (nav→views) + #3 (tap→actions). Biggest
  product value; makes the SDK "drop-in".
- **M2 — Network AOP**: P0 #2. Auto resources + trace without app wiring.
- **M3 — Production hardening**: P1 #4 (schema) + #5 (deferred upload) + #6 (mappers).
- **M4 — Crash/symbolication completeness**: P1 #8–#10 + on-device sign-off.
- **M5 — Vitals + Logs**: P2 #12–#14.
- **M6 — Release**: P2 #18–#20.

Each milestone ships independently and keeps the build/test/lint green; on-device
verification (real HarmonyOS device, not the Previewer — see HANDOFF) gates each.

---

## Open questions (decide before M1/M2)

- **AOP toolchain**: hvigor compile-time bytecode transform vs. a provided
  drop-in `http`/`rcp` wrapper. The former is seamless but heavier to build/maintain.
- **Navigation API coverage**: `Navigation`/`navDestination` only, or also the
  legacy `router`? Cover both or document the supported set.
- **Tap-target naming**: how to derive a stable `action.target.name` from ArkUI
  components (id, accessibility text, or a dev-supplied annotation).
- **Session Replay**: in scope at all for HarmonyOS, or explicitly out?
- **Schema source of truth**: adopt the same `rum-events-format` submodule as
  browser/miniprogram, or a HarmonyOS-tailored subset.
