# Changelog

## Unreleased

- Storage counts an event's UTF-8 bytes with the runtime's native
  `buffer.byteLength` instead of a per-character loop in ArkTS, the largest
  single main-thread cost of writing an event. The counts are unchanged,
  including a lone surrogate (3 bytes, the replacement character).
- Events are buffered in memory and appended to their batch file together,
  with the asynchronous file API, normally within 250 ms of being written or
  as soon as 64 KB are waiting. A write no longer opens, writes and closes the file on
  the main thread. Backgrounding, `stop`, a consent change, a crash record and
  a force-flushed event (errors) write the buffer synchronously. They do not
  wait for an asynchronous append already started, so a process that dies
  right after one of them can still lose that append's events (usually up
  to 64 KB, more when appends fall behind). A native crash, a freeze or a
  process killed outright in the foreground loses what is not on disk yet:
  normally the last 250 ms of events; when appends fall behind, as in a long
  burst, the buffer can hold more, up to 512 KB, past which writes flush
  synchronously. Revoking consent discards the buffer.
- A process still uploads its batches in the order their events were
  written: a batch waits while one written before it has events not yet on
  disk. The intake keeps the view update that arrives last, so a batch
  overtaken by a later one would overwrite the newer view state.
- Events collected while consent was pending upload before the events written
  after the grant. The batch that was active when consent became pending
  used to take the later events too and upload them first.
- A synchronous write is retried only when the file could not be opened. A
  write that failed part-way is no longer repeated (it duplicated the events
  already written), and a failure to close the file after a complete write no
  longer counts as a failed write.
- The active batch rolls 250 ms before its window ends, so it is complete on
  disk before another process may claim it, and the disk quota is enforced
  at every append.
- The network context follows a network coming back after a loss right away:
  events stop reporting `not_connected` as soon as the system says a network
  is available, instead of at its next capability change.
- The context's device carries the preferred languages (`locale`, `locales`),
  the time zone, the battery level (0–1, read at most once a minute) and
  whether a power saving mode is on (power save, extreme power save or custom
  power save). Languages, time zone and power saving are read at
  initialization and again when the system announces a change
  (`usual.event.LOCALE_CHANGED`, `TIMEZONE_CHANGED`,
  `POWER_SAVE_MODE_CHANGED`); the subscription ends when the SDK stops. A value
  the system cannot give is left out. No permission is needed.
- `SdkCore.addUserProperties(extraInfo)`, as Android's
  `Datadog.addUserProperties` (iOS: `addUserExtraInfo`): merges `extraInfo`
  into the current user's extra info. A key already set is replaced, the others
  are kept, and the user's id, name and email are left as they are; with no
  user set, the user gets the extra info only. Events recorded from then on
  carry the result. RUM first writes the events it still holds queued, with the
  user of their call. An `extraInfo` that is not an object is ignored with a
  warning.

## 0.8.2

- `SdkCore.liveWindowContexts()`: the context of every ability whose window
  stage is alive. The core now forwards window stage creation and destruction
  to RUM, with the ability's context, so RUM hooks each window itself. A core
  initialized after the app's window came up looks up the window on top once
  and counts its ability's window stage as up.

## 0.8.1

- `SdkCore.isAppStateKnown()`: whether the system has said yet if the app is
  in the foreground or the background. Until it has, `isAppInForeground()`
  false means unknown, not background.

## 0.8.0

- The RUM last-view file is written to a temporary file and renamed into
  place, so a process killed during the write leaves the previous file whole
  instead of a truncated one the next launch cannot read. Its write reports
  failure to RUM, which retries it.

## 0.7.11

- Released together with `@flashcatcloud/rum` 0.7.11, which cuts main-thread
  load and avoids losing events to the disk quota under bursts of RUM calls.
- Before the user (`setUserInfo`, `clearUserInfo`) or the tracking consent
  changes, the core asks RUM to process the events it still holds queued, so
  they are written with the user and consent of their call.

## 0.7.10

- No changes; released together with `@flashcatcloud/rum` 0.7.10.

## 0.7.9

