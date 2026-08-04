# @flashcatcloud/crash

FlashCat HarmonyOS crash reporting package.

This package has two crash-reporting paths:

- post-mortem capture of HarmonyOS `hiAppEvent` `APP_CRASH` and `APP_FREEZE`
  events, delivered through the RUM pipeline on a later launch; and
- live handling of uncaught main-thread ArkTS exceptions, with an explicit
  `JsCrashPolicy` that reports before the process exits or restarts.

It depends on `@flashcatcloud/core` and requires `@flashcatcloud/rum` to publish
crash error events.

## Install

```sh
ohpm install @flashcatcloud/crash
```

## Quick start

Enable crash reporting with the defaults:

```ts
import { FlashcatCrash, CrashConfigurationBuilder } from '@flashcatcloud/crash';

FlashcatCrash.enable(new CrashConfigurationBuilder().build());
```

The default JS crash policy is `REPORT_THEN_EXIT`.

To synchronously report an uncaught ArkTS exception and restart the app:

```ts
import {
  FlashcatCrash,
  CrashConfigurationBuilder,
  JsCrashPolicy
} from '@flashcatcloud/crash';

FlashcatCrash.enable(new CrashConfigurationBuilder()
  .setJsCrashPolicy(JsCrashPolicy.REPORT_AND_RECOVER)
  .build());
```

Enable RUM before the crash module so pending incidents from a previous launch
are replayed immediately. The JS crash policy itself is enable-order-proof: the
crash module pushes it to RUM, and RUM also pulls it on start, so either order
activates the policy.

```ts
FlashcatRum.enable(rumConfiguration);
FlashcatCrash.enable(crashConfiguration);
```

### Builder reference

| Setter | Default | Meaning |
|---|---:|---|
| `setTrackCrashes(enabled)` | `true` | Watch post-mortem `hiAppEvent.APP_CRASH` events, including ArkTS and native crashes. This does not disable synchronous JS policy reporting. |
| `setTrackAppHangs(enabled)` | `true` | Watch post-mortem `hiAppEvent.APP_FREEZE` events. |
| `setSampleRate(rate)` | `100` | Percentage of `hiAppEvent` crash and freeze events to report. Values are clamped to `0...100`. This does not sample synchronous JS policy reporting. |
| `setJsCrashPolicy(policy)` | `REPORT_THEN_EXIT` | Select the behavior for uncaught main-thread ArkTS exceptions. |
| `setCrashLoopThreshold(threshold)` | `3` | The Nth crash inside the rolling window is blocked from restarting (at most N-1 restarts per window). `1` disables recovery restarts entirely — every crash reports synchronously and exits. Values below `1` become `1`. |
| `setCrashLoopWindowMs(windowMs)` | `60000` | Rolling interval used to count recoverable crashes before the guard trips. Values below `1` become `1`. |
| `setCrashLoopCooldownMs(cooldownMs)` | `300000` | Required crash-free interval before a persisted tripped guard resets. Values below `1` become `1`. |

The crash-loop settings affect only `REPORT_AND_RECOVER`.

## JS crash policies

The policies apply to uncaught synchronous and asynchronous main-thread ArkTS
exceptions observed through `errorManager.on('error')`. They do not apply to
Promise rejections, Worker/TaskPool failures, native signals, or app freezes.

### `REPORT_THEN_EXIT`

This is the default. The SDK synchronously persists a crash incident, flushes
the current RUM writers, and exits the process. The incident is replayed into
RUM on the next launch. If the synchronous write fails, the SDK attempts an
asynchronous RUM report and still exits.

**Behavior change:** previously, merely initializing the SDK registered an error
observer that suppressed the host app's normal exit after an uncaught ArkTS
exception. That latent keep-alive behavior was not semantically neutral. The
default now restores exit semantics after synchronously persisting the crash.

### `REPORT_AND_RECOVER`

The SDK synchronously persists the incident, evaluates the persisted crash-loop
guard, asks HarmonyOS to save app state, and calls `appRecovery.restartApp()`.
The old process exits and a new process starts. On the next launch, the replayed
incident includes `crash.recovered: true`.

If recovery cannot be enabled, loop history cannot be persisted, the loop guard
trips, the incident cannot be updated as recoverable, or the restart request
fails, the SDK degrades to exit behavior.

