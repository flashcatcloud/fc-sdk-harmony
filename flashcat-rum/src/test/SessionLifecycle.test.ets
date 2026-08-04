import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { RumConfigurationBuilder } from '../main/ets/RumConfiguration';

const MIN_15: number = 15 * 60 * 1000;

function testContext(): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: '1.0.0',
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.3.1',
    device: {
      brand: 'HUAWEI', model: 'Pura', osName: 'HarmonyOS', osVersion: 'NEXT',
      apiVersion: 18, deviceType: 'phone'
    },
    user: {},
    anonymousId: 'anon-device-1',
    network: { status: 'connected', interfaces: ['wifi'] },
    featureContext: {}
  };
}

/** Captures every event the scope tree writes. */
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

  ofType(type: string): Array<Record<string, Object>> {
    return this.written.filter((e: Record<string, Object>) => e['type'] === type);
  }
}

class FakeCore implements SdkCore {
  readonly name: string = 'test';
  readonly featureContext: Record<string, Object> = {};

  registerFeature(_feature: Feature): void {}
  getFeature(_featureName: string): FeatureScope | null {
    return null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, update: Record<string, Object>): void {
    for (const k of Object.keys(update)) {
      this.featureContext[k] = update[k];
    }
  }
  getContext(): FlashcatContext {
    return testContext();
  }
  getTrackingConsent(): TrackingConsent {
    return TrackingConsent.GRANTED;
  }
  isActive(): boolean {
    return true;
  }
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
}

function raw(kind: string, timestampMs: number, key?: string): RumRawEvent {
  const e: RumRawEvent = { kind, attributes: {}, timestampMs };
  if (key !== undefined) {
    e.key = key;
  }
  return e;
}

function sessionIdOf(event: Record<string, Object>): string {
  const session: Record<string, Object> = event['session'] as Record<string, Object>;
  return session !== undefined ? session['id'] as string : '';
}

export default function sessionLifecycleTests(): void {
  describe('SessionLifecycle', (): void => {
    it('backdatedFirstEventDoesNotMintAnInstantlyExpiredPhantomSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
        const t0: number = Date.now() - 40 * 60 * 1000; // 40 min in the past

        // A backdated startView (e.g. replayed/timed source). Without the mint
        // clamp, the session would be born 40 min ago and the very next
        // real-time event would read as a >15-min gap — instant expiry plus a
        // phantom replacement session.
        const start: RumRawEvent = raw('startView', t0, 'home');
        start.name = 'Home';
        app.handleEvent(start);

        const tap: RumRawEvent = raw('addAction', Date.now());
        tap.name = 'tap';
        tap.actionType = 'tap';
        tap.actionId = 'a-1';
        tap.actionDurationNs = 0;
        app.handleEvent(tap);

        const sessionIds: Set<string> = new Set<string>();
        for (const v of scope.ofType('view')) {
          sessionIds.add(sessionIdOf(v));
        }
        // One session only — no instant-expiry churn from the backdated birth.
        expect(sessionIds.size).assertEqual(1);
        expect(scope.ofType('action').length).assertEqual(1);
      });

    it('resourceCompletionSpanningExpiryIsSettledIntoTheEndedSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
        const t0: number = Date.now() - 30 * 60 * 1000;

        const start: RumRawEvent = raw('startView', t0, 'home');
        start.name = 'Home';
        app.handleEvent(start);
        const sessionA: string = sessionIdOf(scope.ofType('view')[0]);

        const res: RumRawEvent = raw('startResource', t0 + 1000, 'req-1');
        res.url = 'https://api.example.com/slow';
        res.method = 'GET';
        app.handleEvent(res);

        // The completion itself is the first event past the 15-min gap.
        const stop: RumRawEvent = raw('stopResource', t0 + MIN_15 + 60 * 1000, 'req-1');
        stop.statusCode = 200;
        stop.sizeBytes = 10;
        stop.resourceKind = 'native';
        app.handleEvent(stop);

        const resources: Array<Record<string, Object>> = scope.ofType('resource');
        expect(resources.length).assertEqual(1);
        // Attributed to the session it STARTED in, not dropped, not session B.
        expect(sessionIdOf(resources[0])).assertEqual(sessionA);
      });

    it('stopTypeEventsNeverMintSessions',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);

        app.handleEvent(raw('stopView', Date.now(), 'ghost'));
        app.handleEvent(raw('stopResource', Date.now(), 'nope'));
        app.handleEvent(raw('keepAlive', Date.now()));
        app.handleEvent(raw('markCrash', Date.now()));

        expect(scope.written.length).assertEqual(0);
        expect(app.getCurrentSessionId()).assertUndefined();
      });

    it('stopSessionClosesViewAndNextEventStartsFreshSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
        const t0: number = Date.now() - 60 * 1000;

        const start: RumRawEvent = raw('startView', t0, 'home');
        start.name = 'Home';
        app.handleEvent(start);
        const sessionA: string = sessionIdOf(scope.ofType('view')[0]);

        app.stopCurrentSession(Date.now());
        expect(app.getCurrentSessionId()).assertUndefined();
        const finalDoc: Record<string, Object> =
          scope.ofType('view')[scope.ofType('view').length - 1];
        const viewOfFinal: Record<string, Object> = finalDoc['view'] as Record<string, Object>;
        expect(viewOfFinal['is_active'] as boolean).assertFalse();

        // Next activity mints a NEW session and restarts the last view in it.
        const tap: RumRawEvent = raw('addAction', Date.now());
        tap.name = 'tap';
        tap.actionType = 'tap';
        tap.actionId = 'a-1';
        tap.actionDurationNs = 0;
        app.handleEvent(tap);
        const latest: Record<string, Object> =
          scope.ofType('view')[scope.ofType('view').length - 1];
        expect(sessionIdOf(latest) === sessionA).assertFalse();
      });
  });

  describe('RumConfigTrackErrors', (): void => {
    it('trackErrorsDefaultsToTrueAndIsConfigurable',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(new RumConfigurationBuilder('app').build().trackErrors).assertTrue();
        expect(new RumConfigurationBuilder('app').setTrackErrors(false).build().trackErrors).assertFalse();
        // Crash-relevant toggles are independent of trackErrors.
        const cfg = new RumConfigurationBuilder('app')
          .setTrackErrors(false)
          .setTrackNetworkRequests(true)
          .build();
        expect(cfg.trackNetworkRequests).assertTrue();
      });
  });
}