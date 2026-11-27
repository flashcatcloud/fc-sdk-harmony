import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { batteryInfo, commonEventManager, power } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { ContextProvider } from '../main/ets/internal/context/ContextProvider';
import { DeviceInfo } from '../main/ets/api/context/FlashcatContext';

// The unit-test shims expose what the system reports as plain fields the test sets.
const battery: Record<string, Object> = batteryInfo as Object as Record<string, Object>;
const powerKit: Record<string, Object> = power as Object as Record<string, Object>;
const i18nKit: Record<string, Object> = i18n as Object as Record<string, Object>;
const events: Record<string, Object> = commonEventManager as Object as Record<string, Object>;

function deliver(event: string): void {
  (events['deliver'] as (e: string) => void)(event);
}

/** Restores the shims' defaults after each test's changes. */
function reset(): void {
  Object.defineProperty(battery, 'batterySOC', { value: 80, writable: true, configurable: true });
  powerKit['powerMode'] = 600;
  powerKit['getPowerMode'] = (): number => powerKit['powerMode'] as number;
  i18nKit['languages'] = ['zh-Hans-CN', 'en-US'];
  i18nKit['timeZoneId'] = 'Asia/Shanghai';
  (i18nKit['System'] as Record<string, Object>)['getPreferredLanguageList'] =
    (): string[] => (i18nKit['languages'] as string[]).slice();
}

function provider(nowMs: () => number = (): number => Date.now()): ContextProvider {
  const context: common.Context = { 'filesDir': '/tmp/flashcat-context-device' } as Object as common.Context;
  return new ContextProvider(context, new ConfigurationBuilder('token', 'prod').build(), false, nowMs);
}

function deviceOf(p: ContextProvider): DeviceInfo {
  return p.snapshot().device;
}

