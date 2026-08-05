import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { FlashcatTrace } from '../main/ets/FlashcatTrace';
import { TracedResource } from '../main/ets/TracedResource';
import { TraceConfiguration } from '../main/ets/TraceConfiguration';
import { TraceContext } from '../main/ets/internal/TraceContext';
import { shouldInjectTraceHeaders, hostOfUrl } from '../main/ets/internal/TraceInterceptor';

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

    it('tracestateReplacesDatadogEntryAndMovesItToFront', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // W3C: the mutated member leads; other vendors keep their relative order.
      expect(TraceContext.generate(100).tracestate('foo=bar,dd=s:0;o:rum,baz=qux'))
        .assertEqual('dd=s:1;o:rum,foo=bar,baz=qux');
    });

    // ---- _dd.span_id decimal encoding (Datadog convention; intake parses base-10) ----
    it('convertsHexSpanIdToUnsignedDecimal', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(TraceContext.hexToUnsignedDecimalString('0')).assertEqual('0');
      expect(TraceContext.hexToUnsignedDecimalString('ff')).assertEqual('255');
      expect(TraceContext.hexToUnsignedDecimalString('00000000000000ff')).assertEqual('255');
      // 64-bit value above Number's 53-bit precision — must round-trip exactly.
      expect(TraceContext.hexToUnsignedDecimalString('ffffffffffffffff')).assertEqual('18446744073709551615');
      expect(TraceContext.hexToUnsignedDecimalString('a3f2b1c4d5e6f708')).assertEqual('11813700231506622216');
      expect(TraceContext.hexToUnsignedDecimalString('not-hex')).assertEqual('');
      expect(TraceContext.hexToUnsignedDecimalString('')).assertEqual('');
    });

    it('traceInjectionSkipsExistingTraceparent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const headers: Record<string, Object> = {};
      headers['TraceParent'] = 'custom';
      expect(shouldInjectTraceHeaders(headers)).assertFalse();
    });

    // ---- host parsing behind the first-party gate ----
    it('hostOfUrlParsesSchemeHostPortPathQuery', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(hostOfUrl('https://api.example.com/v1/items?x=1')).assertEqual('api.example.com');
      expect(hostOfUrl('http://api.example.com:8080/p')).assertEqual('api.example.com');
      expect(hostOfUrl('https://user:pw@api.example.com/p')).assertEqual('api.example.com');
      expect(hostOfUrl('api.example.com/p')).assertEqual('api.example.com');
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

    // ---- startTracedResource: the network-stack-agnostic entry point ----
    // Callers pair every start with a stop/fail. That pairing must hold even
    // when nothing is being tracked, otherwise integrations need a second code
    // path for "SDK not ready" and will get it wrong.
    it('startTracedResourceAlwaysReturnsAUsableKey', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const first: TracedResource = FlashcatTrace.startTracedResource('https://api.example.com/a', 'GET');
      const second: TracedResource = FlashcatTrace.startTracedResource('https://api.example.com/b', 'GET');
      expect(first.key.length > 0).assertTrue();
      expect(second.key.length > 0).assertTrue();
      expect(first.key === second.key).assertFalse();
    });

    it('startTracedResourceInjectsNothingBeforeConsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const traced: TracedResource = FlashcatTrace.startTracedResource('https://api.example.com/a', 'GET');
      expect(Object.keys(traced.headers).length).assertEqual(0);
    });

    // A request that already carries a traceparent belongs to an existing
    // trace: generating a second context would both overwrite the caller's
    // chain and tie the resource to a trace that was never sent.
    it('startTracedResourceHonoursInjectTraceFalse', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const traced: TracedResource = FlashcatTrace.startTracedResource('https://api.example.com/a', 'GET', false);
      expect(traced.key.length > 0).assertTrue();
      expect(Object.keys(traced.headers).length).assertEqual(0);
    });

    // Closing is best-effort: an unknown key or a torn-down core must not throw
    // into the caller's response handler.
    it('stopAndFailAreSafeWithoutCoreOrKnownKey', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      let threw: boolean = false;
      try {
        FlashcatTrace.stopTracedResource('no-such-key', 200, 128);
        FlashcatTrace.failTracedResource('no-such-key', 'boom');
      } catch (_e) {
        threw = true;
      }
      expect(threw).assertFalse();
    });

    // FlashcatHttp merges the generated tracestate onto whatever the request
    // already carries, so this helper is load-bearing for that path.
    it('mergeDatadogTracestateKeepsOtherVendorsAndLeads', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(TraceContext.mergeDatadogTracestate('', 'dd=s:1;o:rum')).assertEqual('dd=s:1;o:rum');
      expect(TraceContext.mergeDatadogTracestate('foo=bar', 'dd=s:1;o:rum')).assertEqual('dd=s:1;o:rum,foo=bar');
      expect(TraceContext.mergeDatadogTracestate('foo=bar,dd=s:0;o:rum', 'dd=s:1;o:rum'))
        .assertEqual('dd=s:1;o:rum,foo=bar');
    });
  });
}
