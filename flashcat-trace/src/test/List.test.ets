import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { FlashcatTrace } from '../main/ets/FlashcatTrace';

export default function testsuite(): void {
  describe('flashcat-trace', (): void => {
    it('manualHeadersAreEmptyBeforeConsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const headers: Record<string, string> = FlashcatTrace.getHeaders();
      expect(Object.keys(headers).length).assertEqual(0);
    });
  });
}
