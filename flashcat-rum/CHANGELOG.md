# Changelog

## Unreleased

- App freezes (`APP_FREEZE`) are now reported with `error.category: "ANR"`
  instead of `"App Hang"`. HarmonyOS freezes are the system watchdog's
  application-not-responding verdict — the same mechanism family as Android
  ANRs — so they now share that category for consistent cross-platform
  aggregation.

## 0.5.0

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/core`
  0.5.0: upload pacing now uses the cross-platform batching enums).

## 0.4.0

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/trace`
  0.4.0: resources can now be reported from any network stack).

## 0.3.2

- Crash attribution now covers faults the SDK cannot observe in-process. Native
  crashes and freezes previously replayed into the live post-restart session at
  the current time; they are now written into the session and view the app was
  actually in when it died, stamped with the real fault time. The crashed view's
  document is re-emitted so the crash lands on the session that died.
- A replayed crash counts as an error as well as a crash, matching the live
  path. Crashed sessions previously reported one error fewer than they held.
- The view snapshot backing the above is consumed on load, so a launch that
  crashes before writing a view of its own cannot make the next launch
  re-attribute to an already-closed session.
- A replayed crash is only marked delivered once BOTH the error and the updated
  view document are persisted; a partial write is retried on the next launch
  instead of leaving the session reading crash-free.

## 0.3.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/core`
  0.3.1: the consent value passed at initialization is authoritative again).

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
