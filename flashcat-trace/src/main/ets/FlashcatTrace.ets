import { rcp } from '@kit.RemoteCommunicationKit';
import { Flashcat, SdkCore } from '@flashcatcloud/core';
import { TraceConfiguration } from './TraceConfiguration';
import { TraceContext } from './internal/TraceContext';
import { TraceInterceptor, publishTraceId, isInjectionAllowed } from './internal/TraceInterceptor';

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
   */
  static getHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    if (!isInjectionAllowed(FlashcatTrace.core)) {
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
