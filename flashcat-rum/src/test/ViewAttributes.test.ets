import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from '../main/ets/RumTypes';

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


function newMonitor(scope: CapturingScope): DefaultRumMonitor {
  const monitor: DefaultRumMonitor =
    new DefaultRumMonitor(new FakeCore(), scope, new RumConfigurationBuilder('app-1').build());
  monitor.stopKeepAlive();
  return monitor;
}

function ofType(scope: CapturingScope, type: string): Array<Record<string, Object>> {
  return scope.written.filter((e: Record<string, Object>) => e['type'] === type);
}

function lastOfType(scope: CapturingScope, type: string): Record<string, Object> {
  const events: Array<Record<string, Object>> = ofType(scope, type);
  return events[events.length - 1];
}

function contextOf(event: Record<string, Object>): Record<string, Object> {
  return event['context'] as Record<string, Object>;
}

function viewNameOf(event: Record<string, Object>): string {
  return (event['view'] as Record<string, Object>)['name'] as string;
}

/** The newest view document of the view named `name`, whole (with its context). */
function lastViewEvent(scope: CapturingScope, name: string): Record<string, Object> {
  const docs: Array<Record<string, Object>> =
    ofType(scope, 'view').filter((e: Record<string, Object>) => viewNameOf(e) === name);
  return docs[docs.length - 1];
}

function rawAt(kind: string, timestampMs: number, key?: string): RumRawEvent {
  const e: RumRawEvent = { kind, attributes: {}, timestampMs };
  if (key !== undefined) {
    e.key = key;
    e.name = key;
  }
  return e;
}

