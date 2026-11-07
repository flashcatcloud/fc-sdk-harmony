import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { ViewVitals } from '../main/ets/internal/vitals/ViewVitals';
import { ResourceSampler, ResourceReaders, SamplerTimer } from '../main/ets/internal/vitals/ResourceSampler';
import {
  parseUtimeTicks, parseVmRssKb, systemResourceReaders
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
      cpuTicks: (): number | null => {
        this.cpuReads++;
        if (this.cpuThrows) {
          throw new Error('13900012 permission denied');
        }
        return this.cpu;
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

/** A view whose sample handling fails. */
class ThrowingVitals extends ViewVitals {
  onMemorySample(_bytes: number): void {
    throw new Error('view failed');
  }

  onCpuSample(_ticks: number): void {
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
      vitals.onCpuSample(500);
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
      vitals.onCpuSample(1000);
      vitals.onCpuSample(1004);
      vitals.onCpuSample(1010);
      const fields: Record<string, Object> = vitals.toFields(2 * SECOND_NS);
      expect(fields['cpu_ticks_count']).assertEqual(10);
      expect(fields['cpu_ticks_per_second']).assertEqual(5);
    });

    it('cpuTicksPerSecondNeedsAFullSecond', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const vitals: ViewVitals = new ViewVitals();
      vitals.onCpuSample(0);
      vitals.onCpuSample(3);
      const short: Record<string, Object> = vitals.toFields(SECOND_NS - 1);
      expect(short['cpu_ticks_count']).assertEqual(3);
      expect(short['cpu_ticks_per_second']).assertUndefined();
      expect(vitals.toFields(SECOND_NS)['cpu_ticks_per_second']).assertEqual(3);
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
      expect(parseVmRssKb(STATUS_TEXT)).assertEqual(1000);
      expect(parseVmRssKb('VmHWM:\t 2000 kB\nVmSize:\t 3000 kB\n')).assertNull();
      expect(parseVmRssKb('not a status file')).assertNull();
    });

    it('utimeIsField14CountedAfterTheProcessName', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(parseUtimeTicks(STAT_LINE)).assertEqual(4242);
      expect(parseUtimeTicks('1234 (app) S 1 2 3')).assertNull();
      expect(parseUtimeTicks('not a stat line')).assertNull();
      expect(parseUtimeTicks('1 (a) S 1 1 0 0 -1 0 0 0 0 0 -5 0')).assertNull();
    });

    it('cpuTimeIsReadFromAProcFileWhoseSizeIsZero', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // As on the device: /proc/self/stat has content, and a size of 0.
      const pseudo: Map<string, string> = (fileIo as Object as Record<string, Object>)['pseudoFiles'] as Map<string, string>;
      pseudo.set('/proc/self/stat', STAT_LINE);
      try {
        expect(fileIo.readTextSync('/proc/self/stat')).assertEqual(''); // the trap the reader must avoid
        const read: (() => number | null) | null = systemResourceReaders().cpuTicks;
        expect(read === null ? null : read()).assertEqual(4242);
      } finally {
        pseudo.delete('/proc/self/stat');
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
