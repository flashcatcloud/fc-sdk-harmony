import { window, UIContext, UIObserver, uiObserver } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { FrameSample } from './ViewVitals';
import { FrameSource, FrameSourceFactory } from './FrameObserver';

export const DEFAULT_FRAME_PERIOD_NS: number = 1e9 / 60;
// Draw gaps carry the period they were drawn in plus timer jitter: only a gap
// half a period late counts as a missed frame.
export const SCROLL_SLOW_FACTOR: number = 1.5;
// Vsync gaps outside 20–250 Hz are idle time between redraws, not the period.
const MIN_PERIOD_NS: number = 4_000_000;
const MAX_PERIOD_NS: number = 50_000_000;
const PERIOD_BUCKET_NS: number = 1_000_000;
const PERIOD_WINDOW: number = 120;
const PERIOD_MIN_EVIDENCE: number = 3;

/** How drawn frames are observed on a given API level. */
export enum FramePath {
  /** API 22+: window frameMetricsMeasured, called only when the window redraws, with the UI work of the frame. */
  FRAME_METRICS = 'frame_metrics',
  /** API 12–21: the gaps between willDraw calls, counted only while something scrolls. */
  SCROLL_DRAW = 'scroll_draw',
  NONE = 'none'
}

export function framePathFor(apiVersion: number): FramePath {
  if (apiVersion >= 22) {
    return FramePath.FRAME_METRICS;
  }
  if (apiVersion >= 12) {
    return FramePath.SCROLL_DRAW;
  }
  return FramePath.NONE;
}

/** A system event a frame source listens to. `on` may throw. */
export interface Subscription<C> {
  on(callback: C): void;
  off(callback: C): void;
}

/**
 * The display's frame period, from the vsync timestamps of drawn frames: the
 * most common gap between consecutive ones (the display rate can change, so
 * only recent gaps count). 60 Hz until there is enough evidence.
 */
export class FramePeriodEstimator {
  private readonly gaps: number[] = [];
  private next: number = 0;
  private lastVsyncNs: number = -1;
  // The period of the gaps as they are; recomputed only when a gap is added.
  private cachedPeriodNs: number = DEFAULT_FRAME_PERIOD_NS;
  private stale: boolean = false;

  /** The next frame does not follow the last one seen (observation restarted). */
  reset(): void {
    this.lastVsyncNs = -1;
  }

  onVsync(vsyncNs: number): void {
    if (this.lastVsyncNs >= 0) {
      const gap: number = vsyncNs - this.lastVsyncNs;
      if (gap >= MIN_PERIOD_NS && gap <= MAX_PERIOD_NS) {
        if (this.gaps.length < PERIOD_WINDOW) {
          this.gaps.push(gap);
        } else {
          this.gaps[this.next] = gap;
          this.next = (this.next + 1) % PERIOD_WINDOW;
        }
        this.stale = true;
      }
    }
    this.lastVsyncNs = vsyncNs;
  }

  periodNs(): number {
    if (this.stale) {
      this.cachedPeriodNs = this.computePeriodNs();
      this.stale = false;
    }
    return this.cachedPeriodNs;
  }

  private computePeriodNs(): number {
    const counts: Map<number, number> = new Map<number, number>();
    const sums: Map<number, number> = new Map<number, number>();
    let best: number = -1;
    let bestCount: number = 0;
    for (const gap of this.gaps) {
      const bucket: number = Math.round(gap / PERIOD_BUCKET_NS);
      const count: number = (counts.get(bucket) ?? 0) + 1;
      counts.set(bucket, count);
      sums.set(bucket, (sums.get(bucket) ?? 0) + gap);
      // On a tie the shorter period wins: the stricter deadline.
      if (count > bestCount || (count === bestCount && bucket < best)) {
        best = bucket;
        bestCount = count;
      }
    }
    if (bestCount < PERIOD_MIN_EVIDENCE) {
      return DEFAULT_FRAME_PERIOD_NS;
    }
    return (sums.get(best) as number) / bestCount;
  }
}

