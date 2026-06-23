import { FlashcatContext } from '@flashcatcloud/core';

const VIEW_URL_ATTRIBUTE: string = 'view.url';
const BUILD_ID_ATTRIBUTE: string = 'build_id';
const ERROR_BINARY_IMAGES_ATTRIBUTE: string = 'error.binary_images';
const ERROR_CATEGORY_ATTRIBUTE: string = 'error.category';
const ERROR_SOURCE_TYPE_ATTRIBUTE: string = 'error.source_type';
const ERROR_META_CODE_TYPE_ATTRIBUTE: string = 'error.meta.code_type';

/**
 * Builds RUM event objects (View / Error / Resource) for phase 1. Fields follow
 * the shared `rum-events-format` ViewEvent / ErrorEvent / ResourceEvent shapes.
 *
 * NOTE: the rum-events-format schema submodule is not yet wired into this repo,
 * so these objects are hand-assembled. When schema-driven model generation is
 * added, validate field names/nesting against the generated models.
 *
 * Built as explicit `Record<string, Object>` sub-objects (not nested literals)
 * to satisfy ArkTS's strict object-literal typing.
 */
export class RumEventAssembler {
  static view(
    context: FlashcatContext,
    applicationId: string,
    sessionId: string,
    viewId: string,
    name: string,
    dateMs: number,
    timeSpentNs: number,
    actionCount: number,
    errorCount: number,
    resourceCount: number,
    documentVersion: number,
    isActive: boolean,
    attributes: Record<string, Object>
  ): Record<string, Object> {
    const event: Record<string, Object> = {};
    event['type'] = 'view';
    event['date'] = dateMs; // view START time — stable across all updates of this view.id
    event['_dd'] = RumEventAssembler.dd(documentVersion);
    event['application'] = RumEventAssembler.idObj(applicationId);
    event['session'] = RumEventAssembler.session(sessionId);

    const view: Record<string, Object> = {};
    view['id'] = viewId;
    view['url'] = RumEventAssembler.viewUrl(name, attributes);
    view['name'] = name;
    view['time_spent'] = timeSpentNs;
    view['is_active'] = isActive;
    view['action'] = RumEventAssembler.count(actionCount);
    view['error'] = RumEventAssembler.count(errorCount);
    view['resource'] = RumEventAssembler.count(resourceCount);
    event['view'] = view;

    RumEventAssembler.applyContext(event, context, attributes);
    return event;
  }

  static error(
    context: FlashcatContext,
    applicationId: string,
    sessionId: string,
    viewId: string | undefined,
    viewName: string | undefined,
    message: string,
    source: string,
    stack: string | undefined,
    isCrash: boolean,
    handling: string,
    dateMs: number,
    attributes: Record<string, Object>,
    resourceMethod?: string,
    resourceStatusCode?: number,
    resourceUrl?: string
  ): Record<string, Object> {
    const event: Record<string, Object> = {};
    event['type'] = 'error';
    event['date'] = dateMs;
    event['_dd'] = RumEventAssembler.dd(0);
    const buildId: string = RumEventAssembler.asString(attributes[BUILD_ID_ATTRIBUTE]);
    if (buildId.length > 0) {
      event['build_id'] = buildId;
    }
    event['application'] = RumEventAssembler.idObj(applicationId);
    event['session'] = RumEventAssembler.session(sessionId);
    if (viewId !== undefined) {
      const view: Record<string, Object> = {};
      view['id'] = viewId;
      view['url'] = RumEventAssembler.viewUrl(viewName ?? '', attributes);
      view['name'] = viewName ?? '';
      event['view'] = view;
    }

    const error: Record<string, Object> = {};
    error['message'] = message;
    error['source'] = source;
    if (stack !== undefined) {
      error['stack'] = stack;
    }
    error['is_crash'] = isCrash;
    error['handling'] = handling; // 'handled' | 'unhandled'
    const category: string = RumEventAssembler.asString(attributes[ERROR_CATEGORY_ATTRIBUTE]);
    if (category.length > 0) {
      error['category'] = category;
    }
    const sourceType: string = RumEventAssembler.asString(attributes[ERROR_SOURCE_TYPE_ATTRIBUTE]);
    if (sourceType.length > 0) {
      error['source_type'] = sourceType;
    }
    const binaryImages: Object | undefined = attributes[ERROR_BINARY_IMAGES_ATTRIBUTE];
    if (Array.isArray(binaryImages) && binaryImages.length > 0) {
      error['binary_images'] = binaryImages;
    }
    const codeType: string = RumEventAssembler.asString(attributes[ERROR_META_CODE_TYPE_ATTRIBUTE]);
    if (codeType.length > 0) {
      const meta: Record<string, Object> = {};
      meta['code_type'] = codeType;
      error['meta'] = meta;
    }
    // Failed-resource errors (source 'network') carry the request that failed.
    if (resourceUrl !== undefined) {
      const errResource: Record<string, Object> = {};
      errResource['method'] = resourceMethod ?? 'GET';
      errResource['status_code'] = resourceStatusCode ?? 0;
      errResource['url'] = resourceUrl;
      error['resource'] = errResource;
    }
    event['error'] = error;

    RumEventAssembler.applyContext(event, context, attributes);
    return event;
  }

