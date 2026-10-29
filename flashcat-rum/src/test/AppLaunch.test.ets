import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { common } from '@kit.AbilityKit';
import { window, UIContext } from '@kit.ArkUI';
import { process } from '@kit.ArkTS';
import {
  AppLaunchTracker, AppLaunchSink, StartupType, FrameHookFactory
} from '../main/ets/internal/startup/AppLaunchTracker';
import { systemFrameHooks, systemProcessAgeMs } from '../main/ets/internal/startup/SystemLaunchHooks';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { APP_LAUNCH_TTID, APP_LAUNCH_TTFD } from '../main/ets/internal/assembly/RumEventAssembler';

const MS_NS: number = 1e6;

function testContext(): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: '1.0.0',
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.7.5',
    device: {
      brand: 'HUAWEI', model: 'Pura', osName: 'HarmonyOS', osVersion: 'NEXT',
      apiVersion: 22, deviceType: 'phone'
    },
    user: {},
    anonymousId: 'anon-device-1',
    network: { status: 'connected', interfaces: ['wifi'] },
    featureContext: {}
  };
}

class CapturingScope implements FeatureScope {
  readonly written: Array<Record<string, Object>> = [];

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    const sink: Array<Record<string, Object>> = this.written;
    const writer: EventWriter = {
      write: (event: Record<string, Object>, _forceFlush?: boolean): boolean => {
        sink.push(event);
        return true;
      }
    };
    callback(testContext(), writer);
  }

  sendEvent(_event: Record<string, Object>): void {}

  vitals(): Array<Record<string, Object>> {
    return this.written.filter((e: Record<string, Object>) => e['type'] === 'vital');
  }
}

class FakeCore implements SdkCore {
  readonly name: string = 'test';

  registerFeature(_feature: Feature): void {}
  getFeature(_featureName: string): FeatureScope | null {
    return null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, _update: Record<string, Object>): void {}
  getContext(): FlashcatContext {
    return testContext();
  }
  getTrackingConsent(): TrackingConsent {
    return TrackingConsent.GRANTED;
  }
  isActive(): boolean {
    return true;
  }
  isAppInForeground(): boolean {
    return false;
  }
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'ct-123' };
  }
  readSetting(_key: string): string | null {
    return null;
  }
  writeSetting(_key: string, _value: string | null): void {}
}

class Measured {
  readonly metric: string;
  readonly type: StartupType;
  readonly startMs: number;
  readonly durationMs: number;

  constructor(metric: string, type: StartupType, startMs: number, durationNs: number) {
    this.metric = metric;
    this.type = type;
    this.startMs = startMs;
    this.durationMs = durationNs / MS_NS;
  }

  toString(): string {
    return `${this.metric}:${this.type}@${this.startMs}+${this.durationMs}`;
  }
}

/** A launch tracker on a clock, a process age and frame hooks the test drives. */
class Bench {
  nowMs: number = 100_000;
  ageMs: number | null = 300;
  hookable: boolean = true;
  unhooked: number = 0;
  readonly measured: Measured[] = [];
  private readonly frames: Map<Object, (firstDrawFrame: boolean | null) => void> =
    new Map<Object, (firstDrawFrame: boolean | null) => void>();
  readonly tracker: AppLaunchTracker;

  constructor() {
    const sink: AppLaunchSink = {
      initialDisplay: (type: StartupType, startMs: number, durationNs: number, _atMs: number): void => {
        this.measured.push(new Measured('ttid', type, startMs, durationNs));
      },
      fullDisplay: (type: StartupType, startMs: number, durationNs: number, _atMs: number): void => {
        this.measured.push(new Measured('ttfd', type, startMs, durationNs));
      }
    };
    const hooks: FrameHookFactory =
      (context: Object, onFrame: (firstDrawFrame: boolean | null) => void): (() => void) | null => {
        if (!this.hookable) {
          return null;
        }
        this.frames.set(context, onFrame);
        return (): void => {
          this.unhooked += 1;
          this.frames.delete(context);
        };
      };
    this.tracker = new AppLaunchTracker(sink, hooks, (): number | null => this.ageMs, (): number => this.nowMs);
  }

  /** A frame drawn `afterMs` from now, on every hooked context. */
  frame(afterMs: number, firstDrawFrame: boolean | null): void {
    this.nowMs += afterMs;
    this.frames.forEach((onFrame: (firstDrawFrame: boolean | null) => void) => onFrame(firstDrawFrame));
  }

