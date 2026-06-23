import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { Flashcat } from '../main/ets/Flashcat';
import dataUploaderTests from './DataUploader.test';
import deferredUploadTests from './DeferredUpload.test';

export default function testsuite(): void {
  dataUploaderTests();
  deferredUploadTests();
  describe('flashcat-core', (): void => {
    it('defaultInstanceStartsUninitialized', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(Flashcat.isInitialized()).assertFalse();
    });
  });
}
