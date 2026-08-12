# @flashcatcloud/axios

FlashCat HarmonyOS integration for [`@ohos/axios`](https://ohpm.openharmony.cn/#/cn/detail/@ohos%2Faxios).

`@ohos/axios` sends requests through its own `@ohos.net.http` adapter, which
neither the rcp interceptor nor `FlashcatHttp` can observe. This package
registers axios interceptors that report each request as a RUM resource and
attach the distributed-trace headers.

## Install

```sh
ohpm install @flashcatcloud/axios
```

## Usage

```ts
import axios from '@ohos/axios';
import { trackAxios } from '@flashcatcloud/axios';

const api = axios.create({ baseURL: 'https://api.example.com' });
trackAxios(api);
```

That is the whole integration. Requests through `api` now appear as RUM
resources, carrying `traceparent` for correlation with the server-side trace.

## Notes

- Interceptors are registered **per instance**: the default `axios` export and
  anything from `axios.create()` do not share them. Track each instance whose
  requests should appear in RUM, and track it exactly once — registering twice
  reports every request twice.
- Requires `FlashcatTrace.enable(...)`, and `FlashcatRum.enable(...)` with
  `setTrackNetworkRequests(true)` for the resources to surface.
- `traceparent` is injected only when tracking consent is GRANTED and the host
  matches `setFirstPartyHosts()`. A request that already carries a
  `traceparent` keeps it — the existing trace is not overwritten.
- A response with an error status stays a resource carrying that status. Only a
  request that never received a response is reported as a network error.

## License

Apache-2.0
