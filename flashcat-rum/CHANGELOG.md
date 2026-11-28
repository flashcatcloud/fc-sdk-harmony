# Changelog

## Unreleased

- Every event carries `device.locale`, `device.locales` and
  `device.time_zone`; views, errors and app launches also carry
  `device.battery_level` and `device.power_saving_mode`, as on Android. A
  crash reported at the next launch carries the device state of the run that
  crashed.
- Released with `Flashcat.clearAllData()` (`@flashcatcloud/core`). When the
  data is cleared, RUM writes the running session's record back to the view
  snapshot at once, without its view, so a native crash or freeze from then on
  is still reported in that session; the session's next view document goes on
  file as soon as it is written. The stored active-device beacon and today's
  sent marker are dropped, as Android does, so the beacon is sent again on the
  next trigger. A session kept only on error keeps the events it holds in
  memory, as on Android.
- Feature operations, as on Android and iOS: `startFeatureOperation`,
  `succeedFeatureOperation` and `failFeatureOperation` on the RUM monitor, with
  `FeatureOperationFailureReason` (`ERROR`, `ABANDONED`, `OTHER`). Each call
  reports a `vital` event of type `operation_step` on the current view, with
  `step_type` `start` or `end`, the optional `operation_key`, and
  `failure_reason` on a failed end. No duration is sent: the backend pairs the
  steps by name and key. A blank name, or a key given but blank, is ignored
  with a warning. The steps follow session sampling and are held with the rest
  of a session kept only on error.

## 0.8.2

- Frame rate, slow and frozen frames, and app launch timing no longer need
  `FlashcatRum.startViewTracking()`. The SDK hooks each ability's window when
  its window stage is created, before the first frame, and lets it go when the
  window stage is destroyed, so `stopViewTracking()` is no longer needed either.
  An SDK initialized after the window came up (once a consent prompt is
  answered, say) hooks the window on top at initialization, and RUM enabled
  later hooks the windows already up; that launch's timing is not reported, as
  before. Apps that call `startViewTracking()` / `stopViewTracking()` keep
  working, and an ability is never hooked twice. Those calls can now be
  removed: making them still costs about 2 ms at app start (taking the page's
  `UIContext` and its ability), for nothing the SDK does not already do.
- With `setTrackNavigation(true)`, `router` pages are now tracked without a
  `startViewTracking()` call. Before, an app that turned the option on but
  never made that call tracked no `router` pages. An app that starts its views
  itself (a `Navigation` app, say) should leave `setTrackNavigation` off, or
  its `router` pages are recorded on top of its own views.

## 0.8.1

- Fixed: actions and resources recorded before the first view were dropped.
  This happened when RUM was enabled while the app's first page was already on
  screen, for example after a consent prompt. An action, a resource or an error
  in a session that has never had a view now opens the `ApplicationLaunch` view
  and is recorded in it, as on Android and iOS. Such an error used to be sent
  without a view. The app's first view replaces `ApplicationLaunch`. The view
  carries the global attributes, not the triggering event's own.
  Nothing opens between two views, or in a launch the system reported in the
  background; those events are still dropped, as before.
- CPU sampling costs less than in 0.8.0. The process's CPU time comes from the
  runtime (`process.getPastCpuTime`, all threads, millisecond precision), which
  costs tens of microseconds, instead of a `/proc/self/stat` read, which costs
  about half a millisecond when the sampler wakes for it. `/proc/self/stat` is
  now read at most about once a second (every other reading at the default
  500 ms period), for the user-time tick fields only. So
  `view.cpu_ticks_count` / `view.cpu_ticks_per_second` run from the view's
  first `/proc` reading to its last: a view shorter than about two seconds may
  carry neither, and a short view's ticks per second can read slightly low.
- New: CPU usage per view as a percentage, with the same field names and
  meaning as the iOS SDK, so the two platforms can be compared.
  - `view.cpu_usage_average` / `view.cpu_usage_max`: the process's CPU time
    (user and system, all threads) as a percentage of all the cores it may run
    on.
  - `view.main_thread_cpu_usage_average` / `view.main_thread_cpu_usage_max`:
    the main thread's, as a percentage of one core. Its stat is read at most
    about once a second, so its peaks are taken over about a second.
  - Only foreground time between consecutive readings counts; a stay in the
    background in the middle of a view is left out.
  - Peaks are taken over intervals of at least 0.25 s and are never below the
    average.
  - Reported once the view has 0.9 s of foreground time.
  - `view.cpu_ticks_count` / `view.cpu_ticks_per_second` keep their meaning
    (user time, Android parity).
