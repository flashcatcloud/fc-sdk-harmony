import { FlashcatLog } from '@flashcatcloud/core';
import { RumConfiguration } from '../RumConfiguration';
import { GlobalRumMonitor } from '../RumMonitor';
import { RumActionType } from '../RumTypes';

/**
 * Phase-2 auto-instrumentation hub. Holds the active RUM configuration so the
 * tap / navigation trackers can consult their toggles, and provides the entry
 * points the app (or a wrapper) calls so events are recorded without manual
 * `GlobalRumMonitor` calls.
 *
 * Design contract:
 * - configured on `FlashcatRum.enable`, reset on SDK stop (idempotent);
 * - every toggle is opt-in — a tracker is inert unless its config flag is on, so
 *   the surface never over-promises;
 * - never-throw — a tracker bug must not crash the host app;
 * - manual API stays authoritative — these route through the same monitor.
 */
export class RumAutoInstrumentation {
  private static config: RumConfiguration | null = null;

  /** @internal set by FlashcatRum.enable */
  static configure(config: RumConfiguration): void {
    RumAutoInstrumentation.config = config;
    FlashcatLog.d(
      `rum.auto: configured trackUserInteractions=${config.trackUserInteractions} ` +
      `trackNavigation=${config.trackNavigation} trackNetworkRequests=${config.trackNetworkRequests}`);
  }

  /** @internal set on SDK stop so post-stop calls are inert. */
  static reset(): void {
    RumAutoInstrumentation.config = null;
  }

  static config_(): RumConfiguration | null {
    return RumAutoInstrumentation.config;
  }

  static isTapTrackingEnabled(): boolean {
    const c: RumConfiguration | null = RumAutoInstrumentation.config;
    return c !== null && c.trackUserInteractions;
  }

  static isNavigationTrackingEnabled(): boolean {
    const c: RumConfiguration | null = RumAutoInstrumentation.config;
    return c !== null && c.trackNavigation;
  }

  /**
   * Auto-record a TAP action on the given target. No-op unless RUM is enabled
   * with `trackUserInteractions(true)`. Wrap a component's `onClick` with this
   * (or route every click through one shared handler) to get the interaction
   * timeline without a manual `addAction` per component.
   */
  static trackTap(target: string, attributes?: Record<string, Object>): void {
    if (!RumAutoInstrumentation.isTapTrackingEnabled()) {
      return;
    }
    const name: string = RumAutoInstrumentation.resolveTarget(target);
    try {
      GlobalRumMonitor.get().addAction(RumActionType.TAP, name, attributes);
      FlashcatLog.d(`rum.tap: auto action tap target="${name}"`);
    } catch (e) {
      // The tap path must never throw into the app's click handler.
      FlashcatLog.e(`rum.tap: failed: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  /**
   * Target-name resolution (OQ-3): prefer the dev-supplied label; fall back to a
   * stable placeholder. (Accessibility-text resolution is a later refinement —
   * the app supplies the label at the call site for now.)
   */
  private static resolveTarget(target: string): string {
    const t: string = target.trim();
    return t.length > 0 ? t : 'unknown_target';
  }
}
