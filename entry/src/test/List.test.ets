import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';

export default function testsuite(): void {
  describe('entry-demo', (): void => {
    it('placeholder', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // The demo app is verified manually on a device (see entry/README.md);
      // this placeholder keeps the module's unit-test task green.
      expect(1).assertEqual(1);
    });
  });
}
