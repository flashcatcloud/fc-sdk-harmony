import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  EventWriter, Feature, FeatureEventReceiver, FeatureScope, FlashcatContext, IntakeTarget, SdkCore,
  TrackingConsent, UserInfo
} from '@flashcatcloud/core';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { process } from '@kit.ArkTS';
import { CrashConfiguration, CrashConfigurationBuilder } from '../main/ets/CrashConfiguration';
import { CrashEventMapper } from '../main/ets/internal/CrashEventMapper';
import { CrashFeature } from '../main/ets/internal/CrashFeature';
import {
  BUSY_JANK_EXTERNAL_LOG,
  busyJankParams,
  IDLE_HEAVIEST_JANK_EXTERNAL_LOG,
  idleHeaviestJankParams,
  traceOnlyJankParams
} from './MainThreadJankFixture';

/** Records what a feature scope is sent: crash_report events, or storage commands. */
class RecordingScope implements FeatureScope {
  readonly sent: Array<Record<string, Object>> = [];

  withWriteContext(_callback: (context: FlashcatContext, writer: EventWriter) => void): void {}

  sendEvent(event: Record<string, Object>): void {
    this.sent.push(event);
    event['success'] = true;
  }

  ofType(type: string): Array<Record<string, Object>> {
    return this.sent.filter((e: Record<string, Object>) => e['type'] === type);
  }
}

class FakeCore implements SdkCore {
  readonly name: string = 'test';
  readonly crashScope: RecordingScope = new RecordingScope();
  readonly rumScope: RecordingScope = new RecordingScope();

  registerFeature(_feature: Feature): void {}
  getFeature(featureName: string): FeatureScope | null {
    if (featureName === 'crash') {
      return this.crashScope;
    }
    return featureName === 'rum' ? this.rumScope : null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, _update: Record<string, Object>): void {}
  getContext(): FlashcatContext {
    return { featureContext: {}, sdkVersion: '0.7.5' } as Object as FlashcatContext;
  }
  getTrackingConsent(): TrackingConsent {
    return TrackingConsent.GRANTED;
  }
  isActive(): boolean {
    return true;
  }
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'token' };
  }
  readSetting(_key: string): string | null {
    return null;
  }
  writeSetting(_key: string, _value: string | null): void {}
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
}

/** The shim's record of registered watchers and sampling configs. */
interface WatcherShim {
  watchers: Array<hiAppEvent.Watcher>;
  eventConfigs: Array<Record<string, Object>>;
}

function shim(): WatcherShim {
  return hiAppEvent as Object as WatcherShim;
}

function setApiVersion(version: number): void {
  (deviceInfo as Object as Record<string, Object>)['sdkApiVersion'] = version;
}

let logSeq: number = 0;

/** Writes `text` where the system would put a jank's external log, and returns the path. */
function writeLog(text: string): string {
  const dir: string = `/tmp/flashcat-jank-test-${Date.now()}-${logSeq++}`;
  fileIo.mkdirSync(dir, true);
  const path: string = `${dir}/MAIN_THREAD_JANK_20261030074929_15856.txt`;
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
  fileIo.writeSync(file.fd, text);
  fileIo.closeSync(file);
  return path;
}

/** Starts a crash feature and returns the watcher it registered. */
function startFeature(core: FakeCore, configuration: CrashConfiguration): hiAppEvent.Watcher {
  return startedFeature(core, configuration).watcher;
}

class StartedFeature {
  readonly feature: CrashFeature;
  readonly watcher: hiAppEvent.Watcher;

  constructor(feature: CrashFeature, watcher: hiAppEvent.Watcher) {
    this.feature = feature;
    this.watcher = watcher;
  }
}

// Features a test started; each new start stops the previous ones, so watchers never pile up.
const running: Array<CrashFeature> = [];

