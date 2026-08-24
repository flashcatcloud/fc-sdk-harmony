import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { RemoteConfigStore, RemoteConfigValues } from '../main/ets/internal/remoteconfig/RemoteConfigStore';
import { RemoteConfigController } from '../main/ets/internal/remoteconfig/RemoteConfigController';
import { RemoteConfigFetcher, RemoteConfigResponse, buildConfigUrl } from '../main/ets/internal/remoteconfig/RemoteConfigFetcher';
import { BeforeSamplingContext } from '../main/ets/RumTypes';

function testContext(appVersion: string = '1.0.0'): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: appVersion,
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.5.1',
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

class FakeCore implements SdkCore {
  readonly name: string = 'test';
  readonly settings: Map<string, string> = new Map<string, string>();
  private readonly appVersion: string;
  /** Simulates a device where the settings store cannot be opened at all. */
  storageUnavailable: boolean = false;

  constructor(appVersion: string = '1.0.0') {
    this.appVersion = appVersion;
  }

  registerFeature(_feature: Feature): void {}
  getFeature(_featureName: string): FeatureScope | null {
    return null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, _update: Record<string, Object>): void {}
  getContext(): FlashcatContext {
    return testContext(this.appVersion);
  }
  getTrackingConsent(): TrackingConsent {
    return TrackingConsent.GRANTED;
  }
  isActive(): boolean {
    return true;
  }
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'ct-123' };
  }
  readSetting(key: string): string | null {
    if (this.storageUnavailable) {
      return null;
    }
    const value: string | undefined = this.settings.get(key);
    return value === undefined ? null : value;
  }
  writeSetting(key: string, value: string | null): void {
    if (this.storageUnavailable) {
      return;
    }
    if (value === null) {
      this.settings.delete(key);
    } else {
      this.settings.set(key, value);
    }
  }
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
}

/** Answers whatever the test queued, and records what it was asked. */
class FakeFetcher implements RemoteConfigFetcher {
  readonly urls: string[] = [];
  readonly validators: Array<string | null> = [];
  private response: RemoteConfigResponse | null = null;
  private failure: string | null = null;

  answer(code: number, body: string, etag: string | null = null): void {
    this.response = { code: code, body: body, etag: etag };
    this.failure = null;
  }

  fail(message: string): void {
    this.failure = message;
    this.response = null;
  }

  fetch(url: string, ifNoneMatch: string | null): Promise<RemoteConfigResponse> {
    this.urls.push(url);
    this.validators.push(ifNoneMatch);
    if (this.failure !== null) {
      return Promise.reject(new Error(this.failure));
    }
    return Promise.resolve(this.response as RemoteConfigResponse);
  }
}

function newStore(core: FakeCore): RemoteConfigStore {
  return new RemoteConfigStore(core, RemoteConfigStore.buildStoreKey(core.getContext(), 'https://intake.example.com', 'app-1'));
}

function raw(kind: string, timestampMs: number, key?: string): RumRawEvent {
  const e: RumRawEvent = { kind, attributes: {}, timestampMs };
  if (key !== undefined) {
    e.key = key;
  }
  return e;
}

function startView(app: RumApplicationScope, atMs: number): void {
  const e: RumRawEvent = raw('startView', atMs, 'home');
  e.name = 'Home';
  app.handleEvent(e);
}

function sessionIdOf(event: Record<string, Object>): string {
  const session: Record<string, Object> = event['session'] as Record<string, Object>;
  return session !== undefined ? session['id'] as string : '';
}

function configurationOf(event: Record<string, Object>): Record<string, Object> | undefined {
  const dd: Record<string, Object> = event['_dd'] as Record<string, Object>;
  return dd === undefined ? undefined : dd['configuration'] as Record<string, Object>;
}

/** Body the engine sends: rates live under `rum`, the app's bag under `custom`. */
function body(version: number, enabled: boolean, rate: number | null,
  activation: string = 'next_session', custom: string = ''): string {
  const parts: string[] = [`"version":${version}`, `"ttl":600`, `"enabled":${enabled}`, `"activation":"${activation}"`];
  parts.push(rate === null ? '"rum":{}' : `"rum":{"sessionSampleRate":${rate}}`);
  if (custom.length > 0) {
    parts.push(`"custom":${custom}`);
  }
  return `{${parts.join(',')}}`;
}

