# FlashCat HarmonyOS SDK — Demo App (`entry`)

A single-screen ArkUI app to **manually verify** the SDK on a real device or
emulator. Every button maps to one telemetry path: views, resources, errors, and
crashes (native + ArkTS + freeze).

## One-time setup

1. Open the repo root in **DevEco Studio**.
2. Configure automatic signing: `File → Project Structure → Signing Configs →
   Automatically generate signature` (a free Huawei account works). The CLI build
   produces an **unsigned** HAP; running on a device needs a signature.
3. Edit `entry/src/main/ets/common/DemoSdk.ets` and replace:
   - `DEMO_CLIENT_TOKEN` — your FlashCat client token
   - `DEMO_APPLICATION_ID` — your RUM application id

## Build from CLI (compile check, no signing)

```sh
# env (same as repo HANDOFF.md)
export PATH="$HOME/Downloads/command-line-tools/bin:$HOME/Downloads/command-line-tools/ohpm/bin:/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
ohpm install
node "$HOME/Downloads/command-line-tools/hvigor/bin/hvigorw.js" assembleHap --mode module -p module=entry@default -p product=default --no-daemon
```

Produces `entry/build/default/outputs/default/entry-default-unsigned.hap` and
`libentry.so` (arm64-v8a). To run, use DevEco's Run button against a device/emulator.

## What each button does

| Button | Telemetry produced | How to confirm |
|---|---|---|
| Production env (toggle) | selects prod (`browser.flashcat.cloud`) vs staging (`jira.flashcat.cloud`) — lock at init | status line |
| Initialize SDK | `Flashcat.initialize` + RUM/Trace/Crash enable; starts view `DemoHome` | status line turns blue |
| Start View / Stop View | RUM ViewEvents | `"type":"view"` NDJSON line; FlashCat console session |
| Fire Traced Network Request | rcp GET with injected `traceparent`; RUM ResourceEvent | Charles shows `traceparent: 00-…`; `"type":"resource"` w/ `_dd.trace_id` |
| Add Manual Error | RUM ErrorEvent (`source:custom`, `is_crash:false`) | `"type":"error"` line |
| Throw Unhandled ArkTS Error | unhandled exception → `errorManager` + `APP_CRASH` (JsError) | `"type":"error"` `is_crash:true`, source `source` |
| Trigger Native Crash (SIGSEGV) | `libentry.so` null-deref → `APP_CRASH` (NativeCrash) | next launch: `"type":"error"` with native stack + `_dd.crash.binary_images` |
| Trigger App Freeze (8s) | main-thread block → `APP_FREEZE` | next launch: `"type":"error"` `_dd.crash.kind:freeze` |

> Crash/freeze events are delivered by `hiAppEvent` on the **next app launch** —
> trigger a crash, relaunch the app, then check the proxy/console.

## Verification checklist (device)

- [ ] View/resource/error events reach `/api/v2/rum` (NDJSON, `text/plain`).
- [ ] `traceparent` header is on the wire for the traced request.
- [ ] ArkTS throw produces an `is_crash:true` error.
- [ ] Native crash produces an error whose `error.stack` has a `libentry.so` frame
      and whose `_dd.crash.binary_images` / `_dd.crash.arch` are populated.
- [ ] Freeze produces a `_dd.crash.kind:freeze` error.
- [ ] Confirm the real `hiAppEvent` `params` field shape matches `CrashEventMapper`
      (adjust the mapper if the on-device shape differs — see R1 plan checklist).
