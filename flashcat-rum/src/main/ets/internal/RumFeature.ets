import {
  Flashcat,
  SdkCore,
  Feature,
  FeatureScope,
  FeatureEventReceiver,
  RUM_FEATURE_NAME,
  CRASH_FEATURE_NAME,
  FlashcatLog
} from '@flashcatcloud/core';
import { errorManager } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import appRecovery from '@ohos.app.ability.appRecovery';
import { RumConfiguration } from '../RumConfiguration';
import { RumErrorSource, RumResourceKind, RumResourceMethod } from '../RumTypes';
import { GlobalRumMonitor } from '../RumMonitor';
import { DefaultRumMonitor } from './monitor/DefaultRumMonitor';
import { RumAutoInstrumentation } from './RumAutoInstrumentation';
import { RumNavigationTracker } from './RumNavigationTracker';
import { RumEventMapperHolder } from './RumEventMapperHolder';

/**
 * The RUM feature. Installs the unhandled-exception hook (auto Error capture) and
 * consumes bus events: network requests published by the Trace interceptor (auto
 * Resource capture), crash events (phase 2). Equivalent to Android's RumFeature.
 */
export class RumFeature implements Feature, FeatureEventReceiver {
  readonly name: string = RUM_FEATURE_NAME;
  private readonly core: SdkCore;
  private readonly configuration: RumConfiguration;
  private monitor: DefaultRumMonitor | null = null;
  private errorObserverId: number = -1;
  private rejectionObserver: errorManager.UnhandledRejectionObserver | null = null;
  private activeJsCrashPolicy: string | null = null;
  private handlingError: boolean = false;

  constructor(core: SdkCore, configuration: RumConfiguration) {
    this.core = core;
    this.configuration = configuration;
  }

  /** Set by FlashcatRum.enable once the monitor is built (after registration). */
  attachMonitor(monitor: DefaultRumMonitor): void {
    this.monitor = monitor;
    FlashcatLog.d('rum: monitor attached');
  }

  onInitialize(): void {
    this.core.setEventReceiver(RUM_FEATURE_NAME, this);
    FlashcatLog.d('rum: event receiver registered');

    // Pull the JS crash policy in case the crash module was enabled first
    // (its one-shot publishPolicy() push would have found no RUM receiver).
    // Together with the push this makes policy delivery enable-order-proof.
    try {
      const crash: FeatureScope | null = this.core.getFeature(CRASH_FEATURE_NAME);
      if (crash !== null) {
        const request: Record<string, Object> = {
          'type': 'js_crash_policy_request',
          'target': CRASH_FEATURE_NAME
        };
        crash.sendEvent(request);
        const policy: string = RumFeature.asString(request['policy']);
        if (policy.length > 0) {
          this.activeJsCrashPolicy = policy;
          FlashcatLog.d(`rum.error: pulled js crash policy=${policy}`);
        }
      }
    } catch (e) {
      FlashcatLog.e(`rum.error: crash policy pull failed: ${RumFeature.errorText(e)}`);
    }

    // Auto Error capture: turn uncaught ArkTS exceptions into RUM error events.
    // The callback reads `this.monitor` at error-time, by which point it is set.
    // CRITICAL: this runs inside the global exception handler — it must NEVER throw
    // (that would crash the host app), and must guard against re-entrancy (an error
    // raised while reporting an error must not be re-processed into a loop).
    try {
      this.errorObserverId = errorManager.on('error', {
        onUnhandledException: (errMsg: string) => {
          FlashcatLog.d(`rum.error: onUnhandledException len=${errMsg.length}`);
          this.reportObservedError(errMsg, 'unhandled');
        },
        onException: (errObject: Error) => {
          const text: string = RumFeature.unhandledErrorText(errObject);
          FlashcatLog.d(`rum.error: onException len=${text.length}`);
          this.reportObservedError(text, 'exception');
        }
      });
      FlashcatLog.d(`rum.error: observer registered id=${this.errorObserverId}`);
    } catch (e) {
      this.errorObserverId = -1;
      FlashcatLog.e(`rum.error: observer registration failed: ${RumFeature.errorText(e)}`);
    }

    // Promise rejections are ordinary RUM errors. They are not terminating
    // ArkTS crashes, so they never enter the pending store or policy path.
    try {
      const observer: errorManager.UnhandledRejectionObserver = (reason: Object): void => {
        this.reportUnhandledRejection(reason);
      };
      errorManager.on('unhandledRejection', observer);
      this.rejectionObserver = observer;
      FlashcatLog.d('rum.error: unhandled-rejection observer registered');
    } catch (e) {
      this.rejectionObserver = null;
      FlashcatLog.e(`rum.error: unhandled-rejection registration failed: ${RumFeature.errorText(e)}`);
    }

    // Network auto-instrumentation arrives via the bus (Trace interceptor →
    // onReceive). TODO phase 2: navigation auto-tracking, compile-time AOP.
  }

