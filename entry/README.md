# FlashCat HarmonyOS SDK — Demo App (`entry`)

A single-screen ArkUI app to **manually verify** the SDK on a real device or
emulator. Every button maps to one telemetry path: views, resources, errors, and
crashes (native + ArkTS + freeze).

## ⚠️ Must run on an emulator or real device — NOT the Previewer

The DevEco **Previewer** only renders ArkUI; it stubs native kit APIs (file system,
`systemDateTime`, network, `hiAppEvent`, `errorManager`), so the SDK cannot write
batches or upload there. Symptoms in the Previewer: `systemDateTime.getTime()`
returns `0`, file writes fail (`onDisk=0`), no `upload:` logs. This is expected —
**run on a real runtime instead.**

- **Local emulator** (macOS Apple Silicon / Windows): enough to verify RUM views,
  resources, errors, and uploads (`upload: POST /api/v2/rum -> 202`). Note: creating
  the HarmonyOS NEXT emulator requires a Huawei developer account with **real-name
  authentication (实名认证)**, which in practice needs a **China-mainland identity**.
- **Real device**: required to reliably verify native (`.so`) crash + freeze
  capture via `hiAppEvent` (and crash replay on next launch).

Verified working on the local emulator (2026-06-13): `upload: POST /api/v2/rum -> 202`.

## One-time setup

1. Build the hvigor plugin once. `entry/hvigorfile.ts` imports it from
   `hvigor-plugin/dist/`, which is not checked in, and hvigor evaluates that file on
   every invocation — DevEco project sync included, so skipping this fails the sync
   with a module-not-found error:

   ```sh
   (cd hvigor-plugin && npm ci && npm run build)
   ```

2. Open the repo root in **DevEco Studio**.
3. Configure automatic signing: `File → Project Structure → Signing Configs →
   Automatically generate signature` (a free Huawei account works). The CLI build
   produces an **unsigned** HAP; running on a device needs a signature.
4. Edit `entry/src/main/resources/rawfile/demo_config.json`:
   - `clientToken` — your FlashCat client token
   - `applicationId` — your RUM application id
   - `service` — optional service name; defaults to `flashcat-harmony-demo`

## Build from CLI (compile check, no signing)

```sh
# env
export PATH="$HOME/Downloads/command-line-tools/bin:$HOME/Downloads/command-line-tools/ohpm/bin:/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
ohpm install
node "$HOME/Downloads/command-line-tools/hvigor/bin/hvigorw.js" assembleHap --mode module -p module=entry@default -p product=default --no-daemon
```

Produces `entry/build/default/outputs/default/entry-default-unsigned.hap` and
`libentry.so` (arm64-v8a). To run, use DevEco's Run button against a device/emulator.

## SDK dependency mode: local source vs published packages

The demo can depend on the SDK two ways. Switch with one script — it edits only
**two** files (`entry/oh-package.json5` + the root `oh-package.json5` core
override) and runs `ohpm install`. `build-profile.json5` is never touched, so all
`flashcat-*` modules stay in the project; the local modules do **not** shadow the
registry packages because resolution follows each module's oh-package spec.

```sh
# Default — develop against local source (file:../flashcat-*). Edits to the SDK
# modules are picked up immediately when you rebuild the demo.
scripts/switch-demo-sdk.sh local

# Validate a real release — consume the published @flashcatcloud/* from ohpm.
scripts/switch-demo-sdk.sh published          # latest 0.1.x (^0.1.0)
scripts/switch-demo-sdk.sh published "^0.2.0" # a specific published range
```

**Use `published` to e2e-test a release exactly as an integrator would**: switch,
build + sign in DevEco, run on the emulator/device pointed at your **test
environment** (set `demo_config.json` to the test app's `clientToken` /
`applicationId`), exercise the buttons, and confirm the events land
(`upload: POST /api/v2/rum -> 202`; rows in the test env's `t_views` / `t_actions`
/ `t_resources` / `t_errors`). When done, `scripts/switch-demo-sdk.sh local` to
return to the dev setup. Verified 2026-06-24 against `@flashcatcloud/*@0.1.0`:
view + action + resource (`resource_type=image`) + error all reached the test env.

> Keep the **default committed state on `local`** so SDK contributors build
> against their working tree. `published` mode is a temporary verification step,
> not a state to commit.

## What each button does

| Button | Telemetry produced | How to confirm |
|---|---|---|
| Production env (toggle) | selects prod (`browser.flashcat.cloud`) vs staging (`jira.flashcat.cloud`) — lock at init | status line |
| Initialize SDK | `Flashcat.initialize` + RUM/Trace/Crash enable; starts view `DemoHome` | status line turns blue |
| Start View / Stop View | RUM ViewEvents | `"type":"view"` NDJSON line; FlashCat console session |
| Fire Traced Network Request | rcp GET with injected `traceparent`; RUM ResourceEvent | Charles shows `traceparent: 00-…`; `"type":"resource"` w/ `_dd.trace_id` |
| Add Manual Error | RUM ErrorEvent (`source:custom`, `is_crash:false`) | `"type":"error"` line |
| Throw Unhandled ArkTS Error | unhandled exception → `errorManager` + `APP_CRASH` (JsError) | `"type":"error"` from next-launch crash intake, source `source` |
| Trigger Native Crash (SIGSEGV) | `libentry.so` null-deref → `APP_CRASH` (NativeCrash) | next launch: `"type":"error"` with native stack, `error.binary_images`, `build_id` |
| Trigger App Freeze (8s) | main-thread block → `APP_FREEZE` | next launch: `"type":"error"` with `error.category:"ANR"` |

> Crash/freeze events are delivered by `hiAppEvent` on the **next app launch** —
> trigger a crash, relaunch the app, then check the proxy/console.

## Verification checklist (device)

- [ ] View/resource/error events reach `/api/v2/rum` (NDJSON, `text/plain`).
- [ ] `traceparent` header is on the wire for the traced request.
- [ ] ArkTS throw produces one next-launch crash error.
- [ ] Native crash produces an error whose `error.stack` has a `libentry.so` frame
      and whose `error.binary_images`, `build_id`, and `error.meta.code_type`
      are populated.
- [ ] Freeze produces an error with `error.category:"ANR"`.
- [ ] Confirm the real `hiAppEvent` `params` field shape matches `CrashEventMapper`
      (adjust the mapper if the on-device shape differs — see R1 plan checklist).
