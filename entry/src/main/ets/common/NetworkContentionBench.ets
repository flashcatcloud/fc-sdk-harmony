import { http } from '@kit.NetworkKit';
import { Flashcat, TrackingConsent } from '@flashcatcloud/core';
import { GlobalRumMonitor, RumActionType, RumMonitor } from '@flashcatcloud/rum';

/**
 * Measures how much SDK upload traffic slows the app's own requests.
 *
 * Method mirrors the alternating A/B used for the Android investigation: the two
 * arms are interleaved round by round rather than run as two blocks, so network
 * drift over the session cancels out instead of landing entirely on whichever
 * arm ran second. A block design is what made the first Android numbers
 * unusable.
 *
 * The only difference between arms is whether the SDK is uploading:
 *
 * - PAUSED  — consent PENDING. Every drain is stopped and no events are
 *   generated, so nothing accumulates to flush later.
 * - ACTIVE  — consent GRANTED, a fixed number of events generated, then an
 *   explicit flush so the upload is in flight *while* the measured request runs.
 *   Without the flush the scheduler might not have started before the request
 *   finished, and the arm would measure nothing.
 */
export enum BenchArm {
  UPLOADS_PAUSED = 'uploads_paused',
  UPLOADS_ACTIVE = 'uploads_active'
}

export interface BenchSample {
  round: number;
  arm: BenchArm;
  durationMs: number;
  ok: boolean;
}

export interface ArmStats {
  arm: BenchArm;
  count: number;
  meanMs: number;
  p50Ms: number;
  p95Ms: number;
}

export interface BenchReport {
  paused: ArmStats;
  active: ArmStats;
  /** Positive means requests were slower while the SDK was uploading. */
  deltaPercentMean: number;
  deltaPercentP95: number;
  failures: number;
}

export class NetworkContentionBench {
  /**
   * @param url the app's own request under test — use something representative
   *   of a latency-sensitive call, not a CDN asset.
   * @param rounds rounds per arm; the harness runs 2 x rounds requests.
   * @param eventsPerRound RUM events generated per ACTIVE round. Raise it to
   *   model an event flood (offline replay, error storm).
   */
  static async run(url: string, rounds: number, eventsPerRound: number, requestBodyBytes: number,
    onProgress: (done: number, total: number) => void): Promise<BenchSample[]> {
    const body: string = 'x'.repeat(requestBodyBytes);
    const samples: Array<BenchSample> = [];
    const total: number = rounds * 2;
    for (let i: number = 0; i < total; i++) {
      const arm: BenchArm = (i % 2 === 0) ? BenchArm.UPLOADS_PAUSED : BenchArm.UPLOADS_ACTIVE;
      await NetworkContentionBench.prepareArm(arm, eventsPerRound);
      const sample: BenchSample = await NetworkContentionBench.timeRequest(url, body, i, arm);
      samples.push(sample);
      onProgress(i + 1, total);
    }
    // Leave the SDK in its normal state rather than whatever the last arm set.
    Flashcat.setTrackingConsent(TrackingConsent.GRANTED);
    return samples;
  }

  private static async prepareArm(arm: BenchArm, eventsPerRound: number): Promise<void> {
    if (arm === BenchArm.UPLOADS_PAUSED) {
      // Stops every drain. Nothing is generated either, so the next ACTIVE round
      // does not inherit a backlog that would distort its load.
      Flashcat.setTrackingConsent(TrackingConsent.PENDING);
      await NetworkContentionBench.settle();
      return;
    }
    Flashcat.setTrackingConsent(TrackingConsent.GRANTED);
    await NetworkContentionBench.settle(); // consent change in effect before load
    const monitor: RumMonitor = GlobalRumMonitor.get();
    for (let n: number = 0; n < eventsPerRound; n++) {
      monitor.addAction(RumActionType.CUSTOM, 'bench_event', { 'seq': n as Object });
    }
    Flashcat.flush();
    // Deliberately NO settle here. The measured request has to start while the
    // upload is still on the wire — that overlap is the entire experiment. An
    // earlier version waited 150 ms after the flush and reported no effect,
    // because a batch this size clears the link in well under that and the
    // request then ran against an idle link.
  }

  /** Short pause so the arm's upload state is actually in effect before timing. */
  private static settle(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 150);
    });
  }

  private static async timeRequest(url: string, body: string, round: number,
    arm: BenchArm): Promise<BenchSample> {
    const client: http.HttpRequest = http.createHttp();
    const startedAt: number = Date.now();
    let ok: boolean = false;
    try {
      const response: http.HttpResponse = await client.request(url, {
        // POST with a real payload, not a bare GET. A request that sends almost
        // nothing costs almost no uplink, so it cannot be delayed by competing
        // uploads no matter how narrow the link — the first run measured 2 ms
        // round-trips and reported pure noise. The call this models (an API
        // request carrying a body) is what actually queues behind SDK traffic.
        method: http.RequestMethod.POST,
        extraData: body,
        header: { 'Content-Type': 'application/json' } as Record<string, string>,
        // No connection reuse across rounds: the customer-side call under
        // investigation opens its own connection each time, and a pooled socket
        // would hide exactly the setup cost that contention inflates.
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
    return { round, arm, durationMs: Date.now() - startedAt, ok };
  }

  /** Aggregates raw samples. Failed requests are excluded from the timings. */
  static summarize(samples: Array<BenchSample>): BenchReport {
    const ok: Array<BenchSample> = samples.filter((s: BenchSample) => s.ok);
    const paused: ArmStats = NetworkContentionBench.statsFor(ok, BenchArm.UPLOADS_PAUSED);
    const active: ArmStats = NetworkContentionBench.statsFor(ok, BenchArm.UPLOADS_ACTIVE);
    return {
      paused,
      active,
      deltaPercentMean: NetworkContentionBench.delta(paused.meanMs, active.meanMs),
      deltaPercentP95: NetworkContentionBench.delta(paused.p95Ms, active.p95Ms),
      failures: samples.length - ok.length
    };
  }

  private static statsFor(samples: Array<BenchSample>, arm: BenchArm): ArmStats {
    const values: Array<number> = samples
      .filter((s: BenchSample) => s.arm === arm)
      .map((s: BenchSample) => s.durationMs)
      .sort((a: number, b: number) => a - b);
    if (values.length === 0) {
      return { arm, count: 0, meanMs: 0, p50Ms: 0, p95Ms: 0 };
    }
    let sum: number = 0;
    for (const v of values) {
      sum += v;
    }
    return {
      arm,
      count: values.length,
      meanMs: Math.round(sum / values.length),
      p50Ms: NetworkContentionBench.percentile(values, 50),
      p95Ms: NetworkContentionBench.percentile(values, 95)
    };
  }

  /** Nearest-rank on an already-sorted array. */
  private static percentile(sorted: Array<number>, p: number): number {
    const rank: number = Math.ceil((p / 100) * sorted.length);
    const index: number = rank < 1 ? 0 : (rank > sorted.length ? sorted.length : rank) - 1;
    return sorted[index];
  }

  private static delta(baseline: number, treatment: number): number {
    if (baseline === 0) {
      return 0;
    }
    return Math.round(((treatment - baseline) / baseline) * 1000) / 10;
  }

  /** Tab-separated dump for pasting into the report. */
  static toTsv(samples: Array<BenchSample>): string {
    let out: string = 'round\tarm\tduration_ms\tok\n';
    for (const s of samples) {
      out += `${s.round}\t${s.arm}\t${s.durationMs}\t${s.ok}\n`;
    }
    return out;
  }
}