  onStop(): void {
    this.core.removeEventReceiver(RUM_FEATURE_NAME);
    if (this.errorObserverId !== -1) {
      try {
        errorManager.off('error', this.errorObserverId);
      } catch (_e) {
        // already removed
      }
      this.errorObserverId = -1;
    }
    if (this.rejectionObserver !== null) {
      try {
        errorManager.off('unhandledRejection', this.rejectionObserver);
      } catch (_e) {
        // already removed or unsupported on this platform build
      }
      this.rejectionObserver = null;
    }
    this.activeJsCrashPolicy = null;
    if (this.monitor !== null) {
      this.monitor.stopKeepAlive(); // stop the keep-alive timer so it doesn't leak
    }
    RumNavigationTracker.detach(); // remove the router observer
    RumAutoInstrumentation.reset(); // make tap/nav trackers inert after stop
    RumEventMapperHolder.reset(); // clear the event mapper
    this.monitor = null;
    // Reset the global so post-stop GlobalRumMonitor.get() returns the no-op, not a
    // monitor wired to a torn-down core.
    GlobalRumMonitor.reset();
  }

  /** Bus handler — network request events from the Trace interceptor; crash/freeze
   * events from the Crash feature (hiAppEvent → CrashEventMapper). */
  onReceive(event: Record<string, Object>): void {
    const type: Object | undefined = event['type'];
    if (type === 'network_request_started') {
      this.onNetworkRequestStarted(event);
    } else if (type === 'network_request_completed') {
      this.onNetworkRequestCompleted(event);
    } else if (type === 'network_request_failed') {
      this.onNetworkRequestFailed(event);
    } else if (type === 'crash_report') {
      this.onCrashReport(event);
    } else if (type === 'js_crash_policy') {
      const policy: string = RumFeature.asString(event['policy']);
      this.activeJsCrashPolicy = policy.length > 0 ? policy : null;
      FlashcatLog.d(`rum.error: crash policy owner enabled policy=${policy}`);
    } else if (type === 'keep_alive') {
      // App backgrounded — refresh the active view so its final time_spent is sent
      // before the batch is flushed (published by the core on background).
      const m: DefaultRumMonitor | null = this.monitor;
      if (m !== null) {
        m.keepAlive();
      }
    }
  }

  /**
   * Crash/freeze event published by the Crash feature. Reported as an unhandled
   * `is_crash` error. Native symbolication metadata is carried as internal
   * attributes that RumEventAssembler lifts into backend-consumed error fields.
   */
  private onCrashReport(event: Record<string, Object>): void {
    const m: DefaultRumMonitor | null = this.monitor;
    if (m === null) {
      FlashcatLog.d('rum.crash: dropped because monitor is null');
      return;
    }
    FlashcatLog.d(`rum.crash: reporting crash kind=${RumFeature.asString(event['crash_kind'])}`);
    m.reportError(
      RumFeature.asString(event['message']),
      RumErrorSource.SOURCE,
      RumFeature.asString(event['stack']),
      true,
      'unhandled',
      RumFeature.crashAttributes(event),
      RumFeature.optionalPositiveNumber(event['timestamp_ms']));
  }

  /** Pure: extract native-symbolication metadata from a crash_report bus event. */
  static crashAttributes(event: Record<string, Object>): Record<string, Object> {
    const attributes: Record<string, Object> = {};
    const images: Object | undefined = event['binary_images'];
    if (Array.isArray(images) && images.length > 0) {
      attributes['error.binary_images'] = images;
    }
    const arch: Object | undefined = event['arch'];
    if (typeof arch === 'string' && arch.length > 0) {
      attributes['error.meta.code_type'] = arch;
    }
    const kind: Object | undefined = event['crash_kind'];
    attributes['error.category'] = kind === 'freeze' ? 'App Hang' : 'Exception';
    const buildId: Object | undefined = event['build_id'];
    if (typeof buildId === 'string' && buildId.length > 0) {
      attributes['build_id'] = buildId;
    }
    const sourceType: Object | undefined = event['source_type'];
    attributes['error.source_type'] =
      typeof sourceType === 'string' && sourceType.length > 0 ? sourceType : 'harmony';
    RumFeature.copyNonEmptyString(event, attributes, 'incident_id', 'crash.incident_id');
    RumFeature.copyNonEmptyString(event, attributes, 'original_session_id', 'crash.original_session_id');
    RumFeature.copyNonEmptyString(event, attributes, 'original_view_id', 'crash.original_view_id');
    RumFeature.copyNonEmptyString(event, attributes, 'original_view_name', 'crash.original_view_name');
    if (event['crash.recovered'] === true) {
      attributes['crash.recovered'] = true;
    }
    return attributes;
  }

