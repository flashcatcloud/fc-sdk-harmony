import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { uiObserver, UIContext } from '@kit.ArkUI';
import {
  AppLaunchTracker, AppLaunchSink, StartupType, FrameHookFactory
} from '../main/ets/internal/startup/AppLaunchTracker';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumNavigationTracker } from '../main/ets/internal/RumNavigationTracker';
import { RumAutoInstrumentation } from '../main/ets/internal/RumAutoInstrumentation';
import { GlobalRumMonitor } from '../main/ets/RumMonitor';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';

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

  views(): Array<Record<string, Object>> {
    return this.written
      .filter((e: Record<string, Object>) => e['type'] === 'view')
      .map((e: Record<string, Object>) => e['view'] as Record<string, Object>);
  }

  /** The newest document of the view named `name`. */
  last(name: string): Record<string, Object> {
    const docs: Array<Record<string, Object>> =
      this.views().filter((v: Record<string, Object>) => v['name'] === name);
    return docs[docs.length - 1];
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

function raw(kind: string, timestampMs: number, key?: string): RumRawEvent {
  const e: RumRawEvent = { kind, attributes: {}, timestampMs };
  if (key !== undefined) {
    e.key = key;
    e.name = key;
  }
  return e;
}

function manual(timestampMs: number, overwrite: boolean): RumRawEvent {
  const e: RumRawEvent = raw('addViewLoadingTime', timestampMs);
  e.overwrite = overwrite;
  return e;
}

function auto(timestampMs: number, key: string): RumRawEvent {
  const e: RumRawEvent = raw('addViewLoadingTime', timestampMs, key);
  e.loadingTimeAuto = true;
  return e;
}

function loadingMs(view: Record<string, Object>): number | undefined {
  const ns: Object | undefined = view['loading_time'];
  return ns === undefined ? undefined : (ns as number) / MS_NS;
}

/** A tracker on a clock and frame hooks the test drives; page loads go to `loaded`. */
class Bench {
  nowMs: number = 100_000;
  readonly loaded: string[] = [];
  onLoaded: ((key: string, atMs: number) => void) | null = null;
  private readonly frames: Array<(firstDrawFrame: boolean | null) => void> = [];
  readonly tracker: AppLaunchTracker;

  constructor() {
    const sink: AppLaunchSink = {
      initialDisplay: (_t: StartupType, _s: number, _d: number, _a: number): void => {},
      fullDisplay: (_t: StartupType, _s: number, _d: number, _a: number): void => {},
      viewLoaded: (viewKey: string, atMs: number): void => {
        this.loaded.push(`${viewKey}@${atMs}`);
        if (this.onLoaded !== null) {
          this.onLoaded(viewKey, atMs);
        }
      }
    };
    const hooks: FrameHookFactory =
      (_context: Object, onFrame: (firstDrawFrame: boolean | null) => void): (() => void) | null => {
        this.frames.push(onFrame);
        return (): void => {};
      };
    this.tracker = new AppLaunchTracker(sink, hooks, (): number | null => 0, (): number => this.nowMs);
    this.tracker.attachContext('page');
  }

  frame(afterMs: number): void {
    this.nowMs += afterMs;
    this.frames.forEach((onFrame: (firstDrawFrame: boolean | null) => void) => onFrame(false));
  }
}

function routerInfo(pageId: string, state: uiObserver.RouterPageState): uiObserver.RouterPageInfo {
  const info: Record<string, Object> = {
    'pageId': pageId, 'path': `pages/${pageId}`, 'name': pageId, 'index': 1, 'state': state
  };
  return info as Object as uiObserver.RouterPageInfo;
}

export default function viewLoadingTimeTests(): void {
  describe('rum-view-loading-time', (): void => {
    it('aViewCarriesNoLoadingTimeUntilOneIsSet', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      app.handleEvent(raw('keepAlive', t0 + 100));
      expect(Object.keys(scope.last('home')).indexOf('loading_time')).assertEqual(-1);
      app.handleEvent(manual(t0 + 350, false));
      expect(loadingMs(scope.last('home'))).assertEqual(350);
    });

    it('withoutOverwriteTheFirstValueStaysWithItItIsReplaced', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      app.handleEvent(manual(t0 + 200, false));
      const documents: number = scope.views().length;
      app.handleEvent(manual(t0 + 500, false));
      expect(scope.views().length).assertEqual(documents); // nothing changed, nothing written
      expect(loadingMs(scope.last('home'))).assertEqual(200);
      app.handleEvent(manual(t0 + 800, true));
      expect(loadingMs(scope.last('home'))).assertEqual(800);
    });

    it('aClosedViewKeepsItsLoadingTimeAndTakesNoOther', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      app.handleEvent(manual(t0 + 120, false));
      app.handleEvent(raw('stopView', t0 + 1000, 'home'));
      const closed: Record<string, Object> = scope.last('home');
      expect(closed['is_active']).assertFalse();
      expect(loadingMs(closed)).assertEqual(120);
      const documents: number = scope.views().length;
      app.handleEvent(manual(t0 + 2000, true));
      expect(scope.views().length).assertEqual(documents);
    });

    it('withNoViewOpenNothingIsWrittenAndNoSessionStarts', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      app.handleEvent(manual(Date.now(), true));
      expect(scope.written.length).assertEqual(0);
      expect(app.getCurrentSessionId()).assertUndefined();
    });

    it('theSdksMeasurementAppliesToItsPageOnlyAndNeverOverAManualValue', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      app.handleEvent(auto(t0 + 40, 'detail')); // another page's frame
      expect(loadingMs(scope.last('home'))).assertUndefined();
      app.handleEvent(auto(t0 + 60, 'home'));
      expect(loadingMs(scope.last('home'))).assertEqual(60);
      app.handleEvent(auto(t0 + 90, 'home')); // measured once
      expect(loadingMs(scope.last('home'))).assertEqual(60);
      // The host's own value replaces the SDK's even without overwrite...
      app.handleEvent(manual(t0 + 700, false));
      expect(loadingMs(scope.last('home'))).assertEqual(700);
      // ...and the SDK's never replaces the host's.
      app.handleEvent(raw('startView', t0 + 1000, 'detail'));
      app.handleEvent(manual(t0 + 1300, false));
      app.handleEvent(auto(t0 + 1050, 'detail'));
      expect(loadingMs(scope.last('detail'))).assertEqual(300);
    });

    it('theMonitorSetsTheOpenViewsLoadingTime', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(new FakeCore(), scope, configuration);
      monitor.stopKeepAlive();
      monitor.startView('home', 'Home');
      monitor.addViewLoadingTime(false);
      const loaded: number | undefined = loadingMs(scope.last('Home'));
      expect(loaded !== undefined && loaded >= 0).assertTrue();
      monitor.addAutoViewLoadingTime('home', Date.now() + 5000); // already set by the host
      expect(loadingMs(scope.last('Home'))).assertEqual(loaded);
    });

    it('aShownPageLoadsAtTheNextFrame', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const b: Bench = new Bench();
      b.tracker.expectViewLoad('home');
      b.frame(70);
      b.frame(16); // only the first frame after the page was shown
      expect(b.loaded.join(' ')).assertEqual('home@100070');
    });

    it('aPageHiddenOrBackgroundedBeforeItDrewIsNotLoaded', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const hidden: Bench = new Bench();
      hidden.tracker.expectViewLoad('home');
      hidden.tracker.cancelViewLoad('home');
      hidden.frame(70);
      expect(hidden.loaded.length).assertEqual(0);

      const otherHidden: Bench = new Bench();
      otherHidden.tracker.expectViewLoad('home');
      otherHidden.tracker.cancelViewLoad('other'); // another page's hide changes nothing
      otherHidden.frame(70);
      expect(otherHidden.loaded.join(' ')).assertEqual('home@100070');

      const backgrounded: Bench = new Bench();
      backgrounded.tracker.expectViewLoad('home');
      backgrounded.tracker.onBackground();
      backgrounded.frame(70);
      expect(backgrounded.loaded.length).assertEqual(0);

      const replaced: Bench = new Bench();
      replaced.tracker.expectViewLoad('home');
      replaced.tracker.expectViewLoad('detail');
      replaced.frame(70);
      expect(replaced.loaded.join(' ')).assertEqual('detail@100070');
    });

    it('aFrameMoreThan90sAfterThePageWasShownIsNotItsLoad', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const late: Bench = new Bench();
      late.tracker.expectViewLoad('home');
      late.frame(90_001);
      expect(late.loaded.length).assertEqual(0);
      const atLimit: Bench = new Bench();
      atLimit.tracker.expectViewLoad('home');
      atLimit.frame(90_000);
      expect(atLimit.loaded.length).assertEqual(1);
    });

    it('routerTrackingTimesEachShownPageToItsFirstFrame', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const configuration: RumConfiguration =
        new RumConfigurationBuilder('app-1').setTrackNavigation(true).build();
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(new FakeCore(), scope, configuration);
      monitor.stopKeepAlive();
      const b: Bench = new Bench();
      b.onLoaded = (key: string, _atMs: number): void => monitor.addAutoViewLoadingTime(key, Date.now() + 25);
      GlobalRumMonitor.register(monitor);
      RumAutoInstrumentation.configure(configuration);
      RumNavigationTracker.configureLaunch(b.tracker);
      const observer: Record<string, Object> = uiObserver as Object as Record<string, Object>;
      const context: UIContext = new UIContext();
      try {
        RumNavigationTracker.attach(context);
        const callbacks: Array<(info: uiObserver.RouterPageInfo) => void> =
          observer['routerPageUpdate'] as Array<(info: uiObserver.RouterPageInfo) => void>;
        const update: (info: uiObserver.RouterPageInfo) => void = callbacks[callbacks.length - 1];
        update(routerInfo('home', uiObserver.RouterPageState.ON_PAGE_SHOW));
        b.frame(25);
        const home: Record<string, Object> = scope.last('home');
        expect(home['is_active']).assertTrue();
        expect((loadingMs(home) as number) >= 25).assertTrue();
        // Shown and hidden again before its first frame: it was never loaded.
        update(routerInfo('home', uiObserver.RouterPageState.ON_PAGE_HIDE));
        update(routerInfo('detail', uiObserver.RouterPageState.ON_PAGE_SHOW));
        update(routerInfo('detail', uiObserver.RouterPageState.ON_PAGE_HIDE));
        b.frame(25);
        expect(b.loaded.join(' ')).assertEqual('home@100025');
      } finally {
        RumNavigationTracker.detach();
        RumAutoInstrumentation.reset();
        GlobalRumMonitor.reset();
      }
    });
  });
}
