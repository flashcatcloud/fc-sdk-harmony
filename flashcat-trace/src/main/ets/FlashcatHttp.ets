import { http } from '@kit.NetworkKit';
import { FlashcatLog } from '@flashcatcloud/core';
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
 * never throws beyond the underlying request's own error (passed through
 * unchanged), never writes into the caller's options, and always destroys
 * the HttpRequest handle.
 *
 * Requires `FlashcatTrace.enable(...)` and, for resources to surface,
 * `FlashcatRum.enable(...)` with `setTrackNetworkRequests(true)`.
 */
export class FlashcatHttp {
  static async request(reqUrl: string, options?: http.HttpRequestOptions): Promise<http.HttpResponse> {
    let opts: http.HttpRequestOptions = options ?? {};
    let resourceKey: string = '';
    // The request is the host's: telemetry may fail, but must never stop it,
    // fail it, or change the error the host sees.
    try {
      const method: string = FlashcatHttp.methodOf(opts);
      // The resource lifecycle and the consent / first-party gating live in
      // startTracedResource — this wrapper only adds the @kit.NetworkKit call and
      // copies the returned headers onto it.
      const traced: TracedResource =
        FlashcatTrace.startTracedResource(reqUrl, method, shouldInjectTraceHeaders(opts.header));
      resourceKey = traced.key;
      if (Object.keys(traced.headers).length > 0) {
        // Copy before writing: the host may reuse its options across requests,
        // and a traceparent left on them would be sent again (and block a fresh one).
        const header: Record<string, Object> = FlashcatHttp.headerCopy(opts);
        setHeaderValue(header, 'traceparent', traced.headers['traceparent']);
        // Preserve other vendors already present on the request.
        setHeaderValue(header, 'tracestate', TraceContext.mergeDatadogTracestate(
          headerStringValue(header, 'tracestate'), traced.headers['tracestate']));
        const copy: http.HttpRequestOptions = FlashcatHttp.optionsCopy(opts);
        copy.header = header;
        opts = copy;
      }
    } catch (error) {
      FlashcatHttp.logFailure('request start', error);
    }

    const httpRequest: http.HttpRequest = http.createHttp();
    let response: http.HttpResponse;
    try {
      response = await httpRequest.request(reqUrl, opts);
    } catch (e) {
      if (resourceKey.length > 0) {
        try {
          FlashcatTrace.failTracedResource(resourceKey, e instanceof Error ? e.message : 'network request failed');
        } catch (error) {
          FlashcatHttp.logFailure('request failure', error);
        }
      }
      throw e as Error; // the host's own error, unchanged
    } finally {
      httpRequest.destroy();
    }
    if (resourceKey.length > 0) {
      try {
        FlashcatTrace.stopTracedResource(resourceKey, FlashcatHttp.statusOf(response),
          FlashcatHttp.sizeOf(response), contentTypeOf(response.header));
      } catch (error) {
        FlashcatHttp.logFailure('request completion', error);
      }
    }
    return response;
  }

  private static logFailure(what: string, error: Object): void {
    FlashcatLog.e(`trace.http: ${what} telemetry failed: ${error instanceof Error ? error.message : 'error'}`);
  }

  private static optionsCopy(opts: http.HttpRequestOptions): http.HttpRequestOptions {
    const copy: Record<string, Object> = {};
    const source: Record<string, Object> = opts as Object as Record<string, Object>;
    for (const k of Object.keys(source)) {
      copy[k] = source[k];
    }
    return copy as Object as http.HttpRequestOptions;
  }

  private static methodOf(opts: http.HttpRequestOptions): string {
    return opts.method !== undefined ? `${opts.method}` : 'GET';
  }

  private static headerCopy(opts: http.HttpRequestOptions): Record<string, Object> {
    const copy: Record<string, Object> = {};
    if (opts.header !== undefined && opts.header !== null) {
      const source: Record<string, Object> = opts.header as Record<string, Object>;
      for (const k of Object.keys(source)) {
        copy[k] = source[k];
      }
    }
    return copy;
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
