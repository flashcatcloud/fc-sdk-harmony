import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { window } from '@kit.ArkUI';
import { FrameSample, ViewVitals } from '../main/ets/internal/vitals/ViewVitals';
import { FrameObserver, FrameSource, FrameSourceFactory } from '../main/ets/internal/vitals/FrameObserver';
import { FrameMetricsSource, Subscription } from '../main/ets/internal/vitals/SystemFrameSources';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { VitalsCollectors } from '../main/ets/internal/vitals/VitalsCollector';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { CapturingScope, FakeCore, raw, settle } from './ViewVitals.test';

const MS: number = 1_000_000;
const THRESHOLD_NS: number = 100 * MS;
const UUID: RegExp = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;

/** A UI-work frame of the API 22+ path, or (isUiWork false) a draw gap of the scroll path. */
function frame(durationNs: number, isUiWork: boolean = true): FrameSample {
  return { durationNs, periodNs: 16 * MS, slowAboveNs: 16 * MS, isUiWork };
}

class FakeSource implements FrameSource {
  sink: ((sample: FrameSample) => void) | null = null;

  start(onFrame: (sample: FrameSample) => void): void {
    this.sink = onFrame;
  }

  stop(): void {
    this.sink = null;
  }

  push(sample: FrameSample): void {
    if (this.sink !== null) {
      this.sink(sample);
    }
  }
}

let firstView: ViewVitals = new ViewVitals();

/** An observer in the foreground, its source attached, with one view open; long tasks go to `seen`. */
async function observing(source: FakeSource, seen: number[], thresholdNs: number = THRESHOLD_NS): Promise<FrameObserver> {
  const factory: FrameSourceFactory = (_c: Object): Promise<FrameSource | null> => Promise.resolve(source);
  const frames: FrameObserver = new FrameObserver(factory, (): number => 500, thresholdNs,
    (durationNs: number): void => {
      seen.push(durationNs);
    });
  frames.setForeground(true);
  frames.attach('ctx');
  await settle();
  firstView = new ViewVitals();
  frames.register(firstView);
  return frames;
}

class FakeMetrics implements Subscription<(m: window.FrameMetrics) => void> {
  callback: ((m: window.FrameMetrics) => void) | null = null;

  on(callback: (m: window.FrameMetrics) => void): void {
    this.callback = callback;
  }

  off(_callback: (m: window.FrameMetrics) => void): void {
    this.callback = null;
  }
}

function monitorOn(scope: CapturingScope): DefaultRumMonitor {
  const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
  const monitor: DefaultRumMonitor = new DefaultRumMonitor(new FakeCore(), scope, configuration);
  monitor.stopKeepAlive();
  return monitor;
}

function longTasks(scope: CapturingScope): Array<Record<string, Object>> {
  return scope.written.filter((e: Record<string, Object>) => e['type'] === 'long_task');
}

function longTaskCountOf(view: Record<string, Object>): number {
  return (view['long_task'] as Record<string, Object>)['count'] as number;
}

