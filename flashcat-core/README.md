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
