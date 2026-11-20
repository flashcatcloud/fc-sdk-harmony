import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { process } from '@kit.ArkTS';
import { systemDateTime } from '@kit.BasicServicesKit';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { CpuReading, ViewVitals } from '../main/ets/internal/vitals/ViewVitals';
import { ResourceSampler, ResourceReaders, SamplerTimer } from '../main/ets/internal/vitals/ResourceSampler';
import {
  parseAllowedCpus, parseStatField, parseVmRssKb, systemResourceReaders, UTIME_FIELD
} from '../main/ets/internal/vitals/SystemResourceReaders';
import {
  VitalsUpdateFrequency, vitalsPeriodMs, parseVitalsUpdateFrequency, DEFAULT_VITALS_UPDATE_FREQUENCY
} from '../main/ets/VitalsUpdateFrequency';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { RemoteConfigStore, RemoteConfigValues } from '../main/ets/internal/remoteconfig/RemoteConfigStore';
import { RemoteConfigController, ApplyOutcome } from '../main/ets/internal/remoteconfig/RemoteConfigController';
import { RemoteConfigFetcher, RemoteConfigResponse } from '../main/ets/internal/remoteconfig/RemoteConfigFetcher';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';

const SECOND_NS: number = 1e9;

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

export class CapturingScope implements FeatureScope {
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

  views(): Array<Record<string, Object>> {
    return this.written
      .filter((e: Record<string, Object>) => e['type'] === 'view')
      .map((e: Record<string, Object>) => e['view'] as Record<string, Object>);
  }
}

export class FakeCore implements SdkCore {
  readonly name: string = 'test';
  readonly settings: Map<string, string> = new Map<string, string>();
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
  readSetting(key: string): string | null {
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

/** A clock the test advances by hand: `fire()` is one period elapsing. */
class FakeTimer implements SamplerTimer {
  private nextId: number = 1;
  readonly active: Map<number, () => void> = new Map<number, () => void>();
  readonly periods: number[] = [];

  every(periodMs: number, tick: () => void): number {
    const id: number = this.nextId++;
    this.active.set(id, tick);
    this.periods.push(periodMs);
    return id;
  }

  cancel(id: number): void {
    this.active.delete(id);
  }

  fire(): void {
    this.active.forEach((tick: () => void) => tick());
  }
}

/** Readers whose answers the test sets, counting how often each is asked. */
class FakeReaders {
  cpu: number = 100;
  memory: number = 50_000_000;
  cpuReads: number = 0;
  memoryReads: number = 0;
  cpuThrows: boolean = false;
  memoryAnswer: string = 'value'; // value | null | reject | hold
  private held: Array<(value: number | null) => void> = [];

  readers(): ResourceReaders {
    return {
      memoryBytes: (): Promise<number | null> => {
        this.memoryReads++;
        if (this.memoryAnswer === 'reject') {
          return Promise.reject(new Error('17800001'));
        }
        if (this.memoryAnswer === 'null') {
          return Promise.resolve(null);
        }
        if (this.memoryAnswer === 'hold') {
          return new Promise<number | null>((resolve: (value: number | null) => void) => {
            this.held.push(resolve);
          });
        }
        return Promise.resolve(this.memory);
      },
      cpu: (): CpuReading | null => {
        this.cpuReads++;
        if (this.cpuThrows) {
          throw new Error('13900012 permission denied');
        }
        return ticksAt(this.cpu);
      }
    };
  }

  releaseHeld(value: number): void {
    const pending: Array<(value: number | null) => void> = this.held;
    this.held = [];
    pending.forEach((resolve: (value: number | null) => void) => resolve(value));
  }
}

/** A core that cannot take the open view's context (the view fails to open). */
class RejectingContextCore extends FakeCore {
  updateFeatureContext(_featureName: string, update: Record<string, Object>): void {
    if (update['view.id'] !== undefined) {
      throw new Error('context rejected');
    }
  }
}

/** A view that records the sampler run of each CPU reading. */
class RunRecordingVitals extends ViewVitals {
  readonly runs: number[] = [];

  onCpuSample(cpu: CpuReading, run: number): void {
    this.runs.push(run);
    super.onCpuSample(cpu, run);
  }
}

/** A view whose sample handling fails. */
class ThrowingVitals extends ViewVitals {
  onMemorySample(_bytes: number): void {
    throw new Error('view failed');
  }

  onCpuSample(_cpu: CpuReading, _run: number): void {
    throw new Error('view failed');
  }
}

export function settle(): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, 0));
}

function sampler(readers: FakeReaders, timer: FakeTimer, periodMs: number = 500): ResourceSampler {
  return new ResourceSampler(readers.readers(), (): number => periodMs, timer);
}

export function raw(kind: string, timestampMs: number, key?: string): RumRawEvent {
  const e: RumRawEvent = { kind, attributes: {}, timestampMs };
  if (key !== undefined) {
    e.key = key;
    e.name = key;
  }
  return e;
}

/** utime=4242 (field 14); the process name carries spaces and a ")". */
const STATUS_TEXT: string =
  'Name:\tentry\nUmask:\t0022\nState:\tS (sleeping)\nVmPeak:\t 9000 kB\nVmSize:\t 8000 kB\n' +
  'VmHWM:\t 1200 kB\nVmRSS:\t    1000 kB\nRssAnon:\t 600 kB\nThreads:\t12\n';
const STAT_LINE: string =
  '1234 (com.example.app (x) y) S 1 1234 0 0 -1 4194560 1200 0 3 0 4242 77 0 0 20 0 30 0 5000 0 0';

/** A /proc text as the bytes the readers parse. */
function bytesOf(text: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(text.length);
  for (let i: number = 0; i < text.length; i++) {
    bytes[i] = text.charCodeAt(i);
  }
  return bytes;
}

function vmRssKb(text: string): number | null {
  return parseVmRssKb(bytesOf(text), text.length);
}

function utimeTicks(text: string): number | null {
  return parseStatField(bytesOf(text), text.length, UTIME_FIELD);
}

