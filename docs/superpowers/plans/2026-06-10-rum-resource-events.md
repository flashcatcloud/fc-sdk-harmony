# RUM Resource Events (network tracking + traceparent correlation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit RUM ResourceEvents for network requests, correlated to the injected W3C `traceparent` via `_dd.trace_id` / `_dd.span_id`, completing the phase-1 feature list (App init → Session → View → **Resource** → Error → NDJSON batch → /api/v2/rum).

**Architecture:** The existing `TraceInterceptor` (flashcat-trace, rcp) becomes the single instrumentation point: it keeps injecting `traceparent` and additionally publishes `network_request_started/completed/failed` messages onto the core message bus (`FeatureScope.sendEvent` → RUM's `FeatureEventReceiver`). `RumFeature.onReceive` translates these into `RumMonitor.startResource/stopResource/stopResourceWithError` calls, passing trace ids as the Android-convention internal attributes `_dd.trace_id`/`_dd.span_id`. A new `RumResourceScope` (child of `RumViewScope`, mirroring Android's `RumResourceScope.kt`) assembles the ResourceEvent (completed request) or a network ErrorEvent (failed request). No new module, no inter-feature compile dependency.

**Tech Stack:** ArkTS (HarmonyOS NEXT), HAR modules `flashcat-core` / `flashcat-rum` / `flashcat-trace`. **No hvigor/ohpm toolchain in this dev env — code cannot be compiled or run locally.** Every task therefore ends with an ArkTS-constraint self-check instead of a test run, and on-device verification points are collected in the final task.

**ArkTS constraints checklist (run mentally on every diff):**
- NO object spread `{...x}`
- NO bare `delete obj[k]` on `Record` (build a filtered copy or use `Map`)
- NO `any`; explicit types on locals used in closures
- Untyped object literals only where the target type is explicit (return type / typed const)
- Event-assembly objects built as explicit `Record<string, Object>` field-by-field