  static action(
    context: FlashcatContext,
    applicationId: string,
    sessionId: string,
    viewId: string,
    viewName: string,
    actionId: string,
    actionType: string,
    targetName: string,
    dateMs: number,
    durationNs: number,
    attributes: Record<string, Object>
  ): Record<string, Object> {
    const event: Record<string, Object> = {};
    event['type'] = 'action';
    event['date'] = dateMs;
    event['_dd'] = RumEventAssembler.dd(0);
    event['application'] = RumEventAssembler.idObj(applicationId);
    event['session'] = RumEventAssembler.session(sessionId);

    const view: Record<string, Object> = {};
    view['id'] = viewId;
    view['url'] = RumEventAssembler.viewUrl(viewName, attributes);
    view['name'] = viewName;
    event['view'] = view;

    const action: Record<string, Object> = {};
    action['id'] = actionId;
    action['type'] = actionType;
    action['loading_time'] = durationNs; // ns; 0 for instantaneous custom actions
    const target: Record<string, Object> = {};
    target['name'] = targetName;
    action['target'] = target;
    event['action'] = action;

    RumEventAssembler.applyContext(event, context, attributes);
    return event;
  }

  static resource(
    context: FlashcatContext,
    applicationId: string,
    sessionId: string,
    viewId: string,
    viewName: string,
    resourceId: string,
    url: string,
    method: string,
    kind: string,
    statusCode: number,
    sizeBytes: number,
    dateMs: number,
    durationNs: number,
    traceId: string | undefined,
    spanId: string | undefined,
    attributes: Record<string, Object>
  ): Record<string, Object> {
    const event: Record<string, Object> = {};
    event['type'] = 'resource';
    event['date'] = dateMs; // resource START time
    // RUM↔APM correlation: the trace context that was injected into this exact
    // request (as `traceparent`) rides along in _dd.
    const dd: Record<string, Object> = {};
    dd['format_version'] = 2;
    dd['session'] = RumEventAssembler.sessionPlan();
    if (traceId !== undefined) {
      dd['trace_id'] = traceId;
    }
    if (spanId !== undefined) {
      dd['span_id'] = spanId;
    }
    event['_dd'] = dd;
    event['application'] = RumEventAssembler.idObj(applicationId);
    event['session'] = RumEventAssembler.session(sessionId);

    const view: Record<string, Object> = {};
    view['id'] = viewId;
    view['url'] = RumEventAssembler.viewUrl(viewName, attributes);
    view['name'] = viewName;
    event['view'] = view;

    const resource: Record<string, Object> = {};
    resource['id'] = resourceId;
    resource['type'] = kind;
    resource['url'] = url;
    resource['method'] = method;
    resource['status_code'] = statusCode;
    resource['size'] = sizeBytes;
    resource['duration'] = durationNs;
    event['resource'] = resource;

    RumEventAssembler.applyContext(event, context, attributes);
    return event;
  }