/** A reading at `ms` of `processTicks` ticks (all of them user time) and `main` main-thread ticks, on `cores` cores. */
function cpuAt(ms: number, processTicks: number, main: number, cores: number = 4): CpuReading {
  return {
    userTicks: processTicks, processCpuNs: processTicks * TICK_NS, mainThreadCpuNs: main < 0 ? -1 : main * TICK_NS,
    cores: cores, atNs: ms * 1_000_000
  };
}

/** A reading of `ticks` of user time alone, at no particular time: what the tick fields count. */
function ticksAt(ticks: number, atNs: number = 0): CpuReading {
  return { userTicks: ticks, processCpuNs: ticks * TICK_NS, mainThreadCpuNs: -1, cores: 0, atNs: atNs };
}

// A clock tick (USER_HZ 100) in nanoseconds: the tests count CPU time in ticks.
const TICK_NS: number = 10_000_000;

function procShim(): Record<string, Object> {
  return process as Object as Record<string, Object>;
}

/** Moves the readers' clock on by `ms`, past the throttle on the /proc reads by default. */
// Only ever moves forward, across tests too: the readers remember when they last read.
let clockMs: number = 1_000_000;

function advanceClock(ms: number = 1000): void {
  clockMs += ms;
  (systemDateTime as Object as Record<string, Object>)['elapsedMs'] = clockMs;
}

function resetClock(): void {
  (systemDateTime as Object as Record<string, Object>)['elapsedMs'] = null as Object;
}

class FakeFetcher implements RemoteConfigFetcher {
  fetch(_url: string, _ifNoneMatch: string | null): Promise<RemoteConfigResponse> {
    return Promise.reject(new Error('offline'));
  }
}

function remoteBody(rum: string): string {
  return `{"schema_version":1,"version":3,"ttl":600,"enabled":true,"activation":"next_session","rum":${rum}}`;
}

function newStore(core: FakeCore): RemoteConfigStore {
  return new RemoteConfigStore(core, RemoteConfigStore.buildStoreKey(core.getContext(), 'https://intake.example.com', 'app-1'));
}

