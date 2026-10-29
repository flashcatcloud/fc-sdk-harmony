import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { window, uiObserver, UIContext } from '@kit.ArkUI';
import { FrameSample, ViewVitals } from '../main/ets/internal/vitals/ViewVitals';
import { FrameObserver, FrameSource, FrameSourceFactory } from '../main/ets/internal/vitals/FrameObserver';
import {
  DEFAULT_FRAME_PERIOD_NS, FramePath, FramePeriodEstimator, FrameMetricsSource, ScrollDrawSource,
  Subscription, framePathFor, systemFrameSources
} from '../main/ets/internal/vitals/SystemFrameSources';
import { VitalsCollectors } from '../main/ets/internal/vitals/VitalsCollector';
import { ResourceSampler, SamplerTimer } from '../main/ets/internal/vitals/ResourceSampler';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { VitalsUpdateFrequency, vitalsPeriodMs } from '../main/ets/VitalsUpdateFrequency';
import { CapturingScope, FakeCore, raw, settle } from './ViewVitals.test';

const MS: number = 1_000_000;
const SECOND_NS: number = 1_000_000_000;
// A 100 Hz display keeps the arithmetic exact.
const P100: number = 10 * MS;

function frame(durationNs: number, periodNs: number = P100, slowAboveNs: number = periodNs): FrameSample {
  return { durationNs, periodNs, slowAboveNs };
}

function round3(value: Object | undefined): number {
  return Math.round((value as number) * 1000) / 1000;
}

function countOf(fields: Record<string, Object>, key: string): number {
  return (fields[key] as Record<string, Object>)['count'] as number;
}

/** A frame source the test drives by hand. */
class FakeSource implements FrameSource {
  sink: ((sample: FrameSample) => void) | null = null;
  starts: number = 0;
  stops: number = 0;
  failStart: boolean = false;

  start(onFrame: (sample: FrameSample) => void): void {
    this.starts += 1;
    if (this.failStart) {
      throw new Error('801 Capability not supported.');
    }
    this.sink = onFrame;
  }

  stop(): void {
    this.stops += 1;
    this.sink = null;
  }

  push(sample: FrameSample): void {
    if (this.sink !== null) {
      this.sink(sample);
    }
  }
}

/** Builds the given source for any context, at once or when released. */
class FakeFactory {
  readonly source: FakeSource = new FakeSource();
  hold: boolean = false;
  calls: number = 0;
  private held: Array<() => void> = [];

  factory(): FrameSourceFactory {
    return (_context: Object): Promise<FrameSource | null> => {
      this.calls += 1;
      if (!this.hold) {
        return Promise.resolve(this.source);
      }
      return new Promise<FrameSource | null>((resolve: (s: FrameSource | null) => void) => {
        this.held.push(() => resolve(this.source));
      });
    };
  }

  release(): void {
    const pending: Array<() => void> = this.held;
    this.held = [];
    pending.forEach((r: () => void) => r());
  }
}

/** A system subscription that remembers the callbacks registered on it. */
class FakeSubscription<C> implements Subscription<C> {
  readonly live: C[] = [];
  ons: number = 0;
  failWith: string = '';

  on(callback: C): void {
    if (this.failWith.length > 0) {
      throw new Error(this.failWith);
    }
    this.ons += 1;
    this.live.push(callback);
  }

  off(callback: C): void {
    const i: number = this.live.indexOf(callback);
    if (i >= 0) {
      this.live.splice(i, 1);
    }
  }
}

function metrics(input: number, layout: number, vsync: number): window.FrameMetrics {
  return { firstDrawFrame: false, inputHandlingDuration: input, layoutMeasureDuration: layout, vsyncTimestamp: vsync };
}

function scrollInfo(id: number, start: boolean): uiObserver.ScrollEventInfo {
  return {
    id: `list-${id}`, uniqueId: id, offset: 0,
    scrollEvent: start ? uiObserver.ScrollEventType.SCROLL_START : uiObserver.ScrollEventType.SCROLL_STOP
  };
}