  /** A frame drawn `afterMs` from now, on the window of `context` only. */
  frameOn(context: string, afterMs: number, firstDrawFrame: boolean | null): void {
    this.nowMs += afterMs;
    const onFrame: ((firstDrawFrame: boolean | null) => void) | undefined = this.frames.get(context);
    if (onFrame !== undefined) {
      onFrame(firstDrawFrame);
    }
  }

  /** Cold launch measured: the process is `ageMs` old at ability creation. */
  coldLaunched(): void {
    this.tracker.onAbilityCreated();
    this.tracker.attachContext('page-1');
    this.frame(200, true);
  }

  report(): string {
    return this.measured.map((m: Measured) => m.toString()).join(' ');
  }
}

/** The arkui shim's window module, and the window it hands out. */
function fakes(): Record<string, Object> {
  return window as Object as Record<string, Object>;
}

function fakeWindow(): Record<string, Object> {
  return fakes()['fake'] as Record<string, Object>;
}

function callbacksOf(recorder: Record<string, Object>, type: string): Array<Object> {
  const callbacks: Record<string, Array<Object>> = recorder['callbacks'] as Record<string, Array<Object>>;
  return callbacks[type] ?? [];
}

function settle(): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, 0));
}

function raw(core: SdkCore, configuration: RumConfiguration, scope: CapturingScope): DefaultRumMonitor {
  const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
  monitor.stopKeepAlive();
  return monitor;
}

