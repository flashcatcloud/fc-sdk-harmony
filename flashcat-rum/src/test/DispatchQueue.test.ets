import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { RumActionType } from '../main/ets/RumTypes';

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

/** Captures every written event; each write costs `writeCostMs` of busy time, like a slow disk. */
class SlowScope implements FeatureScope {
  readonly written: Array<Record<string, Object>> = [];
  writeCostMs: number = 1;
  failViews: boolean = false;

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    const sink: Array<Record<string, Object>> = this.written;
    const cost: number = this.writeCostMs;
    const writer: EventWriter = {
      write: (event: Record<string, Object>, _forceFlush?: boolean): boolean => {
        if (this.failViews && event['type'] === 'view') {
          throw new Error('disk gone');
        }
        const until: number = Date.now() + cost;
        while (Date.now() < until) {
          // busy: the cost of serializing and persisting one document
        }
        sink.push(event);
        return true;
      }
    };
    callback(testContext(), writer);
  }

  sendEvent(_event: Record<string, Object>): void {}

  actions(): Array<Record<string, Object>> {
    return this.written.filter((e: Record<string, Object>) => e['type'] === 'action');
  }

  views(): Array<Record<string, Object>> {
    return this.written.filter((e: Record<string, Object>) => e['type'] === 'view');
  }

  actionNames(): string[] {
    return this.actions().map((e: Record<string, Object>) =>
      ((e['action'] as Record<string, Object>)['target'] as Record<string, Object>)['name'] as string);
  }

  lastViewActionCount(): number {
    const views: Array<Record<string, Object>> = this.views();
    const view: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
    return (view['action'] as Record<string, Object>)['count'] as number;
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

const BURST: number = 60;

function monitorOn(scope: SlowScope): DefaultRumMonitor {
  const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
  const monitor: DefaultRumMonitor = new DefaultRumMonitor(new FakeCore(), scope, configuration);
  monitor.startView('home', 'Home');
  return monitor;
}

function burst(monitor: DefaultRumMonitor): void {
  for (let i: number = 0; i < BURST; i++) {
    monitor.addAction(RumActionType.CUSTOM, `a${i}`);
  }
}

function expected(): string[] {
  const names: string[] = [];
  for (let i: number = 0; i < BURST; i++) {
    names.push(`a${i}`);
  }
  return names;
}

function nextTurn(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 0);
  });
}

/** Lets the event loop turn until the burst has been written, or gives up. */
async function settle(scope: SlowScope): Promise<number> {
  let turns: number = 0;
  while (scope.actions().length < BURST && turns < 500) {
    await nextTurn();
    turns += 1;
  }
  return turns;
}

