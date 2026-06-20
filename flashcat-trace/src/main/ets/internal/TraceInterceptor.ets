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
      if (context.request.headers === undefined) {
        context.request.headers = {};
      }
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
      const error: Error = e instanceof Error ? e : new Error('network request failed');
      notifyRequestFailed(this.core, requestKey, error);
      throw error;
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
  const traceId: string | undefined = tc !== null ? tc.traceId : undefined;
  const spanId: string | undefined = tc !== null ? tc.spanId : undefined;
  publishResourceStarted(core, key, request.url.toString(), request.method ?? 'GET', traceId, spanId);
}

function notifyRequestCompleted(core: SdkCore | null, key: string, response: rcp.Response): void {
  publishResourceCompleted(core, key, response.statusCode,
    response.body !== undefined ? response.body.byteLength : 0);
}

function notifyRequestFailed(core: SdkCore | null, key: string, e: Object): void {
  publishResourceFailed(core, key, e instanceof Error ? e.message : 'network request failed');
}

// ---- Reusable resource-lifecycle publishers (shared by the rcp interceptor and
// the FlashcatHttp wrapper). Keyed by plain url/method strings so any network
// stack can drive RUM resource tracking through the same bus path. ----

/** @internal */
export function publishResourceStarted(core: SdkCore | null, key: string, url: string,
  method: string, traceId?: string, spanId?: string): void {
  const scope: FeatureScope | null = rumScope(core);
  if (scope === null) {
    return;
  }
  const event: Record<string, Object> = {};
  event['type'] = 'network_request_started';
  event['key'] = key;
  event['url'] = url;
  event['method'] = method;
  if (traceId !== undefined) {
    event['trace_id'] = traceId;
  }
  if (spanId !== undefined) {
    event['span_id'] = spanId;
  }
  scope.sendEvent(event);
}

/** @internal */
export function publishResourceCompleted(core: SdkCore | null, key: string,
  statusCode: number, size: number): void {
  const scope: FeatureScope | null = rumScope(core);
  if (scope === null) {
    return;
  }
  const event: Record<string, Object> = {};
  event['type'] = 'network_request_completed';
  event['key'] = key;
  event['status_code'] = statusCode;
  event['size'] = size;
  scope.sendEvent(event);
}

/** @internal */
export function publishResourceFailed(core: SdkCore | null, key: string, message: string): void {
  const scope: FeatureScope | null = rumScope(core);
  if (scope === null) {
    return;
  }
  const event: Record<string, Object> = {};
  event['type'] = 'network_request_failed';
  event['key'] = key;
  event['message'] = message;
  scope.sendEvent(event);
}
