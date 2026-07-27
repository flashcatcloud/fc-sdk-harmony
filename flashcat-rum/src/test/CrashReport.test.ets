import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { RumFeature } from '../main/ets/internal/RumFeature';

export default function crashReportTests(): void {
  describe('RumCrashReport', (): void => {
    it('extractsNativeSymbolicationAttributes', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const images: Array<Record<string, Object>> = [
        { 'uuid': 'abc123', 'name': 'libdemo.so', 'is_system': false, 'arch': 'arm64' }
      ];
      const event: Record<string, Object> = {
        'type': 'crash_report',
        'binary_images': images,
        'arch': 'arm64',
        'build_id': 'abc123',
        'source_type': 'harmony',
        'crash_kind': 'crash'
      };
      const attrs: Record<string, Object> = RumFeature.crashAttributes(event);
      expect(attrs['error.binary_images']).assertEqual(event['binary_images']);
      expect(attrs['error.source_type']).assertEqual('harmony');
      expect(attrs['build_id']).assertEqual('abc123');
      expect(attrs['error.meta.code_type']).assertEqual('arm64');
      expect(attrs['error.category']).assertEqual('Exception');
    });

    it('copiesRecoveredCrashMarker',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const event: Record<string, Object> = {
          'type': 'crash_report',
          'crash_kind': 'crash',
          'crash.recovered': true
        };

        const attrs: Record<string, Object> = RumFeature.crashAttributes(event);

        expect(attrs['crash.recovered']).assertEqual(true);
      });

    it('omitsEmptyAttributesForArkTsCrash', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event: Record<string, Object> = {
        'type': 'crash_report',
        'binary_images': '',
        'arch': '',
        'crash_kind': 'freeze'
      };
      const attrs: Record<string, Object> = RumFeature.crashAttributes(event);
      expect(attrs['error.binary_images']).assertUndefined();
      expect(attrs['build_id']).assertUndefined();
      expect(attrs['error.meta.code_type']).assertUndefined();
      expect(attrs['error.source_type']).assertEqual('harmony');
      expect(attrs['error.category']).assertEqual('App Hang');
    });

    it('formatsUnhandledErrorObjectsWithStack', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const err: Error = new Error('boom');
      err.stack = 'Error: boom\n    at Demo.throwArkTsError (Index.ets:68:13)';

      const text: string = RumFeature.unhandledErrorText(err);

      expect(text).assertEqual('Error: boom\n    at Demo.throwArkTsError (Index.ets:68:13)');
    });

    it('marksUnhandledRejectionsAsPlainPromiseErrors',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const err: Error = new Error('rejected');
        err.stack = 'Error: rejected\n    at request (Api.ets:1:2)';

        const text: string = RumFeature.rejectionErrorText(err);
        const attrs: Record<string, Object> = RumFeature.rejectionAttributes();

        expect(text.indexOf('Error: rejected')).assertEqual(0);
        expect(attrs['error.category']).assertEqual('Unhandled Promise Rejection');
        expect(attrs['error.source_type']).assertEqual('promise');
      });
  });
}
