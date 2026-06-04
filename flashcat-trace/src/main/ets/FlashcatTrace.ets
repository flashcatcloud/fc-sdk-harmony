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
 * span data — only the header. RUM correlation is intentionally deferred to
 * phase-2 ResourceEvents, where `_dd.trace_id` / `_dd.span_id` can identify the
 * exact network request.
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
    publishTraceId(FlashcatTrace.core, tc.traceId);
    headers['traceparent'] = tc.traceparent();
    return headers;
  }
}