function startedFeature(core: FakeCore, configuration: CrashConfiguration): StartedFeature {
  while (running.length > 0) {
    running.pop()!.onStop();
  }
  const feature: CrashFeature = new CrashFeature(core, configuration);
  running.push(feature);
  feature.onInitialize();
  const watchers: Array<hiAppEvent.Watcher> = shim().watchers;
  return new StartedFeature(feature, watchers[watchers.length - 1]);
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

/** Waits for the asynchronous log read to deliver `count` reports, or gives up after 2 s. */
async function reportsOf(core: FakeCore, count: number): Promise<Array<Record<string, Object>>> {
  for (let waited = 0; waited < 2000 && core.rumScope.ofType('crash_report').length < count; waited += 10) {
    await sleep(10);
  }
  return core.rumScope.ofType('crash_report');
}

function fileCalls(): Record<string, number> {
  return (fileIo as Object as Record<string, Object>)['calls'] as Record<string, number>;
}

/** The shim's count of synchronous file reads. */
function syncReads(): number {
  return fileCalls()['statSync'] + fileCalls()['readTextSync'];
}

function deliverJank(watcher: hiAppEvent.Watcher, params: Record<string, Object>): void {
  const info: Record<string, Object> = { 'domain': 'OS', 'name': 'MAIN_THREAD_JANK', 'params': params };
  const group: Record<string, Object> = { 'name': 'MAIN_THREAD_JANK', 'appEventInfos': [info] };
  const onReceive = watcher.onReceive as (domain: string, groups: Array<hiAppEvent.AppEventGroup>) => void;
  onReceive('OS', [group as Object as hiAppEvent.AppEventGroup]);
}

function stackLines(event: Record<string, Object>): string[] {
  return (event['stack'] as string).split('\n');
}

export default function mainThreadJankTests(): void {
  describe('MainThreadJankMapper', (): void => {
    it('mapsAJankFromItsSampledCallTree', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event: Record<string, Object> =
        CrashEventMapper.fromMainThreadJank(busyJankParams(), BUSY_JANK_EXTERNAL_LOG) as Record<string, Object>;

      expect(event['type']).assertEqual('crash_report');
      expect(event['crash_kind']).assertEqual('jank');
      expect(event['is_crash']).assertEqual(false);
      expect(event['message']).assertEqual('Main thread jank');
      expect(event['source_type']).assertEqual('harmony');
      expect(event['jank.duration_ms']).assertEqual(1001);
      expect(event['jank.sampled_at']).assertEqual(1793317690154);
      const lines: string[] = stackLines(event);
      // Leaf first, renumbered, in the native-frame shape the backend parses.
      expect(lines.length).assertEqual(33);
      expect(lines[0]).assertEqual('#0 pc 0000000000000668 [vdso] (__kernel_gettimeofday+40)');
      expect(lines[5]).assertEqual('#5 pc 0000007fae923751 [Unknown]');
      expect(lines[12]).assertEqual('#12 pc 0000000000012b2c /system/lib64/platformsdk/libuv.so');
      expect(lines[11]).assertEqual('#11 pc 0000000000008664 /system/lib64/platformsdk/libtimer.z.so ' +
        '(OHOS::JsSysModule::Timer::TimerCallback(uv_timer_s*)+500)');
      expect(lines[32]).assertEqual('#32 pc 000000000000be94 /system/bin/appspawn');
      // Build ids leave the frame lines for the binary images.
      expect((event['stack'] as string).indexOf('e5b4d4ce83e5538298052bc2aa19dda3')).assertEqual(-1);
      const images: Array<Record<string, Object>> = event['binary_images'] as Array<Record<string, Object>>;
      const libuv: Record<string, Object>[] = images.filter((i: Record<string, Object>) => i['name'] === 'libuv.so');
      expect(libuv.length).assertEqual(1);
      expect(libuv[0]['uuid']).assertEqual('1002b69fb34924db60f6297e5d8d9312');
      expect(libuv[0]['is_system']).assertEqual(true);
    });

    it('followsTheBusyBranchWhenTheHeaviestStackIsTheIdleLoop',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const fromTree: string = CrashEventMapper.fromMainThreadJank(
          idleHeaviestJankParams(), IDLE_HEAVIEST_JANK_EXTERNAL_LOG)!['stack'] as string;
        expect(fromTree.indexOf('TimerCallback') >= 0).assertTrue();
        expect(fromTree.indexOf('epoll_wait')).assertEqual(-1);
        // Negative control: the system's own pick, alone, is the idle loop.
        const fromHeaviest: string =
          CrashEventMapper.fromMainThreadJank(idleHeaviestJankParams(), '')!['stack'] as string;
        expect(fromHeaviest.indexOf('epoll_wait') >= 0).assertTrue();
        expect(fromHeaviest.indexOf('TimerCallback')).assertEqual(-1);
      });

    it('picksTheHeaviestBranchWhereverItIsListed', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const tree: string = [
        '4 #00 pc 000000000002c0fc /system/lib64/chipset-sdk-sp/libeventhandler.z.so(Run()+492)',
        '  1 #01 pc 000000000017a82c /system/lib/ld-musl-aarch64.so.1(epoll_wait+80)',
        '  3 #01 pc 0000000000008664 /system/lib64/platformsdk/libtimer.z.so(TimerCallback+500)',
        '    1 #02 pc 0000000000000664 [vdso](__kernel_gettimeofday+36)',
        '    2 #02 pc 0000000000e179f4 /system/lib64/module/arkcompiler/stub.an(RTStub_Dispatch+40)'
      ].join('\n');
      expect(CrashEventMapper.fromMainThreadJank({}, tree)!['stack']).assertEqual([
        '#0 pc 0000000000e179f4 /system/lib64/module/arkcompiler/stub.an (RTStub_Dispatch+40)',
        '#1 pc 0000000000008664 /system/lib64/platformsdk/libtimer.z.so (TimerCallback+500)',
        '#2 pc 000000000002c0fc /system/lib64/chipset-sdk-sp/libeventhandler.z.so (Run()+492)'
      ].join('\n'));
    });

    it('fallsBackToTheHeaviestStackWithoutALog', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event: Record<string, Object> =
        CrashEventMapper.fromMainThreadJank(busyJankParams(), '') as Record<string, Object>;
      const lines: string[] = stackLines(event);
      // Split on the literal "\n" the system writes; its two header lines are not frames.
      expect(lines.length).assertEqual(33);
      expect(lines[0]).assertEqual('#0 pc 0000000000000668 [vdso] (__kernel_gettimeofday+40)');
      expect((event['stack'] as string).indexOf('heaviest stack')).assertEqual(-1);
      expect((event['stack'] as string).indexOf('\\n')).assertEqual(-1);
    });

    it('dropsATraceOnlyJank', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(CrashEventMapper.fromMainThreadJank(traceOnlyJankParams(), '') === null).assertTrue();
      expect(CrashEventMapper.fromMainThreadJank({}, 'not a call tree') === null).assertTrue();
    });

    it('keepsAppNativeAndArkTsFrames', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const heaviest: string = [
        'heaviest stack: ', 'stack counts: 3',
        '#00 pc 0000000000001234 /data/storage/el1/bundle/libs/arm64/libentry.so' +
          '(Busy::spin(int)+12)(abcdef0123456789abcdef0123456789)',
        '#01 at spin (entry/src/main/ets/pages/Index.ets:12:5)',
        '#02 pc 00000000000160ec /system/lib64/platformsdk/libuv.so(uv_run+180)(1002b69fb34924db60f6297e5d8d9312)'
      ].join('\\n');
      const event: Record<string, Object> = CrashEventMapper.fromMainThreadJank(
        { 'heaviest_stack': heaviest }, '') as Record<string, Object>;
      expect(event['stack']).assertEqual([
        '#0 pc 0000000000001234 /data/storage/el1/bundle/libs/arm64/libentry.so (Busy::spin(int)+12)',
        'at spin (entry/src/main/ets/pages/Index.ets:12:5)',
        '#2 pc 00000000000160ec /system/lib64/platformsdk/libuv.so (uv_run+180)'
      ].join('\n'));
      // The app's own library names the build.
      expect(event['build_id']).assertEqual('abcdef0123456789abcdef0123456789');
      expect(event['jank.duration_ms'] === undefined).assertTrue();
      expect(event['jank.sampled_at'] === undefined).assertTrue();
    });

    it('capsTheStack', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const frames: string[] = [];
      for (let i = 0; i < 3000; i++) {
        frames.push(`#${i} pc 00000000000160ec /system/lib64/platformsdk/libuv.so(uv_run+180)`);
      }
      const stack: string = CrashEventMapper.fromMainThreadJank(
        { 'heaviest_stack': frames.join('\\n') }, '')!['stack'] as string;
      expect(stack.length <= 50000 + '…[truncated]'.length).assertTrue();
      expect(stack.endsWith('…[truncated]')).assertTrue();
    });
  });

  describe('MainThreadJankWatcher', (): void => {
    it('isTrackedByDefault', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(new CrashConfigurationBuilder().build().trackMainThreadJank).assertEqual(true);
      expect(new CrashConfigurationBuilder().setTrackMainThreadJank(false).build().trackMainThreadJank)
        .assertEqual(false);
    });

    it('subscribesAndConfiguresStackOnlySamplingFromApi15',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        setApiVersion(15);
        try {
          const before: number = shim().eventConfigs.length;
          const watcher: hiAppEvent.Watcher = startFeature(new FakeCore(), new CrashConfigurationBuilder().build());
          const names: string[] = watcher.appEventFilters![0].names!;
          expect(names.indexOf('MAIN_THREAD_JANK') >= 0).assertTrue();
          expect(names.indexOf('APP_FREEZE') >= 0).assertTrue();
          expect(shim().eventConfigs.length - before).assertEqual(1);
          const set: Record<string, Object> = shim().eventConfigs[shim().eventConfigs.length - 1];
          expect(set['name']).assertEqual('MAIN_THREAD_JANK');
          const config: Record<string, Object> = set['config'] as Record<string, Object>;
          // log_type 1 requires all five keys; sample_count stays at the system default.
          expect(JSON.stringify(config)).assertEqual(JSON.stringify({
            'log_type': '1', 'sample_interval': '150', 'ignore_startup_time': '10',
            'sample_count': '10', 'report_times_per_app': '3'
          }));
        } finally {
          setApiVersion(12);
        }
      });

    it('leavesTheSystemDefaultsBelowApi15', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      setApiVersion(14);
      try {
        const before: number = shim().eventConfigs.length;
        const watcher: hiAppEvent.Watcher = startFeature(new FakeCore(), new CrashConfigurationBuilder().build());
        expect(watcher.appEventFilters![0].names!.indexOf('MAIN_THREAD_JANK') >= 0).assertTrue();
        expect(shim().eventConfigs.length).assertEqual(before);
      } finally {
        setApiVersion(12);
      }
    });

    it('turnedOffNeitherSubscribesNorConfigures', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      setApiVersion(24);
      try {
        const before: number = shim().eventConfigs.length;
        const watcher: hiAppEvent.Watcher = startFeature(new FakeCore(),
          new CrashConfigurationBuilder().setTrackMainThreadJank(false).build());
        expect(watcher.appEventFilters![0].names!.indexOf('MAIN_THREAD_JANK')).assertEqual(-1);
        expect(shim().eventConfigs.length).assertEqual(before);
      } finally {
        setApiVersion(12);
      }
    });

    it('reportsAJankLiveAndNeverDeletesItsLog', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const watcher: hiAppEvent.Watcher = startFeature(core, new CrashConfigurationBuilder().build());
      const commandsBefore: number = core.crashScope.sent.length;
      const params: Record<string, Object> = idleHeaviestJankParams();
      params['pid'] = process.pid;
      const log: string = writeLog(IDLE_HEAVIEST_JANK_EXTERNAL_LOG);
      params['external_log'] = [log];

      deliverJank(watcher, params);

      const reports: Array<Record<string, Object>> = await reportsOf(core, 1);
      expect(reports.length).assertEqual(1);
      expect(reports[0]['crash_kind']).assertEqual('jank');
      // The stack came from the log, not from heaviest_stack (the idle loop).
      expect((reports[0]['stack'] as string).indexOf('TimerCallback') >= 0).assertTrue();
      // Reported live: no fault time to backdate to, no deduplication.
      expect(reports[0]['timestamp_ms'] === undefined).assertTrue();
      expect(reports[0]['dedup_fingerprint'] === undefined).assertTrue();
      // Other watchers in the same app may still need the file.
      expect(fileIo.accessSync(log)).assertEqual(true);
      expect(fileIo.readTextSync(log)).assertEqual(IDLE_HEAVIEST_JANK_EXTERNAL_LOG);
      // Nothing is persisted for a next launch.
      expect(core.crashScope.sent.length).assertEqual(commandsBefore);
    });

    it('dropsAJankOfAnotherProcess', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const watcher: hiAppEvent.Watcher = startFeature(core, new CrashConfigurationBuilder().build());
      const params: Record<string, Object> = busyJankParams();
      params['pid'] = process.pid + 1;
      const log: string = writeLog(BUSY_JANK_EXTERNAL_LOG);
      params['external_log'] = [log];

      deliverJank(watcher, params);

      await sleep(100);
      expect(core.rumScope.ofType('crash_report').length).assertEqual(0);
      // Negative control: the same jank of this process is reported.
      const own: Record<string, Object> = busyJankParams();
      own['pid'] = process.pid;
      deliverJank(watcher, own);
      expect((await reportsOf(core, 1)).length).assertEqual(1);
    });

    it('readsOnlyFilesNamedAsAJankStackLog', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const watcher: hiAppEvent.Watcher = startFeature(core, new CrashConfigurationBuilder().build());
      // A call tree whose heaviest path differs from heaviest_stack, under another name.
      const log: string = writeLog(IDLE_HEAVIEST_JANK_EXTERNAL_LOG);
      const other: string = log.replace(/MAIN_THREAD_JANK_[^/]*$/, 'notes.txt');
      fileIo.renameSync(log, other);
      const params: Record<string, Object> = idleHeaviestJankParams();
      params['pid'] = process.pid;
      params['external_log'] = [other];

      deliverJank(watcher, params);

      // Not read: the stack is the system's heaviest_stack.
      const reports: Array<Record<string, Object>> = await reportsOf(core, 1);
      expect(reports.length).assertEqual(1);
      expect(reports[0]['stack']).assertEqual(
        CrashEventMapper.fromMainThreadJank(idleHeaviestJankParams(), '')!['stack']);
    });

    it('leavesATraceLogAlone', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
      const core: FakeCore = new FakeCore();
      const watcher: hiAppEvent.Watcher = startFeature(core, new CrashConfigurationBuilder().build());
      // Text that would yield a stack if it were read as one.
      const trace: string = writeLog(BUSY_JANK_EXTERNAL_LOG).replace(/\.txt$/, '.trace');
      fileIo.renameSync(trace.replace(/\.trace$/, '.txt'), trace);
      const params: Record<string, Object> = traceOnlyJankParams();
      params['pid'] = process.pid;
      params['external_log'] = [trace];

      deliverJank(watcher, params);

      await sleep(100);
      expect(core.rumScope.ofType('crash_report').length).assertEqual(0);
      expect(fileIo.accessSync(trace)).assertEqual(true);
    });

    it('readsTheLogOffTheWatcherCallback', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const watcher: hiAppEvent.Watcher = startFeature(core, new CrashConfigurationBuilder().build());
        const params: Record<string, Object> = idleHeaviestJankParams();
        params['pid'] = process.pid;
        params['external_log'] = [writeLog(IDLE_HEAVIEST_JANK_EXTERNAL_LOG)];
        const before: number = syncReads();
        const asyncBefore: number = fileCalls()['readText'];

        deliverJank(watcher, params);

        // The callback returned without touching the file: no synchronous read, no report yet.
        expect(syncReads()).assertEqual(before);
        expect(core.rumScope.ofType('crash_report').length).assertEqual(0);
        const reports: Array<Record<string, Object>> = await reportsOf(core, 1);
        expect(reports.length).assertEqual(1);
        expect(fileCalls()['readText'] - asyncBefore).assertEqual(1);
        expect((reports[0]['stack'] as string).indexOf('TimerCallback') >= 0).assertTrue();
      });

    it('readsTheFirstUsableOfSeveralLogs', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const watcher: hiAppEvent.Watcher = startFeature(core, new CrashConfigurationBuilder().build());
        const missing: string = writeLog('').replace(/[^/]*$/, 'MAIN_THREAD_JANK_0_0.txt');
        // A valid tree over the size cap, naming a library no other log has.
        let huge: string = '9 #00 pc 0000000000000001 /system/lib64/liboversized.so';
        while (huge.length <= 512 * 1024) {
          huge += '\n  1 #01 pc 0000000000000002 /system/lib64/liboversized.so';
        }
        const oversized: string = writeLog(huge);
        const usable: string = writeLog(IDLE_HEAVIEST_JANK_EXTERNAL_LOG);
        const params: Record<string, Object> = idleHeaviestJankParams();
        params['pid'] = process.pid;
        params['external_log'] = [missing, oversized, usable];
        const readsBefore: number = fileCalls()['readText'];

        deliverJank(watcher, params);

        const reports: Array<Record<string, Object>> = await reportsOf(core, 1);
        expect(reports.length).assertEqual(1);
        // Missing and oversized logs are skipped without reading them; the usable one is the tree.
        expect(fileCalls()['readText'] - readsBefore).assertEqual(1);
        expect((reports[0]['stack'] as string).indexOf('TimerCallback') >= 0).assertTrue();
        expect((reports[0]['stack'] as string).indexOf('liboversized')).assertEqual(-1);
      });

    it('dropsAJankWhoseLogLandsAfterStop', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const started: StartedFeature = startedFeature(core, new CrashConfigurationBuilder().build());
        const params: Record<string, Object> = busyJankParams();
        params['pid'] = process.pid;
        params['external_log'] = [writeLog(BUSY_JANK_EXTERNAL_LOG)];

        deliverJank(started.watcher, params);
        started.feature.onStop();

        await sleep(100);
        expect(core.rumScope.ofType('crash_report').length).assertEqual(0);
      });
  });
}
