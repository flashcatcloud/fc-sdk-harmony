# @flashcatcloud/rum

FlashCat HarmonyOS RUM package.

This package provides RUM sessions, views, actions, resources, errors, and event
mapping support. It depends on `@flashcatcloud/core`.

## Install

```sh
ohpm install @flashcatcloud/rum
```

## Usage

```ts
import { FlashcatRum, RumConfigurationBuilder } from '@flashcatcloud/rum';

const rumConfig = new RumConfigurationBuilder('<application-id>')
  .setTrackUserInteractions(true)
  .setTrackNetworkRequests(true)
  .build();

FlashcatRum.enable(rumConfig);
FlashcatRum.startView('home', 'Home');
```

## License

Apache-2.0