export default function dispatchQueueTests(): void {
  describe('rumDispatchQueue', (): void => {
    it('processesAnOccasionalCallOnTheCallersTurn', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      scope.writeCostMs = 0;
      const monitor: DefaultRumMonitor = monitorOn(scope);
      monitor.addAction(RumActionType.TAP, 'checkout');
      expect(scope.actionNames().join(',')).assertEqual('checkout');
      expect(scope.lastViewActionCount()).assertEqual(1);
      monitor.stopKeepAlive();
    });

    it('spreadsABurstOverLaterTurnsInCallOrder', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
        const scope: SlowScope = new SlowScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        const startMs: number = Date.now();
        burst(monitor);
        const callerMs: number = Date.now() - startMs;
        // Each action costs two ~1 ms writes; a 4 ms budget stops the caller's
        // turn after a handful of them instead of all 60 (~120 ms).
        expect(scope.actions().length < BURST / 4).assertTrue();
        expect(callerMs < 30).assertTrue();
        const turns: number = await settle(scope);
        expect(turns > 1).assertTrue();
        expect(scope.actionNames().join(',')).assertEqual(expected().join(','));
        expect(scope.lastViewActionCount()).assertEqual(BURST);
        monitor.stopKeepAlive();
      });

    it('writesTheViewOncePerSliceNotOncePerQueuedAction', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
        const scope: SlowScope = new SlowScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        burst(monitor);
        await settle(scope);
        // One view document per synchronous action plus one per slice — far fewer than one per action.
        expect(scope.views().length < BURST / 2).assertTrue();
        expect(scope.lastViewActionCount()).assertEqual(BURST);
        monitor.stopKeepAlive();
      });

    it('keepAliveProcessesTheQueueFirst', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      const monitor: DefaultRumMonitor = monitorOn(scope);
      burst(monitor);
      expect(scope.actions().length < BURST).assertTrue();
      // Backgrounding / a flush: everything called before must be on file now.
      monitor.keepAlive();
      expect(scope.actionNames().join(',')).assertEqual(expected().join(','));
      expect(scope.lastViewActionCount()).assertEqual(BURST);
      monitor.stopKeepAlive();
    });

    it('markCrashCountsAfterEveryQueuedAction', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      const monitor: DefaultRumMonitor = monitorOn(scope);
      burst(monitor);
      monitor.markCrash();
      expect(scope.actions().length).assertEqual(BURST);
      const views: Array<Record<string, Object>> = scope.views();
      const view: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
      expect((view['crash'] as Record<string, Object>)['count'] as number).assertEqual(1);
      expect((view['action'] as Record<string, Object>)['count'] as number).assertEqual(BURST);
      monitor.stopKeepAlive();
    });

    it('openingTheLaunchViewProcessesTheQueueFirst', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      const monitor: DefaultRumMonitor = monitorOn(scope);
      burst(monitor);
      expect(scope.actions().length < BURST).assertTrue();
      // A JS fault is being handled: its crash incident is persisted right after this call.
      monitor.openLaunchView();
      expect(scope.actionNames().join(',')).assertEqual(expected().join(','));
      monitor.stopKeepAlive();
    });

    it('sessionQueriesSeeEveryEarlierCall', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      const monitor: DefaultRumMonitor = monitorOn(scope);
      burst(monitor);
      monitor.stopSession();
      expect(scope.actionNames().join(',')).assertEqual(expected().join(','));
      monitor.stopKeepAlive();
    });

    it('keepsTheCallTimestamp', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const scope: SlowScope = new SlowScope();
      const monitor: DefaultRumMonitor = monitorOn(scope);
      const beforeMs: number = Date.now();
      burst(monitor);
      const afterMs: number = Date.now();
      await settle(scope);
      for (const action of scope.actions()) {
        const date: number = action['date'] as number;
        expect(date >= beforeMs && date <= afterMs).assertTrue();
      }
      monitor.stopKeepAlive();
    });

    it('aFailingDeferredViewWriteDoesNotStallTheQueue', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
        const scope: SlowScope = new SlowScope();
        const monitor: DefaultRumMonitor = monitorOn(scope);
        scope.failViews = true;
        burst(monitor);
        await settle(scope);
        scope.failViews = false;
        expect(scope.actionNames().join(',')).assertEqual(expected().join(','));
        // Still draining: what is queued later reaches storage, with the view counting everything.
        burst(monitor);
        monitor.keepAlive();
        expect(scope.actions().length).assertEqual(BURST * 2);
        expect(scope.lastViewActionCount()).assertEqual(BURST * 2);
        monitor.stopKeepAlive();
      });

    it('processesOnTheCallersTurnAfterStop', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      const monitor: DefaultRumMonitor = monitorOn(scope);
      monitor.stopKeepAlive();
      burst(monitor);
      // Nothing would drain a queue any more: every call is processed when it is made.
      expect(scope.actions().length).assertEqual(BURST);
    });

    it('theCoreAnnouncementOfAChangeDrainsTheQueue', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      const core: FakeCore = new FakeCore();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
      const feature: RumFeature = new RumFeature(core, configuration);
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
      feature.attachMonitor(monitor);
      monitor.startView('home', 'Home');
      burst(monitor);
      expect(scope.actions().length < BURST).assertTrue();
      feature.onReceive({ 'type': 'drain_pending' } as Record<string, Object>);
      expect(scope.actionNames().join(',')).assertEqual(expected().join(','));
      monitor.stopKeepAlive();
    });

    it('stopProcessesTheQueue', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: SlowScope = new SlowScope();
      const monitor: DefaultRumMonitor = monitorOn(scope);
      burst(monitor);
      monitor.stopKeepAlive();
      expect(scope.actions().length).assertEqual(BURST);
    });
  });
}
