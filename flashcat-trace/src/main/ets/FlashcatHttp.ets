import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { SdkCore } from '@flashcatcloud/core';
import { TraceContext } from './internal/TraceContext';
import {
  isInjectionAllowed, publishTraceId,
  publishResourceStarted, publishResourceCompleted, publishResourceFailed, contentTypeOf,
  shouldInjectTraceHeaders, headerStringValue, setHeaderValue
} from './internal/TraceInterceptor';
import { FlashcatTrace } from './FlashcatTrace';
import { TraceConfiguration } from './TraceConfiguration';

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
    const core: SdkCore | null = FlashcatTrace.currentCore();
    const config: TraceConfiguration = FlashcatTrace.currentConfiguration();
    const opts: http.HttpRequestOptions = options ?? {};
    const method: string = FlashcatHttp.methodOf(opts);
    const key: string = util.generateRandomUUID(true);

    // traceparent injection — consent-gated AND first-party-gated.
    let traceId: string | undefined = undefined;
    let spanId: string | undefined = undefined;
    const host: string = FlashcatHttp.hostOf(reqUrl);
    if (isInjectionAllowed(core) && config.isFirstParty(host) && shouldInjectTraceHeaders(opts.header)) {
      const tc: TraceContext = TraceContext.generate(config.sampleRate);
      const header: Record<string, Object> = FlashcatHttp.headerRecord(opts);
      setHeaderValue(header, 'traceparent', tc.traceparent());
      setHeaderValue(header, 'tracestate', tc.tracestate(headerStringValue(header, 'tracestate')));
      opts.header = header;
      publishTraceId(core, tc.traceId);
      traceId = tc.traceId;
      spanId = tc.spanId;
    }

    publishResourceStarted(core, key, reqUrl, method, traceId, spanId);
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(reqUrl, opts);
      publishResourceCompleted(core, key, FlashcatHttp.statusOf(response), FlashcatHttp.sizeOf(response),
        contentTypeOf(response.header));
      return response;
    } catch (e) {
      publishResourceFailed(core, key, e instanceof Error ? e.message : 'network request failed');
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
    let s: string = rawUrl;
    const scheme: number = s.indexOf('://');
    if (scheme >= 0) {
      s = s.substring(scheme + 3);
    }
    let end: number = s.length;
    const seps: string[] = ['/', '?', '#'];
    for (const sep of seps) {
      const i: number = s.indexOf(sep);
      if (i >= 0 && i < end) {
        end = i;
      }
    }
    s = s.substring(0, end);
    const at: number = s.indexOf('@');
    if (at >= 0) {
      s = s.substring(at + 1);
    }
    const colon: number = s.indexOf(':');
    if (colon >= 0) {
      s = s.substring(0, colon);
    }
    return s;
  }
}
