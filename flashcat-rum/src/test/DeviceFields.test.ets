import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { FlashcatContext } from '@flashcatcloud/core';
import { RumEventAssembler } from '../main/ets/internal/assembly/RumEventAssembler';
import { RumFeature } from '../main/ets/internal/RumFeature';

function context(withState: boolean): FlashcatContext {
  const c: FlashcatContext = {
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
    network: { status: 'connected', interfaces: ['wifi'] },
    featureContext: {}
  };
  if (withState) {
    c.device.locale = 'zh-Hans-CN';
    c.device.locales = ['zh-Hans-CN', 'en-US'];
    c.device.timeZone = 'Asia/Shanghai';
    c.device.batteryLevel = 0.42;
    c.device.powerSavingMode = true;
  }
  return c;
}

/** One event of each kind the assembler builds, with `c`. */
function eventsWith(c: FlashcatContext): Record<string, Record<string, Object>> {
  const out: Record<string, Record<string, Object>> = {};
  out['view'] = RumEventAssembler.view(c, 'app', 's', 'v', 'Home', 1, 0, 0, 0, 0, 0, 1, true, {});
  out['error'] = RumEventAssembler.error(c, 'app', 's', 'v', 'Home', 'boom', 'source', undefined, false,
    'handled', 1, {});
  out['app_launch'] = RumEventAssembler.appLaunch(c, 'app', 's', null, 'ttid', 'cold_start', 1, 1000, {});
  out['action'] = RumEventAssembler.action(c, 'app', 's', 'v', 'Home', 'a', 'tap', 'Buy', 1, 0, {});
  out['resource'] = RumEventAssembler.resource(c, 'app', 's', 'v', 'Home', 'r', 'https://a.example.com/x', 'GET',
    'native', 200, 10, 1, 1000, undefined, undefined, '', {}, {});
  return out;
}

function deviceOf(event: Record<string, Object>): Record<string, Object> {
  return event['device'] as Record<string, Object>;
}

export default function deviceFieldsTests(): void {
  describe('DeviceFields', (): void => {
    it('languagesAndTimeZoneGoOnEveryEvent',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const events: Record<string, Record<string, Object>> = eventsWith(context(true));
        for (const type of Object.keys(events)) {
          const device: Record<string, Object> = deviceOf(events[type]);
          expect(device['locale']).assertEqual('zh-Hans-CN');
          expect((device['locales'] as string[]).join(',')).assertEqual('zh-Hans-CN,en-US');
          expect(device['time_zone']).assertEqual('Asia/Shanghai');
        }
      });

    it('batteryAndPowerSavingGoOnViewsErrorsAndLaunchesOnly',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const events: Record<string, Record<string, Object>> = eventsWith(context(true));
        for (const type of ['view', 'error', 'app_launch']) {
          expect(deviceOf(events[type])['battery_level']).assertEqual(0.42);
          expect(deviceOf(events[type])['power_saving_mode']).assertTrue();
        }
        // Negative control: the same context leaves them off the other events.
        for (const type of ['action', 'resource']) {
          expect(deviceOf(events[type])['battery_level']).assertUndefined();
          expect(deviceOf(events[type])['power_saving_mode']).assertUndefined();
        }
      });

    it('aValueTheSystemDidNotGiveIsLeftOut',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const events: Record<string, Record<string, Object>> = eventsWith(context(false));
        for (const type of Object.keys(events)) {
          const keys: string[] = Object.keys(deviceOf(events[type]));
          for (const key of ['locale', 'locales', 'time_zone', 'battery_level', 'power_saving_mode']) {
            expect(keys.indexOf(key)).assertEqual(-1);
          }
        }
      });

    it('aReplayedCrashCarriesTheDeviceStateOfTheRunThatCrashed',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const crashedRun: Record<string, Object> = RumEventAssembler.view(
          context(true), 'app', 's', 'v', 'Home', 1, 0, 0, 0, 0, 0, 1, true, {});
        const now: FlashcatContext = context(true);
        now.device.batteryLevel = 0.9;
        now.device.timeZone = 'Europe/London';
        const replayed: Record<string, Object> = RumFeature.withCrashedRunContext(
          RumEventAssembler.error(now, 'app', 's', 'v', 'Home', 'boom', 'source', undefined, true, 'unhandled', 1, {}),
          crashedRun);
        expect(deviceOf(replayed)['battery_level']).assertEqual(0.42);
        expect(deviceOf(replayed)['time_zone']).assertEqual('Asia/Shanghai');
      });
  });
}
