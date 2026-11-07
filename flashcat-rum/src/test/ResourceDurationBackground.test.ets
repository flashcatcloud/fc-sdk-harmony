import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { AppForegroundHistory } from '../main/ets/internal/AppForegroundHistory';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { RumConfigurationBuilder } from '../main/ets/RumConfiguration';

const HOUR: number = 60 * 60 * 1000;

function testContext(): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: '1.0.0',
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.7.8',
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

/** A core whose own foreground flag the test sets; the history must not depend on it. */
class FakeCore implements SdkCore {
  readonly name: string = 'test';
  foreground: boolean = false;

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
    return this.foreground;
  }
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'token' };
  }
  readSetting(_key: string): string | null {
    return null;
  }
  writeSetting(_key: string, _value: string | null): void {}
}

interface Harness {
  scope: CapturingScope;
  core: FakeCore;
  feature: RumFeature;
  app: RumApplicationScope;
}

/**
 * A view open at t0. App state reaches the history the way it does in the SDK:
 * as core messages delivered to the RUM feature.
 */
function harness(t0: number, fresh: boolean = true): Harness {
  if (fresh) {
    AppForegroundHistory.reset();
  }
  const scope: CapturingScope = new CapturingScope();
  const core: FakeCore = new FakeCore();
  const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
  const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100);
  const view: RumRawEvent = { kind: 'startView', key: 'home', name: 'Home', attributes: {}, timestampMs: t0 };
  app.handleEvent(view);
  return { scope, core, feature, app };
}

/** A core message, with the core's own flag updated first as the core does. */
function send(h: Harness, type: string): void {
  if (type === 'app_background') {
    h.core.foreground = false;
  } else if (type === 'app_foreground' || type === 'app_foreground_detected') {
    h.core.foreground = true;
  }
  h.feature.onReceive({ 'type': type });
}

function startResource(app: RumApplicationScope, key: string, timestampMs: number): void {
  const e: RumRawEvent = {
    kind: 'startResource', key, attributes: {}, timestampMs,
    url: 'https://api.example.com/items', method: 'GET'
  };
  app.handleEvent(e);
}

function stopResource(app: RumApplicationScope, key: string, timestampMs: number, statusCode: number): void {
  const e: RumRawEvent = {
    kind: 'stopResource', key, attributes: {}, timestampMs,
    statusCode, sizeBytes: 512, resourceKind: 'native'
  };
  app.handleEvent(e);
}

function failResource(app: RumApplicationScope, key: string, timestampMs: number): void {
  const e: RumRawEvent = {
    kind: 'stopResourceWithError', key, attributes: {}, timestampMs,
    errorMessage: 'request timed out'
  };
  app.handleEvent(e);
}

function durationOf(scope: CapturingScope, index: number): Object | undefined {
  const resource: Record<string, Object> = scope.ofType('resource')[index]['resource'] as Record<string, Object>;
  return resource['duration'];
}

