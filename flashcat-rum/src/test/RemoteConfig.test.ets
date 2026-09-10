import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { RemoteConfigStore, RemoteConfigValues } from '../main/ets/internal/remoteconfig/RemoteConfigStore';
import { RemoteConfigController, ApplyOutcome, RemoteConfigChangeListener } from '../main/ets/internal/remoteconfig/RemoteConfigController';
import { RemoteConfigFetcher, RemoteConfigResponse, buildConfigUrl } from '../main/ets/internal/remoteconfig/RemoteConfigFetcher';
import { BeforeSamplingContext, BeforeSamplingCallback } from '../main/ets/RumTypes';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumConfigurationBuilder } from '../main/ets/RumConfiguration';

const ignoreChanges: RemoteConfigChangeListener = (_activation: string, _before: number | null, _after: number | null): void => {};

/** Retry delays short enough for a test to wait out, in seconds. The window a
 * test then waits is several times the whole schedule, so a loaded machine
 * cannot turn a timing assertion into a flake. */
const QUICK_RETRIES: number[] = [0.02, 0.04];
const AFTER_EVERY_RETRY_MS: number = 250;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

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
  activation: string = 'next_session', custom: string = '', schemaVersion: number | null = 1): string {
  const parts: string[] = [];
  if (schemaVersion !== null) {
    parts.push(`"schema_version":${schemaVersion}`);
  }
  parts.push(`"version":${version}`, `"ttl":600`, `"enabled":${enabled}`, `"activation":"${activation}"`);
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
      const announced: string[] = [];
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config?client_token=t',
        (activation: string, before: number | null, after: number | null): void => {
          announced.push(`${activation}:${before}:${after}`);
        });

      expect(controller.apply(body(9, true, 25, 'next_session', '{"vip":["u1"]}'), '"e9"'))
        .assertEqual(ApplyOutcome.APPLIED);

      const read: RemoteConfigValues = store.read() as RemoteConfigValues;
      expect(read.sessionSampleRate).assertEqual(25);
      expect(read.version).assertEqual(9);
      expect(read.custom).assertEqual('{"vip":["u1"]}');
      expect(read.etag).assertEqual('"e9"');
      // The controller reports what changed; whether a running session is worth
      // ending is the scope's call — only it knows the session and the hook.
      expect(announced.length).assertEqual(1);
      expect(announced[0]).assertEqual('next_session:null:25');
    });

    it('treatsAnOutOfRangeRateAsAbsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config', ignoreChanges);
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
        store, new FakeFetcher(), 'https://x/config', ignoreChanges);
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
        store, new FakeFetcher(), 'https://x/config', ignoreChanges);
      controller.apply(body(3, true, 30), null);
      expect(controller.apply('<html>gateway error</html>', null)).assertEqual(ApplyOutcome.UNREADABLE);
      expect((store.read() as RemoteConfigValues).sessionSampleRate).assertEqual(30);
    });

    it('refusesASchemaItDoesNotRead', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config', ignoreChanges);

      // Nothing of a body we cannot vouch for reaches storage, not even the fields that parsed.
      expect(controller.apply(body(3, true, 30, 'next_session', '', 99), null))
        .assertEqual(ApplyOutcome.UNSUPPORTED_SCHEMA);
      expect(store.read() === null).assertTrue();
    });

    it('readsABodyWithNoSchemaStampAtAll', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // A body with no stamp is, by construction, the shape that existed before the stamp did —
      // the shape this reader was written against. Refusing it would switch remote configuration
      // silently off against a server that merely predates the field, with nothing to say so.
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config', ignoreChanges);

      expect(controller.apply(body(3, true, 30, 'next_session', '', null), null))
        .assertEqual(ApplyOutcome.APPLIED);
      expect(store.read()?.sessionSampleRate).assertEqual(30);
    });

    it('announcesTheRateThisClientHeldBeforeAndAfter',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const announced: string[] = [];
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new FakeFetcher(), 'https://x/config',
          (activation: string, before: number | null, after: number | null): void => {
            announced.push(`${activation}:${before}:${after}`);
          });

        controller.apply(body(1, true, 20, 'immediate'), null);
        controller.apply(body(2, true, 20, 'immediate'), null);
        controller.apply(body(3, true, 60, 'next_session'), null);
        // `before` is read before the write, so the scope can tell a real move
        // from the console re-publishing what this client already holds.
        expect(announced[0]).assertEqual('immediate:null:20');
        expect(announced[1]).assertEqual('immediate:20:20');
        expect(announced[2]).assertEqual('next_session:20:60');
      });

    it('refusesAConfigurationOlderThanTheOneInForce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const fetcher: FakeFetcher = new FakeFetcher();
        let announcements: number = 0;
        const controller: RemoteConfigController = new RemoteConfigController(
          store, fetcher, 'https://x/config',
          (_a: string, _b: number | null, _c: number | null): void => { announcements++; });
        // In force: foreground refresh off, which is what the operator chose.
        controller.apply(body(7, true, 5, 'next_session', '', 1), '"e7"');
        announcements = 0;

        // A lagging replica or a proxy replaying a held body. Rollbacks are
        // published as a NEW version, so an older one can only be stale.
        expect(controller.apply(`{"schema_version":1,"version":6,"ttl":30,"enabled":true,`
          + `"activation":"immediate","refresh_on_foreground":true,"rum":{"sessionSampleRate":50}}`, '"e6"'))
          .assertEqual(ApplyOutcome.STALE_VERSION);

        const read: RemoteConfigValues = store.read() as RemoteConfigValues;
        expect(read.sessionSampleRate).assertEqual(5);
        expect(read.version).assertEqual(7);
        expect(read.etag).assertEqual('"e7"'); // the validator still validates what we hold
        expect(announcements).assertEqual(0);
        // Nothing the refused body carried may take effect, not even the fields
        // that are not values: a permission read out of a body we would not
        // read would outlive it. Its `refresh_on_foreground: true` must not
        // start the foreground fetching the operator turned off.
        controller.refreshIfStale();
        expect(fetcher.urls.length).assertEqual(0);
      });

    it('refusesABodyThatLostItsVersionAfterOneWasApplied',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new FakeFetcher(), 'https://x/config', ignoreChanges);
        controller.apply(body(3, true, 10), null);

        // Version 0 and a missing version both read as "no version": after a
        // real one has been applied, only a lagging node answers that way.
        expect(controller.apply(body(0, true, 90), null)).assertEqual(ApplyOutcome.STALE_VERSION);
        expect(controller.apply('{"schema_version":1,"enabled":true,"rum":{"sessionSampleRate":90}}', null))
          .assertEqual(ApplyOutcome.STALE_VERSION);
        expect((store.read() as RemoteConfigValues).sessionSampleRate).assertEqual(10);
      });

    it('appliesAConfigurationRepublishedUnderTheSameVersion',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new FakeFetcher(), 'https://x/config', ignoreChanges);
        controller.apply(body(4, true, 10), null);
        // Equal is not stale: the same version can resolve to different values
        // for this client when its env or app version changed under a rule.
        expect(controller.apply(body(4, true, 80), null)).assertEqual(ApplyOutcome.APPLIED);
        expect((store.read() as RemoteConfigValues).sessionSampleRate).assertEqual(80);
      });

    it('ignoresANegativeRateFromTheServer', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      const controller: RemoteConfigController = new RemoteConfigController(
        store, new FakeFetcher(), 'https://x/config', ignoreChanges);
      controller.apply(body(2, true, -1), null);
      // A negative rate would sample nothing: collection must not be switched
      // off by a malformed body. Read off the stored entry rather than through
      // `read()`, which guards the value a second time and would hide a hole
      // here.
      let serialized: string = '';
      core.settings.forEach((value: string, _key: string): void => { serialized = value; });
      expect(serialized.indexOf('"rate"') >= 0).assertFalse();
      expect((store.read() as RemoteConfigValues).sessionSampleRate).assertNull();
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
        store, fetcher, 'https://x/config?client_token=t', ignoreChanges);
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
          store, fetcher, 'https://x/config?client_token=t', ignoreChanges);
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

  describe('rum-remote-config-fetching', (): void => {
    it('retriesTwiceThenWaitsForTheNextTrigger',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.fail('connection reset');
        const controller: RemoteConfigController = new RemoteConfigController(
          newStore(core), fetcher, 'https://x/config', ignoreChanges, QUICK_RETRIES);

        controller.start();
        await sleep(AFTER_EVERY_RETRY_MS);
        // One ask plus the two the budget allows. A fleet must never turn an
        // endpoint incident into a storm.
        expect(fetcher.urls.length).assertEqual(3);
        await sleep(AFTER_EVERY_RETRY_MS);
        expect(fetcher.urls.length).assertEqual(3);
        controller.stop();
      });

    it('aNewSessionAsksAtOnceInsteadOfWaitingOutTheBackoff',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.fail('connection reset');
        const controller: RemoteConfigController = new RemoteConfigController(
          newStore(core), fetcher, 'https://x/config', ignoreChanges, QUICK_RETRIES);

        controller.start();
        await sleep(AFTER_EVERY_RETRY_MS);
        expect(fetcher.urls.length).assertEqual(3); // budget spent

        // A session starting in the middle of an outage does not inherit an
        // exhausted budget: it asks, and is owed the two retries again.
        controller.onSessionStarted();
        await sleep(AFTER_EVERY_RETRY_MS);
        expect(fetcher.urls.length).assertEqual(6);
        controller.stop();
      });

    it('asksAgainAfterAnUnchangedAnswer',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.answer(304, '');
        const controller: RemoteConfigController = new RemoteConfigController(
          newStore(core), fetcher, 'https://x/config', ignoreChanges, QUICK_RETRIES);

        controller.start();
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(1);
        // "Nothing changed" is an answer, not a request still in flight: a 304
        // that left the controller wedged would freeze a whole fleet on the
        // first unchanged reply.
        controller.onSessionStarted();
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(2);
        controller.stop();
      });

    it('dropsAResponseThatLandsAfterTheSdkStopped',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.answer(200, body(3, true, 40, 'immediate'));
        let announcements: number = 0;
        const controller: RemoteConfigController = new RemoteConfigController(
          store, fetcher, 'https://x/config',
          (_a: string, _b: number | null, _c: number | null): void => { announcements++; },
          QUICK_RETRIES);

        controller.start();
        controller.stop(); // the request is already on the wire and cannot be recalled
        await sleep(20);

        expect(store.read()).assertNull();
        expect(announcements).assertEqual(0);
      });

    it('followsTheServerTtlWhenDecidingWhatIsStale',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const fetcher: FakeFetcher = new FakeFetcher();
        // ttl 1s, and the console allows the foreground to ask again.
        fetcher.answer(200, `{"schema_version":1,"version":1,"ttl":1,"enabled":true,`
          + `"activation":"next_session","refresh_on_foreground":true,"rum":{"sessionSampleRate":30}}`);
        const controller: RemoteConfigController = new RemoteConfigController(
          newStore(core), fetcher, 'https://x/config', ignoreChanges, QUICK_RETRIES);

        controller.start();
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(1);

        controller.refreshIfStale();
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(1); // still fresh: switching apps is not a reason

        await sleep(1100);
        controller.refreshIfStale();
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(2); // older than the ttl the server asked for
        controller.stop();
      });

    it('anUnsupportedSchemaLeavesTheRhythmAlone',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const fetcher: FakeFetcher = new FakeFetcher();
        const controller: RemoteConfigController = new RemoteConfigController(
          newStore(core), fetcher, 'https://x/config', ignoreChanges, QUICK_RETRIES);
        controller.apply(body(2, true, 30), null); // refresh_on_foreground absent: off

        // A body written to a contract we cannot read is refused whole — its
        // permissions included.
        expect(controller.apply(`{"schema_version":99,"version":3,"ttl":1,"enabled":true,`
          + `"activation":"next_session","refresh_on_foreground":true,"rum":{"sessionSampleRate":70}}`, null))
          .assertEqual(ApplyOutcome.UNSUPPORTED_SCHEMA);

        controller.refreshIfStale();
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(0);
      });
  });

  describe('rum-remote-config-monitor', (): void => {
    function monitorWith(core: FakeCore, scope: CapturingScope, store: RemoteConfigStore,
      fetcher: FakeFetcher, rate: number): DefaultRumMonitor {
      const controller: RemoteConfigController = new RemoteConfigController(
        store, fetcher, 'https://x/config', ignoreChanges, QUICK_RETRIES);
      return new DefaultRumMonitor(
        core, scope,
        new RumConfigurationBuilder('app-1').setSessionSampleRate(rate)
          .setRemoteConfigurationEnabled(true).build(),
        store, controller);
    }

    it('everyNewSessionAsksTheConsoleAgain',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.answer(304, '');
        const monitor: DefaultRumMonitor = monitorWith(core, scope, newStore(core), fetcher, 100);

        monitor.startView('home', 'Home');
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(1);

        // Without this the console's change reaches nobody who keeps the app
        // open: the next ask would wait for a cold start.
        monitor.stopSession();
        monitor.startView('next', 'Next');
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(2);

        monitor.stopKeepAlive();
        monitor.stopRemoteConfig();
      });

    it('stopRemoteConfigEndsTheAsking',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.answer(304, '');
        const monitor: DefaultRumMonitor = monitorWith(core, scope, newStore(core), fetcher, 100);

        monitor.stopRemoteConfig();
        monitor.startView('home', 'Home');
        await sleep(20);
        expect(fetcher.urls.length).assertEqual(0);
        monitor.stopKeepAlive();
      });

    it('setForcedSessionCollectsAVisitorTheRateDropped',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 3, null, null));
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.answer(304, '');
        const monitor: DefaultRumMonitor = monitorWith(core, scope, store, fetcher, 100);

        monitor.startView('home', 'Home');
        expect(scope.written.length).assertEqual(0);

        monitor.setForcedSession();
        monitor.startView('home', 'Home');
        expect(scope.written.length > 0).assertTrue();

        await sleep(20);
        monitor.stopKeepAlive();
        monitor.stopRemoteConfig();
      });

    it('aPublishedChangeTravelsFromTheResponseToTheRunningSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 1, null, null)); // collection is off
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.answer(200, body(2, true, 100)); // and the console turns it on

        // Wired the way `FlashcatRum.enable` wires it: the controller exists
        // before the monitor that owns it, so the listener finds the monitor
        // when it fires rather than when it is built.
        let monitorRef: DefaultRumMonitor | null = null;
        const controller: RemoteConfigController = new RemoteConfigController(
          store, fetcher, 'https://x/config',
          (activation: string, before: number | null, after: number | null): void => {
            if (monitorRef !== null) {
              monitorRef.onRemoteConfigurationChanged(activation, before, after);
            }
          },
          QUICK_RETRIES);
        const monitor: DefaultRumMonitor = new DefaultRumMonitor(
          core, scope,
          new RumConfigurationBuilder('app-1').setSessionSampleRate(100)
            .setRemoteConfigurationEnabled(true).build(),
          store, controller);
        monitorRef = monitor;

        // Drawn under the stored 0, so nothing is collected — and starting it
        // is what asks the console.
        monitor.startView('home', 'Home');
        expect(scope.written.length).assertEqual(0);
        await sleep(20);

        // The response travelled response → store → announcement → monitor →
        // scope, and ended the session that could not collect anything.
        monitor.startView('next', 'Next');
        expect(scope.written.length > 0).assertTrue();

        monitor.stopKeepAlive();
        monitor.stopRemoteConfig();
      });

    it('getRemoteConfigHandsBackTheDecodedBag',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(100, 3, '{"flags":{"beta":true}}', null));
        const fetcher: FakeFetcher = new FakeFetcher();
        fetcher.answer(304, '');
        const monitor: DefaultRumMonitor = monitorWith(core, scope, store, fetcher, 100);

        const bag: Record<string, Object> = monitor.getRemoteConfig() as Record<string, Object>;
        const flags: Record<string, Object> = bag['flags'] as Record<string, Object>;
        expect(flags['beta']).assertTrue(); // decoded, not handed back as a string

        await sleep(20);
        monitor.stopKeepAlive();
        monitor.stopRemoteConfig();
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

        // Storage changing under a running session decides nothing on its own:
        // only an announcement through `onConfigurationChanged` can end one, and
        // that path is pinned by `theConsoleTurningCollectionOffStopsTheRunningSession`.
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
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(3, 7, null, null));
      const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, store);
      const now: number = Date.now();

      app.forceSession(now + 100);
      startView(app, now + 200);
      expect(scope.written.length > 0).assertTrue();

      // A forced session was not drawn by the published rate, so it must not be
      // reported under it: the console weights a session by 100/rate, and one
      // forced visitor at 3% would land in the estimate as thirty-three.
      const configuration: Record<string, Object> =
        configurationOf(scope.written[0]) as Record<string, Object>;
      expect(configuration['session_sample_rate']).assertEqual(100);
      expect(configuration['rc_version']).assertUndefined();
    });

    it('hookCannotRaiseTheRateAboveTheScale', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(0, 2, null, null));
      const app: RumApplicationScope = new RumApplicationScope(
        scope, core, 'app-1', 0, store,
        (_c: BeforeSamplingContext): number | undefined => 101);
      startView(app, Date.now());
      // 101 is not a rate; the incoming 0 stands rather than being clamped to
      // something nobody asked for.
      expect(scope.written.length).assertEqual(0);
    });

    it('ignoresANegativeRateLeftInStorage', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(-1, 4, null, null));
      const read: RemoteConfigValues | null = store.read();
      // A corrupted entry must not switch collection off: it reads as "nothing
      // published", so the init value keeps applying.
      expect(read === null || read.sessionSampleRate === null).assertTrue();
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

    it('carriesTheDrawnRateEvenWhenRemoteConfigurationIsOff',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100);
        startView(app, Date.now());

        // The backend weights every session by this rate whether or not the app
        // opted into remote configuration; sending nothing is read as a zero,
        // which the console files under "SDK too old to report".
        const configuration: Record<string, Object> =
          configurationOf(scope.written[0]) as Record<string, Object>;
        expect(configuration['session_sample_rate']).assertEqual(100);
        // No version, because no configuration decided it.
        expect(configuration['rc_version']).assertUndefined();
      });
  });

  describe('rum-remote-config-activation', (): void => {
    it('endsARunningSessionOnlyWhenTheChangeDecidesSomething',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A session already under way is never re-drawn on a rate that merely
        // moved: re-rolling a session that lost a fair draw would bias
        // collection upward with every publish.
        expect(RumApplicationScope.shouldEndSession(false, 0, 100, 'next_session')).assertTrue();
        expect(RumApplicationScope.shouldEndSession(false, 30, 100, 'next_session')).assertFalse();
        expect(RumApplicationScope.shouldEndSession(false, 0, 0, 'next_session')).assertFalse();
        // Collecting, and the change means "collect nothing": an emergency stop
        // has to reach the session that is running.
        expect(RumApplicationScope.shouldEndSession(true, 100, 0, 'next_session')).assertTrue();
        expect(RumApplicationScope.shouldEndSession(true, 100, 50, 'next_session')).assertFalse();
        // `immediate` is the console asking for this session to be re-decided,
        // but there is still nothing to gain from replacing a dark session with
        // another one the new rate cannot collect either.
        expect(RumApplicationScope.shouldEndSession(true, 100, 50, 'immediate')).assertTrue();
        expect(RumApplicationScope.shouldEndSession(false, 30, 50, 'immediate')).assertTrue();
        expect(RumApplicationScope.shouldEndSession(false, 30, 0, 'immediate')).assertFalse();
      });

    it('turningCollectionOnReachesTheSessionThatIsAlreadyDark',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 1, null, null));
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100, store);
        const now: number = Date.now();
        startView(app, now);
        expect(scope.written.length).assertEqual(0);
        const dark: string = app.getCurrentSessionId() as string;

        store.write(new RemoteConfigValues(100, 2, null, null));
        app.onConfigurationChanged('next_session', 0, 100, now + 1000);
        // Ended, so the next event draws under the new rate. Without this an
        // operator who just switched collection on sees nothing from anyone
        // already using the app — for up to four hours.
        expect(app.getCurrentSessionId()).assertUndefined();

        startView(app, now + 2000);
        expect(scope.written.length > 0).assertTrue();
        expect(app.getCurrentSessionId() === dark).assertFalse();
      });

    it('republishingTheSameRateCutsNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(100, 1, null, null));
      const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100, store);
      const now: number = Date.now();
      startView(app, now);
      const running: string = app.getCurrentSessionId() as string;

      app.onConfigurationChanged('immediate', 100, 100, now + 1000);
      expect(app.getCurrentSessionId()).assertEqual(running);
      // Falling back to the init value on both sides is the same non-change.
      app.onConfigurationChanged('immediate', null, null, now + 2000);
      expect(app.getCurrentSessionId()).assertEqual(running);
    });

    it('theKillSwitchIsMeasuredAgainstTheInitValue',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 1, null, null));
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100, store);
        const now: number = Date.now();
        startView(app, now);
        expect(scope.written.length).assertEqual(0);

        // The console hands the knob back: `after` is null, and what applies
        // from now on is the 100 this app was built with.
        store.write(new RemoteConfigValues(null, 2, null, null));
        app.onConfigurationChanged('next_session', 0, null, now + 1000);
        expect(app.getCurrentSessionId()).assertUndefined();
      });

    it('aForcedSessionIsNeverEndedByARate', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(0, 1, null, null));
      const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, store);
      const now: number = Date.now();
      app.forceSession(now);
      startView(app, now + 100);
      const forced: string = app.getCurrentSessionId() as string;

      // Every replacement would be forced too, so ending this one only costs
      // the view the visitor is on.
      app.onConfigurationChanged('next_session', 0, 50, now + 200);
      expect(app.getCurrentSessionId()).assertEqual(forced);
      app.onConfigurationChanged('immediate', 50, 0, now + 300);
      expect(app.getCurrentSessionId()).assertEqual(forced);
    });

    it('aSessionTheHookKeepsIsNeverEndedByARate',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 1, null, null));
        const allowList: BeforeSamplingCallback =
          (_c: BeforeSamplingContext): number | undefined => 100;
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, store, allowList);
        const now: number = Date.now();
        startView(app, now);
        const kept: string = app.getCurrentSessionId() as string;
        expect(scope.written.length > 0).assertTrue();

        // The allow-list already answers the question the rate is asking, in
        // both directions: cutting these sessions would split the timeline of
        // exactly the visitors someone chose to keep.
        store.write(new RemoteConfigValues(5, 2, null, null));
        app.onConfigurationChanged('next_session', 0, 5, now + 1000);
        expect(app.getCurrentSessionId()).assertEqual(kept);

        store.write(new RemoteConfigValues(0, 3, null, null));
        app.onConfigurationChanged('next_session', 5, 0, now + 2000);
        expect(app.getCurrentSessionId()).assertEqual(kept);
      });

    it('theConsoleTurningCollectionOffStopsTheRunningSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(100, 1, null, null));
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100, store);
        const now: number = Date.now();
        startView(app, now);
        expect(app.getCurrentSessionId() !== undefined).assertTrue();

        store.write(new RemoteConfigValues(0, 2, null, null));
        app.onConfigurationChanged('next_session', 100, 0, now + 1000);
        expect(app.getCurrentSessionId()).assertUndefined();

        const written: number = scope.written.length;
        startView(app, now + 2000);
        app.handleEvent(raw('addAction', now + 3000));
        expect(scope.written.length).assertEqual(written); // and the replacement collects nothing
      });
  });
}
