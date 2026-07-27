# Phase 0 Crash Soft-Landing Semantics Spike

## Test environment

- Device model: Pura 90 local emulator (not a physical device)
- ROM / HarmonyOS version: HarmonyOS 6.1.0.125(SP9DEVC00E120R4P11), emulator image 6.1.1
- API level: 24
- SDK repository commit: `9638d14555947b1bd54246f20ab4b793f62a0ffd`
- Date: 2026-07-20
- Tester: Codex, automated through `hdc` and `uitest`

> Scope: this table is simulator evidence only. It does not satisfy the API 12 real-device gate, and all conclusions below must be revalidated on supported physical devices before the feature decision is final.
>
> The demo's configured staging upload returned HTTP 401 during the SDK-only cases. Those rows therefore validate local observer, persistence, and `hiAppEvent` behavior, not successful backend ingestion.

Run the complete matrix separately on every device/ROM combination. Do not combine observations from different devices in one table.

## How to run

1. Open the repository root in DevEco Studio, configure signing, and build/run the `entry` demo on a real device. The Previewer is not suitable because it stubs `errorManager`, `hiAppEvent`, and other system APIs.
2. For a command-line compile check, run the commands in `entry/README.md`. Install the signed HAP with DevEco Studio's Run action.
3. Open **Spike: crash soft-landing (Phase 0)**. Select the required persisted mode, wait for the on-screen `persisted mode` confirmation, then force-stop and cold-launch the app. Mode changes only affect the next cold launch because observer registration happens in `EntryAbility.onCreate`.
4. Confirm the on-screen launch counter and the `FCSpike` HiLog line show the expected mode. Run only one trigger per cold launch.
5. Observe whether the app exits, stays visible, or restarts. In `OBSERVE_ONLY`, tap **Post-crash interactivity probe** after the trigger if the UI remains visible.
6. After an exit or restart, relaunch if necessary and record whether the recovery banner shows `marker=pages/Index` and a saved timestamp.
7. Wait at least 30 seconds for fault-log collection, then tap **Query recent APP_CRASH / APP_FREEZE faults**. If no event is returned, wait and retry; fault-log capture can take longer on some devices.
8. Capture the on-screen event log and filter device logs by HiLog tag `FCSpike` for the observer callback, launch number, last-crash timestamp, recovery calls, and fault payloads.

For the `SDK-initialized-only` rows, persist `OFF`, cold-launch, tap **Initialize SDK**, and then run the trigger. This isolates the existing SDK-installed `errorManager` observer from the spike observer. Do not initialize the SDK for `OFF`, `OBSERVE_ONLY`, or `RECOVER` rows.

### Fault-query limitation

The API 12 surface used by this repository does not provide an arbitrary `hiAppEvent.query` call. The page registers a watcher for `APP_CRASH` and `APP_FREEZE` at page load and the query button drains its `AppEventPackageHolder` with `takeNext()`. The result is watcher-scoped queued/replayed data, and reading drains the currently available packages. Record `none yet` separately from a confirmed absence, then retry after fault-log collection has completed.

The TaskPool trigger throws inside an `@Concurrent` worker function. On API 12, `taskpool.execute()` propagates that worker failure by rejecting its returned Promise; the harness deliberately leaves that Promise uncaught. Treat row d as a worker-originated throw observed through an unhandled execute rejection, and use the `FCSpike` trigger log plus the error message to distinguish it from row c's directly created rejected Promise.

## Experiment matrix

Use `yes`, `no`, `N/A`, or `unknown`. Put timing, callback order, launch-counter changes, and fault subtype details in **Notes**.

| Trigger | Mode | App exited? | UI interactive after? | `hiAppEvent` `APP_CRASH` recorded? | Restart happened? | State restored (payload seen)? | Notes |
|---|---|---|---|---|---|---|---|
| a. Main-thread synchronous throw | OFF | yes | N/A | yes | no | N/A | Process exited; replayed fault was `APP_CRASH` / `JsError`. |
| a. Main-thread synchronous throw | OBSERVE_ONLY | no | yes | yes | no | N/A | Same PID remained usable. Callback order was `onUnhandledException` then `onException`; both callbacks ran for one throw. |
| a. Main-thread synchronous throw | RECOVER | yes | yes | yes | yes | no | Old PID exited and a new PID launched. `saveAppState` returned `true`, but the new launch used reason `1`, not `APP_RECOVERY`, and no payload appeared. |
| a. Main-thread synchronous throw | SDK-initialized-only | no | yes | yes | no | N/A | SDK observer kept the same PID alive. It emitted from both error callbacks, then the crash watcher emitted again for the same `APP_CRASH`. |
| b. Async callback throw (`setTimeout(0)`) | OFF | yes | N/A | yes | no | N/A | Process exited; replayed fault was `APP_CRASH` / `JsError`. |
| b. Async callback throw (`setTimeout(0)`) | OBSERVE_ONLY | no | yes | yes | no | N/A | Same PID remained usable. Callback order was `onUnhandledException` then `onException`. |
| b. Async callback throw (`setTimeout(0)`) | RECOVER | yes | yes | yes | yes | no | Restarted into a new PID. State save succeeded, but launch reason remained `1` and no restored payload was visible. |
| b. Async callback throw (`setTimeout(0)`) | SDK-initialized-only | no | yes | yes | no | N/A | Same behavior as synchronous throw: two error callbacks plus one crash-watcher report, with the UI still interactive. |
| c. Unhandled Promise rejection | OFF | no | yes | no | no | N/A | No error-manager callback and no queued fault were observed after the collection window. |
| c. Unhandled Promise rejection | OBSERVE_ONLY | no | yes | no | no | N/A | Observer was not called; interactivity probe succeeded. |
| c. Unhandled Promise rejection | RECOVER | no | yes | no | no | N/A | Observer was not called, so recovery did not start. |
| c. Unhandled Promise rejection | SDK-initialized-only | no | yes | no | no | N/A | SDK observer was not called; no SDK error/crash report was logged. |
| d. TaskPool worker throw (uncaught execute rejection) | OFF | no | yes | no | no | N/A | TaskPool logged the worker exception; the host process remained interactive. |
| d. TaskPool worker throw (uncaught execute rejection) | OBSERVE_ONLY | no | yes | no | no | N/A | No error-manager callback; interactivity probe succeeded. |
| d. TaskPool worker throw (uncaught execute rejection) | RECOVER | no | yes | no | no | N/A | No error-manager callback, so recovery did not start. |
| d. TaskPool worker throw (uncaught execute rejection) | SDK-initialized-only | no | yes | no | no | N/A | SDK observer was not called; no SDK error/crash report was logged. |
| e. Native crash (`libentry.so` SIGSEGV) | OFF | yes | N/A | yes | no | N/A | Process died with `SIGSEGV`; replayed fault was `APP_CRASH` / `NativeCrash`. |
| e. Native crash (`libentry.so` SIGSEGV) | OBSERVE_ONLY | yes | N/A | yes | no | N/A | Native signal bypassed the ArkTS observer and killed the process. |
| e. Native crash (`libentry.so` SIGSEGV) | RECOVER | yes | N/A | yes | no | N/A | `RESTART_WHEN_JS_CRASH` did not restart a native crash; no recovery callback ran. |
| e. Native crash (`libentry.so` SIGSEGV) | SDK-initialized-only | yes | N/A | yes | no | N/A | SDK error observer did not intercept the signal; the next launch replayed `NativeCrash`. |

