import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { CrashConfiguration, CrashConfigurationBuilder, JsCrashPolicy } from '../main/ets/CrashConfiguration';

export default function jsCrashPolicyTests(): void {
  describe('JsCrashPolicy', (): void => {
    it('defaultsToReportThenExit', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const configuration: CrashConfiguration = new CrashConfigurationBuilder().build();

      expect(configuration.jsCrashPolicy).assertEqual(JsCrashPolicy.REPORT_THEN_EXIT);
      expect(configuration.crashLoopThreshold).assertEqual(3);
      expect(configuration.crashLoopWindowMs).assertEqual(60000);
      expect(configuration.crashLoopCooldownMs).assertEqual(300000);
    });

    it('builderAcceptsEveryPolicy', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const recover: CrashConfiguration = new CrashConfigurationBuilder()
        .setJsCrashPolicy(JsCrashPolicy.REPORT_AND_RECOVER)
        .build();
      const observe: CrashConfiguration = new CrashConfigurationBuilder()
        .setJsCrashPolicy(JsCrashPolicy.OBSERVE_ONLY)
        .build();

      expect(recover.jsCrashPolicy).assertEqual(JsCrashPolicy.REPORT_AND_RECOVER);
      expect(observe.jsCrashPolicy).assertEqual(JsCrashPolicy.OBSERVE_ONLY);
    });

    it('builderConfiguresCrashLoopProtection',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const configuration: CrashConfiguration = new CrashConfigurationBuilder()
          .setCrashLoopThreshold(5)
          .setCrashLoopWindowMs(120000)
          .setCrashLoopCooldownMs(600000)
          .build();

        expect(configuration.crashLoopThreshold).assertEqual(5);
        expect(configuration.crashLoopWindowMs).assertEqual(120000);
        expect(configuration.crashLoopCooldownMs).assertEqual(600000);
      });

    it('builderClampsCrashLoopProtectionToPositiveValues',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const configuration: CrashConfiguration = new CrashConfigurationBuilder()
          .setCrashLoopThreshold(0)
          .setCrashLoopWindowMs(0)
          .setCrashLoopCooldownMs(-1)
          .build();

        expect(configuration.crashLoopThreshold).assertEqual(1);
        expect(configuration.crashLoopWindowMs).assertEqual(1);
        expect(configuration.crashLoopCooldownMs).assertEqual(1);
      });
  });
}