/**
 * API 22+. A frame's duration is its UI work: input handling plus layout and
 * measure, the two stages the system reports. It is slow when that alone
 * overruns the display period.
 */
export class FrameMetricsSource implements FrameSource {
  private readonly metrics: Subscription<(m: window.FrameMetrics) => void>;
  private readonly period: FramePeriodEstimator = new FramePeriodEstimator();
  private callback: ((m: window.FrameMetrics) => void) | null = null;

  constructor(metrics: Subscription<(m: window.FrameMetrics) => void>) {
    this.metrics = metrics;
  }

  start(onFrame: (sample: FrameSample) => void): void {
    if (this.callback !== null) {
      return;
    }
    this.period.reset();
    const callback = (m: window.FrameMetrics): void => {
      try {
        this.period.onVsync(m.vsyncTimestamp);
        const period: number = this.period.periodNs();
        onFrame({
          durationNs: m.inputHandlingDuration + m.layoutMeasureDuration,
          periodNs: period,
          slowAboveNs: period
        });
      } catch (_e) {
        // never into the host's frame callback
      }
    };
    this.metrics.on(callback);
    this.callback = callback;
  }

  stop(): void {
    const callback: ((m: window.FrameMetrics) => void) | null = this.callback;
    if (callback === null) {
      return;
    }
    this.callback = null;
    this.metrics.off(callback);
  }
}

/**
 * API 12–21, where no redraw signal carries a duration. While something
 * scrolls, every frame is drawn, so the gap between two draw calls is a
 * frame's duration. Outside a scroll a gap means nothing (the window may sit
 * idle between draws), so the draw callback is only registered while at
 * least one scrollable is moving.
 */
export class ScrollDrawSource implements FrameSource {
  private readonly scroll: Subscription<(info: uiObserver.ScrollEventInfo) => void>;
  private readonly draw: Subscription<() => void>;
  private readonly clockNs: () => number;
  private readonly scrolling: Set<number> = new Set<number>();
  private readonly onScroll: (info: uiObserver.ScrollEventInfo) => void;
  private readonly onDraw: () => void;
  private sink: ((sample: FrameSample) => void) | null = null;
  private drawing: boolean = false;
  private lastDrawNs: number = -1;

  constructor(scroll: Subscription<(info: uiObserver.ScrollEventInfo) => void>,
    draw: Subscription<() => void>, clockNs: () => number) {
    this.scroll = scroll;
    this.draw = draw;
    this.clockNs = clockNs;
    this.onScroll = (info: uiObserver.ScrollEventInfo): void => {
      try {
        this.scrolled(info);
      } catch (_e) {
        // never into the host's scroll callback
      }
    };
    this.onDraw = (): void => {
      try {
        this.drew();
      } catch (_e) {
        // never into the host's draw callback
      }
    };
  }

  start(onFrame: (sample: FrameSample) => void): void {
    if (this.sink !== null) {
      return;
    }
    this.scroll.on(this.onScroll);
    this.sink = onFrame;
  }

  stop(): void {
    if (this.sink === null) {
      return;
    }
    this.sink = null;
    this.scrolling.clear();
    this.stopDrawing();
    this.scroll.off(this.onScroll);
  }

  private scrolled(info: uiObserver.ScrollEventInfo): void {
    if (this.sink === null) {
      return;
    }
    if (info.scrollEvent === uiObserver.ScrollEventType.SCROLL_START) {
      this.scrolling.add(info.uniqueId);
      if (!this.drawing) {
        this.lastDrawNs = -1;
        this.draw.on(this.onDraw);
        this.drawing = true;
      }
    } else if (info.scrollEvent === uiObserver.ScrollEventType.SCROLL_STOP) {
      this.scrolling.delete(info.uniqueId);
      if (this.scrolling.size === 0) {
        this.stopDrawing();
      }
    }
  }

