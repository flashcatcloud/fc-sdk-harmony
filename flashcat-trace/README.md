# @flashcatcloud/trace

FlashCat HarmonyOS trace propagation package.

This package provides W3C `traceparent` generation, manual tracing headers, and
an RCP interceptor for distributed trace propagation. It depends on
`@flashcatcloud/core`.

## Install

```sh
ohpm install @flashcatcloud/trace
```

## Usage

```ts
import { FlashcatTrace, TraceConfigurationBuilder } from '@flashcatcloud/trace';

const traceConfig = new TraceConfigurationBuilder()
  .setSampleRate(100)
  .build();

FlashcatTrace.enable(traceConfig);
const headers = FlashcatTrace.getHeaders('https://api.example.com');
```

## License

Apache-2.0