- Every crash and freeze reports whether the app was in the foreground at the
  fault (`view.in_foreground`) and whether its session was drawn by the sample
  rate (`session.sampled`): `true` when drawn or forced, `false` when kept only
  because it errored. Both are recorded when the fault happens and reported as
  recorded, also when the next launch reports it. `view.in_foreground` is left
  out when the state is unknown — early in a launch, before the system has
  said, or for a crash of an earlier version — and when the error has no view;
  `session.sampled` is left out for a crash of an earlier version. Neither is
  set on jank or on any other error.
- A freeze (`error.category = "ANR"`) no longer counts in its view's
  `view.crash.count`; it still counts in `view.error.count` and stays
  `is_crash = true`. Crash counts leave freezes out; the ANR rate counts them.

## 0.8.0

- New: per-view performance vitals, with the same field names and units as
  the Android SDK. Memory (`view.memory_average`, `view.memory_max`, bytes of
  RSS) and CPU (`view.cpu_ticks_count`, `view.cpu_ticks_per_second`) are
  sampled in the foreground while a view is open. Frames give
  `view.refresh_rate_average`, `view.refresh_rate_min` (normalized to 60),
  `view.is_slow_rendered`, `view.slow_frame.count`, `view.frozen_frame.count`,
  `view.slow_frames_rate` and `view.freeze_rate`; API 22+ uses the window's
  per-frame metrics, API 12–21 counts frames while a list scrolls. A field
  without samples is omitted, never sent as 0.
  `RumConfigurationBuilder.setVitalsUpdateFrequency(VitalsUpdateFrequency.X)`
  sets the sampling period: `FREQUENT` 100 ms, `AVERAGE` 500 ms (default),
  `RARE` 1000 ms, `NEVER` off; remote configuration can set it too
  (`vitalsUpdateFrequency`). Sampling reads the process's `/proc` files with
  reused buffers and kept-open files, so it adds no memory growth.
- New: app launch vitals. A `vital` event with `vital.type = "app_launch"`
  reports the time to initial display of a `cold_start` and of a `hot_start`
  (a return to the foreground); `RumMonitor.reportAppFullyDisplayed()` reports
  the time to full display. TTID is capped at 60 s and TTFD at 90 s. A warm
  start (a process kept by the system recreating its window) is not reported:
  the system delivers no frame for that window. Launch timing needs
  `startViewTracking(ctx)` on the first page.
- New: view loading time (`view.loading_time`), measured automatically for
  `router` pages (page shown to its next frame) and settable with
  `RumMonitor.addViewLoadingTime(overwrite)`.
- A native crash or app freeze reported on the next launch is attributed to
  the session it happened in, as that session was drawn, also when the
  session had no view yet. The SDK now records the session a process is in
  (its id, whether it is collected, how it was drawn, and when it ended) as
  soon as the session starts or ends, not only its last view, and writes a
  session's first view at once:
  - A crash in a collected session with no view yet (during launch, right
    after a session renewal, or in a process with no page) is reported in that
    session, in an `ApplicationLaunch` view, or in a `Background` view when
    the system reports that the app was in the background. It used to be
    reported in a separate session drawn again at the replaying launch's rate.
  - A crash right after a session renewal is no longer attributed to the
    previous session's last view.
  - A crash in a session that is not collected (missed by the sample rate
    without `setSessionOnError(true)`, or kept on error and thrown away
    without one) is not reported, like everything else of that session,
    however long ago the session started. It used to be attributed to the
    last view of an earlier, collected session of the same process, or
    reported in a separate session drawn again. A session kept on error still
    reports its crash, in its own last view.
  - A crash after the recorded session ended (`stopSession`, expiry), or more
    than 15 minutes after a collected session last updated its view (it
    expired unnoticed), is reported in a session of its own. It used to be
    attributed to that session's last view.
  - A crash of a process that recorded no session (a crash before RUM started
    or before the first session), or dated before the recorded session started
    (an earlier process with the same process id), is reported as before: in a
    session of its own, drawn as a new session would be.
  - A crash attributed to a view whose crash-counting update cannot be written
    is no longer also reported in a session of its own.
  The record is put back on file when tracking consent is granted again after
  a refusal, and a write the storage fails is retried by the next one.
  A crash pending from an earlier version, whose file holds only the last
  view, is attributed as before. As before, a crash reported in a view of its
  own carries the replaying launch's version, OS, user and connectivity.
- Events carry `os.version_major` again. The OS version the SDK reports is the
  system's full name (for example `OpenHarmony-6.1.1.125`), which has no
  leading number, so the major version came out empty and was left off every
  event; it is now the first number in the version (`6`).
