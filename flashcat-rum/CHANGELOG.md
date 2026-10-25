# Changelog

## 0.7.3

- **Behavior change:** without `@flashcatcloud/crash`, an uncaught
  main-thread ArkTS exception is now reported as a crash of the live session
  and the process exits, as it would without the SDK (it previously kept
  running). Apps that keep themselves alive on purpose must enable the crash
  module with `REPORT_AND_CONTINUE` or `OBSERVE_ONLY`.
- The public monitor API never throws into the host: a failure inside the
  SDK drops the event. The error callbacks tolerate non-Error values.
- A crash replayed from an earlier launch whose write fails is no longer
  marked delivered (and deleted).

## 0.7.2

- Reports `REPORT_AND_CONTINUE` crashes (see `@flashcatcloud/crash` 0.7.2) into
  the live session, independently of `setTrackErrors`.
- A crash the process survives between `stopView` and the next `startView` (for
  example a timer throwing while backgrounded) is counted on the most recently
  closed view instead of being written without a view. Crashes inherited from a
  previous launch are unchanged.
- Docs: with `OBSERVE_ONLY`, `setTrackErrors(false)` drops uncaught exceptions
  entirely.

## 0.7.1

- **Remote configuration survives app upgrades.** The stored settings were
  keyed by the app version as well as the host, application, service and
  environment, so the first session after every app upgrade found no stored
  entry, was drawn on the values passed to init, and reported no settings
  version. An installed app runs one version at a time, so the key no longer
  includes it: the first session after an upgrade uses the settings the
  previous version stored until the new fetch replaces them. The request still
  sends `app_version`. Entries written by earlier SDK versions are no longer
  read, so the first session after upgrading the SDK itself uses the init
  values once.

## 0.7.0

- **Error-session capture.** `RumConfigurationBuilder.setSessionOnError(true)`
  also keeps the sessions `sessionSampleRate` does not draw, but only those
  that report an error. Such a session is collected in memory and none of its
  events is uploaded until it reports an error the event mapper keeps; then
  the minute leading up to it (its views, and up to 200 actions, resources and
  errors within 64 KiB) is uploaded after a short per-session delay, and the
  rest of the session is collected normally. A session that ends without an
  error is thrown away with everything it held. Off by default; the console's
  `sessionOnError` overrides the init value when remote configuration is on.
  Its view events report `session.sampled_for_error: true` and a session
  sample rate of 0, so each stands for itself.
- `RumMonitor.getCurrentSessionId()` reports `undefined` for such a session
  until it has been released: before that the backend has no session under
  its id.
- A rate-0 configuration with `sessionOnError` on no longer ends the session
  it kept when the configuration is fetched; turning the switch on redraws a
  session drawn dark at rate 0.
- Revoking tracking consent now also discards what RUM holds in memory for a
  session that has not reached storage.
- Known limitations of error-session capture: a crash replayed on a later
  launch that nothing attributes to a session is not reported while the
  current session is withheld; and the event mapper must be a pure function
  of the event — an uncaught exception that terminates the process is mapped
  once at crash time and again when it is replayed on the next launch, and
  the two verdicts must agree.

## 0.6.0

- **Remote configuration.** `RumConfigurationBuilder.setRemoteConfigurationEnabled(true)`
  lets the session sample rate and a `custom` map be changed from the console
  without releasing the app again. Off by default. The SDK fetches the
  configuration at startup, at every new session and, when the console allows
  it, on return to foreground; a failed or malformed response never changes the
  values in use. A new rate applies from the next session, unless the console
  asks for it immediately or it switches collection on or off.
- `RumConfigurationBuilder.setBeforeSampling(callback)` gives the app the last
  word on the rate a session is drawn with, for example an allow-list driven by
  `custom`. It runs synchronously on the calling thread: keep it light, and do
  not report RUM events from inside it.
- `RumMonitor.setForcedSession()` keeps every session from then on, and
  `RumMonitor.getRemoteConfig()` returns the delivered `custom` map.
- View events now report the sample rate their session was drawn with
  (`_dd.configuration.session_sample_rate`), also when remote configuration is
  off, and the configuration version (`rc_version`) when one decided it.
- Fixed: ending a session that had already expired, for example `stopSession()`
  after a long time in the background, credited the idle gap to the last
  view's `time_spent`.

### Breaking

- `RumMonitor` gains `setForcedSession()` and `getRemoteConfig()`. Only code
  that implements `RumMonitor` itself needs to add them.

## 0.5.1

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
