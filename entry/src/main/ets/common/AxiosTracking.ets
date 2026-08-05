/**
 * axios instrumentation built on `FlashcatTrace.startTracedResource` — the
 * network-stack-agnostic entry point.
 *
 * `@ohos/axios` sends requests through its own `@ohos.net.http` adapter, which
 * neither the rcp interceptor nor the `FlashcatHttp` wrapper observes. The
 * primitive registers the resource and hands back the trace headers, leaving
 * this file with only what is genuinely axios-shaped: resolving the url,
 * copying headers onto the request, and carrying the key between the two
 * interceptors.
 *
 * ```ets
 * const api = axios.create({ baseURL: 'https://api.example.com' });
 * trackAxios(api);
 * ```
 *
 * Requires `setTrackNetworkRequests(true)` on the RUM configuration — the
 * resource travels the same path as the rcp interceptor and FlashcatHttp.
 */
import { AxiosInstance, InternalAxiosRequestConfig, AxiosResponse, AxiosError } from '@ohos/axios';
import { FlashcatTrace, TracedResource } from '@flashcatcloud/trace';

/**
 * Resource keys of in-flight requests, keyed by the axios request config —
 * axios hands the same object back on `response.config` and `error.config`.
 */
const pending: Map<Object, string> = new Map();

/** Report every request made through `instance` as a RUM resource. */
export function trackAxios(instance: AxiosInstance): void {
  instance.interceptors.request.use((config: InternalAxiosRequestConfig) => {
    // A request interceptor sees the relative path; axios joins it with
    // `baseURL` inside the adapter. Without the host the first-party check
    // cannot match, and the resource would carry a path with no host.
    const url: string = fullUrlOf(config);
    // An inbound traceparent means this request already belongs to a trace.
    const traced: TracedResource = FlashcatTrace.startTracedResource(
      url, config.method ?? 'GET', !config.headers.has('traceparent'));

    const names: string[] = Object.keys(traced.headers);
    for (const name of names) {
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
      // failures. A response means the request completed and stays a resource
      // carrying that status; only a request that never got one is an error.
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

/** The url axios will actually request: `baseURL` joined with the path. */
function fullUrlOf(config: InternalAxiosRequestConfig): string {
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

/** Best-effort response size; axios exposes the decoded body, not raw bytes. */
function sizeOf(data: Object | undefined): number {
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
