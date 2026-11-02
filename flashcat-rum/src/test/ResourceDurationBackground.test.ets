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
    sdkVersion: '0.7.5',
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

/** A core whose foreground state the test sets, as the app state callback would. */
class FakeCore implements SdkCore {
  readonly name: string = 'test';
  foreground: boolean = true;

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
  app: RumApplicationScope;
}

/** A view open at t0 in an app that is in the foreground. */
function harness(t0: number): Harness {
  AppForegroundHistory.reset();
  AppForegroundHistory.foundInForeground();
  const scope: CapturingScope = new CapturingScope();
  const core: FakeCore = new FakeCore();
  const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100);
  const view: RumRawEvent = { kind: 'startView', key: 'home', name: 'Home', attributes: {}, timestampMs: t0 };
  app.handleEvent(view);
  return { scope, core, app };
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

function resourceOf(event: Record<string, Object>): Record<string, Object> {
  return event['resource'] as Record<string, Object>;
}

/** The app goes to the background and returns: the core's flag, then its bus message. */
function backgroundAndReturn(core: FakeCore): void {
  core.foreground = false;
  core.foreground = true;
  AppForegroundHistory.enteredForeground();
}

export default function resourceDurationBackgroundTests(): void {
  describe('ResourceDurationBackground', (): void => {
    it('aRequestRunInTheForegroundKeepsItsDuration', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const t0: number = Date.now() - 1000;
      const h: Harness = harness(t0);
      startResource(h.app, 'r1', t0 + 100);
      stopResource(h.app, 'r1', t0 + 350, 200);

      const resources: Array<Record<string, Object>> = h.scope.ofType('resource');
      expect(resources.length).assertEqual(1);
      expect(resourceOf(resources[0])['duration'] as number).assertEqual(250 * 1e6);
    });

    it('aRequestSpanningAStayInTheBackgroundIsSentWithoutDuration',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 3 * HOUR;
        const h: Harness = harness(t0);
        startResource(h.app, 'r1', t0 + 100);
        backgroundAndReturn(h.core);
        stopResource(h.app, 'r1', t0 + 2 * HOUR, 0); // resumed hours later, failed

        const resources: Array<Record<string, Object>> = h.scope.ofType('resource');
        expect(resources.length).assertEqual(1);
        const resource: Record<string, Object> = resourceOf(resources[0]);
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
        startResource(h.app, 'r1', t0 + 100);
        h.core.foreground = false; // the completion callback runs first on thaw
        stopResource(h.app, 'r1', t0 + 2 * HOUR, 200);

        const resources: Array<Record<string, Object>> = h.scope.ofType('resource');
        expect(resources.length).assertEqual(1);
        expect(resourceOf(resources[0])['duration']).assertUndefined();
        expect(resourceOf(resources[0])['status_code'] as number).assertEqual(200);
      });

    it('aRequestStoppedWhileStillInTheBackgroundIsSentWithoutDuration',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 1000;
        const h: Harness = harness(t0);
        startResource(h.app, 'r1', t0 + 100);
        h.core.foreground = false;
        stopResource(h.app, 'r1', t0 + 600, 200);

        const resources: Array<Record<string, Object>> = h.scope.ofType('resource');
        expect(resources.length).assertEqual(1);
        expect(resourceOf(resources[0])['duration']).assertUndefined();
      });

    it('aFailedRequestSpanningTheBackgroundIsStillReportedAsANetworkError',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 3 * HOUR;
        const h: Harness = harness(t0);
        startResource(h.app, 'r1', t0 + 100);
        backgroundAndReturn(h.core);
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
      backgroundAndReturn(h.core);
      startResource(h.app, 'r1', t0 + 100);
      stopResource(h.app, 'r1', t0 + 180, 200);

      const resources: Array<Record<string, Object>> = h.scope.ofType('resource');
      expect(resourceOf(resources[0])['duration'] as number).assertEqual(80 * 1e6);
    });

    it('aRequestMadeWhileTheAppIsStillLaunchingKeepsItsDuration',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const t0: number = Date.now() - 1000;
        const h: Harness = harness(t0);
        AppForegroundHistory.reset(); // nothing seen yet: the first window is not up
        h.core.foreground = false;
        startResource(h.app, 'early', t0 + 100);
        startResource(h.app, 'spanning', t0 + 100);
        stopResource(h.app, 'early', t0 + 200, 200); // before the first foreground
        // The launch's first entry into the foreground is not a return.
        h.core.foreground = true;
        AppForegroundHistory.enteredForeground();
        stopResource(h.app, 'spanning', t0 + 400, 200);

        const resources: Array<Record<string, Object>> = h.scope.ofType('resource');
        expect(resources.length).assertEqual(2);
        expect(resourceOf(resources[0])['duration'] as number).assertEqual(100 * 1e6);
        expect(resourceOf(resources[1])['duration'] as number).assertEqual(300 * 1e6);
      });

    it('theFeatureRecordsTheCoreForegroundSignals', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      AppForegroundHistory.reset();
      const core: FakeCore = new FakeCore();
      core.foreground = true; // RUM enabled after the core found the app in the foreground
      const feature: RumFeature = new RumFeature(core,
        new RumConfigurationBuilder('app-1').setTrackActiveDevices(false).build());
      feature.onInitialize();
      expect(AppForegroundHistory.hasBeenInForeground()).assertTrue();
      expect(AppForegroundHistory.returnCount()).assertEqual(0);
      feature.onReceive({ 'type': 'app_foreground' });
      expect(AppForegroundHistory.returnCount()).assertEqual(1);
      feature.onStop();

      AppForegroundHistory.reset();
      feature.onReceive({ 'type': 'app_foreground_detected' });
      expect(AppForegroundHistory.hasBeenInForeground()).assertTrue();
      expect(AppForegroundHistory.returnCount()).assertEqual(0);
      AppForegroundHistory.reset();
    });
  });
}
