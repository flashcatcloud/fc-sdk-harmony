import { AxiosInstance, InternalAxiosRequestConfig, AxiosResponse, AxiosError } from '@ohos/axios';
import { FlashcatLog } from '@flashcatcloud/core';
import { FlashcatTrace, TracedResource } from '@flashcatcloud/trace';

/**
 * Resource keys of in-flight requests, keyed by the axios request config.
 * axios hands the very same config object back on `response.config` and
 * `error.config`, which makes it a reliable join key across the two
 * interceptors.
 */
const pending: Map<Object, string> = new Map();
/**
 * A config that never comes back (another interceptor swapped it, or an error
 * carries none) would otherwise stay here, holding the request body, forever.
 */
const MAX_PENDING: number = 256;

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
  try {
    registerInterceptors(instance);
  } catch (error) {
    // Not an axios instance (null, or an untyped caller's stand-in): nothing is tracked.
    FlashcatLog.usage(`trackAxios ignored: ${error instanceof Error ? error.message : 'not an axios instance'}`);
  }
}

function registerInterceptors(instance: AxiosInstance): void {
  // These interceptors sit on the host's requests: telemetry may fail, but the
  // config, the response and the rejection always pass through unchanged.
  instance.interceptors.request.use((config: InternalAxiosRequestConfig) => {
    try {
      // A request interceptor sees `config.url` as the relative path — axios
      // joins it with `baseURL` further down, inside the adapter. Resolving it
      // here is what lets the first-party host check match, and what puts a full
      // url on the resource instead of a bare path.
      const url: string = fullUrlOf(config);
      // An inbound traceparent means this request already belongs to a trace.
      const traced: TracedResource = FlashcatTrace.startTracedResource(
        url, config.method ?? 'GET', !config.headers.has('traceparent'));

      // Remember first: the resource is open from here on, and a header write
      // that fails must not leave it with no way to be closed.
      if (traced.key.length > 0) {
        remember(config, traced.key);
      }
      for (const name of Object.keys(traced.headers)) {
        config.headers.set(name, traced.headers[name]);
      }
    } catch (error) {
      logFailure('request', error);
    }
    return config;
  });

  instance.interceptors.response.use(
    (response: AxiosResponse) => {
      try {
        const key: string = takeKey(response.config);
        if (key.length > 0) {
          FlashcatTrace.stopTracedResource(key, response.status, sizeOf(response));
        }
      } catch (error) {
        logFailure('response', error);
      }
      return response;
    },
    (error: AxiosError) => {
      try {
        // axios rejects on HTTP status, so this branch is not only transport
        // failures. A response means the request completed, so it stays a
        // resource carrying that status — matching how the rcp interceptor and
        // FlashcatHttp report a 404. Only a request that never got a response
        // becomes a network error.
        const key: string = takeKey(error.config);
        if (key.length > 0) {
          const response: AxiosResponse | undefined = error.response;
          if (response !== undefined) {
            FlashcatTrace.stopTracedResource(key, response.status, sizeOf(response));
          } else {
            FlashcatTrace.failTracedResource(key, error.message);
          }
        }
      } catch (telemetryError) {
        logFailure('error response', telemetryError);
      }
      return Promise.reject(error);
    }
  );
}

function remember(config: Object, key: string): void {
  if (pending.size >= MAX_PENDING) {
    // Evict the oldest (Map keeps insertion order). Usually its response never
    // came back; with more than MAX_PENDING requests truly in flight it may
    // still arrive, and that resource then stays open (RUM caps those per view).
    const oldest: IteratorResult<Object> = pending.keys().next();
    if (!oldest.done) {
      pending.delete(oldest.value);
    }
  }
  pending.set(config, key);
}

function logFailure(what: string, error: Object): void {
  FlashcatLog.e(`axios: ${what} telemetry failed: ${error instanceof Error ? error.message : 'error'}`);
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
 * Best-effort response size, without ever re-encoding the body: the
 * Content-Length header when present (the bytes that came off the wire),
 * else the length of a string / ArrayBuffer body, else 0. A parsed JSON body
 * is not serialized again just to be measured — on the response path that
 * cost the host a full copy and stringify of every payload.
 *
 * @internal — exported for tests.
 */
export function sizeOf(response: AxiosResponse): number {
  const declared: number = contentLengthOf(response);
  if (declared >= 0) {
    return declared;
  }
  const data: Object | undefined = response.data as Object | undefined;
  if (data instanceof ArrayBuffer) {
    return data.byteLength;
  }
  if (typeof data === 'string') {
    return data.length;
  }
  return 0;
}

/** The Content-Length header as a number, or -1 when absent or unreadable. */
function contentLengthOf(response: AxiosResponse): number {
  try {
    const headers: Record<string, Object> | undefined = response.headers as Object as Record<string, Object> | undefined;
    if (headers === undefined || headers === null) {
      return -1;
    }
    let value: Object | undefined = headers['content-length'] ?? headers['Content-Length'];
    if (value === undefined && typeof headers['get'] === 'function') {
      value = (headers['get'] as (name: string) => Object | undefined)('content-length');
    }
    const n: number = typeof value === 'number' ? value : (typeof value === 'string' ? Number(value) : NaN);
    return Number.isFinite(n) && n >= 0 ? n : -1;
  } catch (_e) {
    return -1;
  }
}