The supported promise is: **synchronous crash report + automatic restart
(+ best-effort state restore when the host implements `onSaveState`)**.

### `OBSERVE_ONLY`

The SDK reports the observed exception asynchronously and leaves the process
running. This restores the legacy keep-alive behavior.

Use this only when retaining the process is intentional. The event loop may
remain responsive, but the app may be left in a broken or inconsistent state
after an uncaught exception.

## Soft-landing flow

```text
uncaught main-thread ArkTS exception
                  |
                  v
             select policy
       /                            \
OBSERVE_ONLY                     REPORT_*
      |                             |
      v                             v
async RUM report        synchronously persist incident
keep process running              |
                     +------------+-------------+
                     |                          |
              REPORT_THEN_EXIT          REPORT_AND_RECOVER
                     |                          |
                     v                          v
                   exit              evaluate crash-loop guard
                                           /           \
                                      allow             block/failure
                                        |                    |
                                        v                    v
                              saveAppState + restartApp      exit
                                        |
                                        v
                                   new process

next launch
    |
    v
replay pending incident -> mark consumed -> RUM crash error
    |                                      (+ crash.recovered for recovery)
    v
deduplicate later hiAppEvent APP_CRASH replay
```

One ArkTS crash can surface through `onUnhandledException`, `onException`, and
the later `hiAppEvent.APP_CRASH`. The SDK fingerprints the live callbacks and
uses a persisted consumed-incident sidecar for the later system event, so one
policy-managed crash produces one crash error event in the pipeline.

## Crash-loop protection

With the defaults, `REPORT_AND_RECOVER` allows the first two crashes in a
60-second rolling window to restart the app. The third crash is synchronously
reported but degrades to exit. The timestamps are persisted across processes,
so restarting the app does not reset the guard.

The guard deliberately does not clear history when it trips. Each blocked crash
is recorded as the newest timestamp, keeping recovery disabled until the app
has remained crash-free for the full cooldown. After the default five-minute
crash-free cooldown, history resets and the next crash can restart the app
again.

Tune the threshold, rolling window, and cooldown with
`setCrashLoopThreshold`, `setCrashLoopWindowMs`, and
`setCrashLoopCooldownMs`.

## Host-app state restoration

Automatic restart does not by itself define which page state should be
restored. The host `UIAbility` must implement `onSaveState`, copy the state it
needs into `wantParam`, and return `ALL_AGREE`:

```ts
import { AbilityConstant, UIAbility } from '@kit.AbilityKit';

export default class EntryAbility extends UIAbility {
  onSaveState(
    _reason: AbilityConstant.StateType,
    wantParam: Record<string, Object>
  ): AbilityConstant.OnSaveResult {
    wantParam['route'] = 'pages/Checkout';
    wantParam['draftId'] = 'draft-123';
    return AbilityConstant.OnSaveResult.ALL_AGREE;
  }
}
```

Read the saved parameters from the recovery `Want` in the host lifecycle and
restore only state that is safe to resume. On the API 24 emulator,
`onSaveState` and restored `wantParam` state were observed under SDK
orchestration. Restoration remains best effort and still requires validation
on physical devices.

## Capability boundary

| Failure type | Capture and policy behavior |
|---|---|
| Uncaught ArkTS main-thread synchronous or asynchronous exception | ✅ Live capture. The selected `JsCrashPolicy` applies, including synchronous persistence and optional restart. |
| Unhandled Promise rejection | Captured by RUM as an ordinary, non-crashing error with `error.source_type: promise`. The process does not die and crash policies do not apply. |
| TaskPool or Worker throw | Does not reach the error observer in the verified cases, is not fatal to the host process, and is not covered by crash policies. |
| Native C/C++ signal crash | Cannot be prevented or restarted by any JS crash policy. It is captured post-mortem through `hiAppEvent.APP_CRASH` on a later launch. |
| `APP_FREEZE` | Post-mortem `hiAppEvent.APP_FREEZE` capture only. |

## Verification status

The behavior above was verified on an API 24 emulator, including synchronous
and asynchronous main-thread exceptions, restart into a new process,
best-effort state restoration, replay with `crash.recovered: true`, and
crash-loop degradation. Real-device validation is pending.

See [Phase 0 crash semantics](../docs/spike-phase0-crash-semantics.md) for the
original platform experiment and its test matrix.

## License

Apache-2.0
