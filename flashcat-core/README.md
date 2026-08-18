# @flashcatcloud/core

FlashCat HarmonyOS SDK core package.

This package provides SDK initialization, configuration, context collection,
message bus, local persistence, batched upload, and privacy consent primitives
used by the feature packages.

## Install

```sh
ohpm install @flashcatcloud/core
```

## Usage

```ts
import { Flashcat, ConfigurationBuilder, FlashcatSite, TrackingConsent } from '@flashcatcloud/core';

const config = new ConfigurationBuilder('<client-token>', 'prod')
  .useSite(FlashcatSite.CN)
  .setService('my-harmony-app')
  .build();

Flashcat.initialize(context, config, TrackingConsent.GRANTED);
```

## Permissions

Declare in your app's `module.json5` (`requestPermissions`):

- `ohos.permission.INTERNET` — required; uploads fail without it.
- `ohos.permission.GET_NETWORK_INFO` — optional but recommended; without it the
  `connectivity` context on every event degrades to `maybe` (unknown) instead of
  the real network status/interfaces.

## Upload pacing

Event uploads share the uplink with the app's own requests. On a narrow
connection that competition is measurable, so three settings control how much
airtime the SDK takes. They are the same three the Android, iOS, and Flutter
SDKs expose, with the same names and the same values — tuning advice transfers
between platforms unchanged.

```ts
import { UploadFrequency, BatchSize, BatchProcessingLevel } from '@flashcatcloud/core';

const config = new ConfigurationBuilder('<client-token>', 'prod')
  .setUploadFrequency(UploadFrequency.RARE)              // default AVERAGE
  .setBatchSize(BatchSize.LARGE)                         // default MEDIUM
  .setBatchProcessingLevel(BatchProcessingLevel.LOW)     // default MEDIUM
  .build();
```

| Setting | Cases | Default |
|---|---|---|
| `setUploadFrequency` | `FREQUENT` 500 ms · `AVERAGE` 2 s · `RARE` 5 s | `AVERAGE` |
| `setBatchSize` | `SMALL` 3 s · `MEDIUM` 10 s · `LARGE` 35 s | `MEDIUM` |
| `setBatchProcessingLevel` | `LOW` 1 · `MEDIUM` 20 · `HIGH` 100 batches per cycle | `MEDIUM` |

- **`setBatchSize`** is how long the active batch collects events before it is
  rolled and becomes drainable. Larger packs more events into each request and
  compresses better, so the same events cost fewer bytes. The cost is latency: an
  event can wait this long before it is eligible to ship (`Flashcat.flush()` and
  backgrounding still roll it early).
- **`setBatchProcessingLevel`** is how many batches ship back-to-back before the
  cycle yields for one interval. This is what bounds a burst: at `HIGH`, a
  backlog built up while offline drains in one near-uninterrupted run.

**If the app has latency-sensitive requests on a narrow uplink**, set
`BatchProcessingLevel.LOW` and `BatchSize.LARGE`.

**If uploads must not overlap one specific operation at all**, pacing is not
enough — a cycle already in flight cannot be recalled. Gate uploads instead:
`Flashcat.setTrackingConsent(TrackingConsent.PENDING)` stops every drain and
buffers new events; `GRANTED` migrates the buffer back and resumes. Keep the
pause short — the buffer is capped at 4 MB and evicts its oldest half when full.
Do not use `NOT_GRANTED` for this: it wipes collected data rather than buffering.

**If event volume itself is the problem**, pacing only redistributes bytes.
Reduce events at the source with `RumConfigurationBuilder`'s
`setSessionSampleRate` (drops whole sessions before anything is written) or
`setEventMapper` returning `null` (drops individual events before they reach
disk).

> The cross-process claim guard waits out the largest supported batch window
> before touching a batch another process created, so a configuration mismatch
> between the two processes cannot lose data. Building the configuration once
> and sharing it is still the recommended shape — see below.

## Deferred upload (optional, background delivery)

Uploads normally happen while the app runs. To also deliver batches when the
system grants background time (charging / Wi-Fi windows), declare a
`WorkSchedulerExtensionAbility` and point the SDK at it:

```ts
// main process init
const config = new ConfigurationBuilder('<client-token>', 'prod')
  .setDeferredUploadWork('UploadExtAbility')   // ability name from module.json5
  .build();
Flashcat.initialize(context, config, TrackingConsent.PENDING);
```

```ts
// UploadExtAbility.ets — the extension runs in a SEPARATE process
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { Flashcat } from '@flashcatcloud/core';

export default class UploadExtAbility extends WorkSchedulerExtensionAbility {
  async onWorkStart(_work: workScheduler.WorkInfo): Promise<void> {
    // NOT plain initialize: this entry point acts only on the user's last
    // persisted consent decision and never writes consent/identity back.
    Flashcat.initializeForDeferredUpload(this.context, buildTheSameConfig());
    await Flashcat.flushAndWait();
  }
  onWorkStop(_work: workScheduler.WorkInfo): void {}
}
```

The persisted job is registered only while consent is GRANTED and is cancelled
on revocation and on SDK stop.

## License

Apache-2.0
