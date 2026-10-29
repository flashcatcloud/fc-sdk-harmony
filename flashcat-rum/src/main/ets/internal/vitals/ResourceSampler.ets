import { FlashcatLog } from '@flashcatcloud/core';
import { ViewVitals } from './ViewVitals';

/**
 * Where samples come from. Either half is null when this device has no way to
 * take that reading. A reader answers null (or throws, or rejects) when it
 * cannot read: the sampler then stops asking it for good — the system paths
 * behind these readers do not come and go within a process.
 */
export interface ResourceReaders {
  /** Resident memory of the process, in bytes. */
  readonly memoryBytes: (() => Promise<number | null>) | null;
  /** Cumulative user-mode CPU time of the process, in clock ticks. */
  readonly cpuTicks: (() => number | null) | null;
}

/** The sampler's clock. Injected so a test can tick it by hand. */
export interface SamplerTimer {
  every(periodMs: number, tick: () => void): number;
  cancel(id: number): void;
}

class SystemSamplerTimer implements SamplerTimer {
  every(periodMs: number, tick: () => void): number {
    return setInterval(tick, periodMs);
  }

  cancel(id: number): void {
    clearInterval(id);
  }
}

/**
 * Samples memory and CPU at the configured period while the app is in the
 * foreground and at least one view is open, and hands every sample to the
 * open views. Nothing runs in the background, or while no view is there to
 * receive it (an unsampled session opens none).
 *
 * A view registering takes a reading at once, so its CPU baseline is its own
 * start rather than up to one period earlier, and a view shorter than one
 * period still gets a memory sample.
 *
 * A memory read may be asynchronous. One is never started while the previous
 * is still out (no backlog on a slow device), and one that lands after the
 * sampler stopped or restarted is dropped.
 */
export class ResourceSampler {
  private memoryReader: (() => Promise<number | null>) | null;
  private cpuReader: (() => number | null) | null;
  private readonly periodOf: () => number;
  private readonly timer: SamplerTimer;
  private readonly views: Set<ViewVitals> = new Set<ViewVitals>();
  private foreground: boolean = false;
  private stopped: boolean = false;
  private timerId: number = -1;
  private runningPeriodMs: number = 0;
  // Bumped on every halt: a memory read started before it is stale.
  private generation: number = 0;
  private memoryInFlight: boolean = false;

  /** `periodOf` is asked again on every foreground change and refresh, so a
   * frequency the console publishes applies without rebuilding the sampler. */
  constructor(readers: ResourceReaders, periodOf: () => number, timer: SamplerTimer = new SystemSamplerTimer()) {
    this.memoryReader = readers.memoryBytes;
    this.cpuReader = readers.cpuTicks;
    this.periodOf = periodOf;
    this.timer = timer;
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    this.reconcile();
  }

  /** The configured frequency may have changed. */
  refreshPeriod(): void {
    this.reconcile();
  }

  /** SDK stop: for good. */
  stop(): void {
    this.stopped = true;
    this.halt();
    this.views.clear();
  }

  register(view: ViewVitals): void {
    this.views.add(view);
    if (this.isRunning()) {
      this.sampleNow();
    }
  }

  unregister(view: ViewVitals): void {
    this.views.delete(view);
  }

  isRunning(): boolean {
    return this.timerId !== -1;
  }

  private reconcile(): void {
    let period: number = 0;
    if (this.foreground && !this.stopped && (this.memoryReader !== null || this.cpuReader !== null)) {
      try {
        period = this.periodOf();
      } catch (_e) {
        period = 0;
      }
    }
    // 0 exactly when not running, so this also covers "stays off".
    if (period === this.runningPeriodMs) {
      return;
    }
    this.halt();
    if (period <= 0) {
      return;
    }
    try {
      this.timerId = this.timer.every(period, (): void => this.tick());
      this.runningPeriodMs = period;
    } catch (e) {
      this.timerId = -1;
      FlashcatLog.e(`rum.vitals: sampler not started: ${e instanceof Error ? e.message : 'error'}`);
      return;
    }
    if (this.views.size > 0) {
      this.sampleNow();
    }
  }

  private halt(): void {
    if (this.timerId !== -1) {
      try {
        this.timer.cancel(this.timerId);
      } catch (_e) {
        // already gone
      }
    }
    this.timerId = -1;
    this.runningPeriodMs = 0;
    this.generation += 1;
    this.memoryInFlight = false;
  }

  private tick(): void {
    if (this.views.size > 0) {
      this.sampleNow();
    }
  }

  private sampleNow(): void {
    this.readCpu();
    this.readMemory();
  }

  private readCpu(): void {
    const reader: (() => number | null) | null = this.cpuReader;
    if (reader === null) {
      return;
    }
    let ticks: number | null = null;
    try {
      ticks = reader();
    } catch (_e) {
      ticks = null;
    }
    if (!ResourceSampler.isReading(ticks)) {
      this.cpuReader = null;
      FlashcatLog.d('rum.vitals: CPU time is not readable on this device; views carry no CPU fields');
      return;
    }
    const value: number = ticks as number;
    this.views.forEach((v: ViewVitals) => v.onCpuSample(value));
  }

  private readMemory(): void {
    const reader: (() => Promise<number | null>) | null = this.memoryReader;
    if (reader === null || this.memoryInFlight) {
      return;
    }
    const generation: number = this.generation;
    this.memoryInFlight = true;
    let pending: Promise<number | null>;
    try {
      pending = reader();
    } catch (_e) {
      this.memoryInFlight = false;
      this.disableMemory();
      return;
    }
    pending.then((bytes: number | null) => {
      if (generation !== this.generation) {
        return; // stopped or restarted since: not a sample of the current run
      }
      this.memoryInFlight = false;
      if (!ResourceSampler.isReading(bytes)) {
        this.disableMemory();
        return;
      }
      const value: number = bytes as number;
      this.views.forEach((v: ViewVitals) => v.onMemorySample(value));
    }).catch((_e: Object) => {
      if (generation !== this.generation) {
        return;
      }
      this.memoryInFlight = false;
      this.disableMemory();
    });
  }

  private disableMemory(): void {
    this.memoryReader = null;
    FlashcatLog.d('rum.vitals: memory is not readable on this device; views carry no memory fields');
  }

  private static isReading(value: number | null): boolean {
    return typeof value === 'number' && Number.isFinite(value) && value >= 0;
  }
}
