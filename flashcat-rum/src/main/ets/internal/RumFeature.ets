import { SdkCore, Feature, FeatureEventReceiver, RUM_FEATURE_NAME } from '@flashcatcloud/core';
import { errorManager } from '@kit.AbilityKit';
import { RumConfiguration } from '../RumConfiguration';
import { RumErrorSource } from '../RumTypes';
import { GlobalRumMonitor } from '../RumMonitor';
import { DefaultRumMonitor } from './monitor/DefaultRumMonitor';

/**
 * The RUM feature. Installs the unhandled-exception hook (auto Error capture) and
 * consumes crash events from the bus (phase 2). Equivalent to Android's RumFeature.
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

    // TODO phase 2: navigation auto-tracking, network instrumentation.
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

  /** Bus handler — crash events forwarded from the Crash feature (phase 2). */
  onReceive(event: Record<string, Object>): void {
    // TODO phase 2: map hiAppEvent crash payloads (JS/C++/Freeze) → RUM error.
  }

  private static firstLine(text: string): string {
    const idx: number = text.indexOf('\n');
    return idx >= 0 ? text.substring(0, idx) : text;
  }
}