  private drew(): void {
    const sink: ((sample: FrameSample) => void) | null = this.sink;
    if (sink === null || !this.drawing) {
      return;
    }
    const now: number = this.clockNs();
    const last: number = this.lastDrawNs;
    this.lastDrawNs = now;
    if (last >= 0 && now > last) {
      sink({
        durationNs: now - last,
        periodNs: DEFAULT_FRAME_PERIOD_NS,
        slowAboveNs: DEFAULT_FRAME_PERIOD_NS * SCROLL_SLOW_FACTOR
      });
    }
  }

  private stopDrawing(): void {
    if (!this.drawing) {
      return;
    }
    this.drawing = false;
    this.lastDrawNs = -1;
    try {
      this.draw.off(this.onDraw);
    } catch (_e) {
      // already gone
    }
  }
}

export class WindowFrameMetrics implements Subscription<(m: window.FrameMetrics) => void> {
  private readonly win: window.Window;

  constructor(win: window.Window) {
    this.win = win;
  }

  on(callback: (m: window.FrameMetrics) => void): void {
    this.win.on('frameMetricsMeasured', callback);
  }

  off(callback: (m: window.FrameMetrics) => void): void {
    this.win.off('frameMetricsMeasured', callback);
  }
}

class ObserverScroll implements Subscription<(info: uiObserver.ScrollEventInfo) => void> {
  private readonly observer: UIObserver;

  constructor(observer: UIObserver) {
    this.observer = observer;
  }

  on(callback: (info: uiObserver.ScrollEventInfo) => void): void {
    this.observer.on('scrollEvent', callback);
  }

  off(callback: (info: uiObserver.ScrollEventInfo) => void): void {
    this.observer.off('scrollEvent', callback);
  }
}

export class ObserverDraw implements Subscription<() => void> {
  private readonly observer: UIObserver;

  constructor(observer: UIObserver) {
    this.observer = observer;
  }

  on(callback: () => void): void {
    this.observer.on('willDraw', callback);
  }

  off(callback: () => void): void {
    this.observer.off('willDraw', callback);
  }
}

/** The window a navigation context draws in: a UIContext's own, an ability's last shown. */
export function windowOf(context: Object): Promise<window.Window> {
  if (context instanceof UIContext) {
    const name: string | undefined = context.getWindowName();
    if (name !== undefined) {
      return Promise.resolve(window.findWindow(name));
    }
    const host: common.Context | undefined = context.getHostContext() as common.Context | undefined;
    if (host === undefined) {
      return Promise.reject(new Error('UI context has no window'));
    }
    return window.getLastWindow(host);
  }
  return window.getLastWindow(context as common.BaseContext);
}

export function uiContextOf(context: Object): Promise<UIContext> {
  if (context instanceof UIContext) {
    return Promise.resolve(context);
  }
  return windowOf(context).then((win: window.Window) => win.getUIContext());
}

function uptimeNs(): number {
  // Monotonic, unlike Date.now(): a wall-clock change mid-scroll is no frame.
  return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true);
}

/** The frame sources for a device on `apiVersion`. Looking up a window may
 * reject; the observer contains it. */
export function systemFrameSources(apiVersion: number): FrameSourceFactory {
  const path: FramePath = framePathFor(apiVersion);
  return (context: Object): Promise<FrameSource | null> => {
    switch (path) {
      case FramePath.FRAME_METRICS:
        return windowOf(context).then((win: window.Window): FrameSource =>
          new FrameMetricsSource(new WindowFrameMetrics(win)));
      case FramePath.SCROLL_DRAW:
        return uiContextOf(context).then((ui: UIContext): FrameSource => {
          const observer: UIObserver = ui.getUIObserver();
          return new ScrollDrawSource(new ObserverScroll(observer), new ObserverDraw(observer), uptimeNs);
        });
      default:
        return Promise.resolve(null);
    }
  };
}
