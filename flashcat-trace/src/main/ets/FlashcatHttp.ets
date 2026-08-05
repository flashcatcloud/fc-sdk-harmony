import { http } from '@kit.NetworkKit';
import { TraceContext } from './internal/TraceContext';
import {
  hostOfUrl, contentTypeOf, shouldInjectTraceHeaders, headerStringValue, setHeaderValue
} from './internal/TraceInterceptor';
import { FlashcatTrace } from './FlashcatTrace';
import { TracedResource } from './TracedResource';

/**
 * Phase-2 A2: drop-in `@ohos.net.http` wrapper that auto-captures the request as
 * a RUM resource and injects a W3C `traceparent` — with NO manual interceptor
 * wiring. Use it exactly like `http.createHttp().request(...)`:
 *
 * ```ets
 * const resp = await FlashcatHttp.request('https://api.example.com/items', {
 *   method: http.RequestMethod.GET
 * });
 * ```
 *
 * Behaviour (see docs/PHASE-2-PLAN.md A2):
 * - emits `network_request_started/completed/failed` on the bus → the RUM feature
 *   turns them into a ResourceEvent (or a network ErrorEvent on failure);
 * - injects `traceparent`/`tracestate` only when consent is GRANTED, the host is
 *   first-party (TraceConfiguration.firstPartyHosts — empty = all hosts), and the
 *   request does not already carry a `traceparent`;
 * - never throws beyond the underlying request's own error; always destroys the
 *   HttpRequest handle.
 *
 * Requires `FlashcatTrace.enable(...)` (for trace context) and, for resources to
 * surface, `FlashcatRum.enable(...)` with `setTrackNetworkRequests(true)`.
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
    const names: string[] = Object.keys(traced.headers);
    if (names.length > 0) {
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

  /** Pure: extract the host from a URL (no @ohos.url dependency). */
  static hostOf(rawUrl: string): string {
    return hostOfUrl(rawUrl);
  }
}