- No changes; released together with `@flashcatcloud/rum` 0.7.9.

## 0.7.8

- No changes; released together with `@flashcatcloud/rum` 0.7.8.

## 0.7.7

- No changes; released together with `@flashcatcloud/rum`, `crash`, `trace` and `axios` 0.7.7.

## 0.7.6

- No changes; released together with `@flashcatcloud/rum` 0.7.6.

## 0.7.5

- The core tells RUM when the app moves to the background (and when it was
  launched in the background), so RUM can tell which measurements may span
  a frozen process.
- `setUserInfo(null)` is treated as no user; it previously made every
  event fail to assemble and be dropped.

## 0.7.4

- Revoking tracking consent (`NOT_GRANTED`) now also deletes pending crash
  incidents persisted earlier, which carry a crash's stack and session/view
  ids; they previously stayed on disk until a later launch replayed them.
- Exports `MAX_EVENT_BYTES`, the largest event storage accepts.

## 0.7.3

- The SDK no longer throws into the host app: an event that cannot be
  serialized or stored (e.g. a circular or BigInt attribute) is dropped;
  `Flashcat.initialize` / `initializeForDeferredUpload` return null on
  failure; `setTrackingConsent`, `flush`, `flushAndWait` and `stopInstance`
  are no-ops (always logged) when the instance does not exist.
- A feature that fails to start or stop no longer aborts the others or
  throws out of `enable` / `stopInstance`; a stopped instance accepts no new
  feature.
- A storage or HTTP-setup failure in the upload loop retries with backoff
  instead of ending uploads for the process; a claimed batch is handed back.
- Host misuse (calls before initialize or after stop, failed initialize or
  enable) is always logged, verbose or not.
- Less file work on the calling thread, especially offline:
  - while uploads are backing off, an error no longer closes the active batch
    (offline, every failed request opened a new batch file and re-scanned the
    directory);
  - disk quota is tracked in memory and reconciled with the directory at most
    once a minute, instead of stat'ing every batch file whenever a batch opens;
  - the byte quota (4 MB) now binds instead of the file count: the count cap
    rises from 200 to 1000, so a device offline for half an hour no longer
    discards its oldest events with under 1 MB on disk;
  - no directory check before every write; idle drains look for orphaned
    upload claims at most once a minute.

