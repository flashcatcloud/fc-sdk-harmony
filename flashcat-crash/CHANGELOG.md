# Changelog

## Unreleased

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