- Resources carry the phases of their request — `resource.dns`, `connect`,
  `ssl`, `first_byte`, `download`, each `{ start, duration }` in nanoseconds
  from the start of the request, as in the browser and Android SDKs — when the
  network kit timed it: requests through `FlashcatHttp`, and through the rcp
  interceptor on a session that sets `tracing.collectTimeInfo`. A request on a
  reused connection has no `dns` or `connect`, one over plain http no `ssl`.
  A redirected request reports `resource.redirect` instead: the kit's other
  times then cover every hop and cannot be split. Requests reported with
  `startTracedResource` or `RumMonitor` (axios included) have no phases, and
  neither does a request reported without a duration because it spanned a
  stay in the background.
- A request to one of the trace configuration's `firstPartyHosts` reports
  `resource.provider` as `{ type: 'first party', domain: <host> }`, and so
  does the network error of such a request that fails (`error.resource`). Without it
  the backend could not tell the app's own requests from third-party ones.
- A native crash carries its faulting address as the `crash.fault_address`
  attribute when the crash module reports one.
- Unhandled errors, crashes and freezes carry `error.type`. An uncaught exception is typed by its
  exception name (`Error`, `TypeError`, `SyntaxError`, …), and so is an
  unhandled promise rejection whose reason is an `Error`; a rejection with any
  other value has no type, as in the browser SDK. Crashes and freezes take the
  type the crash module reports (the signal of a native crash, the fault name
  of a freeze). Without a type the backend took every error to be an `Error`,
  so errors of any other type, native crashes and freezes are grouped into new
  issues once after the upgrade. Errors reported with `addError` and failed
  requests stay untyped; an `error.type` attribute passed to `addError` now
  sets the error's type instead of appearing in its context.
- A freeze's own system text is reported in the error's context as
  `freeze.reason`.
- An uncaught exception's stack and message skip the runtime's
  `SourceMap is not initialized yet` line, as they already skipped
  `Cannot get SourceMap info`.

## 0.7.11

Cuts main-thread load and avoids losing events to the disk quota under bursts
of RUM calls.

- A burst of RUM calls no longer holds the calling thread. Within one turn of
  the event loop the SDK processes events on the caller's turn for at most
  4 ms; calls past that budget are queued and processed in slices of the same
  size on later turns, so the thread yields between slices. Events keep the
  time and attributes of their call and their order. The queue is processed
  synchronously, on the caller's turn, before an error or a crash is reported,
  before the app goes to the background or is flushed, before the user or the
  tracking consent changes, before session queries, and on stop.
- While queued events are processed, the view document an action updates is
  written once per slice instead of once per action. A burst writes about half
  as much: a few thousand actions in a row no longer exceed the 4 MB disk quota
  and evict the oldest batches before they are uploaded.

## 0.7.10

- A JS crash before the first view of its session is counted on an
  `ApplicationLaunch` view of that session. The crash module's incident named
  the session but no view, so the replayed error went into a session with no
  view document; the backend builds a session only from view documents, so
  the crash belonged to a session that never appeared. The view is opened as
  the fault is handled, before the incident is written: a persisted crash is
  counted on it and replayed into it, a crash under `REPORT_AND_CONTINUE` (or
  without the crash module) and the error of an `OBSERVE_ONLY` fault are
  written in it, and a session kept on error releases it with the crash. The
  app's first view replaces it, as any view replaces the one before. A crash
  between two views is still counted on the last one.
- A JS crash in a session that expired (15 minutes idle) without ever having a
  view is reported as a crash with no session of its own, like a crash before
  the first session, instead of into the expired session. A crash after an
  unsampled session ended is no longer dropped as sampled out: it, too, is
  reported in a session of its own, drawn as a new session would be.
- A crash, native crash or app freeze replayed on the next launch that cannot
  be attributed to the session it happened in (typically a fault during
  launch, before the first view) is always reported in a session of its own:
  one `ApplicationLaunch` view counting the crash, at the real crash time (or
  now, with the real time in `crash.crashed_at_ms`, past the intake's 24 h
  window). It used to go into the current session whenever that session was
  collected (with a sample rate of 100, every time): at the current time,
  counted in whichever view was current, so a session the crash did not happen
  in read as crashed. The current session is now never touched. The session of
  its own is drawn as a new session would be at that moment (the console's
  rate or the init value, then `setBeforeSampling`, which is asked for this
  draw too): drawn by the rate, it is an ordinary session; missed by the rate
  but kept by `setSessionOnError(true)`, it is marked like a session kept on
  error, as in 0.7.9; missed with neither, the crash is not reported, as
  before. The draw is derived from the incident, so a retry after a failed
  write draws the same way and never leaves half a session behind.
- Known limitation: such a crash carries the current launch's application
  version, OS, user and connectivity. Nothing in it says what the crashed
  run's were.

