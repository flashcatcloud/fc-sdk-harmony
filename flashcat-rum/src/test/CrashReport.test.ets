import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { RumFeature } from '../main/ets/internal/RumFeature';

export default function crashReportTests(): void {
  describe('RumCrashReport', (): void => {
    it('extractsNativeSymbolicationAttributes', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event: Record<string, Object> = {
        'type': 'crash_report',
        'binary_images': '[{"name":"libdemo.so","arch":"arm64"}]',
        'arch': 'arm64',
        'crash_kind': 'crash'
      };
      const attrs: Record<string, Object> = RumFeature.crashAttributes(event);
      expect(attrs['_dd.crash.arch']).assertEqual('arm64');
      expect(attrs['_dd.crash.kind']).assertEqual('crash');
      expect((attrs['_dd.crash.binary_images'] as string).indexOf('libdemo.so')).assertLarger(-1);
    });

    it('omitsEmptyAttributesForArkTsCrash', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event: Record<string, Object> = {
        'type': 'crash_report',
        'binary_images': '',
        'arch': '',
        'crash_kind': 'freeze'
      };
      const attrs: Record<string, Object> = RumFeature.crashAttributes(event);
      expect(attrs['_dd.crash.binary_images']).assertUndefined();
      expect(attrs['_dd.crash.arch']).assertUndefined();
      expect(attrs['_dd.crash.kind']).assertEqual('freeze');
    });
  });
}
