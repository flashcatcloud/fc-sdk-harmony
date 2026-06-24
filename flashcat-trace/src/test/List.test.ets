import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { FlashcatTrace } from '../main/ets/FlashcatTrace';
import { FlashcatHttp } from '../main/ets/FlashcatHttp';
import { TraceConfiguration } from '../main/ets/TraceConfiguration';
import { TraceContext } from '../main/ets/internal/TraceContext';
import { shouldInjectTraceHeaders } from '../main/ets/internal/TraceInterceptor';

export default function testsuite(): void {
  describe('flashcat-trace', (): void => {
    it('manualHeadersAreEmptyBeforeConsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const headers: Record<string, string> = FlashcatTrace.getHeaders();
      expect(Object.keys(headers).length).assertEqual(0);
    });

    // ---- W3C traceparent + tracestate format ----
    // NOTE: trace_id/span_id width (128/64-bit hex) relies on the CryptoArchitectureKit
    // CSPRNG, which is stubbed in the host test runtime, so it's asserted on-device.
    // Here we verify the deterministic parts: version, structure, and the sampled flag.
    it('traceparentHasVersionAndSampledFlag', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const sampled: TraceContext = TraceContext.generate(100);
      expect(sampled.traceparent().startsWith('00-')).assertTrue();
      expect(sampled.traceparent().endsWith('-01')).assertTrue();
      expect(sampled.traceparent()).assertEqual(`00-${sampled.traceId}-${sampled.spanId}-01`);
      const dropped: TraceContext = TraceContext.generate(0);
      expect(dropped.traceparent().endsWith('-00')).assertTrue();
    });

    it('tracestateCarriesDatadogVendorEntry', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(TraceContext.generate(100).tracestate()).assertEqual('dd=s:1;o:rum');
      expect(TraceContext.generate(0).tracestate()).assertEqual('dd=s:0;o:rum');
    });

    it('tracestatePreservesOtherVendorEntries', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(TraceContext.generate(100).tracestate('foo=bar,baz=qux'))
        .assertEqual('dd=s:1;o:rum,foo=bar,baz=qux');
    });

    it('tracestateReplacesExistingDatadogEntryOnly', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(TraceContext.generate(100).tracestate('foo=bar,dd=s:0;o:rum,baz=qux'))
        .assertEqual('foo=bar,dd=s:1;o:rum,baz=qux');
    });

    it('traceInjectionSkipsExistingTraceparent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const headers: Record<string, Object> = {};
      headers['TraceParent'] = 'custom';
      expect(shouldInjectTraceHeaders(headers)).assertFalse();
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