  private onNetworkRequestStarted(event: Record<string, Object>): void {
    const m: DefaultRumMonitor | null = this.monitor;
    if (m === null) {
      return;
    }
    // The trace context injected into this request rides along as internal
    // attributes; RumResourceScope strips them into the event's _dd.
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
    const mimeType: string = RumFeature.asString(event['mime_type']);
    const kind: RumResourceKind =
      mimeType.length > 0 ? RumFeature.resourceKindFromMimeType(mimeType) : RumResourceKind.NATIVE;
    m.stopResource(
      RumFeature.asString(event['key']),
      RumFeature.asNumber(event['status_code']),
      RumFeature.asNumber(event['size']),
      kind);
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

  private reportObservedError(stackText: string, callback: string): void {
    if (this.handlingError) {
      FlashcatLog.d('rum.error: skipped re-entrant unhandled error');
      return;
    }
    this.handlingError = true;
    let asyncReportAttempted: boolean = false;
    try {
      // The crash policy is active only after FlashcatCrash.enable publishes an
      // owner. Without that owner, this branch is skipped and RUM retains its
      // pre-policy observe-and-report behavior for backward compatibility.
      if (this.activeJsCrashPolicy !== null) {
        const crash: FeatureScope | null = this.core.getFeature(CRASH_FEATURE_NAME);
        if (crash !== null) {
          const control: Record<string, Object> = {
            'type': 'js_crash_callback',
            'target': CRASH_FEATURE_NAME,
            'callback': callback,
            'text': stackText,
            'timestamp_ms': Date.now(),
            // Safe defaults preserve the legacy report if the receiver is absent.
            'report_async': true,
            'should_exit': false
          };
          crash.sendEvent(control);
          if (control['duplicate'] === true) {
            return;
          }
          if (control['report_async'] === true) {
            asyncReportAttempted = true;
            try {
              this.reportUnhandledToMonitor(stackText);
            } catch (reportError) {
              // Reporting failure must never bypass policy-driven termination.
              FlashcatLog.e(
                `rum.error: async crash report failed: ${RumFeature.errorText(reportError)}`);
            }
          }
          if (control['should_exit'] === true) {
            this.flushAndTerminate(control['recover'] === true);
          }
          return;
        }
      }

      asyncReportAttempted = true;
      this.reportUnhandledToMonitor(stackText);
    } catch (e) {
      FlashcatLog.e(`rum.error: policy path failed: ${RumFeature.errorText(e)}`);
      if (!asyncReportAttempted) {
        try {
          this.reportUnhandledToMonitor(stackText);
        } catch (fallbackError) {
          FlashcatLog.e(`rum.error: fallback report failed: ${RumFeature.errorText(fallbackError)}`);
        }
      }
    } finally {
      this.handlingError = false;
    }
  }

  private reportUnhandledToMonitor(stackText: string): void {
    const m: DefaultRumMonitor | null = this.monitor;
    if (m !== null) {
      FlashcatLog.d(`rum.error: report unhandled firstLine="${RumFeature.firstLine(stackText)}"`);
      m.reportError(RumFeature.firstLine(stackText), RumErrorSource.SOURCE, stackText, false, 'unhandled');
    } else {
      FlashcatLog.d('rum.error: dropped because monitor is null');
    }
  }

  private reportUnhandledRejection(reason: Object): void {
    if (this.handlingError) {
      FlashcatLog.d('rum.error: skipped re-entrant unhandled rejection');
      return;
    }
    this.handlingError = true;
    try {
      const text: string = RumFeature.rejectionErrorText(reason);
      const m: DefaultRumMonitor | null = this.monitor;
      if (m !== null) {
        m.reportError(
          RumFeature.firstLine(text),
          RumErrorSource.SOURCE,
          text,
          false,
          'unhandled',
          RumFeature.rejectionAttributes());
      } else {
        FlashcatLog.d('rum.error: rejection dropped because monitor is null');
      }
    } catch (e) {
      FlashcatLog.e(`rum.error: rejection report failed: ${RumFeature.errorText(e)}`);
    } finally {
      this.handlingError = false;
    }
  }

  private flushAndTerminate(recover: boolean): void {
    try {
      // This rolls all synchronous writers before termination. The uploader is
      // asynchronous; the durable crash-pending file remains the delivery source.
      Flashcat.flush(this.core.name);
    } catch (e) {
      FlashcatLog.e(`rum.error: pre-exit flush failed: ${RumFeature.errorText(e)}`);
    }
    if (recover) {
      try {
        const saved: boolean = appRecovery.saveAppState();
        FlashcatLog.d(`rum.error: recovery saveAppState result=${saved}`);
      } catch (e) {
        // State restoration is best effort; restart remains the product promise.
        FlashcatLog.e(`rum.error: recovery saveAppState failed: ${RumFeature.errorText(e)}`);
      }
      try {
        FlashcatLog.d('rum.error: requesting app recovery restart');
        appRecovery.restartApp();
        return;
      } catch (e) {
        FlashcatLog.e(`rum.error: recovery restartApp failed: ${RumFeature.errorText(e)}; exiting`);
      }
    }
    // ProcessManager.exit restores the host's terminating crash semantics without
    // requiring an Ability context or synthesizing a second native abort crash.
    try {
      const manager: process.ProcessManager = new process.ProcessManager();
      manager.exit(1);
    } catch (e) {
      FlashcatLog.e(`rum.error: process exit failed: ${RumFeature.errorText(e)}`);
    }
  }

  /**
   * Classify a resource by its response Content-Type, mirroring the Datadog
   * Android (`RumResourceKind.fromMimeType`) and iOS (`RUMResourceType(response:)`)
   * mapping so HarmonyOS reports the same resource types. Unknown or missing
   * content-type → NATIVE (API/json).
   */
  static resourceKindFromMimeType(mimeType: string): RumResourceKind {
    const slash: number = mimeType.indexOf('/');
    if (slash < 0) {
      return RumResourceKind.NATIVE;
    }
    const baseType: string = mimeType.substring(0, slash).trim().toLowerCase();
    let subtype: string = mimeType.substring(slash + 1).toLowerCase();
    const semi: number = subtype.indexOf(';');
    if (semi >= 0) {
      subtype = subtype.substring(0, semi);
    }
    subtype = subtype.trim();
    if (baseType === 'image') {
      return RumResourceKind.IMAGE;
    }
    if (baseType === 'video' || baseType === 'audio') {
      return RumResourceKind.MEDIA;
    }
    if (baseType === 'font') {
      return RumResourceKind.FONT;
    }
    if (baseType === 'text' && subtype === 'css') {
      return RumResourceKind.CSS;
    }
    if (baseType === 'text' && subtype === 'javascript') {
      return RumResourceKind.JS;
    }
    return RumResourceKind.NATIVE;
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

  static unhandledErrorText(errObject: Error): string {
    if (errObject.stack !== undefined && errObject.stack.length > 0) {
      return errObject.stack;
    }
    const name: string = errObject.name.length > 0 ? errObject.name : 'Error';
    return `${name}: ${errObject.message}`;
  }

  static rejectionErrorText(reason: Object): string {
    return reason instanceof Error ? RumFeature.unhandledErrorText(reason) : `${reason}`;
  }

  static rejectionAttributes(): Record<string, Object> {
    return {
      'error.category': 'Unhandled Promise Rejection',
      'error.source_type': 'promise'
    };
  }

  private static firstLine(text: string): string {
    const idx: number = text.indexOf('\n');
    return idx >= 0 ? text.substring(0, idx) : text;
  }

  private static errorText(value: Object): string {
    return value instanceof Error ? value.message : `${value}`;
  }

  private static optionalPositiveNumber(value: Object | undefined): number | undefined {
    return typeof value === 'number' && value > 0 ? value : undefined;
  }

  private static copyNonEmptyString(source: Record<string, Object>, target: Record<string, Object>,
    sourceKey: string, targetKey: string): void {
    const value: Object | undefined = source[sourceKey];
    if (typeof value === 'string' && value.length > 0) {
      target[targetKey] = value;
    }
  }
}
