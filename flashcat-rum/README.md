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

## Automatic error capture

RUM registers both `errorManager.on('error')` and
`errorManager.on('unhandledRejection')`. The error observer captures uncaught
main-thread ArkTS exceptions. Unhandled Promise rejections are reported as
ordinary, non-crashing RUM errors with `error.source_type: promise`; they do not
enter the crash-policy path.

## Crash policies

When `@flashcatcloud/crash` is enabled, that module governs the behavior of
uncaught main-thread ArkTS exceptions. See the
[crash module documentation](../flashcat-crash/README.md) for
`REPORT_THEN_EXIT`, `REPORT_AND_RECOVER`, and `OBSERVE_ONLY`.

`REPORT_THEN_EXIT` is now the default. This is a behavior change: initializing
the SDK previously suppressed the host app's exit after an uncaught ArkTS
exception. The default now reports synchronously and restores exit semantics.

## License

Apache-2.0