## 0.7.2

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/crash`
  0.7.2: `REPORT_AND_CONTINUE` crash policy).

## 0.7.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.7.1: remote configuration survives app upgrades).

## 0.7.0

- Withdrawing tracking consent now also tells the RUM package, so that it
  discards what it holds in memory for error-session capture (see
  `@flashcatcloud/rum` 0.7.0).

## 0.6.0

- `SdkCore` gains `getIntakeTarget()`, `readSetting()` and `writeSetting()`,
  which feature packages use to call an endpoint of their own and keep small
  settings across launches (see `@flashcatcloud/rum` 0.6.0: remote
  configuration).

### Breaking

- Code that implements `SdkCore` itself needs to add the three methods above.

## 0.5.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.5.1: app freezes are now categorized as ANR).

## 0.5.0

### Breaking

- **Removed `ConfigurationBuilder.setBatchUploadFrequencyMs`.** Upload pacing is
  now expressed with the same three enums the Android, iOS and Flutter SDKs use,
  with identical case names and values, so tuning advice transfers between
  platforms unchanged. Migrate:

  ```ts
  // before
  .setBatchUploadFrequencyMs(5000)
  // after
  .setUploadFrequency(UploadFrequency.RARE)
  ```

  `UploadFrequency` (FREQUENT 500 ms / AVERAGE 2 s / RARE 5 s), `BatchSize`
  (SMALL 3 s / MEDIUM 10 s / LARGE 35 s) and `BatchProcessingLevel` (LOW 1 /
  MEDIUM 20 / HIGH 100 batches per upload cycle) are exported from
  `@flashcatcloud/core`.

- **Two defaults changed** to match the other platforms. Apps that never set
  these are affected:
  - Upload cycle interval 5 s → 2 s (`UploadFrequency.AVERAGE`). Pass
    `UploadFrequency.RARE` to keep the previous cadence.
  - Batch roll window 5 s → 10 s (`BatchSize.MEDIUM`). Batches now collect for
    longer before becoming eligible to upload; pass `BatchSize.SMALL` for a
    shorter window than before.

### Added

- `setBatchProcessingLevel` bounds how many batches one upload cycle ships
  back-to-back. Previously a backlog was drained in a single uninterrupted
  burst, which competes with the app's own requests for upstream bandwidth. Set
  `BatchProcessingLevel.LOW` when the app has latency-sensitive requests on a
  narrow uplink. The bound also applies to the deferred-upload and
  `flushAndWait` drains, which previously used a fixed limit.

### Fixed

- A force-flush (an error or crash write, or backgrounding) no longer cancels an
  in-progress upload backoff. A failing intake was being retried at the app's
  error rate instead of on the exponential schedule.
- The deferred-upload process built its persistence layer without the configured
  batch window, and the guard that stops one process from claiming a batch
  another is still writing is derived from that window. It now uses the widest
  supported window, so the two processes cannot disagree and lose acknowledged
  events.

## 0.4.0

- Version bump to keep the SDK packages in lockstep.

## 0.3.2

- Added a durable snapshot of the last written ViewEvent, used by the RUM
  feature to attribute crashes the SDK could not observe in-process (native
  signals, freezes) to the session and view that died.
- Revoking tracking consent now deletes that snapshot along with the collected
  batches — it is a whole ViewEvent, so it carries user id, name, email and any
  custom context.

## 0.3.1

- **Reverts a 0.3.0 behavior change**: the tracking-consent value passed to
  `Flashcat.initialize` is authoritative again in the main process. 0.3.0 let a
  persisted `NOT_GRANTED` override it until an explicit `setTrackingConsent`
  re-grant, which silently discarded a legitimate re-grant from any app that
  manages consent only at initialization — collection stayed off with nothing
  but a debug log to explain it. Android and iOS have no such override; this
  restores parity. Consent is still persisted, but now only so the
  deferred-upload extension process (`initializeForDeferredUpload`) can act on
  the main process's last decision — it has no app in front of it to ask.
- Apps that hardcode `GRANTED` at initialization must reflect a revocation
  through `setTrackingConsent`, the same contract as the Android and iOS SDKs.

## 0.3.0

- **Breaking behavior**: consent semantics reworked — the constructor literal is
  trusted, with exactly one override: a persisted NOT_GRANTED stays sticky until
  an explicit `setTrackingConsent` re-grant. Revocation now also deletes
  already-collected batches (not just the pre-consent buffer).
- New `Flashcat.initializeForDeferredUpload(context, config)` for the
  WorkSchedulerExtensionAbility process: acts on persisted consent only, never
  writes consent/identity/job registrations, and builds upload-only pipelines so
  `flushAndWait` actually delivers batches from the extension (previously a
  no-op). The persisted job is now recurring (`isRepeat`, 2 h) and its
  cancellation works across launches.
- Upload bodies are zlib-compressed (`Content-Encoding: deflate`, 5-10x
  smaller) with uncompressed fallback.
- Upload pipeline hardening: claim timestamps, per-drain claim recovery,
  cross-process foreign-claim age gate, restore-never-clobbers, torn-line drop,
  UTF-8 byte accounting, 23 h batch retention, pending-buffer cap with
  oldest-half eviction, migration age filter + quota, backoff preserved across
  force-flushes, `flushForWork` stops at batch boundary on stop().
- Persisted anonymous device id (`usr.anonymous_id` on every event), persisted
  tracking consent, crash-pending quota + tmp-orphan sweep, NetConnection-backed
  connectivity context, lifecycle observer teardown on stop, `SdkCore.isActive()`.

## 0.2.0

- Add core-owned synchronous crash-pending storage for next-launch replay.

## 0.1.3

- Fix `SDK_VERSION` so events report the correct `_dd.sdk_version` (it was stuck
  at `0.1.0` while the packages shipped `0.1.2`).

## 0.1.2

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.0

- Initial HarmonyOS SDK core release.