export default function viewVitalsTests(): void {
  describe('rum-view-vitals', (): void => {
    it('aViewWithoutSamplesCarriesNoVitalKey', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      expect(Object.keys(vitals.toFields(10 * SECOND_NS)).length).assertEqual(0);
      // One CPU reading is only a baseline: no ticks can be told from it.
      vitals.onCpuSample(ticksAt(500), 0);
      expect(Object.keys(vitals.toFields(10 * SECOND_NS)).length).assertEqual(0);
    });

    it('memoryIsTheMeanAndPeakOfTheViewsSamples', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onMemorySample(100);
      vitals.onMemorySample(300);
      vitals.onMemorySample(200);
      const fields: Record<string, Object> = vitals.toFields(0);
      expect(fields['memory_average']).assertEqual(200);
      expect(fields['memory_max']).assertEqual(300);
    });

    it('cpuTicksCountFromTheViewsFirstReading', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(ticksAt(1000), 0);
      vitals.onCpuSample(ticksAt(1004), 0);
      vitals.onCpuSample(ticksAt(1010), 0);
      const fields: Record<string, Object> = vitals.toFields(2 * SECOND_NS);
      expect(fields['cpu_ticks_count']).assertEqual(10);
      expect(fields['cpu_ticks_per_second']).assertEqual(5);
    });

    it('cpuTicksPerSecondNeedsAFullSecond', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(ticksAt(0), 0);
      vitals.onCpuSample(ticksAt(3), 0);
      const short: Record<string, Object> = vitals.toFields(SECOND_NS - 1);
      expect(short['cpu_ticks_count']).assertEqual(3);
      expect(short['cpu_ticks_per_second']).assertUndefined();
      expect(vitals.toFields(SECOND_NS)['cpu_ticks_per_second']).assertEqual(3);
    });

    it('cpuUsageIsTheProcessShareOfAllCoresAndTheMainThreadsOfOne', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // 4 cores, 1 s: 200 ticks of process time (2 s of CPU) is half of 4 cores; 50 ticks
      // of main-thread time is half of one. The first half-second is the busy one.
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(cpuAt(0, 0, 0), 1);
      vitals.onCpuSample(cpuAt(500, 160, 45), 1);
      vitals.onCpuSample(cpuAt(1000, 200, 50), 1);
      const fields: Record<string, Object> = vitals.toFields(SECOND_NS);
      expect(fields['cpu_usage_average']).assertEqual(50);
      expect(fields['cpu_usage_max']).assertEqual(80);
      expect(fields['main_thread_cpu_usage_average']).assertEqual(50);
      expect(fields['main_thread_cpu_usage_max']).assertEqual(90);
      // The tick fields keep counting user time alone, as before.
      expect(fields['cpu_ticks_count']).assertEqual(200);
    });

    it('cpuUsageNeedsAlmostASecondOfForegroundTime', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(cpuAt(0, 0, 0), 1);
      vitals.onCpuSample(cpuAt(850, 40, 10), 1);
      const short: Record<string, Object> = vitals.toFields(SECOND_NS);
      expect(short['cpu_usage_average']).assertUndefined();
      expect(short['main_thread_cpu_usage_average']).assertUndefined();
      // Negative control: 0.9 s is enough.
      vitals.onCpuSample(cpuAt(900, 40, 10), 1);
      expect(vitals.toFields(SECOND_NS)['cpu_usage_average'] !== undefined).assertTrue();
      expect(vitals.toFields(SECOND_NS)['main_thread_cpu_usage_average'] !== undefined).assertTrue();
    });

    it('cpuUsageLeavesOutTheTimeBetweenTwoSamplerRuns', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // Run 1, a stay in the background (100 s, 5000 ticks the sampler never saw), run 2.
      const feed = (runs: number[]): Record<string, Object> => {
        const vitals: ViewVitals = new ViewVitals();
        vitals.onCpuSample(cpuAt(0, 0, 0), runs[0]);
        vitals.onCpuSample(cpuAt(500, 100, 25), runs[1]);
        vitals.onCpuSample(cpuAt(100_500, 5100, 1025), runs[2]);
        vitals.onCpuSample(cpuAt(101_000, 5200, 1050), runs[3]);
        return vitals.toFields(SECOND_NS);
      };
      const split: Record<string, Object> = feed([1, 1, 2, 2]);
      // 200 ticks over 1 s of foreground on 4 cores; 50 ticks over 1 s on the main thread.
      expect(split['cpu_usage_average']).assertEqual(50);
      expect(split['main_thread_cpu_usage_average']).assertEqual(50);
      expect(split['cpu_usage_max']).assertEqual(50);
      // Negative control: as one run, the background stay counts as if it were the view's.
      const joined: Record<string, Object> = feed([1, 1, 1, 1]);
      expect(joined['cpu_usage_average'] === 50).assertFalse();
    });

    it('aPeakIsTakenOverAQuarterSecondAtLeast', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // One tick of main-thread time in a 0.1 s gap would read 100 %: readings 0.1 s apart
      // are merged until the interval reaches 0.25 s.
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(cpuAt(0, 0, 0, 1), 1);
      vitals.onCpuSample(cpuAt(100, 10, 10, 1), 1);
      for (let ms: number = 200; ms <= 1000; ms += 100) {
        vitals.onCpuSample(cpuAt(ms, 10, 10, 1), 1);
      }
      const fields: Record<string, Object> = vitals.toFields(SECOND_NS);
      // 10 ticks (0.1 s) over the first 0.3 s.
      expect(Math.round((fields['main_thread_cpu_usage_max'] as number) * 1000) / 1000).assertEqual(33.333);
      expect(Math.round((fields['cpu_usage_max'] as number) * 1000) / 1000).assertEqual(33.333);
      expect(fields['main_thread_cpu_usage_average']).assertEqual(10);
    });

    it('anUnknownCoreCountOrMainThreadLeavesOnlyItsOwnFieldsOut', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const noCores: ViewVitals = new ViewVitals();
      noCores.onCpuSample(cpuAt(0, 0, 0, 0), 1);
      noCores.onCpuSample(cpuAt(1000, 100, 50, 0), 1);
      const a: Record<string, Object> = noCores.toFields(SECOND_NS);
      expect(a['cpu_usage_average']).assertUndefined();
      expect(a['cpu_usage_max']).assertUndefined();
      expect(a['main_thread_cpu_usage_average']).assertEqual(50);
      const noMain: ViewVitals = new ViewVitals();
      noMain.onCpuSample(cpuAt(0, 0, -1), 1);
      noMain.onCpuSample(cpuAt(1000, 100, -1), 1);
      const b: Record<string, Object> = noMain.toFields(SECOND_NS);
      expect(b['main_thread_cpu_usage_average']).assertUndefined();
      expect(b['main_thread_cpu_usage_max']).assertUndefined();
      expect(b['cpu_usage_average']).assertEqual(25);
    });

    it('theMainThreadAndUserTimeReadOnEveryOtherReadingStillAddUp', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // As the readers take them: process time every 0.5 s, the /proc values every second.
      const at = (ms: number, processTicks: number, main: number, user: number): CpuReading => ({
        userTicks: user, processCpuNs: processTicks * TICK_NS, mainThreadCpuNs: main < 0 ? -1 : main * TICK_NS,
        cores: 4, atNs: ms * 1_000_000
      });
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(at(0, 0, 0, 0), 1);
      vitals.onCpuSample(at(500, 120, -1, -1), 1);
      vitals.onCpuSample(at(1000, 160, 90, 150), 1);
      vitals.onCpuSample(at(1500, 180, -1, -1), 1);
      vitals.onCpuSample(at(2000, 200, 100, 190), 1);
      const fields: Record<string, Object> = vitals.toFields(2 * SECOND_NS);
      // 100 main-thread ticks over 2 s; the first second's 90 is its peak.
      expect(fields['main_thread_cpu_usage_average']).assertEqual(50);
      expect(fields['main_thread_cpu_usage_max']).assertEqual(90);
      // The process keeps its half-second peaks: 120 ticks in the first 0.5 s of 4 cores.
      expect(fields['cpu_usage_average']).assertEqual(25);
      expect(fields['cpu_usage_max']).assertEqual(60);
      // User time from the readings that have it.
      expect(fields['cpu_ticks_count']).assertEqual(190);
      // Negative control: one main-thread reading is no usage.
      const once: ViewVitals = new ViewVitals();
      once.onCpuSample(at(0, 0, 0, 0), 1);
      once.onCpuSample(at(500, 50, -1, -1), 1);
      once.onCpuSample(at(1000, 100, -1, -1), 1);
      expect(once.toFields(SECOND_NS)['main_thread_cpu_usage_average']).assertUndefined();
      expect(once.toFields(SECOND_NS)['cpu_usage_average']).assertEqual(25);
    });

    it('aReadingAtTheSameInstantLosesNoTicks', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // Two views' timers can land on one clock reading: what the second adds is counted with the next.
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(cpuAt(0, 0, 0), 1);
      vitals.onCpuSample(cpuAt(500, 100, 25), 1);
      vitals.onCpuSample(cpuAt(500, 120, 30), 1);
      vitals.onCpuSample(cpuAt(1000, 200, 50), 1);
      expect(vitals.toFields(SECOND_NS)['cpu_usage_average']).assertEqual(50);
      expect(vitals.toFields(SECOND_NS)['main_thread_cpu_usage_average']).assertEqual(50);
    });

    it('cpuUsageNeverReadsAboveAHundred', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // Tick accounting can run slightly ahead of the clock: a full core reads 100, not more.
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(cpuAt(0, 0, 0, 1), 1);
      vitals.onCpuSample(cpuAt(1000, 103, 103, 1), 1);
      const fields: Record<string, Object> = vitals.toFields(SECOND_NS);
      expect(fields['cpu_usage_average']).assertEqual(100);
      expect(fields['main_thread_cpu_usage_max']).assertEqual(100);
    });

    it('frequenciesMeanTheAndroidPeriods', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(vitalsPeriodMs(VitalsUpdateFrequency.FREQUENT)).assertEqual(100);
      expect(vitalsPeriodMs(VitalsUpdateFrequency.AVERAGE)).assertEqual(500);
      expect(vitalsPeriodMs(VitalsUpdateFrequency.RARE)).assertEqual(1000);
      expect(vitalsPeriodMs(VitalsUpdateFrequency.NEVER)).assertEqual(0);
      expect(DEFAULT_VITALS_UPDATE_FREQUENCY).assertEqual(VitalsUpdateFrequency.AVERAGE);
      expect(new RumConfigurationBuilder('app').build().vitalsUpdateFrequency)
        .assertEqual(DEFAULT_VITALS_UPDATE_FREQUENCY);
      expect(parseVitalsUpdateFrequency('rare')).assertEqual(VitalsUpdateFrequency.RARE);
      expect(parseVitalsUpdateFrequency('Rare')).assertNull();
      expect(parseVitalsUpdateFrequency(1000)).assertNull();
      expect(parseVitalsUpdateFrequency(undefined)).assertNull();
    });

    it('vmRssIsReadInKilobytesFromTheStatusText', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(vmRssKb(STATUS_TEXT)).assertEqual(1000);
      expect(vmRssKb('VmHWM:\t 2000 kB\nVmSize:\t 3000 kB\n')).assertNull();
      expect(vmRssKb('not a status file')).assertNull();
      // Only the bytes read count, not what is left in the buffer past them.
      expect(parseVmRssKb(bytesOf(STATUS_TEXT), STATUS_TEXT.indexOf('VmRSS'))).assertNull();
      expect(vmRssKb('VmRSS:\t 1000 kB')).assertEqual(1000);
      expect(vmRssKb('VmRSS:\t 1000 MB\n')).assertNull();
      expect(vmRssKb('XVmRSS:\t 1000 kB\n')).assertNull();
    });

    it('utimeIsField14CountedAfterTheProcessName', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(utimeTicks(STAT_LINE)).assertEqual(4242);
      expect(utimeTicks('1234 (app) S 1 2 3')).assertNull();
      expect(utimeTicks('not a stat line')).assertNull();
      expect(utimeTicks('1 (a) S 1 1 0 0 -1 0 0 0 0 0 -5 0')).assertNull();
      expect(utimeTicks('1 (a) S 1 1 0 0 -1 0 0 0 0 0 4242')).assertEqual(4242);
    });

    it('cpuTimeIsReadFromAProcFileWhoseSizeIsZero', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // As on the device: /proc/self/stat has content, and a size of 0.
      const pseudo: Map<string, string> = (fileIo as Object as Record<string, Object>)['pseudoFiles'] as Map<string, string>;
      pseudo.set('/proc/self/stat', STAT_LINE);
      try {
        expect(fileIo.readTextSync('/proc/self/stat')).assertEqual(''); // the trap the reader must avoid
        const read: (() => CpuReading | null) | null = systemResourceReaders().cpu;
        advanceClock();
        expect(read === null ? null : read()?.userTicks).assertEqual(4242);
      } finally {
        pseudo.delete('/proc/self/stat');
        resetClock();
      }
    });

    it('statTimesAreField14And15', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(parseStatField(bytesOf(STAT_LINE), STAT_LINE.length, 15)).assertEqual(77);
      // Negative control: a line that stops at utime has no stime.
      const short: string = '1 (a) S 1 1 0 0 -1 0 0 0 0 0 4242';
      expect(parseStatField(bytesOf(short), short.length, 15)).assertNull();
    });

    it('theAllowedCpusAreCountedFromTheStatusText', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const cpus = (list: string): number | null => {
        const text: string = `Name:\tentry\nCpus_allowed:\t1ff\nCpus_allowed_list:\t${list}\nVmRSS:\t 1 kB\n`;
        return parseAllowedCpus(bytesOf(text), text.length);
      };
      expect(cpus('0,1,2,3,4,5,6,7,8')).assertEqual(9);
      expect(cpus('0-8')).assertEqual(9);
      expect(cpus('0-3,6,8-9')).assertEqual(7);
      // Negative controls: no such line, an inverted range, or junk.
      expect(parseAllowedCpus(bytesOf(STATUS_TEXT), STATUS_TEXT.length)).assertNull();
      expect(cpus('3-1')).assertNull();
      expect(cpus('x')).assertNull();
    });

    it('aReadingHasTheProcessesAndTheMainThreadsTimes', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const pseudo: Map<string, string> = (fileIo as Object as Record<string, Object>)['pseudoFiles'] as Map<string, string>;
      const mainPath: string = `/proc/self/task/${process.pid}/stat`;
      try {
        pseudo.set('/proc/self/stat', `${STAT_LINE}\n`);
        pseudo.set(mainPath, `${STAT_LINE.replace(' 4242 77 ', ' 300 20 ')}\n`);
        pseudo.set('/proc/self/status', `${STATUS_TEXT}Cpus_allowed_list:\t0-8\n`);
        const read: (() => CpuReading | null) | null = systemResourceReaders().cpu;
        procShim()['pastCpuMs'] = 1234;
        advanceClock();
        const cpu: CpuReading | null = read === null ? null : read();
        expect(cpu?.userTicks).assertEqual(4242);
        expect(cpu?.processCpuNs).assertEqual(1234 * 1_000_000);
        expect(cpu?.mainThreadCpuNs).assertEqual(320 * TICK_NS);
        expect((cpu?.atNs ?? 0) > 0).assertTrue();
        // Negative control: an unreadable main thread leaves only its own value out.
        pseudo.set(mainPath, 'not a stat line\n');
        advanceClock();
        const without: CpuReading | null = read === null ? null : read();
        expect(without?.processCpuNs).assertEqual(1234 * 1_000_000);
        expect(without?.mainThreadCpuNs).assertEqual(-1);
      } finally {
        pseudo.delete('/proc/self/stat');
        resetClock();
        pseudo.delete(mainPath);
        pseudo.delete('/proc/self/status');
      }
    });

    it('theProcFilesAreReadAboutOnceASecond', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // Each costs about half a millisecond when the sampler wakes for it; the runtime's
      // process time costs tens of microseconds and is read every time.
      const io: Record<string, Object> = fileIo as Object as Record<string, Object>;
      const pseudo: Map<string, string> = io['pseudoFiles'] as Map<string, string>;
      const calls: Record<string, number> = io['calls'] as Record<string, number>;
      const mainPath: string = `/proc/self/task/${process.pid}/stat`;
      try {
        pseudo.set('/proc/self/stat', `${STAT_LINE}\n`);
        pseudo.set(mainPath, `${STAT_LINE}\n`);
        const read: (() => CpuReading | null) | null = systemResourceReaders().cpu;
        advanceClock();
        procShim()['pastCpuMs'] = 100;
        expect(read === null ? null : read()?.userTicks).assertEqual(4242);
        const reads: number = calls['readSync'];
        advanceClock(500);
        procShim()['pastCpuMs'] = 150;
        const half: CpuReading | null = read === null ? null : read();
        expect(half?.processCpuNs).assertEqual(150 * 1_000_000);
        expect(half?.userTicks).assertEqual(-1);
        expect(half?.mainThreadCpuNs).assertEqual(-1);
        expect(calls['readSync']).assertEqual(reads);
        // Negative control: a second on, both files are read again.
        advanceClock(500);
        const full: CpuReading | null = read === null ? null : read();
        expect(full?.userTicks).assertEqual(4242);
        expect((full?.mainThreadCpuNs ?? -1) >= 0).assertTrue();
        expect(calls['readSync'] - reads).assertEqual(2);
      } finally {
        pseudo.delete('/proc/self/stat');
        pseudo.delete(mainPath);
        resetClock();
      }
    });

    it('anUnreadableProcessTimeIsNoReading', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const read: (() => CpuReading | null) | null = systemResourceReaders().cpu;
      try {
        procShim()['pastCpuMs'] = Number.NaN;
        expect(read === null ? null : read()).assertNull();
        procShim()['pastCpuMs'] = -1;
        expect(read === null ? null : read()).assertNull();
        // Negative control: a real value is a reading.
        procShim()['pastCpuMs'] = 5;
        expect(read === null ? null : read()?.processCpuNs).assertEqual(5 * 1_000_000);
      } finally {
        procShim()['pastCpuMs'] = 0;
      }
    });

    it('aShortReadAfterALongOneSeesOnlyItsOwnBytes', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // The readers reuse one buffer: what a longer earlier read left in it is not part of the next file.
      const pseudo: Map<string, string> = (fileIo as Object as Record<string, Object>)['pseudoFiles'] as Map<string, string>;
      try {
        const read: (() => CpuReading | null) | null = systemResourceReaders().cpu;
        pseudo.set('/proc/self/stat', STAT_LINE);
        advanceClock();
        expect(read === null ? null : read()?.userTicks).assertEqual(4242);
        pseudo.set('/proc/self/stat', '1234 (app) S 1 2 3');
        advanceClock();
        // The process's time comes from the runtime: an unreadable stat costs the tick fields alone.
        expect(read === null ? null : read()?.userTicks).assertEqual(-1);
      } finally {
        pseudo.delete('/proc/self/stat');
        resetClock();
      }
    });

    it('aProcFileIsOpenedOnceAndEachReadSeesItsCurrentText', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // procfs builds the text afresh on a read from offset 0: a kept descriptor reads current values.
      const io: Record<string, Object> = fileIo as Object as Record<string, Object>;
      const pseudo: Map<string, string> = io['pseudoFiles'] as Map<string, string>;
      const calls: Record<string, number> = io['calls'] as Record<string, number>;
      try {
        const read: (() => CpuReading | null) | null = systemResourceReaders().cpu;
        pseudo.set('/proc/self/stat', `${STAT_LINE}\n`);
        advanceClock();
        expect(read === null ? null : read()?.userTicks).assertEqual(4242);
        const opens: number = calls['openSync'];
        const reads: number = calls['readSync'];
        pseudo.set('/proc/self/stat', `${STAT_LINE.replace(' 4242 ', ' 5000 ')}\n`);
        advanceClock();
        expect(read === null ? null : read()?.userTicks).assertEqual(5000);
        expect(calls['openSync']).assertEqual(opens);
        // A whole line in the first read is the whole file: no read on to the empty one at the end.
        // One read each for the process's stat and the main thread's.
        expect(calls['readSync'] - reads).assertEqual(2);
      } finally {
        pseudo.delete('/proc/self/stat');
        resetClock();
      }
    });

    it('aShortReadThatEndsALineIsReadOnUntilTheValueIsThere', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // 24 bytes at a time: the first read ends on a whole line ("Umask"), and VmRSS is not there yet.
      const io: Record<string, Object> = fileIo as Object as Record<string, Object>;
      const pseudo: Map<string, string> = io['pseudoFiles'] as Map<string, string>;
      const limit: Record<string, number> = io['pseudoRead'] as Record<string, number>;
      pseudo.set('/proc/self/status', STATUS_TEXT);
      limit['limit'] = 24;
      try {
        const read: (() => Promise<number | null>) | null = systemResourceReaders().memoryBytes;
        expect(read === null ? null : await read()).assertEqual(1_000_000);
      } finally {
        limit['limit'] = 0;
        pseudo.delete('/proc/self/status');
      }
    });

    it('memoryIsReadFromAProcFileWhoseSizeIsZeroWithoutHidebug', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // As on the device: /proc/self/status has content, and a size of 0.
      const pseudo: Map<string, string> = (fileIo as Object as Record<string, Object>)['pseudoFiles'] as Map<string, string>;
      const debug: Record<string, Object> = hidebug as Object as Record<string, Object>;
      const calls: Record<string, number> = debug['calls'] as Record<string, number>;
      const before: number = calls['getRssInfo'] + calls['getAppNativeMemInfo'] + calls['getAppNativeMemInfoAsync'];
      pseudo.set('/proc/self/status', STATUS_TEXT);
      try {
        const read: (() => Promise<number | null>) | null = systemResourceReaders().memoryBytes;
        // 1000 kB from the kernel, Android's ×1000.
        expect(read === null ? null : await read()).assertEqual(1_000_000);
        // hidebug is not called: an isolated call costs milliseconds of CPU on a phone.
        expect(calls['getRssInfo'] + calls['getAppNativeMemInfo'] + calls['getAppNativeMemInfoAsync']).assertEqual(before);
      } finally {
        pseudo.delete('/proc/self/status');
      }
    });

    it('memoryIsFoundPastTheFirstChunkAndAcrossShortReads', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // A status file whose VmRSS comes after a Groups line longer than a chunk,
      // read by a kernel that returns 100 bytes at a time.
      const pseudo: Map<string, string> = (fileIo as Object as Record<string, Object>)['pseudoFiles'] as Map<string, string>;
      const limit: Record<string, number> = (fileIo as Object as Record<string, Object>)['pseudoRead'] as Record<string, number>;
      const groups: string[] = [];
      for (let g: number = 0; g < 1200; g++) {
        groups.push(`${20000 + g}`);
      }
      pseudo.set('/proc/self/status', `Name:\tentry\nGroups:\t${groups.join(' ')}\n` + STATUS_TEXT);
      limit['limit'] = 100;
      try {
        const read: (() => Promise<number | null>) | null = systemResourceReaders().memoryBytes;
        expect(read === null ? null : await read()).assertEqual(1_000_000);
      } finally {
        limit['limit'] = 0;
        pseudo.delete('/proc/self/status');
      }
    });

    it('aStayInTheBackgroundEndsTheSamplersRun', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // A view must know which readings have only foreground time between them.
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      const runs: RunRecordingVitals = new RunRecordingVitals();
      s.register(runs);
      s.setForeground(true);
      timer.fire();
      s.setForeground(false);
      s.setForeground(true);
      timer.fire();
      expect(runs.runs.length).assertEqual(4);
      // Negative control: readings of one stretch in the foreground share their run.
      expect(runs.runs[1]).assertEqual(runs.runs[0]);
      expect(runs.runs[2] === runs.runs[1]).assertFalse();
      expect(runs.runs[3]).assertEqual(runs.runs[2]);
    });

    it('nothingIsSampledInTheBackground', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      const vitals: ViewVitals = new ViewVitals();
      s.register(vitals);
      timer.fire();
      await settle();
      expect(s.isRunning()).assertFalse();
      expect(readers.cpuReads + readers.memoryReads).assertEqual(0);

      s.setForeground(true);
      expect(s.isRunning()).assertTrue();
      expect(timer.periods[0]).assertEqual(500);
      timer.fire();
      await settle();
      const readsInForeground: number = readers.cpuReads;
      expect(readsInForeground).assertEqual(2); // on start, then one period

      s.setForeground(false);
      timer.fire();
      await settle();
      expect(s.isRunning()).assertFalse();
      expect(readers.cpuReads).assertEqual(readsInForeground);
    });

    it('neverSamplesNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer, vitalsPeriodMs(VitalsUpdateFrequency.NEVER));
      s.register(new ViewVitals());
      s.setForeground(true);
      expect(s.isRunning()).assertFalse();
      expect(timer.active.size).assertEqual(0);
      expect(readers.cpuReads).assertEqual(0);
    });

    it('nothingIsReadWhileNoViewIsOpen', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      s.setForeground(true);
      timer.fire();
      timer.fire();
      expect(readers.cpuReads + readers.memoryReads).assertEqual(0);
      const vitals: ViewVitals = new ViewVitals();
      s.register(vitals);
      expect(readers.cpuReads).assertEqual(1); // a view opening reads at once
      s.unregister(vitals);
      timer.fire();
      expect(readers.cpuReads).assertEqual(1);
    });

    it('theTimerRunsOnlyWhileAViewIsOpen', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // An app with no open view (an unsampled session opens none) is never woken.
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      s.setForeground(true);
      expect(timer.active.size).assertEqual(0);
      const first: ViewVitals = new ViewVitals();
      const second: ViewVitals = new ViewVitals();
      s.register(first);
      expect(timer.active.size).assertEqual(1);
      s.register(second);
      expect(timer.active.size).assertEqual(1);
      s.unregister(first);
      expect(timer.active.size).assertEqual(1);
      s.unregister(second);
      expect(timer.active.size).assertEqual(0);
      expect(s.isRunning()).assertFalse();
      s.register(first);
      expect(timer.active.size).assertEqual(1);
    });

    it('aViewFailingToTakeASampleDisablesNoReader', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      readers.memory = 70;
      const s: ResourceSampler = sampler(readers, timer);
      s.setForeground(true);
      s.register(new ThrowingVitals()); // first, so it is handed every sample before the healthy one
      const healthy: ViewVitals = new ViewVitals();
      s.register(healthy);
      await settle();
      timer.fire();
      await settle();
      expect(readers.memoryReads).assertEqual(2);
      timer.fire();
      await settle();
      expect(readers.memoryReads).assertEqual(3); // still asked: the reader was never at fault
      expect(readers.cpuReads).assertEqual(3); // on start, then each period
      const fields: Record<string, Object> = healthy.toFields(SECOND_NS);
      expect(fields['memory_max']).assertEqual(70);
      expect(fields['cpu_ticks_count']).assertEqual(0);
    });

    it('anUnreadableCpuIsDroppedAndMemoryCarriesOn', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const readers: FakeReaders = new FakeReaders();
      readers.cpuThrows = true;
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      const vitals: ViewVitals = new ViewVitals();
      s.register(vitals);
      s.setForeground(true);
      await settle();
      timer.fire();
      await settle();
      expect(readers.cpuReads).assertEqual(1); // not asked again after failing
      const fields: Record<string, Object> = vitals.toFields(5 * SECOND_NS);
      expect(fields['cpu_ticks_count']).assertUndefined();
      expect(fields['memory_max']).assertEqual(50_000_000);
    });

    it('anUnreadableMemoryIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const answers: string[] = ['reject', 'null'];
      for (const answer of answers) {
        const readers: FakeReaders = new FakeReaders();
        readers.memoryAnswer = answer;
        const timer: FakeTimer = new FakeTimer();
        const s: ResourceSampler = sampler(readers, timer);
        const vitals: ViewVitals = new ViewVitals();
        s.register(vitals);
        s.setForeground(true);
        await settle();
        timer.fire();
        await settle();
        expect(readers.memoryReads).assertEqual(1);
        expect(vitals.toFields(0)['memory_average']).assertUndefined();
        expect(readers.cpuReads).assertEqual(2);
      }
    });

    it('aSlowMemoryReadIsNeverStackedUp', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const readers: FakeReaders = new FakeReaders();
      readers.memoryAnswer = 'hold';
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      const vitals: ViewVitals = new ViewVitals();
      s.register(vitals);
      s.setForeground(true);
      timer.fire();
      timer.fire();
      expect(readers.memoryReads).assertEqual(1);
      readers.releaseHeld(7);
      await settle();
      timer.fire();
      expect(readers.memoryReads).assertEqual(2);
      expect(vitals.toFields(0)['memory_max']).assertEqual(7);
    });

    it('aMemoryReadLandingAfterBackgroundIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const readers: FakeReaders = new FakeReaders();
      readers.memoryAnswer = 'hold';
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      const vitals: ViewVitals = new ViewVitals();
      s.register(vitals);
      s.setForeground(true);
      s.setForeground(false);
      readers.releaseHeld(9);
      await settle();
      expect(vitals.toFields(0)['memory_max']).assertUndefined();
    });

    it('aChangedFrequencyRestartsTheSampler', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      let period: number = 500;
      const s: ResourceSampler = new ResourceSampler(readers.readers(), (): number => period, timer);
      s.register(new ViewVitals());
      s.setForeground(true);
      period = 1000;
      s.refreshPeriod();
      expect(timer.periods.join(',')).assertEqual('500,1000');
      expect(timer.active.size).assertEqual(1);
      s.refreshPeriod(); // unchanged: nothing restarts
      expect(timer.periods.length).assertEqual(2);
      period = 0;
      s.refreshPeriod();
      expect(s.isRunning()).assertFalse();
    });

    it('aStoppedSamplerStaysStopped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      s.setForeground(true);
      s.stop();
      s.setForeground(true);
      s.register(new ViewVitals());
      expect(s.isRunning()).assertFalse();
      expect(readers.cpuReads).assertEqual(0);
    });

    it('everyViewDocumentCarriesWhatItsViewSampled', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      s.setForeground(true);
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(
        scope, new FakeCore(), 'app-1', 100, null, null, null, false, s);
      const t0: number = Date.now();
      readers.cpu = 100;
      readers.memory = 10;
      app.handleEvent(raw('startView', t0, 'home'));
      await settle();
      readers.cpu = 120;
      readers.memory = 30;
      timer.fire();
      await settle();
      app.handleEvent(raw('keepAlive', t0 + 1000));
      const kept: Record<string, Object> = scope.views()[scope.views().length - 1];
      expect(kept['is_active']).assertTrue();
      expect(kept['cpu_ticks_count']).assertEqual(20);
      expect(kept['cpu_ticks_per_second']).assertEqual(20);

      // The next view starts from its own baseline; the closed one keeps its numbers.
      readers.cpu = 150;
      readers.memory = 50;
      app.handleEvent(raw('startView', t0 + 2000, 'detail'));
      await settle();
      const views: Array<Record<string, Object>> = scope.views();
      const closedHome: Record<string, Object> = views.filter(
        (v: Record<string, Object>) => v['name'] === 'home' && v['is_active'] === false)[0];
      expect(closedHome['cpu_ticks_count']).assertEqual(20);
      expect(closedHome['memory_average']).assertEqual(20);
      expect(closedHome['memory_max']).assertEqual(30);
      readers.cpu = 155;
      timer.fire();
      await settle();
      app.handleEvent(raw('stopView', t0 + 3000, 'detail'));
      const finalDetail: Record<string, Object> = scope.views()[scope.views().length - 1];
      expect(finalDetail['name']).assertEqual('detail');
      expect(finalDetail['is_active']).assertFalse();
      expect(finalDetail['cpu_ticks_count']).assertEqual(5);
      expect(finalDetail['memory_max']).assertEqual(50);
      expect(finalDetail['cpu_ticks_per_second']).assertEqual(5);
    });

    it('aClosedViewTakesNoLaterSamples', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // Closed by stopView, and superseded by the next startView.
      const closings: boolean[] = [true, false];
      for (const explicitStop of closings) {
        const readers: FakeReaders = new FakeReaders();
        const timer: FakeTimer = new FakeTimer();
        const s: ResourceSampler = sampler(readers, timer);
        s.setForeground(true);
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(
          scope, new FakeCore(), 'app-1', 100, null, null, null, false, s);
        const t0: number = Date.now();
        readers.cpu = 100;
        app.handleEvent(raw('startView', t0, 'home'));
        const res: RumRawEvent = raw('startResource', t0 + 100, 'req-1');
        res.url = 'https://api.example.com/slow';
        res.method = 'GET';
        app.handleEvent(res);
        readers.cpu = 110;
        timer.fire();
        if (explicitStop) {
          app.handleEvent(raw('stopView', t0 + 1000, 'home'));
        }
        // Still sampling for the next view; the response lands after.
        app.handleEvent(raw('startView', t0 + 1100, 'detail'));
        readers.cpu = 500;
        timer.fire();
        await settle();
        const stop: RumRawEvent = raw('stopResource', t0 + 2000, 'req-1');
        stop.statusCode = 200;
        stop.sizeBytes = 10;
        stop.resourceKind = 'native';
        app.handleEvent(stop);
        const homeDocs: Array<Record<string, Object>> =
          scope.views().filter((v: Record<string, Object>) => v['name'] === 'home');
        const late: Record<string, Object> = homeDocs[homeDocs.length - 1];
        expect((late['resource'] as Record<string, Object>)['count']).assertEqual(1);
        expect(late['cpu_ticks_count']).assertEqual(10);
      }
    });

    it('aViewThatFailsToOpenIsNotSampled', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const cores: FakeCore[] = [new RejectingContextCore(), new FakeCore()];
      const running: boolean[] = [];
      for (const core of cores) {
        const readers: FakeReaders = new FakeReaders();
        const timer: FakeTimer = new FakeTimer();
        const s: ResourceSampler = sampler(readers, timer);
        s.setForeground(true);
        const app: RumApplicationScope = new RumApplicationScope(
          new CapturingScope(), core, 'app-1', 100, null, null, null, false, s);
        for (let i = 0; i < 3; i++) {
          try {
            app.handleEvent(raw('startView', Date.now(), `page-${i}`));
          } catch (_e) {
            // the monitor contains it; the scope tree lets it through
          }
        }
        running.push(s.isRunning());
      }
      // No view exists, so nothing is sampled for one.
      expect(running[0]).assertFalse();
      // Negative control: views that did open keep the sampler running.
      expect(running[1]).assertTrue();
    });

    it('aViewWithoutReadingsHasNoVitalFields', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const scope: CapturingScope = new CapturingScope();
      const timer: FakeTimer = new FakeTimer();
      const readers: FakeReaders = new FakeReaders();
      // Never in the foreground.
      const app: RumApplicationScope = new RumApplicationScope(
        scope, new FakeCore(), 'app-1', 100, null, null, null, false, sampler(readers, timer));
      app.handleEvent(raw('startView', Date.now(), 'home'));
      app.handleEvent(raw('stopView', Date.now() + 5000, 'home'));
      const keys: string[] = Object.keys(scope.views()[scope.views().length - 1]);
      expect(keys.filter((k: string) => k.startsWith('memory_') || k.startsWith('cpu_')).length).assertEqual(0);
    });

    it('anUnsampledSessionReadsNothing', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const readers: FakeReaders = new FakeReaders();
      const timer: FakeTimer = new FakeTimer();
      const s: ResourceSampler = sampler(readers, timer);
      s.setForeground(true);
      const scope: CapturingScope = new CapturingScope();
      const app: RumApplicationScope = new RumApplicationScope(
        scope, new FakeCore(), 'app-1', 0, null, null, null, false, s);
      app.handleEvent(raw('startView', Date.now(), 'home'));
      timer.fire();
      expect(readers.cpuReads + readers.memoryReads).assertEqual(0);
      expect(scope.written.length).assertEqual(0);
    });

    it('rumFollowsTheAppInAndOutOfTheForeground', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
      monitor.stopKeepAlive();
      const s: ResourceSampler = sampler(new FakeReaders(), new FakeTimer());
      s.register(new ViewVitals());
      feature.attachMonitor(monitor, s);
      expect(s.isRunning()).assertFalse(); // the core has not seen the foreground
      feature.onReceive({ 'type': 'app_foreground_detected' });
      expect(s.isRunning()).assertTrue();
      feature.onReceive({ 'type': 'app_background' });
      expect(s.isRunning()).assertFalse();
      feature.onReceive({ 'type': 'app_foreground' });
      expect(s.isRunning()).assertTrue();
      feature.onStop();
      expect(s.isRunning()).assertFalse();
      feature.onReceive({ 'type': 'app_foreground' });
      expect(s.isRunning()).assertFalse();
    });

    it('rumEnabledInTheForegroundSamplesAtOnce', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      core.foreground = true;
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, new CapturingScope(), configuration);
      monitor.stopKeepAlive();
      const s: ResourceSampler = sampler(new FakeReaders(), new FakeTimer());
      s.register(new ViewVitals());
      feature.attachMonitor(monitor, s);
      expect(s.isRunning()).assertTrue();
      feature.onStop();
    });

    it('anEntryWrittenBeforeTheFrequencyAsksForTheWholeBody', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // A format-2 entry validated a body this SDK has never read the
      // frequency from: its values stay, its validator does not.
      const core: FakeCore = new FakeCore();
      const store: RemoteConfigStore = newStore(core);
      store.write(new RemoteConfigValues(40, 3, null, '"v3"', 600, false, null, VitalsUpdateFrequency.RARE));
      expect((store.read() as RemoteConfigValues).etag).assertEqual('"v3"');
      const key: string = Array.from(core.settings.keys())[0];
      const record: Record<string, Object> = JSON.parse(core.settings.get(key) as string) as Record<string, Object>;
      record['format'] = 2;
      core.settings.set(key, JSON.stringify(record));
      const old: RemoteConfigValues = store.read() as RemoteConfigValues;
      expect(old.etag).assertNull();
      expect(old.sessionSampleRate).assertEqual(40);
    });

    it('theConsoleSetsTheFrequency', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const store: RemoteConfigStore = newStore(new FakeCore());
      const controller: RemoteConfigController =
        new RemoteConfigController(store, new FakeFetcher(), 'https://x/config', (): void => {});
      expect(controller.apply(remoteBody('{"sessionSampleRate":40,"vitalsUpdateFrequency":"rare"}'), null))
        .assertEqual(ApplyOutcome.APPLIED);
      let stored: RemoteConfigValues | null = store.read();
      expect((stored as RemoteConfigValues).vitalsUpdateFrequency).assertEqual(VitalsUpdateFrequency.RARE);
      expect((stored as RemoteConfigValues).sessionSampleRate).assertEqual(40);

      // A value outside the four names is no value: the init frequency applies,
      // and the rest of the body is still read.
      const invalid: string[] = ['"sometimes"', '1000', 'true', '"RARE"'];
      for (const value of invalid) {
        expect(controller.apply(remoteBody(`{"sessionSampleRate":30,"vitalsUpdateFrequency":${value}}`), null))
          .assertEqual(ApplyOutcome.APPLIED);
        stored = store.read();
        expect((stored as RemoteConfigValues).vitalsUpdateFrequency).assertNull();
        expect((stored as RemoteConfigValues).sessionSampleRate).assertEqual(30);
      }
    });
  });
}