export default function contextDeviceTests(): void {
  describe('ContextDevice', (): void => {
    it('readsLanguagesTimeZoneBatteryAndPowerSaving',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        reset();
        const p: ContextProvider = provider();
        try {
          const device: DeviceInfo = deviceOf(p);
          expect(device.locale).assertEqual('zh-Hans-CN');
          expect((device.locales as string[]).join(',')).assertEqual('zh-Hans-CN,en-US');
          expect(device.timeZone).assertEqual('Asia/Shanghai');
          expect(device.batteryLevel).assertEqual(0.8);
          expect(device.powerSavingMode).assertFalse();
          // Read once at init, kept: the base fields are still there.
          expect(device.brand).assertEqual('TestBrand');
        } finally {
          p.stop();
        }
      });

    it('powerSavingIsTheThreeSavingModesOnly',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const modes: number[] = [600, 601, 602, 603, 650];
        const seen: string[] = [];
        for (const mode of modes) {
          reset();
          powerKit['powerMode'] = mode;
          const p: ContextProvider = provider();
          seen.push(`${mode}:${deviceOf(p).powerSavingMode}`);
          p.stop();
        }
        expect(seen.join(',')).assertEqual('600:false,601:true,602:false,603:true,650:true');
      });

    it('aChangeEventUpdatesTheNextEventsAndStopEndsTheSubscription',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        reset();
        const p: ContextProvider = provider();
        i18nKit['languages'] = ['en-GB'];
        i18nKit['timeZoneId'] = 'Europe/London';
        powerKit['powerMode'] = 601;
        // Negative control: nothing is re-read until the system says it changed.
        expect(deviceOf(p).locale).assertEqual('zh-Hans-CN');
        expect(deviceOf(p).timeZone).assertEqual('Asia/Shanghai');
        expect(deviceOf(p).powerSavingMode).assertFalse();

        deliver('usual.event.LOCALE_CHANGED');
        expect(deviceOf(p).locale).assertEqual('en-GB');
        expect(deviceOf(p).timeZone).assertEqual('Asia/Shanghai'); // only what the event is about
        deliver('usual.event.TIMEZONE_CHANGED');
        expect(deviceOf(p).timeZone).assertEqual('Europe/London');
        deliver('usual.event.POWER_SAVE_MODE_CHANGED');
        expect(deviceOf(p).powerSavingMode).assertTrue();

        p.stop();
        i18nKit['languages'] = ['fr-FR'];
        deliver('usual.event.LOCALE_CHANGED');
        expect(deviceOf(p).locale).assertEqual('en-GB');
      });

    it('snapshotsWithoutAChangeShareOneDeviceAndReadNothingAgain',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        reset();
        let batteryReads: number = 0;
        Object.defineProperty(battery, 'batterySOC', {
          get: (): number => {
            batteryReads++;
            return 80;
          }, configurable: true
        });
        let now: number = 1_000_000;
        const p: ContextProvider = provider((): number => now);
        try {
          const first: DeviceInfo = deviceOf(p);
          const readsAfterFirst: number = batteryReads;
          now += 30_000;
          const second: DeviceInfo = deviceOf(p);
          expect(second === first).assertTrue(); // built once, not per event
          expect(second.locales?.join(',')).assertEqual(first.locales?.join(','));
          expect(second.batteryLevel).assertEqual(0.8);
          expect(batteryReads).assertEqual(readsAfterFirst); // no provider was read again
          // Negative control: a locale change rebuilds, so the next snapshot differs.
          i18nKit['languages'] = ['en-GB'];
          deliver('usual.event.LOCALE_CHANGED');
          const third: DeviceInfo = deviceOf(p);
          expect(third === first).assertFalse();
          expect(third.locale).assertEqual('en-GB');
          expect((third.locales as string[]).join(',')).assertEqual('en-GB');
          // The battery poll also rebuilds, once the minute is up.
          now += 60_000;
          deviceOf(p);
          expect(batteryReads).assertEqual(readsAfterFirst + 1);
        } finally {
          p.stop();
          reset();
        }
      });

    it('theBatteryLevelIsReadAtMostOnceAMinute',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        reset();
        let now: number = 1_000_000;
        const p: ContextProvider = provider((): number => now);
        try {
          expect(deviceOf(p).batteryLevel).assertEqual(0.8);
          battery['batterySOC'] = 55;
          now += 59_000;
          expect(deviceOf(p).batteryLevel).assertEqual(0.8);
          now += 1_000;
          expect(deviceOf(p).batteryLevel).assertEqual(0.55);
        } finally {
          p.stop();
        }
      });

    it('aFailingSystemCallLeavesItsFieldOutAndNeverThrows',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        reset();
        Object.defineProperty(battery, 'batterySOC', {
          get: (): number => {
            throw new Error('battery service unavailable');
          }, configurable: true
        });
        powerKit['getPowerMode'] = (): number => {
          throw new Error('power service unavailable');
        };
        (i18nKit['System'] as Record<string, Object>)['getPreferredLanguageList'] = (): string[] => {
          throw new Error('i18n unavailable');
        };
        let threw: boolean = false;
        let device: DeviceInfo | null = null;
        let p: ContextProvider | null = null;
        try {
          p = provider();
          device = deviceOf(p);
          deliver('usual.event.LOCALE_CHANGED');
          deliver('usual.event.POWER_SAVE_MODE_CHANGED');
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
        const d: DeviceInfo = device as DeviceInfo;
        expect(d.locale).assertUndefined();
        expect(d.locales).assertUndefined();
        expect(d.batteryLevel).assertUndefined();
        expect(d.powerSavingMode).assertUndefined();
        expect(d.timeZone).assertEqual('Asia/Shanghai'); // the call that works still reports
        // An out-of-range reading is no reading.
        reset();
        battery['batterySOC'] = -1;
        const q: ContextProvider = provider();
        expect(deviceOf(q).batteryLevel).assertUndefined();
        q.stop();
        (p as ContextProvider).stop();
        reset();
      });
  });
}
