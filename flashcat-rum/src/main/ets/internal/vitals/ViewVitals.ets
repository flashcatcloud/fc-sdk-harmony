const NS_PER_SECOND: number = 1e9;

/**
 * The memory and CPU samples taken while one view was open, and the view
 * fields they come to. Pure arithmetic: whoever samples feeds it, the view
 * reads it each time it writes its document.
 *
 * A field is present only when there are samples behind it. A view that never
 * got a reading carries no memory or CPU key at all, rather than a 0 the
 * console would average in as a real measurement.
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
   * `view.*` keys for a view that has been open `durationNs`: memory in bytes,
   * CPU in ticks since the view's first reading, ticks per second once the view
   * has lasted a full second (Android parity: a shorter view gives a rate
   * dominated by one sample's rounding).
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
    return fields;
  }
}
