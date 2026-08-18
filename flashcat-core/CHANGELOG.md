# Changelog

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