class NoTimer implements SamplerTimer {
  every(_periodMs: number, _tick: () => void): number {
    return 1;
  }

  cancel(_id: number): void {}
}

function observerWith(factory: FakeFactory, periodOf: () => number = (): number => 500): FrameObserver {
  return new FrameObserver(factory.factory(), periodOf);
}

/** A foreground observer already attached to one context, its source resolved. */
async function liveObserver(factory: FakeFactory): Promise<FrameObserver> {
  const frames: FrameObserver = observerWith(factory);
  frames.setForeground(true);
  frames.attach('ctx');
  await settle();
  return frames;
}

function shim(): Record<string, Object> {
  return window as Object as Record<string, Object>;
}

function resetShim(): void {
  (shim()['resetFakes'] as () => void)();
}

function fakeWindow(): Record<string, Object> {
  return shim()['fake'] as Record<string, Object>;
}

function observerCalls(): string[] {
  const ui: Record<string, Object> = UIContext as Object as Record<string, Object>;
  return (ui['observer'] as Record<string, Object>)['calls'] as string[];
}

export default function frameVitalsTests(): void {
  describe('rum-frame-vitals', (): void => {
    it('aViewWithoutFramesCarriesNoFrameKey', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onMemorySample(100);
      const keys: string[] = Object.keys(vitals.toFields(10 * SECOND_NS));
      expect(keys.join(',')).assertEqual('memory_average,memory_max');
      vitals.onFrame(frame(-1));
      vitals.onFrame(frame(Number.NaN));
      vitals.onFrame(frame(MS, 0));
      expect(Object.keys(vitals.toFields(10 * SECOND_NS)).length).assertEqual(2);
    });

    it('frameRateIsNormalisedToSixtyAndCapped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onFrame(frame(5 * MS));   // within a 100 Hz period: 60
      vitals.onFrame(frame(20 * MS));  // two periods: 30
      const fields: Record<string, Object> = vitals.toFields(0);
      expect(fields['refresh_rate_average']).assertEqual(45);
      expect(fields['refresh_rate_min']).assertEqual(30);
      // 60 Hz: a 25 ms frame reads 40.
      const sixty: ViewVitals = new ViewVitals();
      sixty.onFrame(frame(25 * MS, 1e9 / 60));
      expect(round3(sixty.toFields(0)['refresh_rate_min'])).assertEqual(40);
    });

    it('aFrameOfNoWorkReadsSixty', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onFrame(frame(0));
      const fields: Record<string, Object> = vitals.toFields(0);
      expect(fields['refresh_rate_average']).assertEqual(60);
      expect(countOf(fields, 'slow_frame')).assertEqual(0);
    });

    it('slowIsPastTheBoundUpTo700msFrozenIsPast700ms', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onFrame(frame(P100));            // exactly on the bound: not slow
      vitals.onFrame(frame(P100 + 1));        // slow
      vitals.onFrame(frame(700 * MS));        // still slow
      vitals.onFrame(frame(700 * MS + 1));    // frozen, not slow
      const fields: Record<string, Object> = vitals.toFields(0);
      expect(countOf(fields, 'slow_frame')).assertEqual(2);
      expect(countOf(fields, 'frozen_frame')).assertEqual(1);
    });

    it('theSlowBoundIsTheSourcesNotThePeriod', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onFrame(frame(14 * MS, P100, 15 * MS));
      vitals.onFrame(frame(16 * MS, P100, 15 * MS));
      expect(countOf(vitals.toFields(0), 'slow_frame')).assertEqual(1);
    });

    it('slowFramesRateIsSlowTimeOverFrameTimePerSecond', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      for (let i = 0; i < 10; i++) {
        vitals.onFrame(frame(MS)); // little work: each still occupies a 10 ms period
      }
      vitals.onFrame(frame(50 * MS));         // slow
      vitals.onFrame(frame(800 * MS));        // frozen: frame time, not slow time
      // 50 / (10 × 10 + 50 + 800) × 1000
      expect(round3(vitals.toFields(2 * SECOND_NS)['slow_frames_rate'])).assertEqual(round3(50 / 950 * 1000));
    });

    it('freezeRateCountsFramesOfFiveSecondsPerHour', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onFrame(frame(5 * SECOND_NS - 1));
      expect(vitals.toFields(60 * SECOND_NS)['freeze_rate']).assertEqual(0);
      vitals.onFrame(frame(5 * SECOND_NS));
      // 5 s frozen in a 60 s view: 300 s per hour.
      expect(round3(vitals.toFields(60 * SECOND_NS)['freeze_rate'])).assertEqual(300);
      expect(countOf(vitals.toFields(60 * SECOND_NS), 'frozen_frame')).assertEqual(2);
    });

    it('ratesAreZeroForAViewOfASecondOrLess', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onFrame(frame(50 * MS));
      vitals.onFrame(frame(6 * SECOND_NS));
      const short: Record<string, Object> = vitals.toFields(SECOND_NS);
      expect(short['slow_frames_rate']).assertEqual(0);
      expect(short['freeze_rate']).assertEqual(0);
      const long: Record<string, Object> = vitals.toFields(SECOND_NS + 1);
      expect(long['slow_frames_rate'] as number).assertLarger(0);
      expect(long['freeze_rate'] as number).assertLarger(0);
    });

    it('slowRenderedIsAnAverageBelow55', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const at55: ViewVitals = new ViewVitals();
      at55.onFrame(frame(P100));        // 60
      at55.onFrame(frame(12 * MS));     // 50
      expect(at55.toFields(0)['is_slow_rendered']).assertFalse();
      at55.onFrame(frame(12 * MS));     // average 53.3
      expect(at55.toFields(0)['is_slow_rendered']).assertTrue();
    });

    it('thePeriodIsTheMostCommonRecentVsyncGap', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const estimator: FramePeriodEstimator = new FramePeriodEstimator();
      expect(estimator.periodNs()).assertEqual(DEFAULT_FRAME_PERIOD_NS);
      expect(round3(DEFAULT_FRAME_PERIOD_NS / MS)).assertEqual(16.667);
      let t: number = 1_000 * MS;
      const step = (gap: number): void => {
        t += gap;
        estimator.onVsync(t);
      };
      step(0);
      step(8 * MS);
      step(8 * MS);
      expect(estimator.periodNs()).assertEqual(DEFAULT_FRAME_PERIOD_NS); // two gaps: not yet
      step(8 * MS);
      expect(estimator.periodNs()).assertEqual(8 * MS);
      // Idle time between redraws is not a period; two-period gaps lose the vote.
      step(400 * MS);
      step(16 * MS);
      step(16 * MS);
      expect(estimator.periodNs()).assertEqual(8 * MS);
      // A tie goes to the shorter period.
      step(16 * MS);
      expect(estimator.periodNs()).assertEqual(8 * MS);
    });

    it('sparseRedrawsAndRestartsAreNoPeriod', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // A redraw every 100 ms is idle time, however regular.
      const sparse: FramePeriodEstimator = new FramePeriodEstimator();
      for (let i = 0; i < 10; i++) {
        sparse.onVsync(i * 100 * MS);
      }
      expect(sparse.periodNs()).assertEqual(DEFAULT_FRAME_PERIOD_NS);
      // After a restart the first frame makes no gap with the last one seen.
      const restarted: FramePeriodEstimator = new FramePeriodEstimator();
      restarted.onVsync(0);
      restarted.onVsync(8 * MS);
      restarted.onVsync(16 * MS);
      restarted.reset();
      restarted.onVsync(24 * MS);
      expect(restarted.periodNs()).assertEqual(DEFAULT_FRAME_PERIOD_NS);
      restarted.onVsync(32 * MS);
      expect(restarted.periodNs()).assertEqual(8 * MS);
    });

    it('frameMetricsAreTheUiWorkAgainstTheEstimatedPeriod', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const sub: FakeSubscription<(m: window.FrameMetrics) => void> = new FakeSubscription<(m: window.FrameMetrics) => void>();
      const source: FrameMetricsSource = new FrameMetricsSource(sub);
      const samples: FrameSample[] = [];
      source.start((s: FrameSample) => samples.push(s));
      source.start((s: FrameSample) => samples.push(s));
      expect(sub.ons).assertEqual(1);
      const fire = (m: window.FrameMetrics): void => sub.live.forEach((cb: (m: window.FrameMetrics) => void) => cb(m));
      for (let i = 0; i < 4; i++) {
        fire(metrics(MS, 2 * MS, i * 8 * MS));
      }
      const last: FrameSample = samples[samples.length - 1];
      expect(last.durationNs).assertEqual(3 * MS);
      expect(last.periodNs).assertEqual(8 * MS);
      expect(last.slowAboveNs).assertEqual(8 * MS);
      source.stop();
      expect(sub.live.length).assertEqual(0);
      fire(metrics(MS, 2 * MS, 100 * MS));
      expect(samples.length).assertEqual(4);
    });

    it('aFailingFrameSinkNeverReachesTheSystemCallback', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const sub: FakeSubscription<(m: window.FrameMetrics) => void> = new FakeSubscription<(m: window.FrameMetrics) => void>();
      const source: FrameMetricsSource = new FrameMetricsSource(sub);
      source.start((_s: FrameSample) => {
        throw new Error('sink bug');
      });
      sub.live[0](metrics(MS, MS, 0)); // must not throw
      expect(sub.live.length).assertEqual(1);
    });

    it('drawGapsCountOnlyWhileSomethingScrolls', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scroll: FakeSubscription<(info: uiObserver.ScrollEventInfo) => void> =
        new FakeSubscription<(info: uiObserver.ScrollEventInfo) => void>();
      const draw: FakeSubscription<() => void> = new FakeSubscription<() => void>();
      let now: number = 1_000 * MS;
      const source: ScrollDrawSource = new ScrollDrawSource(scroll, draw, (): number => now);
      const samples: FrameSample[] = [];
      source.start((s: FrameSample) => samples.push(s));
      const drawAt = (t: number): void => {
        now = t;
        draw.live.forEach((cb: () => void) => cb());
      };
      const scrollEvent = (id: number, start: boolean): void =>
        scroll.live.forEach((cb: (info: uiObserver.ScrollEventInfo) => void) => cb(scrollInfo(id, start)));

      expect(draw.live.length).assertEqual(0); // nothing scrolls: not even listening
      drawAt(1_100 * MS);
      scrollEvent(1, true);
      drawAt(2_000 * MS); // first draw of the scroll: no gap before it
      drawAt(2_017 * MS);
      drawAt(2_050 * MS);
      expect(samples.map((s: FrameSample) => s.durationNs / MS).join(',')).assertEqual('17,33');
      expect(samples[0].periodNs).assertEqual(DEFAULT_FRAME_PERIOD_NS);
      expect(samples[0].slowAboveNs).assertEqual(DEFAULT_FRAME_PERIOD_NS * 1.5);

      // Two scrollables: one stopping keeps the other measured.
      scrollEvent(2, true);
      scrollEvent(1, false);
      drawAt(2_066 * MS);
      expect(samples.length).assertEqual(3);
      scrollEvent(2, false);
      expect(draw.live.length).assertEqual(0);
      drawAt(9_000 * MS); // after the scroll: the idle gap is no frame
      scrollEvent(1, true);
      drawAt(9_016 * MS);
      expect(samples.length).assertEqual(3);
      drawAt(9_032 * MS);
      expect(samples.length).assertEqual(4);

      source.stop();
      expect(scroll.live.length + draw.live.length).assertEqual(0);
    });

    it('aScrollGapIsSlowHalfAPeriodLate', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      const bound: number = DEFAULT_FRAME_PERIOD_NS * 1.5;
      vitals.onFrame(frame(Math.floor(bound), DEFAULT_FRAME_PERIOD_NS, bound));
      vitals.onFrame(frame(26 * MS, DEFAULT_FRAME_PERIOD_NS, bound));
      expect(countOf(vitals.toFields(0), 'slow_frame')).assertEqual(1);
    });

    it('framePathFollowsTheApiLevel', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(framePathFor(11)).assertEqual(FramePath.NONE);
      expect(framePathFor(12)).assertEqual(FramePath.SCROLL_DRAW);
      expect(framePathFor(21)).assertEqual(FramePath.SCROLL_DRAW);
      expect(framePathFor(22)).assertEqual(FramePath.FRAME_METRICS);
      expect(framePathFor(24)).assertEqual(FramePath.FRAME_METRICS);
    });

    it('eachApiLevelListensToItsOwnSystemEvent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      resetShim();
      const sink = (_s: FrameSample): void => {};
      const metricsSource: FrameSource | null = await systemFrameSources(22)(new UIContext());
      (metricsSource as FrameSource).start(sink);
      expect(((fakeWindow()['calls']) as string[]).join(',')).assertEqual('on:frameMetricsMeasured');
      expect((shim()['lookups'] as string[]).join(',')).assertEqual('find:main');
      expect(observerCalls().length).assertEqual(0);

      resetShim();
      const scrollSource: FrameSource | null = await systemFrameSources(21)(new UIContext());
      (scrollSource as FrameSource).start(sink);
      expect(observerCalls().join(',')).assertEqual('on:scrollEvent');
      expect((fakeWindow()['calls'] as string[]).length).assertEqual(0);

      // An ability context: its last window.
      resetShim();
      const fromAbility: FrameSource | null = await systemFrameSources(22)({ 'kind': 'ability' } as Record<string, Object>);
      expect(fromAbility === null).assertFalse();
      expect((shim()['lookups'] as string[]).join(',')).assertEqual('last');

      expect(await systemFrameSources(11)(new UIContext())).assertNull();
    });

    it('anUnsupportedDeviceMeansNoFramesAndNoThrow', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      resetShim();
      fakeWindow()['failWith'] = 801;
      const frames: FrameObserver = new FrameObserver(systemFrameSources(22), (): number => 500);
      frames.setForeground(true);
      frames.attach(new UIContext());
      await settle();
      const vitals: ViewVitals = new ViewVitals();
      frames.register(vitals); // starting the source throws 801 inside
      frames.unregister(vitals);
      frames.register(vitals); // dropped: not asked again
      expect((fakeWindow()['calls'] as string[]).length).assertEqual(0);
      expect(Object.keys(vitals.toFields(10 * SECOND_NS)).length).assertEqual(0);
    });

    it('framesAreObservedOnlyInTheForegroundWithAViewOpen', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      const frames: FrameObserver = observerWith(factory);
      frames.attach('ctx');
      await settle();
      const vitals: ViewVitals = new ViewVitals();
      frames.register(vitals);
      expect(factory.source.starts).assertEqual(0); // background
      frames.setForeground(true);
      expect(factory.source.starts).assertEqual(1);
      factory.source.push(frame(5 * MS));
      frames.setForeground(false);
      expect(factory.source.stops).assertEqual(1);
      factory.source.push(frame(5 * MS)); // not listening any more
      frames.setForeground(true);
      frames.unregister(vitals);
      expect(factory.source.stops).assertEqual(2); // no view open
      expect(frames.isObserving()).assertFalse();
      expect(countOf(vitals.toFields(0), 'slow_frame')).assertEqual(0);
      expect(vitals.toFields(0)['refresh_rate_average']).assertEqual(60);
    });

    it('neverObservesNoFrames', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      let frequency: VitalsUpdateFrequency = VitalsUpdateFrequency.NEVER;
      const frames: FrameObserver = observerWith(factory, (): number => vitalsPeriodMs(frequency));
      frames.setForeground(true);
      frames.attach('ctx');
      await settle();
      frames.register(new ViewVitals());
      expect(factory.source.starts).assertEqual(0);
      frequency = VitalsUpdateFrequency.RARE;
      frames.refreshPeriod(); // the console turned it on
      expect(factory.source.starts).assertEqual(1);
      frequency = VitalsUpdateFrequency.NEVER;
      frames.refreshPeriod();
      expect(factory.source.stops).assertEqual(1);
    });

    it('framesGoToTheOpenViewsOnly', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      const frames: FrameObserver = await liveObserver(factory);
      const first: ViewVitals = new ViewVitals();
      const second: ViewVitals = new ViewVitals();
      frames.register(first);
      factory.source.push(frame(20 * MS));
      frames.register(second);
      frames.unregister(first);
      factory.source.push(frame(5 * MS));
      expect(first.toFields(0)['refresh_rate_average']).assertEqual(30);
      expect(second.toFields(0)['refresh_rate_average']).assertEqual(60);
    });

    it('aSourceThatCannotStartIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      factory.source.failStart = true;
      const frames: FrameObserver = await liveObserver(factory);
      const vitals: ViewVitals = new ViewVitals();
      frames.register(vitals);
      frames.unregister(vitals);
      frames.register(vitals);
      expect(factory.source.starts).assertEqual(1);
      // Once dropped, the same context may be attached again (a later page).
      factory.source.failStart = false;
      frames.attach('ctx');
      await settle();
      expect(factory.source.starts).assertEqual(2);
    });

    it('attachingIsIdempotentAndCancelledByDetachOrStop', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      factory.hold = true;
      const frames: FrameObserver = observerWith(factory);
      frames.setForeground(true);
      frames.register(new ViewVitals());
      frames.attach('ctx');
      frames.attach('ctx');
      expect(factory.calls).assertEqual(1);
      frames.detach('ctx');
      factory.release();
      await settle();
      expect(factory.source.starts).assertEqual(0); // detached before it resolved

      frames.attach('ctx');
      frames.stop();
      factory.release();
      await settle();
      expect(factory.source.starts).assertEqual(0);
      frames.attach('other');
      expect(factory.calls).assertEqual(2); // stopped: no more lookups
    });

    it('aFailingWindowLookupNeverThrows', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const throwing: FrameObserver = new FrameObserver((_c: Object): Promise<FrameSource | null> => {
        throw new Error('1300002');
      }, (): number => 500);
      throwing.attach('ctx');
      const rejecting: FrameObserver = new FrameObserver(
        (_c: Object): Promise<FrameSource | null> => Promise.reject(new Error('1300002')), (): number => 500);
      rejecting.attach('ctx');
      await settle();
      rejecting.setForeground(true);
      rejecting.register(new ViewVitals());
      expect(rejecting.isObserving()).assertTrue(); // observing, with nothing to observe
    });

    it('aFrameQueuedPastTheStopIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      const frames: FrameObserver = await liveObserver(factory);
      const vitals: ViewVitals = new ViewVitals();
      frames.register(vitals);
      const late: (sample: FrameSample) => void = factory.source.sink as (sample: FrameSample) => void;
      // Already queued when the app went to the background: the view is still open.
      frames.setForeground(false);
      late(frame(5 * MS));
      expect(Object.keys(vitals.toFields(0)).length).assertEqual(0);
      frames.stop();
      late(frame(5 * MS));
      expect(Object.keys(vitals.toFields(0)).length).assertEqual(0);
      frames.setForeground(true);
      frames.register(vitals);
      expect(factory.source.starts).assertEqual(1); // stopped for good
    });

    it('everyViewDocumentCarriesItsFramesAndRates', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      const frames: FrameObserver = await liveObserver(factory);
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(
        scope, new FakeCore(), 'app-1', 100, null, null, null, false, new VitalsCollectors([frames]));
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      factory.source.push(frame(5 * MS));
      factory.source.push(frame(50 * MS));
      app.handleEvent(raw('keepAlive', t0 + 2000));
      const kept: Record<string, Object> = scope.views()[scope.views().length - 1];
      expect(kept['is_active']).assertTrue();
      expect(countOf(kept, 'slow_frame')).assertEqual(1);
      expect(round3(kept['slow_frames_rate'])).assertEqual(round3(50 / 60 * 1000));
      expect(kept['freeze_rate']).assertEqual(0);

      // The next view starts from nothing; the closed one keeps its frames.
      app.handleEvent(raw('startView', t0 + 3000, 'detail'));
      factory.source.push(frame(800 * MS));
      app.handleEvent(raw('stopView', t0 + 5000, 'detail'));
      const views: Array<Record<string, Object>> = scope.views();
      const closedHome: Record<string, Object> = views.filter(
        (v: Record<string, Object>) => v['name'] === 'home' && v['is_active'] === false)[0];
      expect(countOf(closedHome, 'slow_frame')).assertEqual(1);
      expect(countOf(closedHome, 'frozen_frame')).assertEqual(0);
      expect(closedHome['slow_frames_rate'] as number).assertLarger(0);
      const finalDetail: Record<string, Object> = views[views.length - 1];
      expect(finalDetail['name']).assertEqual('detail');
      expect(finalDetail['is_active']).assertFalse();
      expect(countOf(finalDetail, 'frozen_frame')).assertEqual(1);
      expect(countOf(finalDetail, 'slow_frame')).assertEqual(0);
      expect(finalDetail['slow_frames_rate']).assertEqual(0);
      expect(finalDetail['freeze_rate']).assertEqual(0);
      // Closed: nothing is observed until another view opens.
      expect(frames.isObserving()).assertFalse();
    });

    it('anUnsampledSessionObservesNoFrames', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const factory: FakeFactory = new FakeFactory();
      const frames: FrameObserver = await liveObserver(factory);
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(
        scope, new FakeCore(), 'app-1', 0, null, null, null, false, new VitalsCollectors([frames]));
      app.handleEvent(raw('startView', Date.now(), 'home'));
      expect(factory.source.starts).assertEqual(0);
      expect(scope.written.length).assertEqual(0);
    });

    it('framesFollowTheAppInAndOutOfTheForegroundAndStopWithRum', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setTrackActiveDevices(false).build();
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const scope: CapturingScope = new CapturingScope();
      const factory: FakeFactory = new FakeFactory();
      const frames: FrameObserver = observerWith(factory);
      const collectors: VitalsCollectors = new VitalsCollectors([
        new ResourceSampler({ memoryBytes: null, cpuTicks: null }, (): number => 500, new NoTimer()), frames]);
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration, null, null, collectors);
      monitor.stopKeepAlive();
      feature.attachMonitor(monitor, collectors);
      frames.attach('ctx');
      await settle();
      monitor.startView('home', 'home');
      await settle();
      expect(factory.source.starts).assertEqual(0); // the core has not seen the foreground
      feature.onReceive({ 'type': 'app_foreground_detected' });
      expect(factory.source.starts).assertEqual(1);
      factory.source.push(frame(50 * MS));
      // Background: listening stops before the flush rewrites the view.
      feature.onReceive({ 'type': 'app_background' });
      expect(factory.source.stops).assertEqual(1);
      feature.onReceive({ 'type': 'keep_alive' });
      await settle();
      const kept: Record<string, Object> = scope.views()[scope.views().length - 1];
      expect(countOf(kept, 'slow_frame')).assertEqual(1);
      expect(kept['slow_frames_rate'] === undefined).assertFalse();
      feature.onReceive({ 'type': 'app_foreground' });
      expect(factory.source.starts).assertEqual(2);
      feature.onStop();
      expect(factory.source.stops).assertEqual(3);
      feature.onReceive({ 'type': 'app_foreground' });
      frames.attach('again');
      expect(factory.source.starts).assertEqual(2);
      expect(factory.calls).assertEqual(1);
    });
  });
}
