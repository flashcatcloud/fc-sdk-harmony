# Changelog

## 0.7.3

- Whichever live error callback arrives first carries the crash under the
  active policy; an OS build that delivers only `onException` no longer
  leaves `REPORT_THEN_EXIT` / `REPORT_AND_RECOVER` apps running.
- Exception messages are bounded (4096 characters) for parsing and
  persistence, and multi-line or very long messages no longer break
  deduplication between the live report and the platform's APP_CRASH copy.
- `FlashcatCrash.enable` never throws.

## 0.7.2

- New `JsCrashPolicy.REPORT_AND_CONTINUE`: an uncaught main-thread ArkTS
  exception keeps the process running, like `OBSERVE_ONLY`, but is reported as
  a crash (`is_crash: true`) into the live RUM session and counted in the view's
  crash count. It is not gated by `setTrackErrors(false)` and persists no crash
  incident. Use it when the app keeps the process alive on purpose (for example
  next to another crash reporter's JS crash protection) and the crash must still
  count toward the crash rate.
- The two live error callbacks of one fault are deduplicated in either order; a
  fault that repeats after a completed pair is reported again.
- Consumed crash entries are capped at the newest 100, and a fault repeating in
  a loop no longer rewrites the dedup file on every repeat.

## 0.7.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.7.1: remote configuration survives app upgrades).

## 0.7.0

- An uncaught exception that terminates the process, in a session that RUM is
  holding back for error-session capture, is no longer persisted or reported
  when the RUM event mapper drops it (see `@flashcatcloud/rum` 0.7.0:
  error-session capture). Other sessions and policies are unchanged.

## 0.6.0

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.6.0: remote configuration).

## 0.5.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.5.1: app freezes are now categorized as ANR).

## 0.5.0

- Version bump to keep the SDK packages in lockstep.

## 0.4.0

- Version bump to keep the SDK packages in lockstep.

## 0.3.2

- Version bump to keep the SDK packages in lockstep. Native crashes and freezes
  replayed through this module are now attributed to the session and view that
  died (see `@flashcatcloud/rum` 0.3.2).

## 0.3.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/core`
  0.3.1: the consent value passed at initialization is authoritative again).

## 0.3.0

- **Behavior change**: `error.stack` now carries frames only. The errorManager
  callback's label lines (`Error name:` / `Error message:` / `Stacktrace:`) and
  the "Cannot get SourceMap info" banner are a callback FORMAT, not stack
  content — shipping them made the backend read `Error name:Error` as the
  exception header, mis-titling issues and polluting the stack view. Crash
  fingerprints are unaffected whenever the stack has real frames (the first
  `at `/`#` line is used); only crashes with no parseable frame at all can hash
  differently than on 0.2.0.
- Exactly-once-oriented delivery: incidents deleted only after RUM acks a
  durable write; replay/watcher deduplicate against each other by fingerprint
  and consumption-time-keyed retention; live/watcher fingerprint parity.
- Original-session attribution snapshot includes view.url and origin sampling.
- Crash-loop guard hardening (atomic sidecars, future-timestamp discard);
  `crash.recovered` downgraded on failed restart; NOT_GRANTED persists no crash
  data while preserving recovery restarts.

## 0.2.0

- Default JS crash behavior is now `REPORT_THEN_EXIT`: the SDK no longer silently keeps the app alive after an uncaught exception (behavior fix); set `JsCrashPolicy.OBSERVE_ONLY` to restore the previous behavior.
- Add synchronous crash-pending persistence, next-launch RUM replay, and live/cross-launch deduplication for ArkTS crash callbacks and `APP_CRASH` fault events.
- Add the three-state `JsCrashPolicy`; `REPORT_AND_RECOVER` now enables HarmonyOS app recovery and restarts after synchronous reporting.
- Add persisted crash-loop protection for recovery restarts, with configurable threshold, rolling window, and cool-down.
- Mark replayed soft-landed crashes with the `crash.recovered` event attribute.

## 0.1.3

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.2

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.0

- Initial HarmonyOS crash reporting release.
