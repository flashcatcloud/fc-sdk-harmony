import { rcp } from '@kit.RemoteCommunicationKit';
import { SdkCore, TRACE_FEATURE_NAME, TrackingConsent } from '@flashcatcloud/core';
import { TraceConfiguration } from '../TraceConfiguration';
import { TraceContext } from './TraceContext';

/**
 * rcp interceptor that injects a W3C `traceparent` into every outgoing request of
 * the session it is attached to, and publishes the generated trace_id into the
 * shared trace feature context for future ResourceEvent correlation.
 *
 * Usage: add `FlashcatTrace.interceptor()` to your rcp `SessionConfiguration`.
 * (rcp interceptors are per-session; fully-global auto-injection would require a
 * compile-time AOP plugin — phase 2.)
 */
export class TraceInterceptor implements rcp.Interceptor {
  private readonly core: SdkCore | null;
  private readonly configuration: TraceConfiguration;

  constructor(core: SdkCore | null, configuration: TraceConfiguration) {
    this.core = core;
    this.configuration = configuration;
  }

  async intercept(context: rcp.RequestContext, next: rcp.RequestHandler): Promise<rcp.Response> {
    // Honor tracking consent: do NOT attach a correlatable identifier to outgoing
    // traffic unless the user has granted consent.
    if (isInjectionAllowed(this.core)) {
      const tc: TraceContext = TraceContext.generate(this.configuration.sampleRate);
      context.request.headers['traceparent'] = tc.traceparent();
      publishTraceId(this.core, tc.traceId);
    }
    return next.handle(context);
  }
}

/** Injection is only allowed when consent is explicitly GRANTED. */
export function isInjectionAllowed(core: SdkCore | null): boolean {
  return core !== null && core.getTrackingConsent() === TrackingConsent.GRANTED;
}

/** Publishes the latest trace_id into core context under the 'trace' feature key. */
export function publishTraceId(core: SdkCore | null, traceId: string): void {
  if (core === null) {
    return;
  }
  const update: Record<string, Object> = {};
  update['trace.id'] = traceId;
  core.updateFeatureContext(TRACE_FEATURE_NAME, update);
}