## 0.7.9

- With `setSessionOnError(true)` and a sample rate below 100, a crash, native
  crash or app freeze replayed on the next launch that cannot be attributed to
  the session it happened in (typically a fault during launch, before the
  first view) was dropped when the current session had not been kept: it
  is not that session's error, so it must not release it. Such a crash is now
  reported in a session of its own, with one `ApplicationLaunch` view counting
  the crash, at the real crash time, and marked like a session kept on error.
  The current session is left as it was. The incident is deleted only once
  both events are written, so a failed write is retried on the next launch;
  the retry reuses the same session, view and error ids, so a partly written
  attempt is not counted twice. A crash already counted in a view of its own
  run still gets the view, which then does not count it again.
- A session kept only on error holds at most the newest 20 actions of one
  name (`action.target.name`, case-sensitive). An action reported many times a
  second used to fill the 200-event history with itself and push out the taps,
  view changes and failed requests that explain the error. The other limits
  are unchanged.

## 0.7.8

- New: an active-device beacon, on by default
  (`RumConfigurationBuilder.setTrackActiveDevices(false)` turns it off). At
  most once per local day per device, user and app version, the SDK sends a
  small request of its own to `/api/v2/rum/active` when the app starts in or
  returns to the foreground, when tracking consent is granted and when a new
  user is set, so that a device counts as active that day even when its
  session is too short to upload events. It is sent only in the foreground
  with consent granted, regardless of session sampling, and carries the app,
  OS and device fields and the anonymous and user ids. One that cannot be
  delivered is kept and sent on a later launch, up to 72 hours after the app
  was used; revoking consent discards it. Turning it off also discards
  what an earlier launch stored.

## 0.7.7

- A native crash or app freeze reported on the next launch is attributed to
  the last view on file only when that view was written by the process that
  faulted. A launch that crashed before RUM started writes no view, so the
  file still held the run before it, and the crash took that run's session,
  user, app version and attributes. Such a crash is now reported in the
  current session. The last-view file records the writing process; a file
  written by an earlier version is not used.

## 0.7.6

- A crash reported on the next launch (native crash, app freeze, or a JS
  crash persisted before the process exited) now carries the crashed run's
  app version, OS version, user, connectivity and the session's custom
  attributes, read from that run's last view. Previously it carried the
  relaunch's values and none of the session's attributes, so a crash
  followed by an app update was attributed to the new version. The crash's
  own context keys (`crash.*`) take precedence over a session attribute of
  the same name. A field the event mapper removed from that view is not
  filled in from the relaunch. A persisted JS crash takes the view's
  values only when it happened in that very view, and a native crash or
  freeze dated before the last view started is not attributed to it.
- When a session that holds its events back until an error asks the event
  mapper at crash time whether a persisted crash will be kept, the mapper
  now sees the same event the next launch replays, session attributes
  included.

## 0.7.5

- Crash reports from the crash module carry their thread dump as
  `error.threads` and memory at the fault as `crash.memory.*` context
  attributes.
- A resource whose request was in flight while the app was in the
  background is reported without `resource.duration`. HarmonyOS freezes a
  backgrounded process, so the request's callbacks only run once the app is
  back, and the wall-clock time from start to completion could span hours
  the request never ran. This covers a request that starts while the app is
  in the background, and one in flight when the app moves there. The event
  is still sent with its URL, method, status code and size; requests that
  start and complete in the foreground are unchanged, including requests
  made while the app is still launching.
- An event mapper that calls into the SDK no longer hangs the app. Monitor
  calls made from inside the mapper that report something or change the
  session (startView, addAction, addError, stopSession, …) are ignored and
  logged; any other event it causes is dropped. Previously the next call
  could run the mapper without end.
- Building an event from the host's attributes happens inside the
  monitor's guard: an attribute whose getter throws drops the event instead
  of throwing out of startView, addAction, startResource and the rest;
  startAction/stopAction are guarded the same way.
- `addAttribute` refuses a key that is not a string; such a key made every
  later event fail.
- Crash reports forward the `freeze.dump_started_at` attribute set by
  `@flashcatcloud/crash` for app freezes.

## 0.7.4

- Error-session capture (`setSessionOnError`): held view documents are
  bounded in bytes (twice the per-event storage limit) as well as in count; a
  view larger than storage accepts is not held. An error too large for the
  buffer is now released together with its session's views, after them,
  instead of uploading ahead of them; one storage would refuse releases
  nothing.

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
- The last-view snapshot (used to attribute next-launch native crashes and
  freezes) is written at most once a second, and immediately whenever the
  core flushes (background, flush, pre-exit, stop), instead of on every view
  update — one synchronous write less per action, resource and error.

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
