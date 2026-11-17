const NS_PER_SECOND: number = 1e9;

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

  onCpuSample(ticks: number): void {
    if (this.cpuSamples === 0) {
      this.cpuBaselineTicks = ticks;
      this.cpuLatestTicks = ticks;
    } else {
      this.cpuLatestTicks = Math.max(this.cpuLatestTicks, ticks);
    }
    this.cpuSamples += 1;
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
   * dominated by one sample's rounding).
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
