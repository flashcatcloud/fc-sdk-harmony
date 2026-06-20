import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { FlashcatTrace } from '../main/ets/FlashcatTrace';
import { FlashcatHttp } from '../main/ets/FlashcatHttp';
import { TraceConfiguration } from '../main/ets/TraceConfiguration';

export default function testsuite(): void {
  describe('flashcat-trace', (): void => {
    it('manualHeadersAreEmptyBeforeConsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const headers: Record<string, string> = FlashcatTrace.getHeaders();
      expect(Object.keys(headers).length).assertEqual(0);
    });

    // ---- Phase 2 A2: FlashcatHttp host parsing ----
    it('hostOfParsesSchemeHostPortPathQuery', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(FlashcatHttp.hostOf('https://api.example.com/v1/items?x=1')).assertEqual('api.example.com');
      expect(FlashcatHttp.hostOf('http://api.example.com:8080/p')).assertEqual('api.example.com');
      expect(FlashcatHttp.hostOf('https://user:pw@api.example.com/p')).assertEqual('api.example.com');
      expect(FlashcatHttp.hostOf('api.example.com/p')).assertEqual('api.example.com');
    });

    // ---- Phase 2 A2: first-party host gating ----
    it('isFirstPartyMatchesHostAndSubdomains', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const cfg: TraceConfiguration = new TraceConfiguration(100, ['example.com']);
      expect(cfg.isFirstParty('example.com')).assertTrue();
      expect(cfg.isFirstParty('api.example.com')).assertTrue();
      expect(cfg.isFirstParty('evil.com')).assertFalse();
      expect(cfg.isFirstParty('notexample.com')).assertFalse();
    });

    it('isFirstPartyAllowsAllWhenEmpty', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const cfg: TraceConfiguration = new TraceConfiguration(100, []);
      expect(cfg.isFirstParty('anything.com')).assertTrue();
    });
  });
}
