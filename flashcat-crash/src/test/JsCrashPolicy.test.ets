import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { CrashConfiguration, CrashConfigurationBuilder, JsCrashPolicy } from '../main/ets/CrashConfiguration';

export default function jsCrashPolicyTests(): void {
  describe('JsCrashPolicy', (): void => {
    it('defaultsToReportThenExit', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const configuration: CrashConfiguration = new CrashConfigurationBuilder().build();

      expect(configuration.jsCrashPolicy).assertEqual(JsCrashPolicy.REPORT_THEN_EXIT);
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
  });
}
