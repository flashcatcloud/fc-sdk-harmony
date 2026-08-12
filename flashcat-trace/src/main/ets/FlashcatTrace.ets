import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { Flashcat, SdkCore } from '@flashcatcloud/core';
import { TraceConfiguration } from './TraceConfiguration';
import { TracedResource } from './TracedResource';
import { TraceContext } from './internal/TraceContext';
import {
  TraceInterceptor, publishTraceId, isInjectionAllowed, hostOfUrl,
  publishResourceStarted, publishResourceCompleted, publishResourceFailed
} from './internal/TraceInterceptor';

/**
 * Distributed-tracing context propagation for HarmonyOS.
 *
 * Generates W3C `traceparent` and injects it into outgoing requests so the
 * server-side APM picks up and reports the trace. The client itself reports no
 * span data — only the header. When the RUM feature is enabled, the interceptor
 * additionally reports each request as a RUM resource, with the generated
 * `_dd.trace_id` / `_dd.span_id` on the ResourceEvent identifying the exact
 * network request (RUM↔APM correlation).
 *
 * ```ets
 * FlashcatTrace.enable(new TraceConfigurationBuilder().build());
 *
 * // Auto (rcp): add the interceptor to your session config.
 * const session = rcp.createSession({ interceptors: [FlashcatTrace.interceptor()] });
 *
 * // Manual (any stack): spread the headers into your request.
 * const headers = FlashcatTrace.getHeaders();
 * ```
 */
export class FlashcatTrace {
  private static core: SdkCore | null = null;
  private static configuration: TraceConfiguration = new TraceConfiguration(100);

  static enable(configuration: TraceConfiguration, sdkCore?: SdkCore): void {
    FlashcatTrace.configuration = configuration;
    FlashcatTrace.core = sdkCore ?? Flashcat.getInstance();
  }

  /** rcp interceptor for automatic injection on a session. */
  static interceptor(): rcp.Interceptor {
    return new TraceInterceptor(FlashcatTrace.core, FlashcatTrace.configuration);
  }

  /** @internal — active core for the FlashcatHttp wrapper (null before enable). */
  static currentCore(): SdkCore | null {
    return FlashcatTrace.core;
  }

  /** @internal — active trace configuration for the FlashcatHttp wrapper. */
  static currentConfiguration(): TraceConfiguration {
    return FlashcatTrace.configuration;
  }

  /**
   * Manual fallback: trace headers for any network stack (@ohos.net.http, WebSocket, …).
   * Returns an empty object when tracking consent is not GRANTED (no header injected).
   *
   * Pass the request `url` so the configured `firstPartyHosts` gate applies —
   * without it the caller takes over that responsibility, and trace ids
   * attached to third-party hosts leak correlation identifiers.
   */
  /**
   * Registers an outgoing request as a RUM resource and returns the trace
   * headers to send with it. For network stacks the SDK cannot instrument on
   * its own — axios, a custom client, a WebSocket handshake.
   *
   * Pair every call with `stopTracedResource` or `failTracedResource`,
   * including on the failure path, or the resource never closes.
   *
   * ```ets
   * const traced = FlashcatTrace.startTracedResource(url, 'GET');
   * // merge traced.headers into the request, then send it
   * FlashcatTrace.stopTracedResource(traced.key, response.status, size);
   * ```
   *
   * The resource reaches RUM through the same path as the rcp interceptor and
   * `FlashcatHttp`, so it requires `setTrackNetworkRequests(true)` on the RUM
   * configuration, and is a no-op when the RUM feature is not enabled.
   *
   * @param url full request url — a relative path has no host to match against
   *        `setFirstPartyHosts()`, which would skip injection entirely
   * @param method HTTP method; case-insensitive
   * @param injectTrace pass false when the request already carries a
   *        `traceparent`. No trace context is generated, so the resource is not
   *        tied to a trace the caller never sent.
   */
  static startTracedResource(url: string, method: string, injectTrace: boolean = true): TracedResource {
    const core: SdkCore | null = FlashcatTrace.core;
    const config: TraceConfiguration = FlashcatTrace.configuration;
    const key: string = util.generateRandomUUID(true);
    const headers: Record<string, string> = {};
    let traceId: string | undefined = undefined;
    let spanId: string | undefined = undefined;

    if (injectTrace && isInjectionAllowed(core) && config.isFirstParty(hostOfUrl(url))) {
      const tc: TraceContext = TraceContext.generate(config.sampleRate);
      headers['traceparent'] = tc.traceparent();
      headers['tracestate'] = tc.tracestate();
      // An unsampled trace is dropped by the APM backend — correlate only when
      // it will actually exist there.
      if (tc.sampled) {
        publishTraceId(core, tc.traceId);
        traceId = tc.traceId;
        spanId = tc.spanId;
      }
    }

    publishResourceStarted(core, key, url, method, traceId, spanId);
    return new TracedResource(key, headers);
  }

  /** Closes a traced resource that got a response, whatever its status. */
  static stopTracedResource(key: string, statusCode: number, size: number, mimeType: string = ''): void {
    publishResourceCompleted(FlashcatTrace.core, key, statusCode, size, mimeType);
  }

  /**
   * Closes a traced resource that never got a response — a transport failure.
   * Reports a network error rather than a resource. A response carrying an
   * error status is not this: pass it to `stopTracedResource` instead, so it
   * stays a resource with that status.
   */
  static failTracedResource(key: string, message: string): void {
    publishResourceFailed(FlashcatTrace.core, key, message);
  }

  static getHeaders(url?: string): Record<string, string> {
    const headers: Record<string, string> = {};
    if (!isInjectionAllowed(FlashcatTrace.core)) {
      return headers;
    }
    if (url !== undefined && !FlashcatTrace.configuration.isFirstParty(hostOfUrl(url))) {
      return headers;
    }
    const tc: TraceContext = TraceContext.generate(FlashcatTrace.configuration.sampleRate);
    if (tc.sampled) {
      publishTraceId(FlashcatTrace.core, tc.traceId);
    }
    headers['traceparent'] = tc.traceparent();
    headers['tracestate'] = tc.tracestate();
    return headers;
  }
}