## Questions and conclusions

### Q1. Does the app auto-exit after an uncaught exception with and without an `errorManager.on('error')` observer?

Compare each trigger across `OFF`, `OBSERVE_ONLY`, and `SDK-initialized-only`. Note any trigger types that bypass the main-thread observer, especially TaskPool and native crashes.

**Conclusion:** On this API 24 emulator, an unobserved main-thread synchronous or asynchronous ArkTS exception terminated the process. Registering either the spike observer or the existing SDK observer suppressed that termination for those two trigger types. Direct rejected Promises and the uncaught TaskPool execute result neither terminated the process nor reached the error observer. Native `SIGSEGV` always terminated the process and bypassed the ArkTS observer.


### Q2. If the observer callback does not exit, what state is the app left in? Is the UI still interactive?

Use the post-crash interactivity probe in every `OBSERVE_ONLY` row where the process remains visible. Record whether repeated taps work and whether other controls still respond.

**Conclusion:** The same process and UI remained interactive after observed synchronous and asynchronous exceptions; the probe counter incremented successfully. This demonstrates continued event-loop operation, not a guarantee that arbitrary application state is valid after an uncaught exception.


### Q3. After `appRecovery.restartApp()`, does `hiAppEvent` still record an `APP_CRASH` fault?

Compare `RECOVER` with `OFF` for the same ArkTS trigger. Record the fault name/subtype and timestamp so it can be matched to the pre-restart `FCSpike` log and launch counter.

**Conclusion:** Yes. Both recovered ArkTS cases produced a replayed `APP_CRASH` with subtype `JsError` even though `appRecovery.restartApp()` launched a replacement process.


### Q4. What restore granularity does `appRecovery` state saving provide?

Record whether the recovery launch returns to the Index page, whether the `APP_RECOVERY` launch reason is logged, and whether the banner contains the marker and timestamp written by `onSaveState`.

**Conclusion:** `onSaveState` ran and `saveAppState` returned `true`, but the emulator relaunched with reason `1` and without the saved marker/timestamp payload. The page was opened again, but state restoration was not observed. API 12 physical-device validation is required before concluding whether this is a platform difference or a harness expectation mismatch.


## Decision needed

### Existing SDK observer behavior

- Does initializing the existing SDK already suppress host-app auto-exit for any or all ArkTS trigger types?
- If yes, must the SDK explicitly restore termination semantics when soft landing is disabled?

**Decision:** The existing SDK observer is not semantically inert: SDK initialization changes host termination behavior for synchronous and asynchronous ArkTS exceptions. If soft landing is disabled, prefer not registering a suppressing error observer; otherwise the SDK must explicitly preserve the host's termination semantics. Do not finalize the production behavior until the API 12 real-device matrix confirms the emulator result.


### Deduplication strategy

- If a recovery restart still produces a replayed `APP_CRASH`, which stable fields can correlate the synchronous pre-restart report with the next-launch `hiAppEvent` fault?
- If no `APP_CRASH` is recorded after recovery, what durable fallback record is required for upload and diagnosis?

**Decision:** Deduplication is required. One ArkTS exception invoked both `onUnhandledException` and `onException`, and the SDK crash watcher subsequently received the corresponding `APP_CRASH`, producing three report paths. Collapse the two live callbacks with an in-process fingerprint over normalized name/message/stack plus a short time window. Persist an SDK-generated incident ID and fingerprint before restart, then correlate the next fault by bundle, crash subtype, normalized exception fingerprint, and timestamp window. `app_running_unique_id` is stable in the `hiAppEvent` fault and can deduplicate replayed system faults, but it is not present in the live error-manager callback payload, so it cannot by itself join the pre-restart and post-restart reports.
