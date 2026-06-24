import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { RumResourceKind } from '../main/ets/RumTypes';

/**
 * Resource type classification from the response Content-Type, mirroring the
 * Datadog Android (`RumResourceKind.fromMimeType`) and iOS
 * (`RUMResourceType(response:)`) mapping so HarmonyOS reports the same types.
 */
export default function resourceKindTests(): void {
  describe('RumResourceKindFromMimeType', (): void => {
    it('classifiesImage', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumFeature.resourceKindFromMimeType('image/png')).assertEqual(RumResourceKind.IMAGE);
      expect(RumFeature.resourceKindFromMimeType('image/jpeg')).assertEqual(RumResourceKind.IMAGE);
    });

    it('classifiesMedia', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumFeature.resourceKindFromMimeType('video/mp4')).assertEqual(RumResourceKind.MEDIA);
      expect(RumFeature.resourceKindFromMimeType('audio/mpeg')).assertEqual(RumResourceKind.MEDIA);
    });

    it('classifiesFont', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumFeature.resourceKindFromMimeType('font/woff2')).assertEqual(RumResourceKind.FONT);
    });

    it('classifiesCssAndJs', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumFeature.resourceKindFromMimeType('text/css')).assertEqual(RumResourceKind.CSS);
      expect(RumFeature.resourceKindFromMimeType('text/javascript')).assertEqual(RumResourceKind.JS);
    });

    it('ignoresParametersAndCase', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumFeature.resourceKindFromMimeType('text/css; charset=utf-8')).assertEqual(RumResourceKind.CSS);
      expect(RumFeature.resourceKindFromMimeType('IMAGE/PNG')).assertEqual(RumResourceKind.IMAGE);
    });

    it('defaultsToNativeForApiAndUnknown', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumFeature.resourceKindFromMimeType('application/json')).assertEqual(RumResourceKind.NATIVE);
      expect(RumFeature.resourceKindFromMimeType('text/html')).assertEqual(RumResourceKind.NATIVE);
      expect(RumFeature.resourceKindFromMimeType('')).assertEqual(RumResourceKind.NATIVE);
    });
  });
}