export default function longTaskTests(): void {
  describe('LongTask', (): void => {
    it('aFrameWhoseUiWorkPassesTheThresholdIsALongTaskOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const source: FakeSource = new FakeSource();
        const seen: number[] = [];
        const frames: FrameObserver = await observing(source, seen);
        // Two views open: still one long task per frame.
        frames.register(new ViewVitals());
        source.push(frame(400 * MS));
        // Negative controls: at or under the threshold, and a scroll-path draw gap however long.
        source.push(frame(80 * MS));
        source.push(frame(THRESHOLD_NS));
        source.push(frame(900 * MS, false));
        expect(seen.join(',')).assertEqual(`${400 * MS}`);
      });

    it('noLongTaskWhenOffInTheBackgroundOrWithNoViewOpen',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const offSource: FakeSource = new FakeSource();
        const off: number[] = [];
        await observing(offSource, off, 0);
        offSource.push(frame(400 * MS));
        expect(off.length).assertEqual(0);

        const source: FakeSource = new FakeSource();
        const seen: number[] = [];
        const frames: FrameObserver = await observing(source, seen);
        const view: ViewVitals = new ViewVitals();
        frames.register(view);
        frames.unregister(firstView);
        frames.setForeground(false);
        source.push(frame(5000 * MS));
        expect(seen.length).assertEqual(0);
        frames.setForeground(true);
        source.push(frame(400 * MS));
        expect(seen.length).assertEqual(1); // control: the same observer reports once back in the foreground
        frames.unregister(view);
        source.push(frame(400 * MS));
        expect(seen.length).assertEqual(1); // no view open
      });

    it('theFrameMetricsPathMarksItsFramesAsUiWork',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const metrics: FakeMetrics = new FakeMetrics();
        const samples: FrameSample[] = [];
        new FrameMetricsSource(metrics).start((s: FrameSample): void => {
          samples.push(s);
        });
        (metrics.callback as (m: window.FrameMetrics) => void)({
          firstDrawFrame: false, inputHandlingDuration: 150 * MS, layoutMeasureDuration: 60 * MS, vsyncTimestamp: 1
        });
        expect(samples.length).assertEqual(1);
        expect(samples[0].durationNs).assertEqual(210 * MS);
        expect(samples[0].isUiWork).assertTrue();
      });

    it('aLongTaskEventHasTheAndroidShapeAndCountsOnTheView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        monitor.startView('home', 'Home');
        const before: number = Date.now();
        monitor.addLongTask(400_123_456);
        const after: number = Date.now();
        monitor.addLongTask(800 * MS);
        monitor.drainPending();

        const tasks: Array<Record<string, Object>> = longTasks(scope);
        expect(tasks.length).assertEqual(2);
        const first: Record<string, Object> = tasks[0];
        // date is when the task started: when it was seen, minus its duration.
        expect(first['date'] as number >= before - 400).assertTrue();
        expect(first['date'] as number <= after - 400).assertTrue();
        const task: Record<string, Object> = first['long_task'] as Record<string, Object>;
        expect(task['duration']).assertEqual(400_123_456); // nanoseconds, as on Android
        expect(task['is_frozen_frame']).assertFalse();
        expect(UUID.test(task['id'] as string)).assertTrue();
        expect(((tasks[1]['long_task'] as Record<string, Object>)['is_frozen_frame'])).assertTrue();
        expect((first['view'] as Record<string, Object>)['name']).assertEqual('Home');
        expect((first['view'] as Record<string, Object>)['id']).assertEqual(scope.views()[0]['id']);

        const views: Array<Record<string, Object>> = scope.views();
        expect(longTaskCountOf(views[0])).assertEqual(0);
        expect(longTaskCountOf(views[views.length - 1])).assertEqual(2);
      });

    it('aFrozenLongFrameIsOneFrozenFrameAndOneLongTask',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // The whole path: frame source -> observer -> views and the scope tree.
        const scope: CapturingScope = new CapturingScope();
        const source: FakeSource = new FakeSource();
        let app: RumApplicationScope | null = null;
        const factory: FrameSourceFactory = (_c: Object): Promise<FrameSource | null> => Promise.resolve(source);
        const frames: FrameObserver = new FrameObserver(factory, (): number => 500, THRESHOLD_NS,
          (durationNs: number): void => {
            const e: RumRawEvent = raw('addLongTask', Date.now());
            e.longTaskDurationNs = durationNs;
            (app as RumApplicationScope).handleEvent(e);
          });
        app = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100, null, null, null, false,
          new VitalsCollectors([frames]));
        frames.setForeground(true);
        frames.attach('ctx');
        await settle();
        app.handleEvent(raw('startView', Date.now(), 'home'));
        source.push(frame(900 * MS));
        const tasks: Array<Record<string, Object>> = longTasks(scope);
        expect(tasks.length).assertEqual(1);
        expect((tasks[0]['long_task'] as Record<string, Object>)['is_frozen_frame']).assertTrue();
        const views: Array<Record<string, Object>> = scope.views();
        const last: Record<string, Object> = views[views.length - 1];
        expect(longTaskCountOf(last)).assertEqual(1);
        // Counted once, by the frame measurement: the long task adds no second frozen frame.
        expect((last['frozen_frame'] as Record<string, Object>)['count']).assertEqual(1);
      });

    it('aLongTaskOutsideAViewOrASessionIsDropped',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
        const task: (atMs: number) => void = (atMs: number): void => {
          const e: RumRawEvent = raw('addLongTask', atMs);
          e.longTaskDurationNs = 200 * MS;
          app.handleEvent(e);
        };
        const now: number = Date.now();
        task(now); // no session yet: a long task does not start one
        expect(app.getCurrentSessionId()).assertUndefined();
        app.handleEvent(raw('startView', now + 1, 'home'));
        app.handleEvent(raw('stopView', now + 2, 'home'));
        task(now + 3); // between two views
        expect(longTasks(scope).length).assertEqual(0);
        app.handleEvent(raw('startView', now + 4, 'next'));
        task(now + 5);
        expect(longTasks(scope).length).assertEqual(1); // control
      });

    it('trackLongTasksDefaultsTo100MsAndZeroTurnsItOff',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(new RumConfigurationBuilder('a').build().longTaskThresholdMs).assertEqual(100);
        expect(new RumConfigurationBuilder('a').trackLongTasks().build().longTaskThresholdMs).assertEqual(100);
        expect(new RumConfigurationBuilder('a').trackLongTasks(250).build().longTaskThresholdMs).assertEqual(250);
        expect(new RumConfigurationBuilder('a').trackLongTasks(0).build().longTaskThresholdMs).assertEqual(0);
        expect(new RumConfigurationBuilder('a').trackLongTasks(-5).build().longTaskThresholdMs).assertEqual(0);
        expect(new RumConfigurationBuilder('a').trackLongTasks(NaN).build().longTaskThresholdMs).assertEqual(0);
      });
  });
}
