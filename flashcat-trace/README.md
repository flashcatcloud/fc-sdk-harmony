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
// Pass the target URL so the firstPartyHosts allow-list is applied; calling
// getHeaders() without a URL skips that gate (the caller takes responsibility).
const headers = FlashcatTrace.getHeaders('https://api.example.com');
```

## Instrumenting another network stack

`rcp` and `@kit.NetworkKit` are covered by the interceptor and by
`FlashcatHttp`. Anything else — axios, a custom client, a WebSocket handshake —
goes through `startTracedResource`, which registers the RUM resource and returns
the headers to send:

```ts
import { FlashcatTrace, TracedResource } from '@flashcatcloud/trace';

const traced: TracedResource = FlashcatTrace.startTracedResource(url, 'GET');
// merge traced.headers into the request, then send it
try {
  const response = await send(url, traced.headers);
  FlashcatTrace.stopTracedResource(traced.key, response.status, response.size);
} catch (e) {
  // A response with an error status is not a failure — pass it to
  // stopTracedResource so it stays a resource carrying that status. Only a
  // request that never got a response belongs here.
  FlashcatTrace.failTracedResource(traced.key, `${e}`);
}
```

Notes:

- Pass the **full** url. A relative path has no host to match against
  `setFirstPartyHosts()`, so nothing would be injected and the resource would be
  reported without a host.
- `headers` is empty when consent is not GRANTED or the host is not
  first-party. The resource is still tracked — send the request either way.
- Pass `injectTrace: false` when the request already carries a `traceparent`;
  it belongs to an existing trace, and generating a second context would both
  break the caller's chain and tie the resource to a trace never sent.
- Always close the resource, including on the failure path, or it stays open.
- Resources reach RUM through the same path as the interceptor and
  `FlashcatHttp`, so this requires `setTrackNetworkRequests(true)`.

## License

Apache-2.0
