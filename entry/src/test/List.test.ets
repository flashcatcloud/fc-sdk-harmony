import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { DemoConfigLoader } from '../main/ets/common/DemoConfig';

export default function testsuite(): void {
  describe('entry-demo', (): void => {
    it('loadsSdkCredentialsFromConfigJson', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const cfg = DemoConfigLoader.parse('{"clientToken":"token-1","applicationId":"app-1","service":"svc"}');
      expect(cfg.clientToken).assertEqual('token-1');
      expect(cfg.applicationId).assertEqual('app-1');
      expect(cfg.service).assertEqual('svc');
    });

    it('usesDefaultServiceWhenConfigOmitsIt', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const cfg = DemoConfigLoader.parse('{"clientToken":"token-1","applicationId":"app-1"}');
      expect(cfg.service).assertEqual('flashcat-harmony-demo');
    });
  });
}