export default function resourceDurationBackgroundTests(): void {
  describe('ResourceDurationBackground', (): void => {
    it('aRequestRunInTheForegroundKeepsItsDuration', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const t0: number = Date.now() - 1000;
      const h: Harness = harness(t0);
      send(h, 'app_foreground');
      startResource(h.app, 'r1', t0 + 100);
      stopResource(h.app, 'r1', t0 + 350, 200);

      expect(h.scope.ofType('resource').length).assertEqual(1);
      expect(durationOf(h.scope, 0) as number).assertEqual(250 * 1e6);
    });

    it('aRequestSpanningAStayInTheBackgroundIsSentWithoutDuration',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 3 * HOUR;
        const h: Harness = harness(t0);
        send(h, 'app_foreground');
        startResource(h.app, 'r1', t0 + 100);
        send(h, 'app_background');
        send(h, 'app_foreground');
        stopResource(h.app, 'r1', t0 + 2 * HOUR, 0); // resumed hours later, failed

        const resources: Array<Record<string, Object>> = h.scope.ofType('resource');
        expect(resources.length).assertEqual(1);
        const resource: Record<string, Object> = resources[0]['resource'] as Record<string, Object>;
        expect(Object.keys(resource).indexOf('duration')).assertEqual(-1);
        expect(resource['status_code'] as number).assertEqual(0);
        expect(resource['url'] as string).assertEqual('https://api.example.com/items');
        expect(resource['size'] as number).assertEqual(512);
        expect(resources[0]['date'] as number).assertEqual(t0 + 100);
        // Absent from what is uploaded, not null or 0.
        expect(JSON.stringify(resources[0]).indexOf('"duration"')).assertEqual(-1);
      });

    it('aCompletionRunBeforeTheReturnIsReportedIsSentWithoutDuration',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 3 * HOUR;
        const h: Harness = harness(t0);
        send(h, 'app_foreground');
        startResource(h.app, 'r1', t0 + 100);
        send(h, 'app_background');
        stopResource(h.app, 'r1', t0 + 2 * HOUR, 200); // runs on thaw, before app_foreground
        send(h, 'app_foreground');

        expect(h.scope.ofType('resource').length).assertEqual(1);
        expect(durationOf(h.scope, 0)).assertUndefined();
      });

    it('aRequestStartedInTheBackgroundIsSentWithoutDuration',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 3 * HOUR;
        const h: Harness = harness(t0);
        send(h, 'app_background');
        startResource(h.app, 'r1', t0 + 100);
        send(h, 'app_foreground');
        stopResource(h.app, 'r1', t0 + 2 * HOUR, 200);

        expect(durationOf(h.scope, 0)).assertUndefined();
      });

    it('aFailedRequestSpanningTheBackgroundIsStillReportedAsANetworkError',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 3 * HOUR;
        const h: Harness = harness(t0);
        startResource(h.app, 'r1', t0 + 100);
        send(h, 'app_background');
        send(h, 'app_foreground');
        failResource(h.app, 'r1', t0 + 2 * HOUR);

        const errors: Array<Record<string, Object>> = h.scope.ofType('error');
        expect(errors.length).assertEqual(1);
        const error: Record<string, Object> = errors[0]['error'] as Record<string, Object>;
        expect(error['source'] as string).assertEqual('network');
        const resource: Record<string, Object> = error['resource'] as Record<string, Object>;
        expect(resource['url'] as string).assertEqual('https://api.example.com/items');
        expect(JSON.stringify(errors[0]).indexOf('"duration"')).assertEqual(-1);
      });

    it('aRequestStartedAfterTheReturnKeepsItsDuration', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const t0: number = Date.now() - 1000;
      const h: Harness = harness(t0);
      send(h, 'app_background');
      send(h, 'app_foreground');
      startResource(h.app, 'r1', t0 + 100);
      stopResource(h.app, 'r1', t0 + 180, 200);

      expect(durationOf(h.scope, 0) as number).assertEqual(80 * 1e6);
    });

    it('aRequestMadeWhileTheAppIsStillLaunchingKeepsItsDuration',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 1000;
        const h: Harness = harness(t0); // initialized in onCreate: no state reported yet
        startResource(h.app, 'early', t0 + 100);
        startResource(h.app, 'spanning', t0 + 100);
        stopResource(h.app, 'early', t0 + 200, 200);
        send(h, 'app_foreground'); // the launch's first window reaches the foreground
        stopResource(h.app, 'spanning', t0 + 400, 200);

        expect(h.scope.ofType('resource').length).assertEqual(2);
        expect(durationOf(h.scope, 0) as number).assertEqual(100 * 1e6);
        expect(durationOf(h.scope, 1) as number).assertEqual(300 * 1e6);
      });

    it('aStartupProbeAnsweringBeforeTheLaunchCallbackIsNoReturn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 1000;
        const h: Harness = harness(t0);
        send(h, 'app_foreground_detected');
        startResource(h.app, 'r1', t0 + 100);
        send(h, 'app_foreground'); // the launch's own state callback, after the probe
        stopResource(h.app, 'r1', t0 + 300, 200);

        expect(durationOf(h.scope, 0) as number).assertEqual(200 * 1e6);
      });

    it('aStayInTheBackgroundIsSeenWithoutAnyForegroundReport',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The startup probe never answered and the launch callback came before
        // RUM listened: the only state ever reported is the stay itself.
        const t0: number = Date.now() - 3 * HOUR;
        const h: Harness = harness(t0);
        h.core.foreground = true;
        startResource(h.app, 'r1', t0 + 100);
        send(h, 'app_background');
        send(h, 'app_foreground');
        stopResource(h.app, 'r1', t0 + 2 * HOUR, 200);

        expect(durationOf(h.scope, 0)).assertUndefined();
      });

    it('aRestartedSdkInTheForegroundKeepsDurationsBeforeItsProbeAnswers',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 1000;
        const first: Harness = harness(t0);
        send(first, 'app_foreground');
        send(first, 'app_background'); // stopped while in the background
        first.feature.onStop();

        // Started again once the app is back; its core has reported nothing yet.
        const h: Harness = harness(t0, false); // only what the SDK itself forgets
        startResource(h.app, 'r1', t0 + 100);
        stopResource(h.app, 'r1', t0 + 150, 200);
        send(h, 'app_foreground_detected');

        expect(durationOf(h.scope, 0) as number).assertEqual(50 * 1e6);
      });

    it('stoppingTheSdkForgetsTheReportedState', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const h: Harness = harness(Date.now());
      send(h, 'app_background');
      expect(AppForegroundHistory.inBackground()).assertTrue();
      expect(AppForegroundHistory.backgroundCount()).assertEqual(1);
      h.feature.onStop();
      expect(AppForegroundHistory.inBackground()).assertFalse();
      expect(AppForegroundHistory.backgroundCount()).assertEqual(0);
    });
  });
}
