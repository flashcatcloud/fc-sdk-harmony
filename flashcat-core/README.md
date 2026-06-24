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

## License

Apache-2.0
