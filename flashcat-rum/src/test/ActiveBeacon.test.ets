import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { ActiveDeviceBeacon, ActiveBeaconSender, NETWORK_ERROR } from '../main/ets/internal/ActiveDeviceBeacon';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { RumConfigurationBuilder } from '../main/ets/RumConfiguration';

const ANONYMOUS_ID: string = '0f8fad5b-d9cb-469f-a165-70867728950e';
const SENT_KEY: string = 'rum.active.sent';
const PENDING_KEY: string = 'rum.active.pending';
const HOUR_MS: number = 60 * 60 * 1000;
// Noon, so a few hours either way stays on the same local day in any timezone
// a test machine is likely to run in.
const NOON: number = new Date(2026, 9, 21, 12, 0, 0).getTime();
const QUICK_RETRIES: number[] = [5, 10];

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

class FakeCore implements SdkCore {
  readonly name: string = 'test';
  readonly settings: Map<string, string> = new Map<string, string>();
  consent: TrackingConsent = TrackingConsent.GRANTED;
  foreground: boolean = true;
  user: UserInfo = {};
  pendingReads: number = 0;

  registerFeature(_feature: Feature): void {}
  getFeature(_featureName: string): FeatureScope | null {
    return null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, _update: Record<string, Object>): void {}
  getContext(): FlashcatContext {
    return {
      env: 'prod',
      variant: '',
      service: 'svc',
      version: '2.3.0',
      buildVersion: '230',
      bundleId: 'com.example.demo',
      source: 'harmony',
      sdkVersion: '0.7.5',
      device: {
        brand: 'HUAWEI', model: 'Pura 70', osName: 'HarmonyOS', osVersion: '5.0.1',
        apiVersion: 18, deviceType: 'phone'
      },
      user: this.user,
      anonymousId: ANONYMOUS_ID,
      network: { status: 'connected', interfaces: ['wifi'] },
      featureContext: {}
    };
  }
  getTrackingConsent(): TrackingConsent {
    return this.consent;
  }
  isActive(): boolean {
    return true;
  }
  isAppInForeground(): boolean {
    return this.foreground;
  }
  setUserInfo(user: UserInfo): void {
    this.user = user;
  }
  clearUserInfo(): void {
    this.user = {};
  }
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com/', clientToken: 'ct 1' };
  }
  readSetting(key: string): string | null {
    if (key === PENDING_KEY) {
      this.pendingReads++;
    }
    const value: string | undefined = this.settings.get(key);
    return value === undefined ? null : value;
  }
  writeSetting(key: string, value: string | null): void {
    if (value === null) {
      this.settings.delete(key);
    } else {
      this.settings.set(key, value);
    }
  }
}

/** Answers the queued status codes in order (202 once the queue is empty). */
class FakeSender implements ActiveBeaconSender {
  readonly urls: string[] = [];
  readonly bodies: Array<Record<string, Object>> = [];
  readonly codes: number[] = [];
  /** When set, answers wait for it: a request still on the wire. */
  gate: Promise<void> | null = null;

  async send(url: string, body: string): Promise<number> {
    this.urls.push(url);
    this.bodies.push(JSON.parse(body) as Record<string, Object>);
    const code: number | undefined = this.codes.shift();
    if (this.gate !== null) {
      await this.gate;
    }
    return code === undefined ? 202 : code;
  }
}

class Clock {
  ms: number = NOON;
}

function beaconOf(core: FakeCore, sender: FakeSender, clock: Clock): ActiveDeviceBeacon {
  return new ActiveDeviceBeacon(core, sender, QUICK_RETRIES, (): number => clock.ms);
}

/** Lets a trigger's run (and its short retries) finish. */
function settle(): Promise<void> {
  return sleep(60);
}

function usr(body: Record<string, Object>): Record<string, Object> {
  return body['usr'] as Record<string, Object>;
}

