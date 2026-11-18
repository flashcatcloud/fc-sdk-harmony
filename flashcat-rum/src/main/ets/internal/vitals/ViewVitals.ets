const NS_PER_SECOND: number = 1e9;
// USER_HZ: the unit of the CPU times in /proc, fixed by the kernel ABI on the
// architectures HarmonyOS runs on.
const CLOCK_TICKS_PER_SECOND: number = 100;
// iOS parity (CPUUsageInfo): no usage until the view has this much foreground time
// between its readings, and peaks over intervals at least this long, so one
// clock tick in a very short interval does not read as a spike.
const MIN_CPU_USAGE_NS: number = 900_000_000;
const MIN_CPU_PEAK_NS: number = 250_000_000;

/**
 * One reading of CPU time, cumulative since the process (or thread) started, in
 * clock ticks. A reader may hand out the same object every time: whoever takes a
 * reading copies what it needs before the next one.
 */
export interface CpuReading {
  /** User-mode time of the process. */
  userTicks: number;
  /** User- and kernel-mode time of the process, all threads. */
  processTicks: number;
  /** User- and kernel-mode time of the main thread; -1 when it cannot be read. */
  mainThreadTicks: number;
  /** The CPUs the process may run on; 0 when unknown. */
  cores: number;
  /** When it was read: a monotonic clock, in nanoseconds. */
  atNs: number;
}

/** What one drawn frame took, as a frame source measured it. */
export interface FrameSample {
  /** The frame's duration: its UI work (API 22+), or the gap since the previous draw (scroll). */
  durationNs: number;
  /** The display's frame period when the frame was drawn. */
  periodNs: number;
  /** A frame longer than this, and not frozen, is slow. */
  slowAboveNs: number;
}

// Android parity (SlowFramesConfiguration / RumViewScope defaults).
export const FROZEN_FRAME_ABOVE_NS: number = 700_000_000;
export const FREEZE_AT_LEAST_NS: number = 5_000_000_000;
export const SLOW_RENDERED_BELOW_FPS: number = 55;
export const MAX_FPS: number = 60;
// A view this short reports both rates as 0: one frame would dominate them.
export const MIN_VIEW_FOR_RATES_NS: number = NS_PER_SECOND;
const MS_PER_SECOND: number = 1000;
const SECONDS_PER_HOUR: number = 3600;

/**
 * The samples taken while one view was open — memory, CPU and drawn frames —
 * and the view fields they come to. Pure arithmetic: whoever samples feeds it,
 * the view reads it each time it writes its document.
 *
 * A field is present only when there are samples behind it. A view that never
 * got a reading carries no memory, CPU or frame key at all, rather than a 0
 * the console would average in as a real measurement.
 */
export class ViewVitals {
  private memorySamples: number = 0;
  private memorySumBytes: number = 0;
  private memoryMaxBytes: number = 0;
  // utime is cumulative since the process started: the first reading is the
  // view's baseline, and only what comes after it is this view's.
  private cpuSamples: number = 0;
  private cpuBaselineTicks: number = 0;
  private cpuLatestTicks: number = 0;
  // CPU usage: what the process (and its main thread) used over the foreground time
  // between consecutive readings of one sampler run. A run ends when sampling halts
  // (background): the time to the next run's first reading is not counted.
  private cpuRun: number = -1;
  private cores: number = 0;
  private lastAtNs: number = 0;
  private lastProcessTicks: number = 0;
  private lastMainTicks: number = -1;
  private processNs: number = 0;
  private processTicks: number = 0;
  private mainNs: number = 0;
  private mainTicks: number = 0;
  private peakFromNs: number = 0;
  private peakFromProcessTicks: number = 0;
  private peakFromMainTicks: number = -1;
  private processPeak: number = -1;
  private mainPeak: number = -1;
  private frames: number = 0;
  private fpsSum: number = 0;
  private fpsMin: number = MAX_FPS;
  private slowFrames: number = 0;
  private frozenFrames: number = 0;
  private slowNs: number = 0;
  private freezeNs: number = 0;
  private totalFrameNs: number = 0;

  onMemorySample(bytes: number): void {
    this.memorySamples += 1;
    this.memorySumBytes += bytes;
    this.memoryMaxBytes = Math.max(this.memoryMaxBytes, bytes);
  }

  /** A CPU reading of sampler run `run`; `cpu` may be reused by the reader after this returns. */
  onCpuSample(cpu: CpuReading, run: number): void {
    const ticks: number = cpu.userTicks;
    if (this.cpuSamples === 0) {
      this.cpuBaselineTicks = ticks;
      this.cpuLatestTicks = ticks;
    } else {
      this.cpuLatestTicks = Math.max(this.cpuLatestTicks, ticks);
    }
    this.cpuSamples += 1;
    if (cpu.cores > 0) {
      this.cores = cpu.cores;
    }
    const main: number = cpu.mainThreadTicks;
    if (run === this.cpuRun && cpu.atNs <= this.lastAtNs) {
      return; // no time since the last reading: what it adds is counted with the next one
    }
    if (run === this.cpuRun) {
      const elapsedNs: number = cpu.atNs - this.lastAtNs;
      this.processNs += elapsedNs;
      this.processTicks += Math.max(0, cpu.processTicks - this.lastProcessTicks);
      if (main >= 0 && this.lastMainTicks >= 0) {
        this.mainNs += elapsedNs;
        this.mainTicks += Math.max(0, main - this.lastMainTicks);
      }
      const peakNs: number = cpu.atNs - this.peakFromNs;
      if (peakNs >= MIN_CPU_PEAK_NS) {
        if (this.cores > 0) {
          this.processPeak = Math.max(this.processPeak,
            ViewVitals.usage(cpu.processTicks - this.peakFromProcessTicks, peakNs, this.cores));
        }
        if (main >= 0 && this.peakFromMainTicks >= 0) {
          this.mainPeak = Math.max(this.mainPeak, ViewVitals.usage(main - this.peakFromMainTicks, peakNs, 1));
        }
        this.startPeakInterval(cpu);
      }
    } else {
      this.startPeakInterval(cpu);
    }
    this.cpuRun = run;
    this.lastAtNs = cpu.atNs;
    this.lastProcessTicks = cpu.processTicks;
    this.lastMainTicks = main;
  }

