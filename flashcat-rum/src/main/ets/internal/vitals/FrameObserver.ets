import { FlashcatLog } from '@flashcatcloud/core';
import { FrameSample, ViewVitals } from './ViewVitals';
import { VitalsCollector } from './VitalsCollector';

/**
 * The drawn frames of one window. `start` may throw (the device does not
 * support it, the window is gone): the observer then drops the source.
 */
export interface FrameSource {
  start(onFrame: (sample: FrameSample) => void): void;
  stop(): void;
}

/** The frame source for a UI context, or null when its API level has none. */
export type FrameSourceFactory = (context: Object) => Promise<FrameSource | null>;

/**
 * Hands every drawn frame to the open views. Sources listen only while the
 * app is in the foreground, at least one view is open, and vitals are not
 * turned off (`VitalsUpdateFrequency.NEVER`): otherwise no system callback is
 * registered at all.
 *
 * Sources are attached per UI context (`FlashcatRum.startViewTracking`), the
 * same way navigation tracking is. Nothing a source or the system does
 * reaches the host: failures are logged and the source is dropped.
 */
export class FrameObserver implements VitalsCollector {
  private readonly sourceFor: FrameSourceFactory;
  private readonly periodOf: () => number;
  private readonly sources: Map<Object, FrameSource> = new Map<Object, FrameSource>();
  // Contexts whose source is still being built; detach or stop cancels them.
  private readonly pending: Set<Object> = new Set<Object>();
  private readonly views: Set<ViewVitals> = new Set<ViewVitals>();
  private readonly onFrame: (sample: FrameSample) => void;
  private foreground: boolean = false;
  private stopped: boolean = false;
  private observing: boolean = false;

  /** Frames have no period, only on and off: they are observed while the
   * vitals period (`vitalsPeriodMs`) is above 0. `periodOf` is asked again on
   * every change, so a frequency the console publishes applies at once. */
  constructor(sourceFor: FrameSourceFactory, periodOf: () => number) {
    this.sourceFor = sourceFor;
    this.periodOf = periodOf;
    this.onFrame = (sample: FrameSample): void => this.deliver(sample);
  }

  /** Observe the frames of `context`'s window. Idempotent per context. */
  attach(context: Object): void {
    if (this.stopped || this.sources.has(context) || this.pending.has(context)) {
      return;
    }
    this.pending.add(context);
    let request: Promise<FrameSource | null>;
    try {
      request = this.sourceFor(context);
    } catch (e) {
      this.pending.delete(context);
      FrameObserver.log('no frame source', e);
      return;
    }
    request.then((source: FrameSource | null) => {
      if (!this.pending.delete(context) || source === null) {
        return; // detached or stopped meanwhile, or nothing to observe
      }
      this.sources.set(context, source);
      if (this.observing) {
        this.startSource(context, source);
      }
    }).catch((e: Object) => {
      this.pending.delete(context);
      FrameObserver.log('no frame source', e);
    });
  }

  /** Stop observing `context`'s window; without a context, every window. */
  detach(context?: Object): void {
    if (context === undefined) {
      this.pending.clear();
      this.sources.forEach((source: FrameSource) => this.stopSource(source));
      this.sources.clear();
      return;
    }
    this.pending.delete(context);
    const source: FrameSource | undefined = this.sources.get(context);
    if (source !== undefined) {
      this.stopSource(source);
      this.sources.delete(context);
    }
  }

  register(view: ViewVitals): void {
    this.views.add(view);
    this.reconcile();
  }

  unregister(view: ViewVitals): void {
    this.views.delete(view);
    this.reconcile();
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    this.reconcile();
  }

  refreshPeriod(): void {
    this.reconcile();
  }

  stop(): void {
    this.stopped = true;
    this.views.clear();
    this.reconcile();
    this.detach();
  }

  isObserving(): boolean {
    return this.observing;
  }

  private reconcile(): void {
    let observe: boolean = false;
    if (this.foreground && !this.stopped && this.views.size > 0) {
      try {
        observe = this.periodOf() > 0;
      } catch (_e) {
        observe = false;
      }
    }
    if (observe === this.observing) {
      return;
    }
    this.observing = observe;
    this.sources.forEach((source: FrameSource, context: Object) => {
      if (observe) {
        this.startSource(context, source);
      } else {
        this.stopSource(source);
      }
    });
  }

  private startSource(context: Object, source: FrameSource): void {
    try {
      source.start(this.onFrame);
    } catch (e) {
      this.sources.delete(context);
      FrameObserver.log('frame source unavailable; views carry no frame fields', e);
    }
  }

  private stopSource(source: FrameSource): void {
    try {
      source.stop();
    } catch (_e) {
      // already gone
    }
  }

  private deliver(sample: FrameSample): void {
    if (!this.observing) {
      return; // a callback already queued when the source stopped
    }
    this.views.forEach((v: ViewVitals) => v.onFrame(sample));
  }

  private static log(what: string, e: Object): void {
    FlashcatLog.d(`rum.vitals: ${what} (${e instanceof Error ? e.message : 'error'})`);
  }
}
