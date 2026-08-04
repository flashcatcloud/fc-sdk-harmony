# Changelog

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