**Decisions locked in (do not relitigate):**
- Adding the interceptor to an rcp session IS the opt-in for auto resource tracking. `RumConfiguration.trackNetworkRequests` stays inert (reserved for phase-2 compile-time AOP).
- Resources with no active view are dropped (matches Android; viewless errors still work).
- When a view stops, its still-pending resources are dropped silently (phase-1 simplification of Android's "view stays alive until resources settle").
- Max 100 pending resources per view; further `startResource` calls are ignored until slots free.
- Bus message timestamps are taken at monitor-call time (`systemDateTime.getTime()` in `DefaultRumMonitor.raw`) — bus delivery is synchronous so drift is negligible.
- Failed requests emit an ErrorEvent (`source: 'network'`, `handling: 'handled'`, `error.resource` sub-object), NOT a ResourceEvent — Android parity.
- Auto-tracked rcp resources use `RumResourceKind.NATIVE`.
- Unknown HTTP methods map to `GET` (RumResourceMethod has no OPTIONS/TRACE/CONNECT).

**Process rule (user requirement):** after EVERY task, update `docs/HANDOFF.md` (mark the task done, record exact next step + any surprises) and include it in that task's commit, so a fresh session can resume losslessly if this one dies.

---

### Task 1: Handoff log scaffolding

**Files:**
- Create: `docs/HANDOFF.md`
- Create: `docs/superpowers/plans/2026-06-10-rum-resource-events.md` (this file)

- [x] **Step 1: Write `docs/HANDOFF.md`** with: goal recap, link to this plan, task checklist (1–9), "current state", "next step", "gotchas" sections.

- [x] **Step 2: Commit**

```bash
git add docs/
git commit -m "docs: add resource-events plan + handoff log"
```

---

### Task 2: Raw-event + public API surface for resources

**Files:**
- Modify: `flashcat-rum/src/main/ets/internal/scope/RumScope.ets`
- Modify: `flashcat-rum/src/main/ets/RumMonitor.ets`

- [x] **Step 1: Extend `RumRawEvent`** — update the kind comment and add resource fields:

```ets
export interface RumRawEvent {
  kind: string;                 // 'startView' | 'stopView' | 'addAction' | 'addError'
                                // | 'startResource' | 'stopResource' | 'stopResourceWithError'
  key?: string;                 // view key, or resource key
  name?: string;
  attributes: Record<string, Object>;
  timestampMs: number;          // epoch ms

  // error specifics (kind === 'addError' | 'stopResourceWithError')
  errorMessage?: string;
  errorSource?: string;
  errorStack?: string;
  errorHandling?: string;       // 'handled' | 'unhandled'
  isCrash?: boolean;

  // resource specifics (kind === 'startResource' | 'stopResource')
  url?: string;
  method?: string;              // 'GET' | 'POST' | ...
  statusCode?: number;
  sizeBytes?: number;
  resourceKind?: string;        // RumResourceKind value, e.g. 'native'
}
```

- [x] **Step 2: Add `stopResourceWithError` to the `RumMonitor` interface** (after `stopResource`):

```ets
  stopResourceWithError(key: string, message: string, statusCode?: number,
    attributes?: Record<string, Object>): void;
```

And the matching no-op in `NoOpRumMonitor`:

```ets
  stopResourceWithError(key: string, message: string, statusCode?: number,
    attributes?: Record<string, Object>): void {}
```

- [x] **Step 3: ArkTS self-check** against the checklist above; verify imports unchanged.

- [x] **Step 4: Update `docs/HANDOFF.md`, commit**

```bash
git add flashcat-rum docs/HANDOFF.md
git commit -m "feat(rum): extend raw events and monitor API for resources"
```

---

### Task 3: ResourceEvent assembly

**Files:**
- Modify: `flashcat-rum/src/main/ets/internal/assembly/RumEventAssembler.ets`

- [x] **Step 1: Add `RumEventAssembler.resource(...)`** after `error(...)`:

```ets
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
    const dd: Record<string, Object> = {};
    dd['format_version'] = 2;
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
    view['url'] = viewName;
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
```

- [x] **Step 2: Extend `error(...)`** with optional trailing params for failed-resource info (appended AFTER `attributes` would break the positional convention — instead append after `attributes`? No: keep existing call sites valid by appending three optional params at the END of the signature):

```ets
  static error(
    context: FlashcatContext,
    ...existing params...,
    attributes: Record<string, Object>,
    resourceMethod?: string,
    resourceStatusCode?: number,
    resourceUrl?: string
  ): Record<string, Object> {
```

and inside, after `error['handling'] = handling;`:

```ets
    if (resourceUrl !== undefined) {
      const errResource: Record<string, Object> = {};
      errResource['method'] = resourceMethod ?? 'GET';
      errResource['status_code'] = resourceStatusCode ?? 0;
      errResource['url'] = resourceUrl;
      error['resource'] = errResource;
    }
```

- [x] **Step 3: Update the `applyContext` NOTE comment** — RUM↔Trace correlation now happens on ResourceEvents via `_dd.trace_id`/`_dd.span_id`; keep the warning that stamping trace ids on View/Error stays out.

- [x] **Step 4: ArkTS self-check; existing `error()` call sites (RumViewScope, RumSessionScope) still compile unchanged (new params optional).**

- [x] **Step 5: Update `docs/HANDOFF.md`, commit**

```bash
git add flashcat-rum docs/HANDOFF.md
git commit -m "feat(rum): assemble resource events with trace correlation"
```

---

### Task 4: RumResourceScope

**Files:**
- Create: `flashcat-rum/src/main/ets/internal/scope/RumResourceScope.ets`

- [x] **Step 1: Write the scope** (mirrors Android `RumResourceScope.kt`: strips `_dd.trace_id`/`_dd.span_id` from start attributes into event `_dd`; completed → ResourceEvent; failed → network ErrorEvent):

```ets
import { FeatureScope, FlashcatContext, EventWriter } from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { RumRawEvent } from './RumScope';
import { RumEventAssembler } from '../assembly/RumEventAssembler';

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
    start: RumRawEvent
  ) {
    this.featureScope = featureScope;
    this.applicationId = applicationId;
    this.sessionId = sessionId;
    this.viewId = viewId;
    this.viewName = viewName;
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
        this.traceId, this.spanId, attrs);
      writer.write(event);
    });
  }

  /** Request failed — emit a network ErrorEvent carrying the resource info. */
  stopWithError(raw: RumRawEvent): void {
    const attrs: Record<string, Object> = this.mergedAttributes(raw);
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.error(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.errorMessage ?? 'network request failed', 'network', undefined,
        false, 'handled', raw.timestampMs, attrs,
        this.method, raw.statusCode, this.url);
      writer.write(event, true);
    });
  }

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
}
```

- [x] **Step 2: ArkTS self-check** (no spread — manual copies; no delete — filtered copy; closure reads typed locals).

- [x] **Step 3: Update `docs/HANDOFF.md`, commit**

```bash
git add flashcat-rum docs/HANDOFF.md
git commit -m "feat(rum): add resource scope"
```

---

### Task 5: View scope integration + real resource counts

**Files:**
- Modify: `flashcat-rum/src/main/ets/internal/scope/RumViewScope.ets`
- Modify: `flashcat-rum/src/main/ets/internal/assembly/RumEventAssembler.ets` (view signature)

- [x] **Step 1: `RumEventAssembler.view` gets a `resourceCount` param** — add `resourceCount: number` after `errorCount: number`, and change `view['resource'] = RumEventAssembler.count(0)` to `RumEventAssembler.count(resourceCount)`.

- [x] **Step 2: `RumViewScope`** — add fields, routing, counting:

Imports: add `import { RumResourceScope } from './RumResourceScope';` and a `const MAX_PENDING_RESOURCES: number = 100;`

Fields (after `errorCount`):
```ets
  private resourceCount: number = 0;
  private readonly pendingResources: Map<string, RumResourceScope> = new Map<string, RumResourceScope>();
```

`handleEvent` — new cases before `default`:
```ets
      case 'startResource': {
        const key: string = event.key ?? '';
        if (key !== '' && this.pendingResources.size < MAX_PENDING_RESOURCES) {
          this.pendingResources.set(key, new RumResourceScope(
            this.featureScope, this.applicationId, this.sessionId,
            this.viewId, this.viewName, event));
        }
        return this;
      }
      case 'stopResource': {
        const scope: RumResourceScope | undefined = this.pendingResources.get(event.key ?? '');
        if (scope !== undefined) {
          this.pendingResources.delete(event.key ?? '');
          scope.stop(event);
          this.resourceCount += 1;
          this.writeViewEvent(event.timestampMs);
        }
        return this;
      }
      case 'stopResourceWithError': {
        const scope: RumResourceScope | undefined = this.pendingResources.get(event.key ?? '');
        if (scope !== undefined) {
          this.pendingResources.delete(event.key ?? '');
          scope.stopWithError(event);
          this.errorCount += 1;
          this.writeViewEvent(event.timestampMs);
        }
        return this;
      }
```

`forceStop` and the `stopView` case: drop pending resources (`this.pendingResources.clear();`) before writing the final view event. Comment: phase-1 simplification — Android keeps the view alive until resources settle.

`writeViewEvent`: snapshot `const resources: number = this.resourceCount;` and pass it to `RumEventAssembler.view(..., errors, resources, version, ...)` matching the new signature.

- [x] **Step 3: ArkTS self-check; confirm the only `RumEventAssembler.view` call site is here.**

- [x] **Step 4: Update `docs/HANDOFF.md`, commit**

```bash
git add flashcat-rum docs/HANDOFF.md
git commit -m "feat(rum): track resources in view scope with real counts"
```

---

### Task 6: DefaultRumMonitor resource methods

**Files:**
- Modify: `flashcat-rum/src/main/ets/internal/monitor/DefaultRumMonitor.ets`

- [x] **Step 1: Replace the no-op resource methods:**

```ets
  startResource(key: string, method: RumResourceMethod, url: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('startResource', attributes);
    e.key = key;
    e.method = method as string;
    e.url = url;
    this.applicationScope.handleEvent(e);
  }

  stopResource(key: string, statusCode: number, size: number, kind: RumResourceKind,
    attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('stopResource', attributes);
    e.key = key;
    e.statusCode = statusCode;
    e.sizeBytes = size;
    e.resourceKind = kind as string;
    this.applicationScope.handleEvent(e);
  }

  stopResourceWithError(key: string, message: string, statusCode?: number,
    attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('stopResourceWithError', attributes);
    e.key = key;
    e.errorMessage = message;
    e.statusCode = statusCode;
    this.applicationScope.handleEvent(e);
  }
```

- [x] **Step 2: Update the class doc comment** — phase 1 now covers View + Error + Resource; actions still count-only.

- [x] **Step 3: ArkTS self-check (`method as string` on a string enum is valid ArkTS).**

- [x] **Step 4: Update `docs/HANDOFF.md`, commit**

```bash
git add flashcat-rum docs/HANDOFF.md
git commit -m "feat(rum): implement resource monitor API"
```

---

### Task 7: Bus translation in RumFeature

**Files:**
- Modify: `flashcat-rum/src/main/ets/internal/RumFeature.ets`

- [x] **Step 1: Implement `onReceive`** (replace the TODO body) + helpers:

```ets
  /** Bus handler — network request events from the Trace interceptor, crash events (phase 2). */
  onReceive(event: Record<string, Object>): void {
    const type: Object | undefined = event['type'];
    if (type === 'network_request_started') {
      this.onNetworkRequestStarted(event);
    } else if (type === 'network_request_completed') {
      this.onNetworkRequestCompleted(event);
    } else if (type === 'network_request_failed') {
      this.onNetworkRequestFailed(event);
    }
    // TODO phase 2: map hiAppEvent crash payloads (JS/C++/Freeze) → RUM error.
  }

  private onNetworkRequestStarted(event: Record<string, Object>): void {
    const m: DefaultRumMonitor | null = this.monitor;
    if (m === null) {
      return;
    }
    const attributes: Record<string, Object> = {};
    const traceId: Object | undefined = event['trace_id'];
    const spanId: Object | undefined = event['span_id'];
    if (typeof traceId === 'string') {
      attributes['_dd.trace_id'] = traceId;
    }
    if (typeof spanId === 'string') {
      attributes['_dd.span_id'] = spanId;
    }
    m.startResource(
      RumFeature.asString(event['key']),
      RumFeature.toMethod(RumFeature.asString(event['method'])),
      RumFeature.asString(event['url']),
      attributes);
  }

  private onNetworkRequestCompleted(event: Record<string, Object>): void {
    const m: DefaultRumMonitor | null = this.monitor;
    if (m === null) {
      return;
    }
    m.stopResource(
      RumFeature.asString(event['key']),
      RumFeature.asNumber(event['status_code']),
      RumFeature.asNumber(event['size']),
      RumResourceKind.NATIVE);
  }

  private onNetworkRequestFailed(event: Record<string, Object>): void {
    const m: DefaultRumMonitor | null = this.monitor;
    if (m === null) {
      return;
    }
    m.stopResourceWithError(
      RumFeature.asString(event['key']),
      RumFeature.asString(event['message']));
  }

  private static asString(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private static asNumber(value: Object | undefined): number {
    return typeof value === 'number' ? value : 0;
  }

  private static toMethod(method: string): RumResourceMethod {
    switch (method.toUpperCase()) {
      case 'POST': return RumResourceMethod.POST;
      case 'PUT': return RumResourceMethod.PUT;
      case 'DELETE': return RumResourceMethod.DELETE;
      case 'HEAD': return RumResourceMethod.HEAD;
      case 'PATCH': return RumResourceMethod.PATCH;
      default: return RumResourceMethod.GET; // incl. unknown verbs — enum has no OPTIONS/TRACE
    }
  }
```

Imports: extend the RumTypes import to `{ RumErrorSource, RumResourceKind, RumResourceMethod }`.

Also update the class doc comment and the `onInitialize` phase-2 TODO (network instrumentation now arrives via the bus; nav tracking still phase 2).

- [x] **Step 2: ArkTS self-check.**

- [x] **Step 3: Update `docs/HANDOFF.md`, commit**

```bash
git add flashcat-rum docs/HANDOFF.md
git commit -m "feat(rum): consume network request bus events as resources"
```

---

### Task 8: TraceInterceptor reports resources

**Files:**
- Modify: `flashcat-trace/src/main/ets/internal/TraceInterceptor.ets`
- Modify: `flashcat-trace/src/main/ets/FlashcatTrace.ets` (doc comment only)

- [x] **Step 1: Rewrite `intercept`** to time the request and notify RUM via the bus:

```ets
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { SdkCore, FeatureScope, RUM_FEATURE_NAME, TRACE_FEATURE_NAME, TrackingConsent } from '@flashcatcloud/core';
import { TraceConfiguration } from '../TraceConfiguration';
import { TraceContext } from './TraceContext';
```

```ets
  async intercept(context: rcp.RequestContext, next: rcp.RequestHandler): Promise<rcp.Response> {
    // Honor tracking consent: do NOT attach a correlatable identifier to outgoing
    // traffic unless the user has granted consent. (RUM resource events are still
    // reported — the writer itself buffers/drops them per consent.)
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
```

Helpers (module-level, beside `publishTraceId`):

```ets
/** RUM resource tracking: publish request lifecycle onto the bus for the RUM feature. */
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
```

Class doc comment: interceptor now (1) injects `traceparent`, (2) reports the request as a RUM resource via the bus; correlation lands on the ResourceEvent's `_dd.trace_id`/`_dd.span_id`.

- [x] **Step 2: Update `FlashcatTrace` doc comment** — drop "deferred to phase-2" wording; document that the interceptor also produces RUM resources when RUM is enabled.

- [x] **Step 3: ArkTS self-check.** Device-verify notes: `request.url.toString()`, `request.method`, `response.statusCode`, `response.body?.byteLength` field shapes on real rcp; catch-param `instanceof Error`.

- [x] **Step 4: Update `docs/HANDOFF.md`, commit**

```bash
git add flashcat-trace docs/HANDOFF.md
git commit -m "feat(trace): report intercepted requests as RUM resources"
```

---

### Task 9: Wrap-up — device verification checklist + memory

**Files:**
- Modify: `docs/HANDOFF.md` (final state + on-device verification checklist)

- [x] **Step 1: Final `docs/HANDOFF.md`** — mark all tasks done; consolidate the on-device verification checklist (rcp field shapes, bus delivery, NDJSON output contains `type:resource` with `_dd.trace_id`, view `resource.count` increments, failed request → `source:network` error, traceparent present on wire).

- [x] **Step 2: Commit**

```bash
git add docs/HANDOFF.md
git commit -m "docs: resource events handoff wrap-up"
```

- [x] **Step 3: Update the auto-memory file `fc-sdk-harmony.md`** (outside the repo) with the new state.

---

## Self-Review

- **Spec coverage:** goal list — init/session/view/error/NDJSON/upload already shipped; Resource + traceparent correlation = Tasks 2–8; platform aggregation needs `type:resource` events with session/view ids, provided by Task 3 assembly. ✓
- **Placeholder scan:** Task 3 Step 2 shows the exact appended params + inserted block; all other steps carry full code. ✓
- **Type consistency:** `RumRawEvent.sizeBytes`/`statusCode`/`resourceKind` (Task 2) match usage in Tasks 4/6; `RumEventAssembler.resource` 16-param order (Task 3) matches the Task 4 call; `stopResourceWithError(key, message, statusCode?, attributes?)` consistent across Tasks 2/6/7; bus field names `key/url/method/trace_id/span_id/status_code/size/message` consistent across Tasks 7/8. ✓
