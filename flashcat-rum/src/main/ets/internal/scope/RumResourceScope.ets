import { FeatureScope, FlashcatContext, EventWriter } from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { RumRawEvent } from './RumScope';
import { RumEventAssembler } from '../assembly/RumEventAssembler';
import { writeMapped } from '../RumEventMapperHolder';

const MS_TO_NS: number = 1e6;
/** Internal attribute keys carrying the injected trace context (Android convention). */
export const TRACE_ID_ATTRIBUTE: string = '_dd.trace_id';
export const SPAN_ID_ATTRIBUTE: string = '_dd.span_id';

/**
 * Tracks one in-flight network request inside a view. Created on startResource;
 * on stopResource it assembles a ResourceEvent (correlated to the traceparent that
 * was injected into the request, via _dd.trace_id/_dd.span_id start attributes);
 * on stopResourceWithError it assembles a network ErrorEvent instead.
 * Mirrors Android's RumResourceScope.
 */
export class RumResourceScope {
  private readonly featureScope: FeatureScope;
  private readonly applicationId: string;
  private readonly sessionId: string;
  private readonly viewId: string;
  private readonly viewName: string;
  private readonly viewUrl: string;
  private readonly resourceId: string;
  private readonly url: string;
  private readonly method: string;
  private readonly startedAtMs: number;
  private readonly traceId: string | undefined;
  private readonly spanId: string | undefined;
  private readonly attributes: Record<string, Object>;

  constructor(
    featureScope: FeatureScope,
    applicationId: string,
    sessionId: string,
    viewId: string,
    viewName: string,
    viewUrl: string,
    start: RumRawEvent
  ) {
    this.featureScope = featureScope;
    this.applicationId = applicationId;
    this.sessionId = sessionId;
    this.viewId = viewId;
    this.viewName = viewName;
    this.viewUrl = viewUrl;
    this.resourceId = util.generateRandomUUID(true);
    this.url = start.url ?? '';
    this.method = start.method ?? 'GET';
    this.startedAtMs = start.timestampMs;
    // Pull the trace correlation out of the attributes; everything else passes through.
    const src: Record<string, Object> = start.attributes;
    const traceVal: Object | undefined = src[TRACE_ID_ATTRIBUTE];
    const spanVal: Object | undefined = src[SPAN_ID_ATTRIBUTE];
    this.traceId = typeof traceVal === 'string' ? traceVal : undefined;
    this.spanId = typeof spanVal === 'string' ? spanVal : undefined;
    const attrs: Record<string, Object> = {};
    for (const k of Object.keys(src)) {
      if (k === TRACE_ID_ATTRIBUTE || k === SPAN_ID_ATTRIBUTE) {
        continue;
      }
      attrs[k] = src[k];
    }
    this.attributes = attrs;
  }

  /** Request completed — emit the ResourceEvent. */
  stop(raw: RumRawEvent): void {
    const durationNs: number = Math.max(0, raw.timestampMs - this.startedAtMs) * MS_TO_NS;
    const attrs: Record<string, Object> = this.mergedAttributes(raw);
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.resource(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        this.resourceId, this.url, this.method, raw.resourceKind ?? 'native',
        raw.statusCode ?? 0, raw.sizeBytes ?? 0, this.startedAtMs, durationNs,
        this.traceId, this.spanId, this.withViewUrl(attrs));
      writeMapped(writer, event, false);
    });
  }

  /** Request failed — emit a network ErrorEvent carrying the resource info. */
  stopWithError(raw: RumRawEvent): void {
    const attrs: Record<string, Object> = this.mergedAttributes(raw);
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.error(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.errorMessage ?? 'network request failed', 'network', undefined,
        false, 'handled', raw.timestampMs, this.withViewUrl(attrs),
        this.method, raw.statusCode, this.url);
      writeMapped(writer, event, true);
    });
  }

  /** Start attributes overlaid with stop-time attributes (stop wins). */
  private mergedAttributes(stop: RumRawEvent): Record<string, Object> {
    const attrs: Record<string, Object> = {};
    for (const k of Object.keys(this.attributes)) {
      attrs[k] = this.attributes[k];
    }
    const stopAttrs: Record<string, Object> = stop.attributes;
    for (const k of Object.keys(stopAttrs)) {
      attrs[k] = stopAttrs[k];
    }
    return attrs;
  }

  private withViewUrl(attributes: Record<string, Object>): Record<string, Object> {
    const attrs: Record<string, Object> = {};
    for (const k of Object.keys(attributes)) {
      attrs[k] = attributes[k];
    }
    attrs['view.url'] = this.viewUrl;
    return attrs;
  }
}
