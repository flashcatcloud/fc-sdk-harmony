import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { GlobalRumMonitor } from '../main/ets/RumMonitor';
import { RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from '../main/ets/RumTypes';

export default function testsuite(): void {
  describe('flashcat-rum', (): void => {
    it('defaultMonitorIsNoOp', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const monitor = GlobalRumMonitor.get();
      monitor.startView('view-key', 'Home');
      monitor.addAction(RumActionType.CUSTOM, 'tap');
      monitor.startResource('resource-key', RumResourceMethod.GET, 'https://example.com');
      monitor.stopResource('resource-key', 200, 0, RumResourceKind.NATIVE);
      monitor.addError('message', RumErrorSource.CUSTOM);

      let currentSessionId: string | undefined = 'unexpected';
      monitor.getCurrentSessionId((sessionId: string | undefined): void => {
        currentSessionId = sessionId;
      });
      expect(currentSessionId).assertUndefined();
    });
  });
}