export default function viewAttributesTests(): void {
  describe('rum-view-attributes', (): void => {
    it('addedAttributesReachTheViewAndEveryEventInIt', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor = newMonitor(scope);
      monitor.startView('home', 'home');
      monitor.addViewAttributes({ 'tier': 'gold', 'count': 3 });
      monitor.addAction(RumActionType.TAP, 'buy');
      monitor.addError('boom', RumErrorSource.CUSTOM);
      monitor.startResource('r1', RumResourceMethod.GET, 'https://example.com/a');
      monitor.stopResource('r1', 200, 10, RumResourceKind.NATIVE);
      monitor.startResource('r2', RumResourceMethod.GET, 'https://example.com/b');
      monitor.stopResourceWithError('r2', 'timeout');
      monitor.drainPending();
      for (const type of ['action', 'resource', 'view']) {
        const ctx: Record<string, Object> = contextOf(lastOfType(scope, type));
        expect(ctx['tier']).assertEqual('gold');
        expect(ctx['count']).assertEqual(3);
      }
      for (const error of ofType(scope, 'error')) {
        expect(contextOf(error)['tier']).assertEqual('gold');
      }
      expect(ofType(scope, 'error').length).assertEqual(2);
      // View attributes are not global ones.
      expect(monitor.getAttributes()['tier']).assertUndefined();
    });

    it('aViewDocumentWrittenBeforeTheCallDoesNotCarryThem', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor = newMonitor(scope);
      monitor.startView('home', 'home');
      monitor.drainPending();
      const before: number = ofType(scope, 'view').length;
      monitor.addViewAttributes({ 'tier': 'gold' });
      monitor.drainPending();
      // Android parity: adding attributes writes no document of its own.
      expect(ofType(scope, 'view').length).assertEqual(before);
      expect(contextOf(lastViewEvent(scope, 'home'))['tier']).assertUndefined();
      monitor.addAction(RumActionType.TAP, 'buy');
      monitor.drainPending();
      expect(contextOf(lastViewEvent(scope, 'home'))['tier']).assertEqual('gold');
    });

    it('theyStopWithTheViewAndTheNextViewStartsWithoutThem', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor = newMonitor(scope);
      monitor.startView('home', 'home');
      monitor.addViewAttributes({ 'tier': 'gold' });
      monitor.stopView('home');
      monitor.startView('detail', 'detail');
      monitor.addAction(RumActionType.TAP, 'open');
      monitor.addError('boom', RumErrorSource.CUSTOM);
      monitor.drainPending();
      // The closing document of home still carries them (control) ...
      expect(contextOf(lastViewEvent(scope, 'home'))['tier']).assertEqual('gold');
      // ... nothing of the next view does.
      expect(contextOf(lastViewEvent(scope, 'detail'))['tier']).assertUndefined();
      expect(contextOf(lastOfType(scope, 'action'))['tier']).assertUndefined();
      expect(contextOf(lastOfType(scope, 'error'))['tier']).assertUndefined();
    });

    it('removedAttributesLeaveTheEventsThatFollow', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor = newMonitor(scope);
      monitor.addAttribute('app', 'global');
      monitor.startView('home', 'home', { 'from_start': 'yes' });
      monitor.addViewAttributes({ 'tier': 'gold', 'kept': 1 });
      monitor.addAction(RumActionType.TAP, 'first');
      monitor.removeViewAttributes(['tier', 'from_start', 'app']);
      monitor.addAction(RumActionType.TAP, 'second');
      monitor.drainPending();
      const actions: Array<Record<string, Object>> = ofType(scope, 'action');
      const first: Record<string, Object> = contextOf(actions[0]);
      expect(first['tier']).assertEqual('gold'); // control: present before the removal
      expect(first['from_start']).assertEqual('yes');
      const second: Record<string, Object> = contextOf(actions[1]);
      expect(second['tier']).assertUndefined();
      expect(second['from_start']).assertUndefined();
      expect(second['kept']).assertEqual(1);
      // A global attribute is not the view's to remove.
      expect(second['app']).assertEqual('global');
      const view: Record<string, Object> = contextOf(lastViewEvent(scope, 'home'));
      expect(view['tier']).assertUndefined();
      expect(view['kept']).assertEqual(1);
    });

    it('withNoViewOpenTheCallsAreIgnoredAndStartNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor = newMonitor(scope);
      monitor.addViewAttributes({ 'tier': 'gold' });
      monitor.removeViewAttributes(['tier']);
      monitor.drainPending();
      expect(scope.written.length).assertEqual(0);
      // Not activity of the user's: no session is started for them.
      let sessionId: string | undefined = 'unset';
      monitor.getCurrentSessionId((id: string | undefined): void => {
        sessionId = id;
      });
      expect(sessionId).assertUndefined();
      monitor.startView('home', 'home');
      monitor.addAction(RumActionType.TAP, 'buy');
      monitor.drainPending();
      expect(contextOf(lastOfType(scope, 'action'))['tier']).assertUndefined();
      // Untyped callers: null arguments are ignored, not thrown.
      monitor.addViewAttributes(null as Object as Record<string, Object>);
      monitor.removeViewAttributes(null as Object as Array<string>);
      monitor.addAction(RumActionType.TAP, 'again');
      monitor.drainPending();
      expect(ofType(scope, 'action').length).assertEqual(2);
    });

    it('aViewRestartedInANewSessionDoesNotInheritAddedAttributes', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
      const t0: number = Date.now();
      const start: RumRawEvent = rawAt('startView', t0, 'home');
      start.attributes = { 'from_start': 'yes' };
      app.handleEvent(start);
      const add: RumRawEvent = rawAt('addViewAttributes', t0 + 10);
      add.attributes = { 'tier': 'gold' };
      app.handleEvent(add);
      // 16 min later: the session has expired; the action restarts home in a new one.
      app.handleEvent(rawAt('addAction', t0 + 16 * 60 * 1000));
      const restarted: Record<string, Object> = contextOf(lastViewEvent(scope, 'home'));
      expect(restarted['from_start']).assertEqual('yes');
      expect(restarted['tier']).assertUndefined();
    });
  });
}
