import { window, UIContext } from '@kit.ArkUI';
import { process } from '@kit.ArkTS';
import { systemDateTime } from '@kit.BasicServicesKit';
import { FlashcatLog } from '@flashcatcloud/core';
import { FrameHookFactory } from './AppLaunchTracker';
import {
  FramePath, framePathFor, Subscription, WindowFrameMetrics, ObserverDraw, windowOf, uiContextOf
} from '../vitals/SystemFrameSources';

/**
 * How long ago this process started, in milliseconds: the launch clock minus
 * the process start time, which is read on that same clock. Not
 * `process.uptime()`: that is whole seconds, rounded up. Null when either is
 * unavailable or the two do not make a process age (negative, not finite).
 */
export function systemProcessAgeMs(): number | null {
  try {
    const ageMs: number = systemElapsedMs() - process.getStartRealtime();
    return Number.isFinite(ageMs) && ageMs >= 0 ? ageMs : null;
  } catch (_e) {
    return null;
  }
}

/** Milliseconds since boot, deep sleep excluded: the clock launch durations and
 * the process age are measured on, because `process.getStartRealtime()` is on
 * it. Against the clock with deep sleep a process a tenth of a second old
 * measured as old as all the device's sleep since boot (18 h on a phone), and
 * every cold start was taken for a warm one. NaN when the clock cannot be read:
 * it is read inside lifecycle and frame callbacks, where nothing may throw, and
 * NaN measures nothing. */
export function systemElapsedMs(): number {
  try {
    return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, false);
  } catch (_e) {
    return NaN;
  }
}

/**
 * Frame hooks for launch timing on a device on `apiVersion`, over the same
 * window lookup and system events as the per-view frame observer. They differ
 * from it in when they listen: from `startViewTracking` until the SDK stops,
 * whatever the vitals frequency, the foreground or the open views say — a
 * launch's first frame comes before any of those is known. On API 22+ every
 * redraw counts and the system names the window's first frame; on API 12–21
 * every `willDraw` counts, scrolling or not, and none is named.
 */
export function systemFrameHooks(apiVersion: number): FrameHookFactory {
  const path: FramePath = framePathFor(apiVersion);
  return (context: Object, onFrame: (firstDrawFrame: boolean | null) => void): (() => void) | null => {
    try {
      switch (path) {
        case FramePath.FRAME_METRICS:
          return hook<(m: window.FrameMetrics) => void>(
            windowOf(context).then((win: window.Window) => new WindowFrameMetrics(win)),
            (m: window.FrameMetrics): void => {
              let first: boolean;
              try {
                first = m.firstDrawFrame === true;
              } catch (_e) {
                return; // a malformed report is no frame, and never a throw into the system's callback
              }
              onFrame(first);
            });
        case FramePath.SCROLL_DRAW:
          return hook<() => void>(
            uiContextOf(context).then((ui: UIContext) => new ObserverDraw(ui.getUIObserver())),
            (): void => onFrame(null));
        default:
          return null;
      }
    } catch (e) {
      // findWindow throws for a window that is gone
      FlashcatLog.d(`rum.launch: frames not hooked (${e instanceof Error ? e.message : 'error'})`);
      return null;
    }
  };
}

/** Subscribe `callback` once the subscription resolves, unless unhooked first.
 * Neither the lookup nor the system's `on` may throw into the host. */
function hook<C>(subscription: Promise<Subscription<C>>, callback: C): () => void {
  let hooked: Subscription<C> | null = null;
  let unhooked: boolean = false;
  subscription.then((s: Subscription<C>) => {
    if (unhooked) {
      return;
    }
    try {
      s.on(callback);
      hooked = s;
    } catch (e) {
      // 801: the device does not report these frames.
      FlashcatLog.d(`rum.launch: frames not hooked (${e instanceof Error ? e.message : 'error'})`);
    }
  }).catch((_e: Object) => {
    // no window: no frames from this context
  });
  return (): void => {
    unhooked = true;
    if (hooked !== null) {
      hooked.off(callback);
      hooked = null;
    }
  };
}
