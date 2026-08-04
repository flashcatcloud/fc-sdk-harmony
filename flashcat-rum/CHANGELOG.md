# Changelog

## 0.3.0

- **Breaking behavior**: `setTrackNetworkRequests(false)` (the default) now
  actually disables resource capture — it was previously accepted and ignored.
- New `RumConfigurationBuilder.setTrackErrors(enabled)` (default `true`) toggles
  AUTOMATIC error capture — uncaught non-crash reports and unhandled Promise
  rejections. Crash reporting is NOT affected (uncaught exceptions still follow
  the crash policy and are replayed as `is_crash` errors), and manual `addError`
  calls still deliver; use the event mapper to drop those too if needed.
- Crash attribution: crashes are counted and replayed into the ORIGINAL session
  (crash in session A, relaunch session B → queryable in A); >23 h-old replays
  fall back to current-time reporting; unsampled-origin crashes are dropped
  uniformly with sampling.
- Session/view correctness: view restart after expiry/renewal (sessions no
  longer read duration 0), monotonic session activity, no phantom sessions from
  backdated or stop-type events, in-flight resources survive view AND session
  transitions, frozen time_spent after close, resolved view.url on all events.
- New monitor APIs: `stopSession()`, `getAttributes()`, `clearAttributes()`.
- Error quality: uncaught-error `error.stack` carries frames only (the
  errorManager label lines are stripped, so issues are no longer titled
  "Error name"), BusinessError-shaped rejection reasons unwrapped, sourcemap
  banner skipped, client-side `error.id`, os/device/connectivity fields.

## 0.2.0

- Default JS crash behavior is now `REPORT_THEN_EXIT`: the SDK no longer silently keeps the app alive after an uncaught exception (behavior fix); set `JsCrashPolicy.OBSERVE_ONLY` to restore the previous behavior.
- Route crash-enabled ArkTS exception callbacks through the synchronous crash-policy path while preserving legacy observe-only behavior when the crash module is not enabled.
- Orchestrate `REPORT_AND_RECOVER` termination through HarmonyOS app recovery after flush, with clean-exit fallback when recovery is unavailable or crash-loop protection trips.
- Forward the `crash.recovered` attribute on replayed soft-landed crash events.
- Capture unhandled promise rejections as ordinary, non-crashing RUM error events.

## 0.1.3

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.2

- Fix crash-free rate: emit `view.crash.count` so the backend can derive
  `session_crash_count` (it previously stayed 0, so crash-free rate read 100%).

## 0.1.0

- Initial HarmonyOS RUM release.
