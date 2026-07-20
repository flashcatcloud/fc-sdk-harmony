# Phase 0 Crash Soft-Landing Semantics Spike

## Test environment

- Device model:
- ROM / HarmonyOS version:
- API level:
- SDK repository commit:
- Date:
- Tester:

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
| a. Main-thread synchronous throw | OFF |  |  |  |  |  |  |
| a. Main-thread synchronous throw | OBSERVE_ONLY |  |  |  |  |  |  |
| a. Main-thread synchronous throw | RECOVER |  |  |  |  |  |  |
| a. Main-thread synchronous throw | SDK-initialized-only |  |  |  |  |  |  |
| b. Async callback throw (`setTimeout(0)`) | OFF |  |  |  |  |  |  |
| b. Async callback throw (`setTimeout(0)`) | OBSERVE_ONLY |  |  |  |  |  |  |
| b. Async callback throw (`setTimeout(0)`) | RECOVER |  |  |  |  |  |  |
| b. Async callback throw (`setTimeout(0)`) | SDK-initialized-only |  |  |  |  |  |  |
| c. Unhandled Promise rejection | OFF |  |  |  |  |  |  |
| c. Unhandled Promise rejection | OBSERVE_ONLY |  |  |  |  |  |  |
| c. Unhandled Promise rejection | RECOVER |  |  |  |  |  |  |
| c. Unhandled Promise rejection | SDK-initialized-only |  |  |  |  |  |  |
| d. TaskPool worker throw (uncaught execute rejection) | OFF |  |  |  |  |  |  |
| d. TaskPool worker throw (uncaught execute rejection) | OBSERVE_ONLY |  |  |  |  |  |  |
| d. TaskPool worker throw (uncaught execute rejection) | RECOVER |  |  |  |  |  |  |
| d. TaskPool worker throw (uncaught execute rejection) | SDK-initialized-only |  |  |  |  |  |  |
| e. Native crash (`libentry.so` SIGSEGV) | OFF |  |  |  |  |  |  |
| e. Native crash (`libentry.so` SIGSEGV) | OBSERVE_ONLY |  |  |  |  |  |  |
| e. Native crash (`libentry.so` SIGSEGV) | RECOVER |  |  |  |  |  |  |
| e. Native crash (`libentry.so` SIGSEGV) | SDK-initialized-only |  |  |  |  |  |  |

## Questions and conclusions

### Q1. Does the app auto-exit after an uncaught exception with and without an `errorManager.on('error')` observer?

Compare each trigger across `OFF`, `OBSERVE_ONLY`, and `SDK-initialized-only`. Note any trigger types that bypass the main-thread observer, especially TaskPool and native crashes.

**Conclusion:**


### Q2. If the observer callback does not exit, what state is the app left in? Is the UI still interactive?

Use the post-crash interactivity probe in every `OBSERVE_ONLY` row where the process remains visible. Record whether repeated taps work and whether other controls still respond.

**Conclusion:**


### Q3. After `appRecovery.restartApp()`, does `hiAppEvent` still record an `APP_CRASH` fault?

Compare `RECOVER` with `OFF` for the same ArkTS trigger. Record the fault name/subtype and timestamp so it can be matched to the pre-restart `FCSpike` log and launch counter.

**Conclusion:**


### Q4. What restore granularity does `appRecovery` state saving provide?

Record whether the recovery launch returns to the Index page, whether the `APP_RECOVERY` launch reason is logged, and whether the banner contains the marker and timestamp written by `onSaveState`.

**Conclusion:**


## Decision needed

### Existing SDK observer behavior

- Does initializing the existing SDK already suppress host-app auto-exit for any or all ArkTS trigger types?
- If yes, must the SDK explicitly restore termination semantics when soft landing is disabled?

**Decision:**


### Deduplication strategy

- If a recovery restart still produces a replayed `APP_CRASH`, which stable fields can correlate the synchronous pre-restart report with the next-launch `hiAppEvent` fault?
- If no `APP_CRASH` is recorded after recovery, what durable fallback record is required for upload and diagnosis?

**Decision:**
