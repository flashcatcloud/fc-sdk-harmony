# Changelog

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
