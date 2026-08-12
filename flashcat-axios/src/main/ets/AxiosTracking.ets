import { AxiosInstance, InternalAxiosRequestConfig, AxiosResponse, AxiosError } from '@ohos/axios';
import { FlashcatTrace, TracedResource } from '@flashcatcloud/trace';

/**
 * Resource keys of in-flight requests, keyed by the axios request config.
 * axios hands the very same config object back on `response.config` and
 * `error.config`, which makes it a reliable join key across the two
 * interceptors.
 */
const pending: Map<Object, string> = new Map();

/**
 * Reports every request made through `instance` as a RUM resource, with the
 * distributed-trace headers attached.
 *
 * ```ets
 * import axios from '@ohos/axios';
 * import { trackAxios } from '@flashcatcloud/axios';
 *
 * const api = axios.create({ baseURL: 'https://api.example.com' });
 * trackAxios(api);
 * ```
 *
 * Interceptors are registered per instance: the default `axios` export and
 * anything from `axios.create()` do not share them. Track each instance whose
 * requests should appear in RUM, and track it exactly once — registering twice
 * reports every request twice.
 *
 * Requires `FlashcatTrace.enable(...)` and, for resources to surface,
 * `FlashcatRum.enable(...)` with `setTrackNetworkRequests(true)`.
 */
export function trackAxios(instance: AxiosInstance): void {
  instance.interceptors.request.use((config: InternalAxiosRequestConfig) => {
    // A request interceptor sees `config.url` as the relative path — axios
    // joins it with `baseURL` further down, inside the adapter. Resolving it
    // here is what lets the first-party host check match, and what puts a full
    // url on the resource instead of a bare path.
    const url: string = fullUrlOf(config);
    // An inbound traceparent means this request already belongs to a trace.
    const traced: TracedResource = FlashcatTrace.startTracedResource(
      url, config.method ?? 'GET', !config.headers.has('traceparent'));

    for (const name of Object.keys(traced.headers)) {
      config.headers.set(name, traced.headers[name]);
    }
    pending.set(config, traced.key);
    return config;
  });

  instance.interceptors.response.use(
    (response: AxiosResponse) => {
      const key: string = takeKey(response.config);
      if (key.length > 0) {
        FlashcatTrace.stopTracedResource(key, response.status, sizeOf(response.data));
      }
      return response;
    },
    (error: AxiosError) => {
      // axios rejects on HTTP status, so this branch is not only transport
      // failures. A response means the request completed, so it stays a
      // resource carrying that status — matching how the rcp interceptor and
      // FlashcatHttp report a 404. Only a request that never got a response
      // becomes a network error.
      const key: string = takeKey(error.config);
      if (key.length > 0) {
        const response: AxiosResponse | undefined = error.response;
        if (response !== undefined) {
          FlashcatTrace.stopTracedResource(key, response.status, sizeOf(response.data));
        } else {
          FlashcatTrace.failTracedResource(key, error.message);
        }
      }
      return Promise.reject(error);
    }
  );
}

/**
 * The url axios will actually request: `baseURL` joined with the per-request
 * path, unless the path is already absolute.
 *
 * @internal — exported for tests.
 */
export function fullUrlOf(config: InternalAxiosRequestConfig): string {
  const url: string = config.url ?? '';
  const base: string = config.baseURL ?? '';
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return url;
  }
  if (base.length === 0) {
    return url;
  }
  if (url.length === 0) {
    return base;
  }
  const left: string = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  const right: string = url.startsWith('/') ? url.substring(1) : url;
  return `${left}/${right}`;
}

/** Consumes the pending key for `config`; returns '' when there is none. */
function takeKey(config: Object | undefined): string {
  if (config === undefined) {
    return '';
  }
  const key: string | undefined = pending.get(config);
  if (key === undefined) {
    return '';
  }
  pending.delete(config);
  return key;
}

/**
 * Best-effort response size — axios exposes the decoded body, not the bytes
 * that came off the wire.
 *
 * @internal — exported for tests.
 */
export function sizeOf(data: Object | undefined): number {
  if (data instanceof ArrayBuffer) {
    return data.byteLength;
  }
  if (typeof data === 'string') {
    return data.length;
  }
  if (data !== undefined && data !== null) {
    try {
      return JSON.stringify(data).length;
    } catch (_e) {
      return 0;
    }
  }
  return 0;
}
