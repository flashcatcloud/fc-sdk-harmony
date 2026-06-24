# @flashcatcloud/crash

FlashCat HarmonyOS crash reporting package.

This package captures HarmonyOS `hiAppEvent` crash and freeze reports and
publishes them into the SDK pipeline as crash error events. It depends on
`@flashcatcloud/core`.

## Install

```sh
ohpm install @flashcatcloud/crash
```

## Usage

```ts
import { FlashcatCrash, CrashConfigurationBuilder } from '@flashcatcloud/crash';

const crashConfig = new CrashConfigurationBuilder()
  .setTrackCrashes(true)
  .setTrackAppHangs(true)
  .build();

FlashcatCrash.enable(crashConfig);
```

## License

Apache-2.0
