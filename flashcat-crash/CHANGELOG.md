# Changelog

## Unreleased

- Default JS crash behavior is now `REPORT_THEN_EXIT`: the SDK no longer silently keeps the app alive after an uncaught exception (behavior fix); set `JsCrashPolicy.OBSERVE_ONLY` to restore the previous behavior.
- Add synchronous crash-pending persistence, next-launch RUM replay, and live/cross-launch deduplication for ArkTS crash callbacks and `APP_CRASH` fault events.
- Add the three-state `JsCrashPolicy`; `REPORT_AND_RECOVER` falls back to `REPORT_THEN_EXIT` until Phase 2 adds recovery orchestration and crash-loop protection.

## 0.1.3

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.2

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.0

- Initial HarmonyOS crash reporting release.
