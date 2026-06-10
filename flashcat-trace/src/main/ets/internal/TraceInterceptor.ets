import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { SdkCore, FeatureScope, RUM_FEATURE_NAME, TRACE_FEATURE_NAME, TrackingConsent } from '@flashcatcloud/core';
import { TraceConfiguration } from '../TraceConfiguration';
import { TraceContext } from './TraceContext';

/**
 * rcp interceptor that (1) injects a W3C `traceparent` into every outgoing
 * request of the session it is attached to, and (2) reports the request as a RUM
 * resource via the message bus (when the RUM feature is enabled). The generated
 * trace_id/span_id ride along on the ResourceEvent's `_dd` for RUM↔APM
 * correlation.
 *
 * Usage: add `FlashcatTrace.interceptor()` to your rcp `SessionConfiguration`.
 * Adding the interceptor IS the opt-in for auto resource tracking.
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
    // traffic unless the user has granted consent. (RUM resource events are still
    // reported — the consent-gated writer buffers or drops them itself.)
    let tc: TraceContext | null = null;
    if (isInjectionAllowed(this.core)) {
      tc = TraceContext.generate(this.configuration.sampleRate);
      context.request.headers['traceparent'] = tc.traceparent();
      publishTraceId(this.core, tc.traceId);
    }
    const requestKey: string = util.generateRandomUUID(true);
    notifyRequestStarted(this.core, requestKey, context.request, tc);
    try {
      const response: rcp.Response = await next.handle(context);
      notifyRequestCompleted(this.core, requestKey, response);
      return response;
    } catch (e) {
      notifyRequestFailed(this.core, requestKey, e);
      throw e;
    }
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

// ---- RUM resource tracking: publish the request lifecycle onto the bus. ----
// The RUM feature (if enabled) translates these into start/stopResource calls;
// when RUM is not enabled, getFeature returns null and the events are dropped.

function rumScope(core: SdkCore | null): FeatureScope | null {
  return core !== null ? core.getFeature(RUM_FEATURE_NAME) : null;
}

function notifyRequestStarted(core: SdkCore | null, key: string,
  request: rcp.Request, tc: TraceContext | null): void {
  const scope: FeatureScope | null = rumScope(core);
  if (scope === null) {
    return;
  }
  const event: Record<string, Object> = {};
  event['type'] = 'network_request_started';
  event['key'] = key;
  event['url'] = request.url.toString();
  event['method'] = request.method ?? 'GET';
  if (tc !== null) {
    event['trace_id'] = tc.traceId;
    event['span_id'] = tc.spanId;
  }
  scope.sendEvent(event);
}

function notifyRequestCompleted(core: SdkCore | null, key: string, response: rcp.Response): void {
  const scope: FeatureScope | null = rumScope(core);
  if (scope === null) {
    return;
  }
  const event: Record<string, Object> = {};
  event['type'] = 'network_request_completed';
  event['key'] = key;
  event['status_code'] = response.statusCode;
  event['size'] = response.body !== undefined ? response.body.byteLength : 0;
  scope.sendEvent(event);
}

function notifyRequestFailed(core: SdkCore | null, key: string, e: Object): void {
  const scope: FeatureScope | null = rumScope(core);
  if (scope === null) {
    return;
  }
  const event: Record<string, Object> = {};
  event['type'] = 'network_request_failed';
  event['key'] = key;
  event['message'] = e instanceof Error ? e.message : 'network request failed';
  scope.sendEvent(event);
}
