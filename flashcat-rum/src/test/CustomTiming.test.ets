import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { RumViewScope } from '../main/ets/internal/scope/RumViewScope';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumConfigurationBuilder } from '../main/ets/RumConfiguration';

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
  isAppStateKnown(): boolean {
    return true;
  }

  liveWindowContexts(): Array<Object> {
    return [];
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

function timing(timestampMs: number, name: string): RumRawEvent {
  const e: RumRawEvent = raw('addTiming', timestampMs);
  e.name = name;
  return e;
}

function timingsOf(view: Record<string, Object>): Record<string, Object> | undefined {
  return view['custom_timings'] as Record<string, Object> | undefined;
}

export default function customTimingTests(): void {
  describe('rum-custom-timings', (): void => {
    it('aTimingIsTheNanosecondsSinceTheViewStartedSentWithANewDocument', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      // Control: no timing until one is added.
      expect(timingsOf(scope.last('home'))).assertUndefined();
      const before: number = scope.views().length;
      app.handleEvent(timing(t0 + 250, 'hero_image'));
      expect(scope.views().length).assertEqual(before + 1);
      const view: Record<string, Object> = scope.last('home');
      expect((timingsOf(view) as Record<string, Object>)['hero_image']).assertEqual(250 * MS_NS);
      expect(view['is_active']).assertTrue();
    });

    it('whileQueuedEventsAreProcessedTimingsShareOneViewDocument', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      const before: number = scope.views().length;
      RumViewScope.deferActionViewWrites(true);
      try {
        app.handleEvent(timing(t0 + 10, 'first'));
        app.handleEvent(timing(t0 + 20, 'second'));
        // Deferred like an action: no document per timing while the queue drains.
        expect(scope.views().length).assertEqual(before);
      } finally {
        RumViewScope.deferActionViewWrites(false);
      }
      // One document when the slice ends, carrying both timings.
      expect(scope.views().length).assertEqual(before + 1);
      const timings: Record<string, Object> = timingsOf(scope.last('home')) as Record<string, Object>;
      expect(timings['first']).assertEqual(10 * MS_NS);
      expect(timings['second']).assertEqual(20 * MS_NS);
    });

    it('timingsAccumulateAndTheSameNameIsReplaced', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      app.handleEvent(timing(t0 + 100, 'first'));
      app.handleEvent(timing(t0 + 300, 'second'));
      app.handleEvent(timing(t0 + 500, 'first'));
      // A timing at the view's very start is still sent, as 1 ns (Android).
      app.handleEvent(timing(t0, 'at_start'));
      const timings: Record<string, Object> = timingsOf(scope.last('home')) as Record<string, Object>;
      expect(Object.keys(timings).join(',')).assertEqual('first,second,at_start');
      expect(timings['first']).assertEqual(500 * MS_NS);
      expect(timings['second']).assertEqual(300 * MS_NS);
      expect(timings['at_start']).assertEqual(1);
      // Later documents keep carrying them.
      app.handleEvent(raw('keepAlive', t0 + 900));
      expect((timingsOf(scope.last('home')) as Record<string, Object>)['second']).assertEqual(300 * MS_NS);
    });

    it('namesAreSanitizedAsOnAndroid', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      app.handleEvent(timing(t0 + 10, 'Az09-_.@$')); // control: every allowed character kept
      app.handleEvent(timing(t0 + 20, 'first paint/ok?'));
      app.handleEvent(timing(t0 + 30, '加载'));
      const timings: Record<string, Object> = timingsOf(scope.last('home')) as Record<string, Object>;
      expect(Object.keys(timings).join(',')).assertEqual('Az09-_.@$,first_paint_ok_,__');
    });

    it('aStoppedViewTakesNoTimingAndTheNextViewStartsWithNone', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      app.handleEvent(raw('startView', t0, 'home'));
      app.handleEvent(timing(t0 + 100, 'before_stop'));
      app.handleEvent(raw('stopView', t0 + 200, 'home'));
      const documents: number = scope.views().length;
      app.handleEvent(timing(t0 + 300, 'after_stop'));
      expect(scope.views().length).assertEqual(documents);
      const home: Record<string, Object> = scope.last('home');
      expect(home['is_active']).assertFalse();
      expect(Object.keys(timingsOf(home) as Record<string, Object>).join(',')).assertEqual('before_stop');
      app.handleEvent(raw('startView', t0 + 400, 'detail'));
      app.handleEvent(raw('keepAlive', t0 + 500));
      expect(timingsOf(scope.last('detail'))).assertUndefined();
      // Control: the next view takes a timing of its own, from its own start.
      app.handleEvent(timing(t0 + 450, 'detail_ready'));
      expect((timingsOf(scope.last('detail')) as Record<string, Object>)['detail_ready']).assertEqual(50 * MS_NS);
    });

    it('anEmptyOrBlankNameIsIgnored', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor =
        new DefaultRumMonitor(new FakeCore(), scope, new RumConfigurationBuilder('app-1').build());
      monitor.stopKeepAlive();
      monitor.startView('home', 'home');
      monitor.addTiming('');
      monitor.addTiming('   ');
      monitor.drainPending();
      expect(timingsOf(scope.last('home'))).assertUndefined();
      // Control: a real name on the same view is recorded.
      monitor.addTiming('ready');
      monitor.drainPending();
      const timings: Record<string, Object> = timingsOf(scope.last('home')) as Record<string, Object>;
      expect(Object.keys(timings).join(',')).assertEqual('ready');
    });

    it('withNoViewOpenATimingIsIgnoredAndStartsNoSession', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor =
        new DefaultRumMonitor(new FakeCore(), scope, new RumConfigurationBuilder('app-1').build());
      monitor.stopKeepAlive();
      monitor.addTiming('orphan');
      monitor.addTiming(null as Object as string);
      monitor.drainPending();
      expect(scope.written.length).assertEqual(0);
      let sessionId: string | undefined = 'unset';
      monitor.getCurrentSessionId((id: string | undefined): void => {
        sessionId = id;
      });
      expect(sessionId).assertUndefined();
      // Control: through the monitor, with a view open, the timing is sent.
      monitor.startView('home', 'home');
      monitor.addTiming('ready');
      monitor.drainPending();
      const timings: Record<string, Object> = timingsOf(scope.last('home')) as Record<string, Object>;
      expect(Object.keys(timings).join(',')).assertEqual('ready');
      expect(typeof timings['ready']).assertEqual('number');
    });
  });
}
