import { SdkCore, Feature, FeatureEventReceiver, RUM_FEATURE_NAME } from '@flashcatcloud/core';
import { errorManager } from '@kit.AbilityKit';
import { RumConfiguration } from '../RumConfiguration';
import { RumErrorSource, RumResourceKind, RumResourceMethod } from '../RumTypes';
import { GlobalRumMonitor } from '../RumMonitor';
import { DefaultRumMonitor } from './monitor/DefaultRumMonitor';

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
  }

  onInitialize(): void {
    this.core.setEventReceiver(RUM_FEATURE_NAME, this);

    // Auto Error capture: turn uncaught ArkTS exceptions into RUM error events.
    // The callback reads `this.monitor` at error-time, by which point it is set.
    // CRITICAL: this runs inside the global exception handler — it must NEVER throw
    // (that would crash the host app), and must guard against re-entrancy (an error
    // raised while reporting an error must not be re-processed into a loop).
    this.errorObserverId = errorManager.on('error', {
      onUnhandledException: (errMsg: string) => {
        if (this.handlingError) {
          return;
        }
        this.handlingError = true;
        try {
          const m: DefaultRumMonitor | null = this.monitor;
          if (m !== null) {
            m.reportError(RumFeature.firstLine(errMsg), RumErrorSource.SOURCE, errMsg, false, 'unhandled');
          }
        } catch (_e) {
          // Swallow — the error handler must not throw.
        } finally {
          this.handlingError = false;
        }
      }
    });

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
    this.monitor = null;
    // Reset the global so post-stop GlobalRumMonitor.get() returns the no-op, not a
    // monitor wired to a torn-down core.
    GlobalRumMonitor.reset();
  }

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

  private static firstLine(text: string): string {
    const idx: number = text.indexOf('\n');
    return idx >= 0 ? text.substring(0, idx) : text;
  }
}
