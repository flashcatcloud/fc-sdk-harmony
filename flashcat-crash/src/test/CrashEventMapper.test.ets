import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { JsCrashPolicy } from '../main/ets/CrashConfiguration';
import { CrashEventMapper } from '../main/ets/internal/CrashEventMapper';
import { CrashIncidentRecord } from '../main/ets/internal/CrashIncident';

export default function crashEventMapperTests(): void {
  describe('CrashEventMapper', (): void => {
    it('mapsArkTsCrash', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const exception: Record<string, Object> = {
        'name': 'TypeError',
        'message': "Cannot read property 'x' of undefined",
        'stack': 'at foo (entry/src/main/ets/pages/Index.ets:42:13)'
      };
      const params: Record<string, Object> = {
        'crash_type': 'JsError',
        'exception': exception
      };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(params);
      expect(ev['type']).assertEqual('crash_report');
      expect(ev['target']).assertEqual('rum');
      expect(ev['is_crash']).assertEqual(true);
      expect(ev['crash_kind']).assertEqual('crash');
      expect(ev['source']).assertEqual('source');
      expect((ev['message'] as string).indexOf('TypeError')).assertLarger(-1);
      expect((ev['stack'] as string).indexOf('Index.ets:42')).assertLarger(-1);
    });

    it('mapsNativeCrashWithBinaryImages', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const exception: Record<string, Object> = {
        'signal': 11,
        'message': 'SIGSEGV',
        'stack': '#00 pc 00001234 /data/app/libdemo.so'
      };
      const images: Array<Record<string, Object>> = [
        { 'uuid': 'demo-build', 'name': 'libdemo.so', 'arch': 'arm64' }
      ];
      const params: Record<string, Object> = {
        'crash_type': 'NativeCrash',
        'exception': exception,
        'arch': 'arm64',
        'binary_images': images
      };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(params);
      expect(ev['crash_kind']).assertEqual('crash');
      expect(ev['arch']).assertEqual('arm64');
      expect(ev['build_id']).assertEqual('demo-build');
      expect((ev['stack'] as string).indexOf('libdemo.so')).assertLarger(-1);
      const mappedImages: Array<Record<string, Object>> = ev['binary_images'] as Array<Record<string, Object>>;
      expect(mappedImages.length).assertEqual(1);
      expect(mappedImages[0]['name']).assertEqual('libdemo.so');
      expect(mappedImages[0]['arch']).assertEqual('arm64');
    });

    // Real on-device hiAppEvent APP_CRASH shape for a NATIVE crash (captured from an
    // emulator 2026-06-23): exception has NO name/message/stack — the stack lives in
    // `exception.frames` (array of objects), arch is `cpu_abi`, and there is no
    // top-level `binary_images`. The mapper must serialize frames into the text stack
    // that fc-rum's stack.ParseHarmony understands, derive a message, and synthesize
    // binary_images from the native frames' build ids.
    it('mapsNativeFramesArrayToParseableStack', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const frames: Array<Record<string, Object>> = [
        {
          'buildId': '0df21d9613830e786e65dd55781b762c60e48e35',
          'file': '/data/storage/el1/bundle/libs/arm64/libentry.so',
          'offset': 0,
          'pc': '0000000000001e10',
          'symbol': ''
        },
        {
          'column': 14,
          'file': 'entry/src/main/ets/pages/Index.ets',
          'line': 96,
          'packageName': 'entry',
          'symbol': 'triggerNativeCrash'
        }
      ];
      const exception: Record<string, Object> = { 'frames': frames };
      const params: Record<string, Object> = {
        'crash_type': 'NativeCrash',
        'cpu_abi': 'arm64-v8a',
        'exception': exception
      };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(params);
      const stack: string = ev['stack'] as string;
      // Native frame rendered in bionic "#NN pc <addr> <lib>" form.
      expect(stack.indexOf('pc 0000000000001e10')).assertLarger(-1);
      expect(stack.indexOf('libentry.so')).assertLarger(-1);
      // ArkTS frame rendered in V8 "at func (file:line:col)" form.
      expect(stack.indexOf('at triggerNativeCrash (entry/src/main/ets/pages/Index.ets:96:14)')).assertLarger(-1);
      // arch is normalized to the token used by fc-rum native symbol storage.
      expect(ev['arch']).assertEqual('arm64');
      expect(ev['build_id']).assertEqual('0df21d9613830e786e65dd55781b762c60e48e35');
      // message is not the useless fallback.
      expect((ev['message'] as string).indexOf('Unknown crash')).assertEqual(-1);
      expect((ev['message'] as string).length > 0).assertTrue();
      // binary_images synthesized from native frames carries the build id + lib name.
      const images: Array<Record<string, Object>> = ev['binary_images'] as Array<Record<string, Object>>;
      expect(images.length).assertEqual(1);
      expect(images[0]['uuid']).assertEqual('0df21d9613830e786e65dd55781b762c60e48e35');
      expect(images[0]['name']).assertEqual('libentry.so');
      expect(images[0]['arch']).assertEqual('arm64');
    });

    it('dropsNativeImagesWithoutBuildId', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const frames: Array<Record<string, Object>> = [
        {
          'file': '/data/storage/el1/bundle/libs/arm64/libentry.so',
          'pc': '0000000000001e10'
        }
      ];
      const exception: Record<string, Object> = { 'frames': frames };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash({
        'crash_type': 'NativeCrash',
        'cpu_abi': 'arm64-v8a',
        'exception': exception
      });

      expect((ev['binary_images'] as Array<Record<string, Object>>).length).assertEqual(0);
      expect(ev['build_id']).assertEqual('');
    });

    it('mapsFreeze', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const exception: Record<string, Object> = { 'message': 'App freeze: THREAD_BLOCK_6S' };
      const params: Record<string, Object> = { 'exception': exception };
      const ev: Record<string, Object> = CrashEventMapper.fromAppFreeze(params);
      expect(ev['crash_kind']).assertEqual('freeze');
      expect(ev['is_crash']).assertEqual(true);
      expect((ev['message'] as string).indexOf('freeze')).assertLarger(-1);
    });

    it('mapsPendingIncidentAsCrash', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const incident: CrashIncidentRecord = new CrashIncidentRecord(
        'incident-1',
        123456,
        'TypeError',
        'boom',
        'TypeError: boom\n    at run (Index.ets:1:2)',
        'fp-1',
        JsCrashPolicy.REPORT_THEN_EXIT,
        '0.5.1',
        'session-1',
        'view-1',
        'Home');

      const ev: Record<string, Object> = CrashEventMapper.fromPendingIncident(incident);

      expect(ev['type']).assertEqual('crash_report');
      expect(ev['is_crash']).assertEqual(true);
      expect(ev['incident_id']).assertEqual('incident-1');
      expect(ev['fingerprint']).assertEqual('fp-1');
      expect(ev['timestamp_ms']).assertEqual(123456);
      expect(ev['original_session_id']).assertEqual('session-1');
      expect(ev['original_view_id']).assertEqual('view-1');
      expect(ev['crash.recovered']).assertUndefined();
    });

    it('marksRecoveredPendingIncident', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const incident: CrashIncidentRecord = new CrashIncidentRecord(
        'incident-recovered',
        123456,
        'TypeError',
        'boom',
        'TypeError: boom\n    at run (Index.ets:1:2)',
        'fp-recovered',
        JsCrashPolicy.REPORT_AND_RECOVER,
        '0.5.1',
        'session-1',
        'view-1',
        'Home');

      const ev: Record<string, Object> = CrashEventMapper.fromPendingIncident(incident);

      expect(ev['crash.recovered']).assertEqual(true);
    });

    it('truncatesOversizedStackAndMessage', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const longReason: string = 'x'.repeat(5000);
      const longStack: string = 'y'.repeat(80000);
      const exception: Record<string, Object> = { 'name': 'E', 'message': longReason, 'stack': longStack };
      const params: Record<string, Object> = { 'exception': exception };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(params);
      expect((ev['message'] as string).length <= 2100).assertTrue();
      expect((ev['stack'] as string).length <= 50100).assertTrue();
      expect((ev['stack'] as string).indexOf('truncated')).assertLarger(-1);
    });

    it('dropsOversizedBinaryImages', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const big: Array<Record<string, Object>> = [];
      for (let i = 0; i < 5000; i++) {
        big.push({ 'name': `lib_${i}_aaaaaaaaaaaaaaaaaaaaaaaaaaaa.so`, 'arch': 'arm64' });
      }
      const params: Record<string, Object> = { 'exception': {} as Record<string, Object>, 'binary_images': big };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(params);
      expect((ev['binary_images'] as Array<Record<string, Object>>).length).assertEqual(0);
    });

    it('toleratesMissingFields', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const empty: Record<string, Object> = {};
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(empty);
      expect(ev['type']).assertEqual('crash_report');
      expect(ev['message']).assertEqual('Unknown crash');
      expect(ev['stack']).assertEqual('');
      expect((ev['binary_images'] as Array<Record<string, Object>>).length).assertEqual(0);
      expect(ev['arch']).assertEqual('');
      expect(ev['build_id']).assertEqual('');
    });
  });
}
