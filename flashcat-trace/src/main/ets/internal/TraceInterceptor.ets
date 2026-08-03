import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { SdkCore, FeatureScope, RUM_FEATURE_NAME, TRACE_FEATURE_NAME, TrackingConsent } from '@flashcatcloud/core';
import { TraceConfiguration } from '../TraceConfiguration';
import { TraceContext } from './TraceContext';

/**
 * rcp interceptor that (1) injects a W3C `traceparent`/`tracestate` into outgoing
 * requests that do not already carry a W3C trace context, and (2) reports the
 * request as a RUM resource via the message bus (when the RUM feature is enabled).
 * The generated trace_id/span_id ride along on the ResourceEvent's `_dd` for
 * RUM↔APM correlation.
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
    if (isInjectionAllowed(this.core)
      && this.configuration.isFirstParty(hostOfUrl(context.request.url.toString()))
      && shouldInjectTraceHeaders(context.request.headers)) {
      tc = TraceContext.generate(this.configuration.sampleRate);
      if (context.request.headers === undefined) {
        context.request.headers = {};
      }
      setHeaderValue(context.request.headers as Record<string, Object>, 'traceparent', tc.traceparent());
      setHeaderValue(context.request.headers as Record<string, Object>, 'tracestate',
        tc.tracestate(headerStringValue(context.request.headers, 'tracestate')));
      if (tc.sampled) {
        publishTraceId(this.core, tc.traceId);
      }
    }
    const requestKey: string = util.generateRandomUUID(true);
    // An unsampled trace is dropped by the APM backend, so advertising its ids on
    // the RUM resource would create a dead RUM->APM link. Correlate only when sampled.
    notifyRequestStarted(this.core, requestKey, context.request, tc !== null && tc.sampled ? tc : null);
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

/** Injection requires a live (non-stopped) core with explicitly GRANTED consent. */
export function isInjectionAllowed(core: SdkCore | null): boolean {
  return core !== null && core.isActive() && core.getTrackingConsent() === TrackingConsent.GRANTED;
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

/** Pure: extract the host from a URL (no @ohos.url dependency). */
export function hostOfUrl(rawUrl: string): string {
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

/** Do not take over a request that already carries a W3C trace context. */
export function shouldInjectTraceHeaders(headers: Object | undefined): boolean {
  return headerStringValue(headers, 'traceparent').length === 0;
}

/** Reads a header value case-insensitively. For multi-value headers, uses the first string value. */
export function headerStringValue(headers: Object | undefined, name: string): string {
  const key: string = headerKey(headers, name);
  if (key.length === 0) {
    return '';
  }
  const map: Record<string, Object | undefined> = headers as Record<string, Object | undefined>;
  const value: Object | undefined = map[key];
  if (typeof value === 'string') {
    return value;
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (const item of items) {
      if (typeof item === 'string') {
        return item;
      }
    }
  }
  return '';
}

/** Sets a header without creating a duplicate when the caller used different casing. */
export function setHeaderValue(headers: Record<string, Object>, name: string, value: string): void {
  const key: string = headerKey(headers, name);
  headers[key.length > 0 ? key : name] = value;
}

function headerKey(headers: Object | undefined, name: string): string {
  if (headers === undefined || typeof headers !== 'object') {
    return '';
  }
  const lowerName: string = name.toLowerCase();
  const map: Record<string, Object | undefined> = headers as Record<string, Object | undefined>;
  for (const key of Object.keys(map)) {
    if (key.toLowerCase() === lowerName) {
      return key;
    }
  }
  return '';
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
    response.body !== undefined ? response.body.byteLength : 0,
    contentTypeOf(response.headers));
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
    // _dd.span_id must be the unsigned-decimal form (Datadog convention; the
    // intake parses it base-10). The hex form lives only in traceparent.
    const decimal: string = TraceContext.hexToUnsignedDecimalString(spanId);
    if (decimal.length > 0) {
      event['span_id'] = decimal;
    }
  }
  scope.sendEvent(event);
}

/** @internal */
export function publishResourceCompleted(core: SdkCore | null, key: string,
  statusCode: number, size: number, mimeType: string = ''): void {
  const scope: FeatureScope | null = rumScope(core);
  if (scope === null) {
    return;
  }
  const event: Record<string, Object> = {};
  event['type'] = 'network_request_completed';
  event['key'] = key;
  event['status_code'] = statusCode;
  event['size'] = size;
  // Response Content-Type → the RUM feature classifies the resource type from it
  // (image/media/font/css/js/native), matching the Android/iOS SDKs.
  if (mimeType.length > 0) {
    event['mime_type'] = mimeType;
  }
  scope.sendEvent(event);
}

/**
 * Reads the `Content-Type` header value (case-insensitively) from a header map,
 * shared by the rcp interceptor and the FlashcatHttp wrapper.
 */
export function contentTypeOf(headers: Object | undefined): string {
  return headerStringValue(headers, 'content-type');
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
