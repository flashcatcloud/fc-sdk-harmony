import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { CrashEventMapper } from '../main/ets/internal/CrashEventMapper';

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
        { 'name': 'libdemo.so', 'arch': 'arm64' }
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
      expect((ev['stack'] as string).indexOf('libdemo.so')).assertLarger(-1);
      expect((ev['binary_images'] as string).indexOf('libdemo.so')).assertLarger(-1);
    });

    it('mapsFreeze', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const exception: Record<string, Object> = { 'message': 'App freeze: THREAD_BLOCK_6S' };
      const params: Record<string, Object> = { 'exception': exception };
      const ev: Record<string, Object> = CrashEventMapper.fromAppFreeze(params);
      expect(ev['crash_kind']).assertEqual('freeze');
      expect(ev['is_crash']).assertEqual(true);
      expect((ev['message'] as string).indexOf('freeze')).assertLarger(-1);
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
      expect(ev['binary_images']).assertEqual(''); // dropped, not truncated (unparseable JSON)
    });

    it('toleratesMissingFields', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const empty: Record<string, Object> = {};
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(empty);
      expect(ev['type']).assertEqual('crash_report');
      expect(ev['message']).assertEqual('Unknown crash');
      expect(ev['stack']).assertEqual('');
      expect(ev['binary_images']).assertEqual('');
      expect(ev['arch']).assertEqual('');
    });
  });
}