export default function appLaunchTests(): void {
  describe('rum-app-launch', (): void => {
    it('aColdStartRunsFromProcessStartToTheFirstFrame', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.ageMs = 300;
      b.coldLaunched();
      // Started 300 ms before the ability was created, ended at the frame 200 ms after it.
      expect(b.report()).assertEqual('ttid:cold_start@99700+500');
    });

    it('tenSecondsOfProcessAgeIsStillCold', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.ageMs = 10_000;
      b.coldLaunched();
      expect(b.report()).assertEqual('ttid:cold_start@90000+10200');
    });

    it('anOlderProcessLaunchesWarmFromTheAbilityCreation', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.ageMs = 10_001;
      b.coldLaunched();
      expect(b.report()).assertEqual('ttid:warm_start@100000+200');
    });

    it('anAbilityRecreatedInALiveProcessIsWarm', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.coldLaunched();
      b.tracker.onBackground();
      b.tracker.onAbilityDestroyed();
      b.nowMs = 200_000;
      b.tracker.onAbilityCreated();
      b.tracker.onForeground();
      b.tracker.attachContext('page-2');
      b.frame(150, true);
      expect(b.report()).assertEqual('ttid:cold_start@99700+500 ttid:warm_start@200000+150');
    });

    it('aWarmLaunchIsNotAlsoAHotStartWhicheverComesFirst', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.coldLaunched();
      b.tracker.onBackground();
      b.tracker.onAbilityDestroyed();
      b.nowMs = 200_000;
      b.tracker.onForeground(); // the foreground is announced before the ability
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-2');
      b.frameOn('page-2', 150, true);
      b.tracker.onBackground();
      b.tracker.onAbilityDestroyed();
      b.nowMs = 300_000;
      b.tracker.onAbilityCreated(); // and the other way round
      b.tracker.onForeground();
      b.tracker.attachContext('page-3');
      b.frameOn('page-3', 120, true);
      expect(b.report()).assertEqual(
        'ttid:cold_start@99700+500 ttid:warm_start@200000+150 ttid:warm_start@300000+120');
    });

    it('anAbilityCreatedInFrontOfTheUserIsNoLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // The SDK started inside a running ability: it never saw that ability's
      // creation, so the next one is not the first of an empty app.
      const returned: Bench = new Bench();
      returned.tracker.onForeground();
      returned.tracker.onAbilityCreated();
      returned.tracker.attachContext('page-2');
      returned.frame(200, true);
      expect(returned.report()).assertEqual('');

      const probed: Bench = new Bench();
      probed.tracker.onForegroundDetected();
      probed.tracker.onAbilityCreated();
      probed.tracker.attachContext('page-2');
      probed.frame(200, true);
      expect(probed.report()).assertEqual('');
    });

    it('aWindowFromBeforeTheLaunchNeitherEndsNorCancelsIt', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.coldLaunched(); // page-1 stays hooked: the host never called stopViewTracking
      b.tracker.onBackground();
      b.tracker.onAbilityDestroyed();
      b.nowMs = 200_000;
      b.tracker.onAbilityCreated();
      b.frameOn('page-1', 10, false); // must not cancel the warm launch
      b.frameOn('page-1', 10, true); // nor end it
      b.tracker.attachContext('page-2');
      b.frameOn('page-2', 130, true);
      expect(b.report()).assertEqual('ttid:cold_start@99700+500 ttid:warm_start@200000+150');
    });

    it('aSecondAbilityBesideALiveOneIsNoLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.coldLaunched();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-2'); // the second ability's own window
      b.frameOn('page-2', 100, true);
      expect(b.report()).assertEqual('ttid:cold_start@99700+500');
    });

    it('aReturnToTheForegroundIsAHotStartEndingAtTheNextFrame', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.coldLaunched();
      b.tracker.onBackground();
      b.nowMs = 500_000;
      b.tracker.onForeground();
      b.frame(80, false); // not the window's first frame: a hot start does not need one
      b.frame(16, false);
      b.tracker.onBackground();
      b.nowMs = 900_000;
      b.tracker.onForeground();
      b.frame(40, false);
      expect(b.report()).assertEqual(
        'ttid:cold_start@99700+500 ttid:hot_start@500000+80 ttid:hot_start@900000+40');
    });

    it('theFirstForegroundOfALaunchIsNotAHotStart', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-1');
      b.tracker.onForeground();
      b.frame(200, true);
      b.tracker.onForeground();
      b.frame(16, false);
      expect(b.report()).assertEqual('ttid:cold_start@99700+500');

      // An SDK started after the ability, before the app reached the
      // foreground: that foreground is the launch's, not a return.
      const late: Bench = new Bench();
      late.tracker.attachContext('page-1');
      late.tracker.onForeground();
      late.frame(16, false);
      expect(late.report()).assertEqual('');
    });

    it('noHotStartWithoutAFrameHook', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.hookable = false;
      b.coldLaunched();
      b.tracker.onBackground();
      b.tracker.onForeground();
      b.hookable = true;
      b.tracker.attachContext('late');
      b.frame(30, false);
      expect(b.report()).assertEqual('');
    });

    it('anSdkStartedAfterTheAbilityReportsNoLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.tracker.attachContext('page-1'); // no ability creation was ever seen
      b.frame(200, true);
      expect(b.report()).assertEqual('');
    });

    it('framesHookedAfterTheWindowsFirstFrameReportNoLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-2');
      b.frame(900, false);
      b.frame(16, true); // nothing may revive the launch once its first frame was missed
      expect(b.report()).assertEqual('');
    });

    it('aSourceThatCannotNameTheFirstFrameNeedsTheHookBeforeAnyView', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const late: Bench = new Bench();
      late.tracker.onAbilityCreated();
      late.tracker.onViewStarted();
      late.tracker.attachContext('page-1');
      late.frame(200, null);
      expect(late.report()).assertEqual('');

      const inTime: Bench = new Bench();
      inTime.tracker.onAbilityCreated();
      inTime.tracker.attachContext('page-1');
      inTime.tracker.onViewStarted();
      inTime.frame(200, null);
      expect(inTime.report()).assertEqual('ttid:cold_start@99700+500');
    });

    it('aFrameMoreThan90sAfterTheStartReportsNoLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.ageMs = 0;
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-1');
      b.frame(90_001, true);
      expect(b.report()).assertEqual('');

      const atLimit: Bench = new Bench();
      atLimit.ageMs = 0;
      atLimit.tracker.onAbilityCreated();
      atLimit.tracker.attachContext('page-1');
      atLimit.frame(90_000, true);
      expect(atLimit.report()).assertEqual('ttid:cold_start@100000+90000');
    });

    it('goingToTheBackgroundBeforeTheFirstFrameReportsNoLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-1');
      b.tracker.onBackground();
      b.frame(200, true);
      expect(b.report()).assertEqual('');
    });

    it('anUnknownProcessAgeReportsNoLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.ageMs = null;
      b.coldLaunched();
      expect(b.report()).assertEqual('');
    });

    it('fullDisplayRunsFromTheLaunchStartAfterItsFirstFrame', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-1');
      b.tracker.onFullyDisplayed(); // before the first frame: dropped
      b.frame(200, true);
      b.nowMs += 1_000;
      b.tracker.onFullyDisplayed();
      b.nowMs += 1_000;
      b.tracker.onFullyDisplayed(); // once per launch
      expect(b.report()).assertEqual('ttid:cold_start@99700+500 ttfd:cold_start@99700+1500');
    });

    it('fullDisplayBelongsToTheColdOrWarmLaunchNeverToAHotStart', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.coldLaunched();
      b.tracker.onBackground();
      b.tracker.onForeground(); // a quick trip out while the first screen still loads
      b.nowMs += 1_000;
      b.tracker.onFullyDisplayed(); // the hot start is still waiting: the cold launch is reported
      b.frame(20, false);
      b.tracker.onFullyDisplayed();
      expect(b.report()).assertEqual(
        'ttid:cold_start@99700+500 ttfd:cold_start@99700+1500 ttid:hot_start@100200+1020');

      const onlyHot: Bench = new Bench();
      onlyHot.ageMs = null; // the cold launch could not be measured
      onlyHot.coldLaunched();
      onlyHot.tracker.onBackground();
      onlyHot.tracker.onForeground();
      onlyHot.frame(20, false);
      onlyHot.tracker.onFullyDisplayed();
      expect(onlyHot.report()).assertEqual('ttid:hot_start@100200+20');
    });

    it('fullDisplayWithoutALaunchOrPast90sIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const none: Bench = new Bench();
      none.tracker.onFullyDisplayed();
      expect(none.report()).assertEqual('');

      const late: Bench = new Bench();
      late.ageMs = 0;
      late.coldLaunched();
      late.nowMs = 100_000 + 90_001;
      late.tracker.onFullyDisplayed();
      expect(late.report()).assertEqual('ttid:cold_start@100000+200');

      const atLimit: Bench = new Bench();
      atLimit.ageMs = 0;
      atLimit.coldLaunched();
      atLimit.nowMs = 100_000 + 90_000;
      atLimit.tracker.onFullyDisplayed();
      expect(atLimit.report()).assertEqual('ttid:cold_start@100000+200 ttfd:cold_start@100000+90000');
    });

    it('aStoppedTrackerUnhooksAndMeasuresNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-1');
      b.tracker.attachContext('page-1'); // once per context
      b.tracker.stop();
      expect(b.unhooked).assertEqual(1);
      b.frame(200, true);
      b.tracker.onAbilityDestroyed();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-2');
      b.frame(200, true);
      expect(b.report()).assertEqual('');
    });

    it('aFrameHandlerThatThrowsStaysInsideTheSdk', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      let onFrame: ((firstDrawFrame: boolean | null) => void) | null = null;
      let reached: boolean = false;
      const sink: AppLaunchSink = {
        initialDisplay: (_t: StartupType, _s: number, _d: number, _a: number): void => {
          reached = true;
          throw new Error('sink failed');
        },
        fullDisplay: (_t: StartupType, _s: number, _d: number, _a: number): void => {}
      };
      const tracker: AppLaunchTracker = new AppLaunchTracker(sink,
        (_c: Object, cb: (firstDrawFrame: boolean | null) => void): (() => void) | null => {
          onFrame = cb;
          return (): void => {};
        }, (): number | null => 0);
      tracker.onAbilityCreated();
      tracker.attachContext('page-1');
      (onFrame as (firstDrawFrame: boolean | null) => void)(true); // must not throw
      expect(reached).assertTrue();
    });

    it('noFrameHookBelowApi12', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(systemFrameHooks(11)({} as common.UIAbilityContext, (_f: boolean | null): void => {})).assertNull();
    });

    it('api22HooksMeasuredFramesOfTheWindowAlways', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      (fakes()['resetFakes'] as () => void)();
      const seen: Array<boolean | null> = [];
      const unhook: (() => void) | null = systemFrameHooks(22)(new UIContext(),
        (firstDrawFrame: boolean | null): void => {
          seen.push(firstDrawFrame);
        });
      await settle();
      // No view, no foreground, any frequency: a launch's first frame comes first.
      const callbacks: Array<(m: Record<string, Object>) => void> =
        callbacksOf(fakeWindow(), 'frameMetricsMeasured') as Array<(m: Record<string, Object>) => void>;
      expect(callbacks.length).assertEqual(1);
      callbacks[0]({ 'firstDrawFrame': true });
      callbacks[0]({ 'firstDrawFrame': false });
      expect(seen.join(',')).assertEqual('true,false');
      (unhook as () => void)();
      expect(callbacksOf(fakeWindow(), 'frameMetricsMeasured').length).assertEqual(0);
    });

    it('api12to21HooksEveryWillDrawWhichCannotNameTheFirstFrame', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      (fakes()['resetFakes'] as () => void)();
      const seen: Array<boolean | null> = [];
      const unhook: (() => void) | null = systemFrameHooks(18)({} as common.UIAbilityContext,
        (firstDrawFrame: boolean | null): void => {
          seen.push(firstDrawFrame);
        });
      await settle();
      const observer: Record<string, Object> = (UIContext as Object as Record<string, Object>)['observer'] as Record<string, Object>;
      const callbacks: Array<() => void> = callbacksOf(observer, 'willDraw') as Array<() => void>;
      expect(callbacks.length).assertEqual(1); // no scroll needed
      expect(callbacksOf(observer, 'scrollEvent').length).assertEqual(0);
      callbacks[0]();
      expect(seen.length).assertEqual(1);
      expect(seen[0]).assertNull();
      (unhook as () => void)();
      expect(callbacksOf(observer, 'willDraw').length).assertEqual(0);
    });

    it('aDeviceWithoutFrameMetricsGetsNoHookAndNoThrow', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      (fakes()['resetFakes'] as () => void)();
      fakeWindow()['failWith'] = 801;
      const unhook: (() => void) | null =
        systemFrameHooks(22)(new UIContext(), (_f: boolean | null): void => {});
      await settle();
      (unhook as () => void)(); // nothing hooked: unhooking subscribes nothing off
      expect((fakeWindow()['calls'] as string[]).join(',')).assertEqual('');
      // A window lookup that throws is no hook either, and no throw.
      const findWindow: Object = fakes()['findWindow'];
      fakes()['findWindow'] = (_name: string): Object => {
        throw new Error('1300002');
      };
      try {
        expect(systemFrameHooks(22)(new UIContext(), (_f: boolean | null): void => {})).assertNull();
      } finally {
        fakes()['findWindow'] = findWindow;
        (fakes()['resetFakes'] as () => void)();
      }
    });

    it('anUnhookBeforeTheWindowIsFoundSubscribesNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      (fakes()['resetFakes'] as () => void)();
      const unhook: (() => void) | null =
        systemFrameHooks(22)({} as common.UIAbilityContext, (_f: boolean | null): void => {});
      (unhook as () => void)();
      await settle();
      expect(callbacksOf(fakeWindow(), 'frameMetricsMeasured').length).assertEqual(0);
    });

    it('processAgeIsUptimeMinusTheProcessStartAndNeverNegative', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const p: Record<string, Object> = process as Object as Record<string, Object>;
      p['uptimeSeconds'] = 3600;
      p['startRealtimeMs'] = 3_599_250;
      expect(systemProcessAgeMs()).assertEqual(750);
      p['startRealtimeMs'] = 3_600_001;
      expect(systemProcessAgeMs()).assertNull();
      p['uptimeSeconds'] = 0;
      p['startRealtimeMs'] = 0;
    });

    it('theVitalIsAnAndroidShapedAppLaunchOnTheOpenView', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
      const monitor: DefaultRumMonitor = raw(new FakeCore(), configuration, scope);
      monitor.addAttribute('tier', 'gold');
      monitor.startView('home', 'Home', { 'view.url': 'pages/Index' });
      const now: number = Date.now();
      monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.COLD, now - 700, 700 * MS_NS, now);
      const vitals: Array<Record<string, Object>> = scope.vitals();
      expect(vitals.length).assertEqual(1);
      const e: Record<string, Object> = vitals[0];
      expect(e['date']).assertEqual(now - 700);
      const vital: Record<string, Object> = e['vital'] as Record<string, Object>;
      expect(vital['type']).assertEqual('app_launch');
      expect(vital['name']).assertEqual('time_to_initial_display');
      expect(vital['app_launch_metric']).assertEqual('ttid');
      expect(vital['startup_type']).assertEqual('cold_start');
      expect(vital['duration']).assertEqual(700_000_000);
      expect(/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(vital['id'] as string)).assertTrue();
      const view: Record<string, Object> = e['view'] as Record<string, Object>;
      expect(view['name']).assertEqual('Home');
      expect(view['url']).assertEqual('pages/Index');
      expect(typeof view['id']).assertEqual('string');
      const session: Record<string, Object> = e['session'] as Record<string, Object>;
      const homeView: Record<string, Object> = scope.written[0];
      expect(session['id']).assertEqual((homeView['session'] as Record<string, Object>)['id']);
      expect((e['context'] as Record<string, Object>)['tier']).assertEqual('gold');
      const dd: Record<string, Object> = e['_dd'] as Record<string, Object>;
      expect((dd['configuration'] as Record<string, Object>)['session_sample_rate']).assertEqual(100);
      expect(dd['document_version']).assertUndefined();

      monitor.reportAppLaunch(APP_LAUNCH_TTFD, StartupType.COLD, now - 700, 900 * MS_NS, now + 200);
      const full: Record<string, Object> = scope.vitals()[1]['vital'] as Record<string, Object>;
      expect(full['name']).assertEqual('time_to_full_display');
      expect(full['app_launch_metric']).assertEqual('ttfd');
    });

    it('coldOrWarmOncePerSessionHotEveryTimeFullDisplayOnce', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
      const monitor: DefaultRumMonitor = raw(new FakeCore(), configuration, scope);
      monitor.startView('home', 'Home');
      const now: number = Date.now();
      monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.COLD, now, MS_NS, now);
      monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.WARM, now, MS_NS, now);
      monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.HOT, now, MS_NS, now);
      monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.HOT, now, MS_NS, now);
      monitor.reportAppLaunch(APP_LAUNCH_TTFD, StartupType.COLD, now, MS_NS, now);
      monitor.reportAppLaunch(APP_LAUNCH_TTFD, StartupType.HOT, now, MS_NS, now);
      const seen: string[] = scope.vitals().map((e: Record<string, Object>) => {
        const v: Record<string, Object> = e['vital'] as Record<string, Object>;
        return `${v['app_launch_metric']}:${v['startup_type']}`;
      });
      expect(seen.join(' ')).assertEqual('ttid:cold_start ttid:hot_start ttid:hot_start ttfd:cold_start');

      // A new session may report its own launch again.
      monitor.stopSession();
      monitor.startView('home', 'Home');
      monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.WARM, now, MS_NS, Date.now());
      expect(scope.vitals().length).assertEqual(5);
    });

    it('anUnsampledSessionWritesNoLaunchVital', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(0).build();
      const monitor: DefaultRumMonitor = raw(new FakeCore(), configuration, scope);
      monitor.startView('home', 'Home');
      const now: number = Date.now();
      monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.COLD, now, MS_NS, now);
      expect(scope.written.length).assertEqual(0);
    });

    it('rumFeedsTheAppLifecycleToTheLaunchTracker', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setTrackActiveDevices(false).build();
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const monitor: DefaultRumMonitor = raw(core, configuration, new CapturingScope());
      const b: Bench = new Bench();
      feature.attachMonitor(monitor, null, b.tracker);
      feature.onReceive({ 'type': 'ability_created' });
      b.tracker.attachContext('page-1');
      b.frame(200, true);
      feature.onReceive({ 'type': 'app_background' });
      feature.onReceive({ 'type': 'app_foreground_detected' }); // not a return from the background
      b.frame(10, false);
      feature.onReceive({ 'type': 'app_foreground' });
      b.frame(30, false);
      expect(b.report()).assertEqual('ttid:cold_start@99700+500 ttid:hot_start@100210+30');
      feature.onStop();
      expect(b.unhooked).assertEqual(1);
    });

    it('rumTellsTheTrackerAboutAnAppFoundInTheForeground', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setTrackActiveDevices(false).build();
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const b: Bench = new Bench();
      feature.attachMonitor(raw(core, configuration, new CapturingScope()), null, b.tracker);
      feature.onReceive({ 'type': 'app_foreground_detected' });
      feature.onReceive({ 'type': 'ability_created' }); // created in front of the user
      b.tracker.attachContext('page-2');
      b.frame(200, true);
      expect(b.report()).assertEqual('');
      feature.onStop();
    });

    it('reportAppFullyDisplayedGoesThroughTheTracker', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
      const b: Bench = new Bench();
      const monitor: DefaultRumMonitor =
        new DefaultRumMonitor(new FakeCore(), scope, configuration, null, null, null, b.tracker);
      monitor.stopKeepAlive();
      b.tracker.onAbilityCreated();
      b.tracker.attachContext('page-1');
      b.frame(200, true);
      b.nowMs += 300;
      monitor.reportAppFullyDisplayed();
      expect(b.report()).assertEqual('ttid:cold_start@99700+500 ttfd:cold_start@99700+800');
      // Without a tracker it is a logged no-op, never a throw.
      raw(new FakeCore(), configuration, scope).reportAppFullyDisplayed();
    });
  });
}
