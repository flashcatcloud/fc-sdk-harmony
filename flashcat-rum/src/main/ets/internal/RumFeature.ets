import { SdkCore, Feature, FeatureEventReceiver, RUM_FEATURE_NAME, FlashcatLog } from '@flashcatcloud/core';
import { errorManager } from '@kit.AbilityKit';
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

    // Auto Error capture: turn uncaught ArkTS exceptions into RUM error events.
    // The callback reads `this.monitor` at error-time, by which point it is set.
    // CRITICAL: this runs inside the global exception handler — it must NEVER throw
    // (that would crash the host app), and must guard against re-entrancy (an error
    // raised while reporting an error must not be re-processed into a loop).
    try {
      this.errorObserverId = errorManager.on('error', {
        onUnhandledException: (errMsg: string) => {
          FlashcatLog.d(`rum.error: onUnhandledException len=${errMsg.length}`);
          this.reportUnhandledError(errMsg);
        },
        onException: (errObject: Error) => {
          const text: string = RumFeature.unhandledErrorText(errObject);
          FlashcatLog.d(`rum.error: onException len=${text.length}`);
          this.reportUnhandledError(text);
        }
      });
      FlashcatLog.d(`rum.error: observer registered id=${this.errorObserverId}`);
    } catch (e) {
      this.errorObserverId = -1;
      FlashcatLog.e(`rum.error: observer registration failed: ${RumFeature.errorText(e)}`);
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
   * `is_crash` error. Native symbolication metadata (binary images, arch) rides
   * along as internal `_dd.crash.*` attributes for the backend symbolicator.
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
      RumFeature.crashAttributes(event));
  }

  /** Pure: extract native-symbolication metadata from a crash_report bus event. */
  static crashAttributes(event: Record<string, Object>): Record<string, Object> {
    const attributes: Record<string, Object> = {};
    const images: Object | undefined = event['binary_images'];
    if (typeof images === 'string' && images.length > 0) {
      attributes['_dd.crash.binary_images'] = images;
    }
    const arch: Object | undefined = event['arch'];
    if (typeof arch === 'string' && arch.length > 0) {
      attributes['_dd.crash.arch'] = arch;
    }
    const kind: Object | undefined = event['crash_kind'];
    if (typeof kind === 'string' && kind.length > 0) {
      attributes['_dd.crash.kind'] = kind;
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

  private reportUnhandledError(stackText: string): void {
    if (this.handlingError) {
      FlashcatLog.d('rum.error: skipped re-entrant unhandled error');
      return;
    }
    this.handlingError = true;
    try {
      const m: DefaultRumMonitor | null = this.monitor;
      if (m !== null) {
        FlashcatLog.d(`rum.error: report unhandled isCrash=true firstLine="${RumFeature.firstLine(stackText)}"`);
        m.reportError(RumFeature.firstLine(stackText), RumErrorSource.SOURCE, stackText, true, 'unhandled');
      } else {
        FlashcatLog.d('rum.error: dropped because monitor is null');
      }
    } catch (e) {
      // Swallow — the error handler must not throw.
      FlashcatLog.e(`rum.error: report failed: ${RumFeature.errorText(e)}`);
    } finally {
      this.handlingError = false;
    }
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

  private static firstLine(text: string): string {
    const idx: number = text.indexOf('\n');
    return idx >= 0 ? text.substring(0, idx) : text;
  }

  private static errorText(value: Object): string {
    return value instanceof Error ? value.message : `${value}`;
  }
}