  // ---- shared sub-objects ----

  private static dd(documentVersion: number): Record<string, Object> {
    const dd: Record<string, Object> = {};
    dd['format_version'] = 2;
    dd['session'] = RumEventAssembler.sessionPlan();
    if (documentVersion > 0) {
      dd['document_version'] = documentVersion;
    }
    return dd;
  }

  private static sessionPlan(): Record<string, Object> {
    const session: Record<string, Object> = {};
    session['plan'] = 1;
    return session;
  }

  private static idObj(id: string): Record<string, Object> {
    const o: Record<string, Object> = {};
    o['id'] = id;
    return o;
  }

  private static session(sessionId: string): Record<string, Object> {
    const s: Record<string, Object> = {};
    s['id'] = sessionId;
    s['type'] = 'user';
    return s;
  }

  private static count(n: number): Record<string, Object> {
    const c: Record<string, Object> = {};
    c['count'] = n;
    return c;
  }

  private static viewUrl(fallback: string, attributes: Record<string, Object>): string {
    const value: Object | undefined = attributes[VIEW_URL_ATTRIBUTE];
    return typeof value === 'string' && value.length > 0 ? value : fallback;
  }

  /** Adds source/service/version/os/device/connectivity/user/context + trace link. */
  private static applyContext(
    event: Record<string, Object>,
    context: FlashcatContext,
    attributes: Record<string, Object>
  ): void {
    event['source'] = context.source;
    event['service'] = context.service;
    event['version'] = context.version;

    const os: Record<string, Object> = {};
    os['name'] = context.device.osName;
    os['version'] = context.device.osVersion;
    event['os'] = os;

    const device: Record<string, Object> = {};
    device['type'] = context.device.deviceType;
    device['brand'] = context.device.brand;
    device['model'] = context.device.model;
    event['device'] = device;

    const connectivity: Record<string, Object> = {};
    connectivity['status'] = context.network.connectivity;
    event['connectivity'] = connectivity;

    if (context.user.id !== undefined || context.user.name !== undefined
      || context.user.email !== undefined || context.user.extraInfo !== undefined) {
      const usr: Record<string, Object> = {};
      if (context.user.id !== undefined) {
        usr['id'] = context.user.id;
      }
      if (context.user.name !== undefined) {
        usr['name'] = context.user.name;
      }
      if (context.user.email !== undefined) {
        usr['email'] = context.user.email;
      }
      if (context.user.extraInfo !== undefined) {
        const extra: Record<string, Object> = context.user.extraInfo;
        for (const k of Object.keys(extra)) {
          usr[k] = extra[k];
        }
      }
      event['usr'] = usr;
    }

    // Custom attributes. NOTE: RUM↔Trace correlation lives on ResourceEvents only
    // (_dd.trace_id / _dd.span_id, see resource()). Stamping "the last request's
    // trace id" onto a View/Error would be racy and meaningless — keep it out.
    const ctx: Record<string, Object> = {};
    for (const k of Object.keys(attributes)) {
      if (RumEventAssembler.isInternalAttribute(k)) {
        continue;
      }
      ctx[k] = attributes[k];
    }
    event['context'] = ctx;
  }

  private static isInternalAttribute(key: string): boolean {
    return key === VIEW_URL_ATTRIBUTE || key === BUILD_ID_ATTRIBUTE ||
      key === ERROR_BINARY_IMAGES_ATTRIBUTE || key === ERROR_CATEGORY_ATTRIBUTE ||
      key === ERROR_SOURCE_TYPE_ATTRIBUTE || key === ERROR_META_CODE_TYPE_ATTRIBUTE;
  }

  private static asString(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }
}
