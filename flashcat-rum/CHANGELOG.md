# Changelog

## 0.1.3

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.2

- Fix crash-free rate: emit `view.crash.count` so the backend can derive
  `session_crash_count` (it previously stayed 0, so crash-free rate read 100%).

## 0.1.0

- Initial HarmonyOS RUM release.
