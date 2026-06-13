# HarmonyOS SDK — End-to-End Verification Runbook

Validates the full loop: demo app → crash/telemetry → symbol upload → fc-rum
symbolication → FlashCat console. Needs a HarmonyOS device/emulator and either
staging (`jira.flashcat.cloud`) or a local fc-rum with the
`feat/harmony-symbolication` branch deployed.

This is the gate that closes the validation gaps left by Rounds 1–4 (which were
unit-tested but could not exercise on-device `hiAppEvent` delivery, real
ArkTS-obfuscated `sourceMaps.map`, or the MySQL/MinIO/Symbolicator store path).

## 0. Prereqsuites

- DevEco Studio + a device/emulator (HarmonyOS NEXT).
- fc-rum reachable with `feat/harmony-symbolication` (commit `afccf23`) deployed,
  MinIO + MySQL + Symbolicator wired (same infra as Android NDK symbolication).
- A FlashCat API key (for symbol upload) + RUM client token + application id.

## 1. Build a RELEASE (obfuscated) demo

Symbolication is only meaningful on an obfuscated build (a debug build has no
`nameCache.json` and readable frames).

```sh
# fill credentials first: entry/src/main/ets/common/DemoSdk.ets (REPLACE_WITH_*)
hvigorw assembleHap --mode module -p module=entry@default -p product=default -p buildMode=release
```

Confirm the artifacts exist:
- `entry/build/default/outputs/default/mapping/sourceMaps.map`
- `entry/build/.../intermediates/.../nameCache.json` (release only)
- `entry/build/.../intermediates/cmake/default/obj/arm64-v8a/libentry.so` (unstripped)

## 2. Upload symbols (hvigor plugin)

Wire `@flashcatcloud/hvigor-plugin` into `entry/hvigorfile.ts` (see the plugin
README), then:

```sh
FLASHCAT_UPLOAD=1 FLASHCAT_API_KEY=*** \
  hvigorw uploadFlashcatSymbols --mode module -p module=entry@default -p product=default
```

Expected log: `sourcemap upload OK (200)` and `symbol libentry.so (arm64) OK (200)`.
Verify in the console "uploaded symbols" list (type=harmony) that both appear.

## 3. Run + exercise the app

Install the signed HAP, then per `entry/README.md`:

1. Toggle environment, tap **Initialize SDK** (status turns blue).
2. **Start View**, **Fire Traced Network Request**, **Add Manual Error** — these
   upload immediately. Check a proxy (Charles) for `traceparent` on the request.
3. **Throw Unhandled ArkTS Error** — app may terminate.
4. **Trigger Native Crash (SIGSEGV)** — app terminates.
5. **Trigger App Freeze (8s)** — watchdog fires.
6. **Relaunch the app** (crash/freeze events are delivered by `hiAppEvent` on the
   NEXT launch and uploaded then).

## 4. Verify on the wire (proxy / fc-rum logs)

- A batch `POST /api/v2/rum` (NDJSON, `text/plain`) contains:
  - `"type":"view"`, `"type":"resource"` (with `_dd.trace_id`),
  - `"type":"error"` with `error.is_crash:true` for the ArkTS throw,
  - `"type":"error"` with `_dd.crash.kind:"crash"` + `_dd.crash.binary_images`
    + `_dd.crash.arch` for the native crash,
  - `"type":"error"` with `_dd.crash.kind:"freeze"` for the freeze.
- **CONFIRM the real `hiAppEvent` `params` shape** matches `CrashEventMapper`'s
  field reads (`exception.name/message/stack`, `binary_images`, `arch`). If the
  device delivers a different shape, adjust `CrashEventMapper` and re-test — this
  is the one field-mapping assumption that could not be unit-verified.

## 5. Verify symbolication (FlashCat console)

- The native crash issue resolves `libentry.so` frames to
  `FlashcatCrashDepthTwo` / `FlashcatCrashDepthOne` (from `napi_init.cpp`).
- The ArkTS error resolves to the original `.ets` source lines (not obfuscated).
- If native frames stay raw: check the uploaded `build_id` equals the crash-time
  binary-image build-id (the plugin↔Go extractor were verified identical, so a
  mismatch points at the device not reporting build-ids — capture a sample).
- If ArkTS frames stay raw: capture a real obfuscated frame + the matching
  `sourceMaps.map` module key; the enrich lookup matches `minified_url` to the
  frame `File`, so a key-format mismatch is the likely cause (adjust
  `normalizeHarmonyFile` / the upload module-key form).

## 6. Sign-off checklist

- [ ] view / resource / manual-error events ingested
- [ ] `traceparent` injected on the traced request
- [ ] ArkTS unhandled error → `is_crash:true` error, symbolicated to source
- [ ] native SIGSEGV → error with native stack, symbolicated to `libentry.so` fn
- [ ] freeze → `_dd.crash.kind:freeze` error
- [ ] `hiAppEvent` `params` shape confirmed (or `CrashEventMapper` adjusted)
- [ ] payload caps: a forced huge stack is truncated, batch stays < 1 MiB
- [ ] symbols visible in console "uploaded symbols" (type=harmony)
