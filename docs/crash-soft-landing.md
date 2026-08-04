# Crash soft landing: design and verification

This document describes the implementation boundary and evidence for the
HarmonyOS JS crash-policy path. Read it before changing crash observation,
persistence, replay, deduplication, or process termination.

## Problem

HarmonyOS `errorManager` is a notification API. Registering
`errorManager.on('error')` observes an uncaught ArkTS exception after it has
escaped; it does not provide a replacement event-loop hook in which the SDK can
repair arbitrary application state and continue safely. On the verified
runtime, installing the observer also suppresses the platform's normal exit.

Therefore a Bugly-style "anti-crash" promise that catches any failure and keeps
the same process healthy is not implementable for HarmonyOS. CrashSight parity
is limited to crash observation and reporting. For supported main-thread ArkTS
exceptions, HarmonyOS `appRecovery` provides the closest safe soft landing:
persist the report synchronously, terminate the damaged process, and optionally
start a new one. Native signals remain outside this path.

## Architecture

Ownership is split across three modules:

| Module | Responsibility |
|---|---|
| `flashcat-crash` | Owns `JsCrashPolicy`, pending-incident orchestration, live and cross-launch deduplication, crash-loop decisions, and `hiAppEvent` crash/freeze mapping. |
| `flashcat-rum` | Owns the `errorManager` observers, converts errors into RUM events, and is the termination point that flushes before `ProcessManager.exit()` or `saveAppState()` + `restartApp()`. |
| `flashcat-core` | Owns `CrashPendingStore`, the synchronous filesystem receiver registered on the message bus. It stores pending incidents, consumed fingerprints, and loop history outside normal upload batches. |

### Control-event flow

The control path uses synchronous message-bus events and a mutable event record
for the crash module's decision:

1. On startup, crash sends `js_crash_policy` to RUM. RUM keeps its legacy
   observe-and-report behavior if no crash-module owner announces a policy.
2. RUM's `onUnhandledException` or `onException` callback sends
   `js_crash_callback` to crash with the callback kind, error text, and
   timestamp.
3. Crash returns control fields on the same record: `fingerprint`,
   `duplicate`, `report_async`, `should_exit`, and `recover`.
4. For `REPORT_*`, crash sends synchronous `crash_storage_*` commands to the
   core-owned store:
   - `crash_storage_write`, `crash_storage_list`, and
     `crash_storage_delete` manage pending incidents;
   - `crash_storage_read_consumed` and `crash_storage_write_consumed` manage
     the cross-launch dedup sidecar; and
   - `crash_storage_read_loop` and `crash_storage_write_loop` manage restart
     history.
5. RUM follows the returned decision. It uses asynchronous reporting only as a
   fallback, flushes current writers, then exits or asks `appRecovery` to save
   state and restart.
6. On a later launch, crash lists pending incidents, maps each one to a
   `crash_report`, sends it to RUM, records it as consumed, and deletes the
   pending file.

The durable pending file is the delivery source across process termination.
Flushing does not make the asynchronous uploader part of the crash-time
guarantee.

## Three-path deduplication

One uncaught ArkTS exception can produce three report paths:

1. `errorManager.onUnhandledException`;
2. `errorManager.onException`; and
3. the later `hiAppEvent.APP_CRASH` replay.

The first callback creates a normalized fingerprint and stores it in a
two-second in-process guard. A matching second callback inside that window is
suppressed. `onException` remains an asynchronous fallback on platform builds
where it is the only callback.

For a `REPORT_*` incident, the synchronously persisted record is replayed once
on the next launch. After replay, crash writes its incident ID, fingerprint, and
timestamp to the consumed sidecar. A matching JS `APP_CRASH` within the
30-second correlation window is then skipped. Consumed entries are retained
for 24 hours so delayed watcher delivery does not reintroduce the event. The
result is one crash error event in the pipeline for one policy-managed crash.

The fingerprint uses normalized exception name, message, and first stack frame.
It removes path and line/column differences that are unstable across the live
and system payloads.

### Labeled-text parsing pitfall

`onUnhandledException` supplies text shaped like:

```text
Error name:Error
Error message:example
Stacktrace:
...
```

The first implementation treated `Error name:Error` as a conventional error
header. Its live fingerprint therefore differed from the field-wise
`hiAppEvent` fingerprint, and the system replay was not suppressed. The parser
now recognizes the labeled name/message format explicitly before applying the
generic header heuristic. A parity regression test covers this case.

## Crash-loop guard

The restart guard stores crash timestamps synchronously in `loop.json`. Before
requesting a recovery restart, crash:

1. clears prior history only if the newest recorded crash is at least the
   configured cooldown old;
2. if the retained history has already reached the threshold, keeps the guard
   tripped and appends the current blocked crash without applying the rolling
   window;
3. otherwise removes entries outside the configured rolling window and appends
   the current crash; and
4. permits restart only if that updated count remains below the threshold.

With the defaults, crashes one and two inside 60 seconds restart, while crash
three logs:

```text
crash.loop: threshold reached (3 in 60s); degrading to exit
```

History is not cleared when the threshold trips. Clearing it would allow the
next cold launch to restart immediately and recreate the loop. Instead, each
blocked crash becomes the newest timestamp and recovery remains disabled until
the app stays crash-free for the full five-minute cooldown. Failure to persist
loop history also degrades to exit.

## Emulator verification summary

All runtime results below are from an API 24 emulator. They are not
physical-device evidence.

### Phase 1: synchronous reporting and exit semantics

- Uncaught main-thread synchronous and asynchronous ArkTS exceptions reached
  `onUnhandledException` followed by `onException`.
- `REPORT_THEN_EXIT` synchronously wrote the pending incident, flushed, and
  restored process exit semantics.
- The next launch replayed the pending incident into RUM.
- The live callback pair and later `APP_CRASH` were correlated so the
  policy-managed crash produced one crash error event.
- Unhandled Promise rejections were captured separately as non-crashing RUM
  errors with `error.source_type: promise`.

### Phase 2: recovery and loop protection

- `REPORT_AND_RECOVER` wrote the incident before termination, called
  `saveAppState()` and `restartApp()`, and launched a new process.
- Under SDK orchestration, a host `onSaveState` implementation ran and its
  `wantParam` state was observed after restart. This is best-effort behavior and
  remains a host-app responsibility.
- The replayed incident appeared in the local RUM batch with
  `crash.recovered: true`.
- Repeated crashes tripped the default guard on the third crash. HiLog included
  `crash.loop: threshold reached (3 in 60s); degrading to exit`, and that
  attempt exited instead of restarting.

The earlier [Phase 0 platform spike](spike-phase0-crash-semantics.md) did not
observe restored state in its standalone harness. The later Phase 2 result is
specific to the final SDK orchestration and does not remove the need for the
real-device matrix.

## Known limitations and future work

- The complete real-device and supported-ROM matrix is pending; current runtime
  verification covers only an API 24 emulator.
- Hypium unit suites compile from the command line, but CLI execution still
  requires a device or emulator.
- End-to-end staging ingestion was blocked by HTTP 401. Verification inspected
  local persistence, logs, and the generated RUM batch rather than a successful
  backend intake.
- TaskPool and Worker throws did not reach the error observer in the verified
  cases and are not covered by the policy path.
- Native C/C++ signal crashes cannot be prevented or restarted by these
  policies. They remain post-mortem `hiAppEvent.APP_CRASH` reports.
- `APP_FREEZE` remains post-mortem capture only.
