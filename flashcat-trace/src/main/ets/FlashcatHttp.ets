import { http } from '@kit.NetworkKit';
import { TraceContext } from './internal/TraceContext';
import {
  contentTypeOf, shouldInjectTraceHeaders, headerStringValue, setHeaderValue
} from './internal/TraceInterceptor';
import { FlashcatTrace } from './FlashcatTrace';
import { TracedResource } from './TracedResource';

/**
 * Drop-in `@ohos.net.http` wrapper that reports the request as a RUM resource
 * and injects a W3C `traceparent`, with no interceptor wiring. Use it exactly
 * like `http.createHttp().request(...)`:
 *
 * ```ets
 * const resp = await FlashcatHttp.request('https://api.example.com/items', {
 *   method: http.RequestMethod.GET
 * });
 * ```
 *
 * All of the resource and trace behaviour — consent and first-party gating,
 * sampled-only correlation, the event the RUM feature turns into a resource —
 * belongs to {@link FlashcatTrace.startTracedResource}. What this wrapper adds
 * is the request itself: it copies the returned headers onto the options,
 * never throws beyond the underlying request's own error, and always destroys
 * the HttpRequest handle.
 *
 * Requires `FlashcatTrace.enable(...)` and, for resources to surface,
 * `FlashcatRum.enable(...)` with `setTrackNetworkRequests(true)`.
 */
export class FlashcatHttp {
  static async request(reqUrl: string, options?: http.HttpRequestOptions): Promise<http.HttpResponse> {
    const opts: http.HttpRequestOptions = options ?? {};
    const method: string = FlashcatHttp.methodOf(opts);

    // The resource lifecycle and the consent / first-party gating live in
    // startTracedResource — this wrapper only adds the @kit.NetworkKit call and
    // copies the returned headers onto it.
    const traced: TracedResource =
      FlashcatTrace.startTracedResource(reqUrl, method, shouldInjectTraceHeaders(opts.header));
    if (Object.keys(traced.headers).length > 0) {
      const header: Record<string, Object> = FlashcatHttp.headerRecord(opts);
      setHeaderValue(header, 'traceparent', traced.headers['traceparent']);
      // Preserve other vendors already present on the request.
      setHeaderValue(header, 'tracestate', TraceContext.mergeDatadogTracestate(
        headerStringValue(header, 'tracestate'), traced.headers['tracestate']));
      opts.header = header;
    }

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(reqUrl, opts);
      FlashcatTrace.stopTracedResource(traced.key, FlashcatHttp.statusOf(response),
        FlashcatHttp.sizeOf(response), contentTypeOf(response.header));
      return response;
    } catch (e) {
      FlashcatTrace.failTracedResource(traced.key, e instanceof Error ? e.message : 'network request failed');
      throw (e instanceof Error ? e : new Error('network request failed'));
    } finally {
      httpRequest.destroy();
    }
  }

  private static methodOf(opts: http.HttpRequestOptions): string {
    return opts.method !== undefined ? `${opts.method}` : 'GET';
  }

  private static headerRecord(opts: http.HttpRequestOptions): Record<string, Object> {
    if (opts.header !== undefined) {
      return opts.header as Record<string, Object>;
    }
    return {};
  }

  private static statusOf(response: http.HttpResponse): number {
    return response.responseCode as number;
  }

  private static sizeOf(response: http.HttpResponse): number {
    const result: string | Object | ArrayBuffer = response.result;
    if (result instanceof ArrayBuffer) {
      return result.byteLength;
    }
    if (typeof result === 'string') {
      return result.length;
    }
    return 0;
  }
}
