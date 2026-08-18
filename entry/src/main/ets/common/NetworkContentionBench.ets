import { http } from '@kit.NetworkKit';
import { Flashcat, TrackingConsent } from '@flashcatcloud/core';
import { GlobalRumMonitor, RumActionType, RumMonitor } from '@flashcatcloud/rum';

/**
 * Measures how much SDK upload traffic slows the app's own requests.
 *
 * BETWEEN-GROUP design: one group per app run, compared across runs. An earlier
 * version alternated uploads on/off round by round inside a single run, which
 * reads as the stronger design — it cancels drift — but it silently breaks.
 * Consent PENDING stops new drains, not an HTTP upload already in flight, so as
 * soon as an upload outlives its round it spills into the supposedly quiet arm
 * and both arms end up carrying upload traffic. Measured at 0.5 Mbps that wiped
 * the effect out entirely (p95 delta fell from +32..44% to ~0).
 *
 * Groups are therefore whole runs, matching the three-group experiment used for
 * the Android investigation. Drift is handled by repeating each group and
 * comparing medians instead.
 *
 * Load is organic: events are generated continuously and the SDK's own scheduler
 * decides when to upload. There is deliberately no flush() — forcing the upload
 * bypasses the batch window, the cycle interval and the per-cycle bound, which
 * is to say it bypasses every setting the experiment exists to compare.
 */
export interface BenchSample {
  round: number;
  durationMs: number;
  ok: boolean;
}

export interface BenchStats {
  count: number;
  meanMs: number;
  p50Ms: number;
  p95Ms: number;
  failures: number;
}

export class NetworkContentionBench {
  private static generatorId: number = -1;

  /**
   * @param uploading false runs the baseline group: consent stays PENDING and no
   *   events are generated, so the SDK contributes no traffic at all.
   * @param eventsPerTick events emitted every 20 ms while the group runs. Raise
   *   it until uploads occupy a meaningful share of the link — RUM events
   *   compress hard (roughly 25 bytes each on the wire), so a low rate produces
   *   nothing to contend with.
   */
  static async runGroup(url: string, rounds: number, bodyBytes: number, eventsPerTick: number,
    uploading: boolean, onProgress: (done: number, total: number) => void): Promise<BenchSample[]> {
    const body: string = 'x'.repeat(bodyBytes);
    const samples: Array<BenchSample> = [];
    if (uploading) {
      Flashcat.setTrackingConsent(TrackingConsent.GRANTED);
      NetworkContentionBench.startGenerator(eventsPerTick);
    } else {
      Flashcat.setTrackingConsent(TrackingConsent.PENDING);
    }
    // Let the group's steady state establish before the first measurement: with
    // uploads on, the first batch has to reach the wire or the early rounds
    // measure an idle link and drag the group's mean toward the baseline.
    await NetworkContentionBench.pause(2000);
    try {
      for (let i: number = 0; i < rounds; i++) {
        samples.push(await NetworkContentionBench.timeRequest(url, body, i));
        await NetworkContentionBench.pause(200);
        onProgress(i + 1, rounds);
      }
    } finally {
      NetworkContentionBench.stopGenerator();
      Flashcat.setTrackingConsent(TrackingConsent.GRANTED);
    }
    return samples;
  }

  private static startGenerator(eventsPerTick: number): void {
    NetworkContentionBench.stopGenerator();
    const monitor: RumMonitor = GlobalRumMonitor.get();
    let seq: number = 0;
    NetworkContentionBench.generatorId = setInterval((): void => {
      for (let n: number = 0; n < eventsPerTick; n++) {
        seq += 1;
        monitor.addAction(RumActionType.CUSTOM, 'bench_event', { 'seq': seq as Object });
      }
    }, 20);
  }

  private static stopGenerator(): void {
    if (NetworkContentionBench.generatorId !== -1) {
      clearInterval(NetworkContentionBench.generatorId);
      NetworkContentionBench.generatorId = -1;
    }
  }

  private static pause(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private static async timeRequest(url: string, body: string, round: number): Promise<BenchSample> {
    const client: http.HttpRequest = http.createHttp();
    const startedAt: number = Date.now();
    let ok: boolean = false;
    try {
      const response: http.HttpResponse = await client.request(url, {
        // POST with a real payload. A bare GET sends almost nothing, so it costs
        // almost no uplink and cannot be delayed however narrow the link is —
        // an earlier run measured 2 ms round-trips and reported pure noise.
        method: http.RequestMethod.POST,
        extraData: body,
        header: { 'Content-Type': 'application/json' } as Record<string, string>,
        usingCache: false,
        connectTimeout: 30000,
        readTimeout: 30000
      });
      ok = response.responseCode >= 200 && response.responseCode < 400;
    } catch (_e) {
      ok = false;
    } finally {
      client.destroy();
    }
    return { round, durationMs: Date.now() - startedAt, ok };
  }

  static summarize(samples: Array<BenchSample>): BenchStats {
    const values: Array<number> = samples
      .filter((s: BenchSample) => s.ok)
      .map((s: BenchSample) => s.durationMs)
      .sort((a: number, b: number) => a - b);
    const failures: number = samples.length - values.length;
    if (values.length === 0) {
      return { count: 0, meanMs: 0, p50Ms: 0, p95Ms: 0, failures };
    }
    let sum: number = 0;
    for (const v of values) {
      sum += v;
    }
    return {
      count: values.length,
      meanMs: Math.round(sum / values.length),
      p50Ms: NetworkContentionBench.percentile(values, 50),
      p95Ms: NetworkContentionBench.percentile(values, 95),
      failures
    };
  }

  /** Nearest-rank on an already-sorted array. */
  private static percentile(sorted: Array<number>, p: number): number {
    const rank: number = Math.ceil((p / 100) * sorted.length);
    const index: number = rank < 1 ? 0 : (rank > sorted.length ? sorted.length : rank) - 1;
    return sorted[index];
  }
}
