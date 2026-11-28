import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { FeatureOperationFailureReason } from '../main/ets/RumTypes';
import { FeatureOperationFailureReason as ExportedFailureReason } from '../../Index';

function testContext(): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: '1.0.0',
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.8.2',
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
    const writer: EventWriter = {
      write: (event: Record<string, Object>, _forceFlush?: boolean): boolean => {
        this.written.push(event);
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
    return true;
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

function monitorOn(scope: CapturingScope, rate: number = 100): DefaultRumMonitor {
  const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(rate).build();
  const monitor: DefaultRumMonitor = new DefaultRumMonitor(new FakeCore(), scope, configuration);
  monitor.stopKeepAlive();
  return monitor;
}

function vitalOf(event: Record<string, Object>): Record<string, Object> {
  return event['vital'] as Record<string, Object>;
}

function operationStep(atMs: number, name: string, stepType: string): RumRawEvent {
  return { kind: 'operationStep', attributes: {}, timestampMs: atMs, name, operationStepType: stepType };
}

const UUID: RegExp = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;

export default function featureOperationTests(): void {
  describe('FeatureOperation', (): void => {
    it('startSucceedAndFailHaveTheAndroidWireShape',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        monitor.startView('home', 'Home');
        monitor.addAttribute('tenant', 'acme');
        monitor.startFeatureOperation('checkout', 'order-42', { 'channel': 'cart' });
        monitor.succeedFeatureOperation('checkout', 'order-42');
        monitor.failFeatureOperation('upload', undefined, FeatureOperationFailureReason.ABANDONED);
        monitor.drainPending();

        const vitals: Array<Record<string, Object>> = scope.vitals();
        expect(vitals.length).assertEqual(3);
        const view: Record<string, Object> = scope.written[0]['view'] as Record<string, Object>;
        for (const e of vitals) {
          const v: Record<string, Object> = vitalOf(e);
          expect(v['type']).assertEqual('operation_step');
          expect(UUID.test(v['id'] as string)).assertTrue();
          // The backend measures the operation from its steps: no duration, as on Android and iOS.
          expect(v['duration']).assertUndefined();
          expect((e['view'] as Record<string, Object>)['id']).assertEqual(view['id']);
          expect((e['view'] as Record<string, Object>)['name']).assertEqual('Home');
          expect((e['session'] as Record<string, Object>)['id'] as string).assertEqual(
            (scope.written[0]['session'] as Record<string, Object>)['id'] as string);
          expect(typeof e['date']).assertEqual('number');
          expect(e['action']).assertUndefined();
          expect((e['context'] as Record<string, Object>)['tenant']).assertEqual('acme');
        }
        expect(new Set<string>(vitals.map((e: Record<string, Object>) => vitalOf(e)['id'] as string)).size)
          .assertEqual(3);

        const start: Record<string, Object> = vitalOf(vitals[0]);
        expect(start['name']).assertEqual('checkout');
        expect(start['operation_key']).assertEqual('order-42');
        expect(start['step_type']).assertEqual('start');
        expect(start['failure_reason']).assertUndefined();
        expect((vitals[0]['context'] as Record<string, Object>)['channel']).assertEqual('cart');

        const succeed: Record<string, Object> = vitalOf(vitals[1]);
        expect(succeed['step_type']).assertEqual('end');
        expect(succeed['operation_key']).assertEqual('order-42');
        expect(succeed['failure_reason']).assertUndefined();
        expect((vitals[1]['context'] as Record<string, Object>)['channel']).assertUndefined();

        const fail: Record<string, Object> = vitalOf(vitals[2]);
        expect(fail['name']).assertEqual('upload');
        expect(fail['step_type']).assertEqual('end');
        expect(fail['failure_reason']).assertEqual('abandoned');
        // Started without a key: none is sent, not an empty one.
        expect(Object.keys(fail).indexOf('operation_key')).assertEqual(-1);
      });

    it('everyFailureReasonMapsToTheSchemaValue',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        monitor.startView('home', 'Home');
        monitor.failFeatureOperation('a', 'k', FeatureOperationFailureReason.ERROR);
        monitor.failFeatureOperation('a', 'k', FeatureOperationFailureReason.ABANDONED);
        monitor.failFeatureOperation('a', 'k', FeatureOperationFailureReason.OTHER);
        // An untyped caller's made-up reason still yields a value the schema allows.
        monitor.failFeatureOperation('a', 'k', 'timeout' as Object as FeatureOperationFailureReason);
        monitor.drainPending();
        expect(scope.vitals().map((e: Record<string, Object>) => vitalOf(e)['failure_reason'] as string).join(','))
          .assertEqual('error,abandoned,other,other');
        expect(ExportedFailureReason.ERROR).assertEqual(FeatureOperationFailureReason.ERROR);
      });

    it('aBlankNameOrKeyIsRefusedAndAValidCallIsNot',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        monitor.startView('home', 'Home');
        let threw: boolean = false;
        try {
          monitor.startFeatureOperation('');
          monitor.startFeatureOperation('   ');
          monitor.succeedFeatureOperation('checkout', '');
          monitor.failFeatureOperation('checkout', ' \t', FeatureOperationFailureReason.ERROR);
          monitor.startFeatureOperation(null as Object as string);
          monitor.startFeatureOperation('checkout', 42 as Object as string);
        } catch (_e) {
          threw = true;
        }
        monitor.drainPending();
        expect(threw).assertFalse();
        expect(scope.vitals().length).assertEqual(0);
        // Negative control: the same monitor does send a valid step, and a null key means "no key".
        monitor.startFeatureOperation('checkout', null as Object as string);
        monitor.drainPending();
        expect(scope.vitals().length).assertEqual(1);
        expect(Object.keys(vitalOf(scope.vitals()[0])).indexOf('operation_key')).assertEqual(-1);
      });

    it('anUnsampledSessionSendsNoStepAndASampledOneDoes',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const unsampled: CapturingScope = new CapturingScope();
        const off: DefaultRumMonitor = monitorOn(unsampled, 0);
        off.startView('home', 'Home');
        off.startFeatureOperation('checkout');
        off.succeedFeatureOperation('checkout');
        off.drainPending();
        expect(unsampled.written.length).assertEqual(0);

        const sampled: CapturingScope = new CapturingScope();
        const on: DefaultRumMonitor = monitorOn(sampled, 100);
        on.startView('home', 'Home');
        on.startFeatureOperation('checkout');
        on.drainPending();
        expect(sampled.vitals().length).assertEqual(1);
      });

    it('aSessionWithoutAViewOpensTheLaunchViewForIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        monitor.startFeatureOperation('cold_start_sync');
        monitor.drainPending();
        const vitals: Array<Record<string, Object>> = scope.vitals();
        expect(vitals.length).assertEqual(1);
        expect((vitals[0]['view'] as Record<string, Object>)['name']).assertEqual('ApplicationLaunch');
      });

    it('aSessionKeptOnErrorHoldsStepsUntilItErrors',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 0, null, null, null, true);
        const now: number = Date.now();
        const view: RumRawEvent = { kind: 'startView', attributes: {}, timestampMs: now, key: 'home', name: 'Home' };
        app.handleEvent(view);
        app.handleEvent(operationStep(now + 10, 'checkout', 'start'));
        app.releaseScheduledWithheld();
        // Withheld: nothing has errored yet.
        expect(scope.written.length).assertEqual(0);

        const error: RumRawEvent = {
          kind: 'addError', attributes: {}, timestampMs: now + 20, errorMessage: 'boom', errorSource: 'source'
        };
        app.handleEvent(error);
        app.releaseScheduledWithheld();
        const vitals: Array<Record<string, Object>> = scope.vitals();
        expect(vitals.length).assertEqual(1);
        expect(vitalOf(vitals[0])['step_type']).assertEqual('start');
        const dd: Record<string, Object> = vitals[0]['_dd'] as Record<string, Object>;
        expect((dd['configuration'] as Record<string, Object>)['session_sample_rate']).assertEqual(0);
      });
  });
}
