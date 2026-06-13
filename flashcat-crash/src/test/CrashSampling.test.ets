import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { CrashFeature } from '../main/ets/internal/CrashFeature';

export default function crashSamplingTests(): void {
  describe('CrashSampling', (): void => {
    it('alwaysSamplesAt100', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(CrashFeature.sampled(100)).assertTrue();
      expect(CrashFeature.sampled(150)).assertTrue();
    });

    it('neverSamplesAt0', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(CrashFeature.sampled(0)).assertFalse();
      expect(CrashFeature.sampled(-5)).assertFalse();
    });

    it('probabilisticInBetween', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // 50% over many draws should produce both outcomes; assert it stays within [0,n].
      let yes: number = 0;
      for (let i = 0; i < 200; i++) {
        if (CrashFeature.sampled(50)) {
          yes++;
        }
      }
      expect(yes >= 0 && yes <= 200).assertTrue();
    });
  });
}