  private startPeakInterval(cpu: CpuReading): void {
    this.peakFromNs = cpu.atNs;
    this.peakFromProcessTicks = cpu.processTicks;
    this.peakFromMainTicks = cpu.mainThreadTicks;
  }

  /** Percent of `cores` cores that `ticks` of CPU time took over `ns`, within 0..100. */
  private static usage(ticks: number, ns: number, cores: number): number {
    const percent: number = ticks / CLOCK_TICKS_PER_SECOND / (ns / NS_PER_SECOND * cores) * 100;
    return Math.min(100, Math.max(0, percent));
  }

  /**
   * One drawn frame. Its rate is normalised to a 60 Hz display and capped at
   * 60 (Android parity): a frame that met the display's deadline reads 60
   * whatever the display's rate. A frame of no measurable work reads 60.
   * Slow: longer than the source's slow bound, up to 700 ms. Frozen: longer
   * than 700 ms. A frame of 5 s or more also counts towards the freeze rate.
   */
  onFrame(sample: FrameSample): void {
    const duration: number = sample.durationNs;
    const period: number = sample.periodNs;
    if (!Number.isFinite(duration) || duration < 0 || !Number.isFinite(period) || period <= 0) {
      return;
    }
    const fps: number = duration === 0 ? MAX_FPS : Math.min(MAX_FPS, MAX_FPS * period / duration);
    this.frames += 1;
    this.fpsSum += fps;
    this.fpsMin = Math.min(this.fpsMin, fps);
    if (duration > FROZEN_FRAME_ABOVE_NS) {
      this.frozenFrames += 1;
    } else if (duration > sample.slowAboveNs) {
      this.slowFrames += 1;
      this.slowNs += duration;
    }
    if (duration >= FREEZE_AT_LEAST_NS) {
      this.freezeNs += duration;
    }
    // A frame occupies at least one display period, however little work it took.
    this.totalFrameNs += Math.max(duration, period);
  }

  /**
   * `view.*` keys for a view that has been open `durationNs`: memory in bytes,
   * CPU in ticks since the view's first reading, ticks per second once the view
   * has lasted a full second (Android parity: a shorter view gives a rate
   * dominated by one sample's rounding). It also carries CPU usage as a percentage
   * (the process of all its cores, the main thread of one core) once the view has
   * 0.9 s of foreground time between readings (iOS parity).
   *
   * Frame keys come with the first frame. The two rates are on every document
   * (not only the last, as on Android), so whichever write closes the view
   * carries them; a view of a second or less reports them as 0.
   */
  toFields(durationNs: number): Record<string, Object> {
    const fields: Record<string, Object> = {};
    if (this.memorySamples > 0) {
      fields['memory_average'] = this.memorySumBytes / this.memorySamples;
      fields['memory_max'] = this.memoryMaxBytes;
    }
    if (this.cpuSamples >= 2) {
      const ticks: number = this.cpuLatestTicks - this.cpuBaselineTicks;
      fields['cpu_ticks_count'] = ticks;
      if (durationNs >= NS_PER_SECOND) {
        fields['cpu_ticks_per_second'] = ticks * NS_PER_SECOND / durationNs;
      }
    }
    // iOS parity: the average over the view's foreground time, and a peak that is at
    // least the average (a busy trailing interval shorter than a peak interval still
    // counts in the average).
    if (this.processNs >= MIN_CPU_USAGE_NS && this.cores > 0) {
      const average: number = ViewVitals.usage(this.processTicks, this.processNs, this.cores);
      fields['cpu_usage_average'] = average;
      fields['cpu_usage_max'] = Math.max(this.processPeak, average);
    }
    if (this.mainNs >= MIN_CPU_USAGE_NS) {
      const average: number = ViewVitals.usage(this.mainTicks, this.mainNs, 1);
      fields['main_thread_cpu_usage_average'] = average;
      fields['main_thread_cpu_usage_max'] = Math.max(this.mainPeak, average);
    }
    if (this.frames > 0) {
      const average: number = this.fpsSum / this.frames;
      fields['refresh_rate_average'] = average;
      fields['refresh_rate_min'] = this.fpsMin;
      fields['is_slow_rendered'] = average < SLOW_RENDERED_BELOW_FPS;
      fields['slow_frame'] = ViewVitals.count(this.slowFrames);
      fields['frozen_frame'] = ViewVitals.count(this.frozenFrames);
      const rated: boolean = durationNs > MIN_VIEW_FOR_RATES_NS;
      fields['slow_frames_rate'] = rated && this.totalFrameNs > 0
        ? this.slowNs / this.totalFrameNs * MS_PER_SECOND : 0;
      fields['freeze_rate'] = rated ? this.freezeNs / durationNs * SECONDS_PER_HOUR : 0;
    }
    return fields;
  }

  private static count(n: number): Record<string, Object> {
    const c: Record<string, Object> = {};
    c['count'] = n;
    return c;
  }
}