export default function activeBeaconTests(): void {
  describe('ActiveBeacon', (): void => {
    it('sendsTheContractBodyToTheIntake', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      beaconOf(core, sender, new Clock()).trigger();
      await settle();

      expect(sender.urls.length).assertEqual(1);
      expect(sender.urls[0]).assertEqual('https://intake.example.com/api/v2/rum/active?dd-api-key=ct%201');
      const body: Record<string, Object> = sender.bodies[0];
      expect(body['service']).assertEqual('svc');
      expect(body['env']).assertEqual('prod');
      expect(body['version']).assertEqual('2.3.0');
      expect(body['build_version']).assertEqual('230');
      expect(body['sdk_version']).assertEqual('0.7.5');
      expect(body['age_ms']).assertEqual(0);
      expect(usr(body)['anonymous_id']).assertEqual(ANONYMOUS_ID);
      expect(usr(body)['id']).assertUndefined(); // no user set
      const os: Record<string, Object> = body['os'] as Record<string, Object>;
      expect(os['name']).assertEqual('HarmonyOS');
      expect(os['version']).assertEqual('5.0.1');
      const device: Record<string, Object> = body['device'] as Record<string, Object>;
      expect(device['type']).assertEqual('mobile');
      expect(device['model']).assertEqual('Pura 70');
      expect(device['brand']).assertEqual('HUAWEI');
      expect(JSON.stringify(body).length < 2048).assertTrue();
    });

    it('sendsOncePerLocalDay', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      const clock: Clock = new Clock();
      const beacon: ActiveDeviceBeacon = beaconOf(core, sender, clock);
      beacon.trigger();
      await settle();
      clock.ms += 3 * HOUR_MS; // back to the foreground later that day
      beacon.trigger();
      await settle();
      expect(sender.urls.length).assertEqual(1);

      // The marker survives a restart: a new instance reads it from settings.
      beaconOf(core, sender, clock).trigger();
      await settle();
      expect(sender.urls.length).assertEqual(1);

      clock.ms += 24 * HOUR_MS; // the next day
      beacon.trigger();
      await settle();
      expect(sender.urls.length).assertEqual(2);
    });

    it('aNewUserIsReportedTheSameDay', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      const beacon: ActiveDeviceBeacon = beaconOf(core, sender, new Clock());
      beacon.trigger();
      await settle();
      core.setUserInfo({ id: 'user-a' });
      beacon.trigger();
      await settle();
      core.setUserInfo({ id: 'user-a', name: 'renamed' }); // same id: nothing new
      beacon.trigger();
      await settle();
      core.setUserInfo({ id: 'user-b' });
      beacon.trigger();
      await settle();

      expect(sender.urls.length).assertEqual(3);
      expect(usr(sender.bodies[1])['id']).assertEqual('user-a');
      expect(usr(sender.bodies[2])['id']).assertEqual('user-b');
      expect(usr(sender.bodies[2])['anonymous_id']).assertEqual(ANONYMOUS_ID);
    });

    it('aTriggerDuringASendIsNotLost', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // The user logs in while the launch beacon is still on the wire.
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      let release: () => void = (): void => {};
      sender.gate = new Promise<void>((resolve: () => void) => {
        release = resolve;
      });
      const beacon: ActiveDeviceBeacon = beaconOf(core, sender, new Clock());
      beacon.trigger();
      await sleep(5);
      expect(sender.urls.length).assertEqual(1);
      core.setUserInfo({ id: 'user-a' });
      beacon.trigger();
      release();
      await settle();
      expect(sender.urls.length).assertEqual(2);
      expect(usr(sender.bodies[0])['id']).assertUndefined();
      expect(usr(sender.bodies[1])['id']).assertEqual('user-a');
    });

    it('pendingConsentNeitherSendsNorStores', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      core.consent = TrackingConsent.PENDING;
      const sender: FakeSender = new FakeSender();
      const beacon: ActiveDeviceBeacon = beaconOf(core, sender, new Clock());
      beacon.trigger();
      await settle();
      expect(sender.urls.length).assertEqual(0);
      expect(core.settings.size).assertEqual(0);

      // The grant is a trigger of its own (the core announces it).
      core.consent = TrackingConsent.GRANTED;
      beacon.trigger();
      await settle();
      expect(sender.urls.length).assertEqual(1);
    });

    it('revokedConsentDropsWhatIsStored', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      sender.codes.push(503, 503, 503);
      const beacon: ActiveDeviceBeacon = beaconOf(core, sender, new Clock());
      beacon.trigger();
      await settle();
      expect(core.settings.has(PENDING_KEY)).assertTrue();

      core.consent = TrackingConsent.NOT_GRANTED;
      beacon.forget();
      expect(core.settings.size).assertEqual(0);

      // A launch under NOT_GRANTED drops a record an earlier launch left.
      core.settings.set(PENDING_KEY, '{"payload":{},"used_at":1,"key":"k"}');
      beacon.trigger();
      await settle();
      expect(core.settings.has(PENDING_KEY)).assertFalse();
      expect(sender.urls.length).assertEqual(3);
    });

    it('revocationDuringRetriesStoresNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      sender.codes.push(503, 503, 503);
      const beacon: ActiveDeviceBeacon = new ActiveDeviceBeacon(core, sender, [30, 30], (): number => NOON);
      beacon.trigger();
      await sleep(5);
      core.consent = TrackingConsent.NOT_GRANTED;
      await sleep(100);
      expect(sender.urls.length).assertEqual(1);
      expect(core.settings.size).assertEqual(0);
    });

    it('aBackgroundLaunchDoesNotSend', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      core.foreground = false;
      const sender: FakeSender = new FakeSender();
      const beacon: ActiveDeviceBeacon = beaconOf(core, sender, new Clock());
      beacon.trigger();
      await settle();
      expect(sender.urls.length).assertEqual(0);

      core.foreground = true; // the user opens it
      beacon.trigger();
      await settle();
      expect(sender.urls.length).assertEqual(1);
    });

    it('retriesTwiceThenSendsLateWithItsAge', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      sender.codes.push(NETWORK_ERROR, 500, 429);
      const clock: Clock = new Clock();
      beaconOf(core, sender, clock).trigger();
      await settle();
      expect(sender.urls.length).assertEqual(3); // first try + 2 retries
      expect(core.settings.has(PENDING_KEY)).assertTrue();
      expect(core.settings.has(SENT_KEY)).assertFalse();

      // Next launch, an hour later the same day.
      clock.ms += HOUR_MS;
      beaconOf(core, sender, clock).trigger();
      await settle();
      expect(sender.urls.length).assertEqual(4); // the stored one covers today too
      expect(sender.bodies[3]['age_ms']).assertEqual(HOUR_MS);
      expect(core.settings.has(PENDING_KEY)).assertFalse();
      expect(core.settings.has(SENT_KEY)).assertTrue();
    });

    it('aStoredBeaconFromAnotherDayIsFollowedByToday', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      sender.codes.push(503, 503, 503);
      const clock: Clock = new Clock();
      beaconOf(core, sender, clock).trigger();
      await settle();

      clock.ms += 30 * HOUR_MS;
      beaconOf(core, sender, clock).trigger();
      await settle();
      expect(sender.urls.length).assertEqual(5);
      expect(sender.bodies[3]['age_ms']).assertEqual(30 * HOUR_MS);
      expect(sender.bodies[4]['age_ms']).assertEqual(0);
    });

    it('aStoredBeaconOlderThan72hIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      sender.codes.push(503, 503, 503);
      const clock: Clock = new Clock();
      beaconOf(core, sender, clock).trigger();
      await settle();

      clock.ms += 73 * HOUR_MS;
      beaconOf(core, sender, clock).trigger();
      await settle();
      expect(sender.urls.length).assertEqual(4); // only today's
      expect(sender.bodies[3]['age_ms']).assertEqual(0);
      expect(core.settings.has(PENDING_KEY)).assertFalse();
    });

    it('aClientErrorIsNotRetriedOrStored', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      sender.codes.push(400);
      beaconOf(core, sender, new Clock()).trigger();
      await settle();
      expect(sender.urls.length).assertEqual(1);
      expect(core.settings.size).assertEqual(0);
    });

    it('stopDuringBackoffStoresForTheNextLaunch', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const sender: FakeSender = new FakeSender();
      sender.codes.push(503);
      const beacon: ActiveDeviceBeacon = new ActiveDeviceBeacon(core, sender, [60000, 60000], (): number => NOON);
      beacon.trigger();
      await sleep(5);
      beacon.stop();
      await sleep(5);
      expect(sender.urls.length).assertEqual(1);
      expect(core.settings.has(PENDING_KEY)).assertTrue();
      beacon.trigger(); // a stopped beacon sends nothing
      await sleep(5);
      expect(sender.urls.length).assertEqual(1);
    });

    // Wiring through the feature. The unit-test network always fails, so the
    // observable effect of a trigger is that the beacon reads its stored record;
    // stopping the feature cuts the retry short and stores the beacon.
    it('theFeatureTriggersOnLaunchAndOnCoreSignals', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      core.foreground = false; // launched before the first foreground
      const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
      feature.onInitialize();
      await sleep(5);
      expect(core.pendingReads).assertEqual(0);

      core.foreground = true;
      feature.onReceive({ 'type': 'app_foreground' });
      await sleep(5);
      expect(core.pendingReads).assertEqual(1);
      feature.onReceive({ 'type': 'user_changed' }); // in flight: queued behind it
      feature.onReceive({ 'type': 'consent_granted' });
      feature.onStop();
      await sleep(5);
      expect(core.settings.has(PENDING_KEY)).assertTrue();

      const second: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
      second.onInitialize(); // launch trigger, already in the foreground
      await sleep(5);
      expect(core.pendingReads).assertEqual(2);
      second.onReceive({ 'type': 'consent_revoked' });
      expect(core.settings.has(PENDING_KEY)).assertFalse();
      second.onStop();
    });

    it('theToggleOffSendsNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const feature: RumFeature = new RumFeature(core,
        new RumConfigurationBuilder('app-1').setTrackActiveDevices(false).build());
      feature.onInitialize();
      feature.onReceive({ 'type': 'app_foreground' });
      feature.onReceive({ 'type': 'user_changed' });
      feature.onReceive({ 'type': 'consent_granted' });
      await sleep(5);
      feature.onStop();
      expect(core.pendingReads).assertEqual(0);
      expect(core.settings.size).assertEqual(0);
      expect(new RumConfigurationBuilder('app-1').build().trackActiveDevices).assertTrue();
    });
  });
}