export default function remoteConfigTests(): void {
  describe('rum-remote-config-store', (): void => {
    it('keepsAbsentKnobsAbsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(null, 7, null, '"tag"'));
      const read: RemoteConfigValues | null = store.read();
      expect(read !== null).assertTrue();
      // A version with no rates is what "the console turned the feature off"
      // looks like: the client is up to date, and its init rate applies.
      expect((read as RemoteConfigValues).sessionSampleRate).assertNull();
      expect((read as RemoteConfigValues).version).assertEqual(7);
      expect((read as RemoteConfigValues).etag).assertEqual('"tag"');
    });

    it('roundTripsPublishedValues', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(42.5, 3, '{"tier":"vip"}', '"e1"'));
      const read: RemoteConfigValues = store.read() as RemoteConfigValues;
      expect(read.sessionSampleRate).assertEqual(42.5);
      expect(read.custom).assertEqual('{"tier":"vip"}');
      expect(store.appliedVersion()).assertEqual(3);
    });

    it('readsCorruptEntryAsNothingStored', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(50, 1, null, null));
      core.settings.forEach((_v: string, k: string) => core.settings.set(k, 'not json'));
      expect(store.read()).assertNull();
      expect(store.appliedVersion()).assertNull();
    });

    it('unavailableStorageReadsAsNothingStored', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      core.storageUnavailable = true;
      store.write(new RemoteConfigValues(50, 1, null, null));
      expect(store.read()).assertNull();
    });

    it('separatesAppVersions', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const first: string = RemoteConfigStore.buildStoreKey(testContext('1.0.0'), 'https://intake.example.com/', 'app-1');
      const same: string = RemoteConfigStore.buildStoreKey(testContext('1.0.0'), 'https://intake.example.com', 'app-1');
      const shipped: string = RemoteConfigStore.buildStoreKey(testContext('2.0.0'), 'https://intake.example.com', 'app-1');
      const otherApp: string = RemoteConfigStore.buildStoreKey(testContext('1.0.0'), 'https://intake.example.com', 'app-2');
      expect(first).assertEqual(same); // a trailing slash is not a different host
      expect(first === shipped).assertFalse();
      expect(first === otherApp).assertFalse();
    });
  });

  describe('rum-remote-config-controller', (): void => {
    it('storesWhatThePublishedConfigurationCarried', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      let restarts: number = 0;
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config?client_token=t', 100, (): void => { restarts++; });

      expect(controller.apply(body(9, true, 25, 'next_session', '{"vip":["u1"]}'), '"e9"')).assertTrue();

      const read: RemoteConfigValues = store.read() as RemoteConfigValues;
      expect(read.sessionSampleRate).assertEqual(25);
      expect(read.version).assertEqual(9);
      expect(read.custom).assertEqual('{"vip":["u1"]}');
      expect(read.etag).assertEqual('"e9"');
      expect(restarts).assertEqual(0); // next_session: nobody's session is cut short
    });

    it('treatsAnOutOfRangeRateAsAbsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config', 100, (): void => {});
      controller.apply(body(2, true, 140), null);
      // Not clamped to 100: a rate we cannot trust is not a rate to sample with,
      // so the value the app was initialised with keeps applying.
      expect((store.read() as RemoteConfigValues).sessionSampleRate).assertNull();
      expect((store.read() as RemoteConfigValues).version).assertEqual(2);
    });

    it('killSwitchHandsTheKnobsBack', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config', 100, (): void => {});
      controller.apply(body(4, true, 10, 'next_session', '{"tier":"vip"}'), null);
      controller.apply(body(5, false, 10, 'next_session', '{"tier":"vip"}'), null);
      const read: RemoteConfigValues = store.read() as RemoteConfigValues;
      expect(read.sessionSampleRate).assertNull();
      expect(read.custom).assertNull();
      expect(read.version).assertEqual(5); // still traceable to the change that switched it off
    });

    it('unreadableBodyIsAFailedAskNotAnEmptyConfiguration', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config', 100, (): void => {});
      controller.apply(body(3, true, 30), null);
      expect(controller.apply('<html>gateway error</html>', null)).assertFalse();
      expect((store.read() as RemoteConfigValues).sessionSampleRate).assertEqual(30);
    });

    it('immediateActivationOnlyCutsSessionsWhenThisClientsRateChanged',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        let restarts: number = 0;
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new FakeFetcher(), 'https://x/config', 100, (): void => { restarts++; });

        controller.apply(body(1, true, 20, 'immediate'), null);
        expect(restarts).assertEqual(1);
        // The console republishing the same rate must not cut every session in two.
        controller.apply(body(2, true, 20, 'immediate'), null);
        expect(restarts).assertEqual(1);
        controller.apply(body(3, true, 60, 'immediate'), null);
        expect(restarts).assertEqual(2);
      });

    it('foregroundRefreshNeedsPermissionAndAge', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RemoteConfigController.shouldRefreshOnForeground(false, 999999, 60)).assertFalse();
      expect(RemoteConfigController.shouldRefreshOnForeground(true, 1000, 60)).assertFalse();
      expect(RemoteConfigController.shouldRefreshOnForeground(true, 60000, 60)).assertTrue();
    });

    it('spreadsRetriesAroundTheAskedDelay', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(Math.round(RemoteConfigController.jittered(10, 0))).assertEqual(8);
      expect(Math.round(RemoteConfigController.jittered(10, 1))).assertEqual(12);
      expect(Math.round(RemoteConfigController.jittered(10, 0.5))).assertEqual(10);
    });

    it('keepsStoredValuesWhenTheRequestFails', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const fetcher: FakeFetcher = new FakeFetcher();
      const controller: RemoteConfigController = new RemoteConfigController(
        store, fetcher, 'https://x/config?client_token=t', 100, (): void => {});
      controller.apply(body(6, true, 15), '"e6"');

      fetcher.fail('connection reset');
      controller.start();
      await Promise.resolve();
      await Promise.resolve();
      controller.stop(); // drop the scheduled retry so the test leaves no timer

      const read: RemoteConfigValues = store.read() as RemoteConfigValues;
      expect(read.sessionSampleRate).assertEqual(15);
      expect(read.version).assertEqual(6);
    });

    it('carriesTheAppliedVersionAndValidatorOnTheRequest',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const fetcher: FakeFetcher = new FakeFetcher();
        const controller: RemoteConfigController = new RemoteConfigController(
          store, fetcher, 'https://x/config?client_token=t', 100, (): void => {});
        controller.apply(body(6, true, 15), '"e6"');

        fetcher.answer(304, '');
        controller.start();
        await Promise.resolve();
        await Promise.resolve();
        controller.stop();

        expect(fetcher.urls[0]).assertEqual('https://x/config?client_token=t&applied_version=6');
        expect(fetcher.validators[0]).assertEqual('"e6"');
        // 304: what is stored is still the answer.
        expect((store.read() as RemoteConfigValues).sessionSampleRate).assertEqual(15);
      });

    it('buildsTheConfigUrlTheEngineAnswers', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const url: string = buildConfigUrl('https://intake.example.com/', 'ct 123', testContext('2.3.4'));
      expect(url).assertEqual(
        'https://intake.example.com/api/v2/rum/config?client_token=ct%20123&sdk=harmony&env=prod&app_version=2.3.4&sdk_version=0.5.1');
    });
  });

  describe('rum-remote-config-sampling', (): void => {
    it('publishedRateAppliesToTheNextSessionNotTheRunningOne',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(100, 4, null, null));
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, store);

        const now: number = Date.now();
        startView(app, now);
        expect(scope.written.length > 0).assertTrue(); // the console's 100 beat the init 0
        const runningSession: string = sessionIdOf(scope.written[0]);

        // The console drops to 0 while the session runs: it must keep collecting.
        store.write(new RemoteConfigValues(0, 5, null, null));
        app.handleEvent(raw('addAction', now + 1000));
        const last: Record<string, Object> = scope.written[scope.written.length - 1];
        expect(sessionIdOf(last)).assertEqual(runningSession);

        // Only the NEXT session is drawn under it.
        app.stopCurrentSession(now + 2000);
        const before: number = scope.written.length;
        startView(app, now + 3000);
        app.handleEvent(raw('addAction', now + 4000));
        expect(scope.written.length).assertEqual(before);
      });

    it('initValueAppliesWhenNothingWasEverPublished',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, newStore(core));
        startView(app, Date.now());
        expect(scope.written.length).assertEqual(0); // init 0 still means "collect nothing"
      });

    it('beforeSamplingHasTheLastWordAndSeesTheCustomValues',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 8, '{"vip":["u-42"]}', null));
        const scope: CapturingScope = new CapturingScope();
        let sawRate: number = -1;
        let sawVip: string = '';
        const app: RumApplicationScope = new RumApplicationScope(
          scope, core, 'app-1', 90, store,
          (context: BeforeSamplingContext): number | undefined => {
            sawRate = context.sessionSampleRate;
            const custom: Record<string, Object> | null = context.custom;
            if (custom !== null) {
              const vip: Array<Object> = custom['vip'] as Array<Object>;
              sawVip = vip[0] as string;
            }
            return 100;
          });

        startView(app, Date.now());
        expect(sawRate).assertEqual(0); // the rate that WOULD apply: the console's, not init
        expect(sawVip).assertEqual('u-42');
        expect(scope.written.length > 0).assertTrue(); // the allow-list kept a session 0% would drop
      });

    it('ignoresAnUnusableAnswerFromTheHook', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const thrower: RumApplicationScope = new RumApplicationScope(
        scope, core, 'app-1', 100, newStore(core),
        (_c: BeforeSamplingContext): number | undefined => {
          throw new Error('bad hook');
        });
      startView(thrower, Date.now());
      expect(scope.written.length > 0).assertTrue(); // a throwing hook must not take collection down

      const outOfRange: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(
        outOfRange, core, 'app-1', 100, newStore(core),
        (_c: BeforeSamplingContext): number | undefined => -5);
      startView(app, Date.now());
      expect(outOfRange.written.length > 0).assertTrue();

      const passthrough: CapturingScope = new CapturingScope();
      const untouched: RumApplicationScope = new RumApplicationScope(
        passthrough, core, 'app-1', 0, newStore(core),
        (_c: BeforeSamplingContext): number | undefined => undefined);
      startView(untouched, Date.now());
      expect(passthrough.written.length).assertEqual(0); // nothing returned: the incoming 0 stands
    });

    it('forcedSessionCollectsWhatTheRateDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, newStore(core));
      const now: number = Date.now();
      startView(app, now);
      expect(scope.written.length).assertEqual(0);

      app.forceSession(now + 100);
      startView(app, now + 200);
      expect(scope.written.length > 0).assertTrue();
    });

    it('forcingAgainWhileItRunsChangesNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, newStore(core));
      const now: number = Date.now();
      app.forceSession(now);
      startView(app, now + 100);
      const sessionId: string = sessionIdOf(scope.written[0]);

      app.forceSession(now + 200);
      app.handleEvent(raw('addAction', now + 300));
      const last: Record<string, Object> = scope.written[scope.written.length - 1];
      expect(sessionIdOf(last)).assertEqual(sessionId);
    });

    it('viewEventsCarryTheDrawnRateAndVersion', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(100, 12, null, null));
      const scope: CapturingScope = new CapturingScope();
      // init says 17; the console says 100 — the event must report what was drawn.
      const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 17, store);
      startView(app, Date.now());

      const view: Record<string, Object> = scope.written[0];
      const configuration: Record<string, Object> = configurationOf(view) as Record<string, Object>;
      expect(configuration['session_sample_rate']).assertEqual(100);
      expect(configuration['rc_version']).assertEqual(12);
    });

    it('carriesNoConfigurationBlockWhenRemoteConfigurationIsOff',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100);
        startView(app, Date.now());
        expect(configurationOf(scope.written[0])).assertUndefined();
      });
  });
}
