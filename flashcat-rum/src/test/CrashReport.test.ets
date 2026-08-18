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
      expect(attrs['error.category']).assertEqual('ANR');
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

    it('unwrapsBusinessErrorShapedRejectionReasons',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const reason: Record<string, Object> = { 'code': 201, 'message': 'Permission denied' };

        expect(RumFeature.rejectionErrorText(reason)).assertEqual('Permission denied (code 201)');
      });

    it('serializesMessagelessObjectRejectionReasons',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const reason: Record<string, Object> = { 'status': 500 };

        expect(RumFeature.rejectionErrorText(reason)).assertEqual('{"status":500}');
      });

    it('keepsStringRejectionReasonsVerbatim',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(RumFeature.rejectionErrorText('plain refusal')).assertEqual('plain refusal');
      });

    it('buildsMessageFromErrorNameAndMessage',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const err: Error = new TypeError('boom');
        // Frames-only stack (ArkTS has no "Name: message" header line).
        err.stack = '    at Demo.throwArkTsError (Index.ets:68:13)';

        expect(RumFeature.messageFromError(err)).assertEqual('TypeError: boom');
      });

    it('parsesLabeledUnhandledExceptionText',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const text: string = 'Error name:RangeError\nError message:out of bounds\nStacktrace:\nat f (a.ets:1:1)';

        expect(RumFeature.errorMessageFromText(text)).assertEqual('RangeError: out of bounds');
      });

    it('rendersLabeledTextMatchingOsCallbackShape',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Both errorManager callbacks must feed the crash module the same
        // labeled shape, or live dedup fingerprints never match across them.
        const err: Error = new RangeError('index out of bounds');
        err.stack = '    at pick (Index.ets:12:5)';

        const text: string = RumFeature.labeledErrorText(err);

        expect(text.indexOf('Error name:RangeError')).assertEqual(0);
        expect(text.indexOf('\nError message:index out of bounds\n')).assertLarger(-1);
        expect(text.indexOf('Stacktrace:\n    at pick (Index.ets:12:5)')).assertLarger(-1);
      });

    it('skipsSourceMapBannerWhenDerivingMessage',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const bannerOnly: string = 'Cannot get SourceMap info, dump raw stack:';
        const bannerWithFrames: string = 'Cannot get SourceMap info, dump raw stack:\nat f (a.ets:1:1)';

        expect(RumFeature.errorMessageFromText(bannerOnly)).assertEqual('Uncaught exception');
        expect(RumFeature.errorMessageFromText(bannerWithFrames)).assertEqual('Uncaught exception');
      });

    it('emptyMessagesProduceNameAloneNotDanglingColon',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Production symptom: events titled "Error name:Error" with no stack —
        // a message-less non-Error throw. The derived message must be the name
        // alone, never the raw label line and never "Error: ".
        const labeledEmpty: string = 'Error name:Error\nError message:\nStacktrace:';
        expect(RumFeature.errorMessageFromText(labeledEmpty)).assertEqual('Error');

        const err: Error = new Error();
        err.stack = '';
        expect(RumFeature.messageFromError(err)).assertEqual('Error');
      });

    it('emptyObjectRejectionNeverReportsObjectObject',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // `Promise.reject({})` JSON-serializes to '{}' which is skipped — the
        // fallback must not interpolate the object into "[object Object]".
        const text: string = RumFeature.rejectionErrorText({} as Object);
        expect(text.indexOf('[object')).assertEqual(-1);
        expect(text.length > 0).assertTrue();
      });
  });
}
