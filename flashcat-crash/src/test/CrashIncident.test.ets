import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { JsCrashPolicy } from '../main/ets/CrashConfiguration';
import {
  ConsumedCrashIncident,
  CrashDeduplication,
  CrashFingerprint,
  CrashIncidentRecord,
  CrashLoopDecision,
  CrashLoopGuard,
  LiveCrashIncidentGuard
} from '../main/ets/internal/CrashIncident';

export default function crashIncidentTests(): void {
  describe('CrashIncident', (): void => {
    it('normalizesAbsolutePathsAndLocations', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const first: string = CrashFingerprint.fromParts(
        'TypeError',
        'Cannot read property x',
        'TypeError: Cannot read property x\n    at open (/Users/fiona/work/app/Index.ets:42:13)');
      const second: string = CrashFingerprint.fromParts(
        'TypeError',
        'Cannot read property x',
        'TypeError: Cannot read property x\n    at open (/private/tmp/build/app/Index.ets:99:4)');

      expect(first).assertEqual(second);
    });

    it('parsesLabeledErrorManagerTextIntoParts', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const observerText: string =
        'Error name:RangeError\nError message:index out of bounds\nStacktrace:\n    at pick (entry/src/main/ets/pages/Index.ets:12:5)';
      const parts = CrashFingerprint.partsFromText(observerText);

      expect(parts.name).assertEqual('RangeError');
      expect(parts.message).assertEqual('index out of bounds');
      // Live observer text and a watcher-style separated report must agree on
      // the fingerprint, or cross-launch dedup silently stops working.
      const live: string = CrashFingerprint.fromText(observerText);
      const watcher: string = CrashFingerprint.fromParts(
        'RangeError',
        'index out of bounds',
        'RangeError: index out of bounds\n    at pick (entry/src/main/ets/pages/Index.ets:12:5)');
      expect(live).assertEqual(watcher);
    });

    it('roundTripsViewUrlThroughSerialization', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const record: CrashIncidentRecord = new CrashIncidentRecord(
        'inc-1', 1000, 'Error', 'boom', 'Error: boom\n    at f (a.ets:1:1)', 'fp-1',
        JsCrashPolicy.REPORT_THEN_EXIT, '0.2.0', 's-1', 'v-1', 'Home', 'pages/Home');

      const parsed: CrashIncidentRecord | null = CrashIncidentRecord.parse(record.serialize());

      expect(parsed !== null).assertTrue();
      if (parsed !== null) {
        expect(parsed.viewUrl).assertEqual('pages/Home');
      }
      // Records written by older SDK versions (no view_url key) still parse.
      const legacy: CrashIncidentRecord | null = CrashIncidentRecord.parse(
        '{"incident_id":"inc-2","timestamp_ms":1,"exception_name":"Error","message":"m",' +
        '"stack":"s","fingerprint":"fp","policy":"REPORT_THEN_EXIT","sdk_version":"0.1.0",' +
        '"session_id":"s","view_id":"v","view_name":"n"}');
      expect(legacy !== null).assertTrue();
      if (legacy !== null) {
        expect(legacy.viewUrl).assertEqual('');
      }
    });

    it('ignoresSourceMapBannerWhenParsingParts', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const bannerText: string =
        'Cannot get SourceMap info, dump raw stack:\n    at anonymous (entry|entry|1.0.0|src/main/ets/pages/Index.ts:12:5)';
      const parts = CrashFingerprint.partsFromText(bannerText);

      expect(parts.name).assertEqual('Error');
      expect(parts.message).assertEqual('');
      // The raw text (banner included) is still retained as the stack.
      expect(parts.stack.indexOf('Cannot get SourceMap info')).assertEqual(0);
    });

    it('changesWhenMessageChanges', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const first: string = CrashFingerprint.fromParts(
        'Error', 'first', 'Error: first\n    at run (/data/app/Index.ets:10:2)');
      const second: string = CrashFingerprint.fromParts(
        'Error', 'second', 'Error: second\n    at run (/data/app/Index.ets:10:2)');

      expect(first === second).assertFalse();
    });

    it('suppressesMatchingLiveCallbackOnlyInsideWindow',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const guard: LiveCrashIncidentGuard = new LiveCrashIncidentGuard(2000);
        guard.remember('fp-1', 1000);

        expect(guard.isDuplicate('fp-1', 2999)).assertTrue();
        expect(guard.isDuplicate('fp-2', 1500)).assertFalse();
        expect(guard.isDuplicate('fp-1', 3001)).assertFalse();
      });

    it('matchesConsumedIncidentInsideCrossLaunchWindow',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const consumed: ConsumedCrashIncident[] = [
          new ConsumedCrashIncident('incident-1', 'fp-1', 100000)
        ];

        expect(CrashDeduplication.matchesConsumed('fp-1', 70000, consumed, 30000)).assertTrue();
        expect(CrashDeduplication.matchesConsumed('fp-1', 130000, consumed, 30000)).assertTrue();
        expect(CrashDeduplication.matchesConsumed('fp-1', 130001, consumed, 30000)).assertFalse();
        expect(CrashDeduplication.matchesConsumed('fp-2', 100000, consumed, 30000)).assertFalse();
      });

    it('retainsConsumedMetadataOnlyForConfiguredLifetime',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const consumed: ConsumedCrashIncident[] = [
          new ConsumedCrashIncident('expired', 'fp-1', 1000),
          new ConsumedCrashIncident('recent', 'fp-2', 9000)
        ];

        const recent: ConsumedCrashIncident[] =
          CrashDeduplication.retainRecent(consumed, 10000, 2000);

        expect(recent.length).assertEqual(1);
        expect(recent[0].incidentId).assertEqual('recent');
      });

    it('serializesAndParsesPendingRecord', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const original: CrashIncidentRecord = new CrashIncidentRecord(
        'incident-1',
        123456,
        'TypeError',
        'boom',
        'TypeError: boom\n    at run (Index.ets:1:2)',
        'fp-1',
        JsCrashPolicy.REPORT_THEN_EXIT,
        '0.2.0',
        'session-1',
        'view-1',
        'Home');

      const parsed: CrashIncidentRecord | null = CrashIncidentRecord.parse(original.serialize());

      expect(parsed === null).assertFalse();
      if (parsed !== null) {
        expect(parsed.incidentId).assertEqual('incident-1');
        expect(parsed.timestampMs).assertEqual(123456);
        expect(parsed.exceptionName).assertEqual('TypeError');
        expect(parsed.message).assertEqual('boom');
        expect(parsed.stack.indexOf('Index.ets')).assertLarger(-1);
        expect(parsed.fingerprint).assertEqual('fp-1');
        expect(parsed.policy).assertEqual(JsCrashPolicy.REPORT_THEN_EXIT);
        expect(parsed.sdkVersion).assertEqual('0.2.0');
        expect(parsed.sessionId).assertEqual('session-1');
        expect(parsed.viewId).assertEqual('view-1');
        expect(parsed.viewName).assertEqual('Home');
      }
    });

    it('returnsNullForCorruptedPendingRecord', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(CrashIncidentRecord.parse('{broken json')).assertNull();
      expect(CrashIncidentRecord.parse('{"incident_id":"missing fields"}')).assertNull();
    });

    it('roundTripsConsumedSidecarAndToleratesCorruption',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const consumed: ConsumedCrashIncident[] = [
          new ConsumedCrashIncident('incident-1', 'fp-1', 123456)
        ];

        const parsed: ConsumedCrashIncident[] =
          CrashDeduplication.parseConsumed(CrashDeduplication.serializeConsumed(consumed));

        expect(parsed.length).assertEqual(1);
        expect(parsed[0].incidentId).assertEqual('incident-1');
        expect(parsed[0].fingerprint).assertEqual('fp-1');
        expect(parsed[0].timestampMs).assertEqual(123456);
        expect(CrashDeduplication.parseConsumed('{broken').length).assertEqual(0);
      });

    it('allowsRecoveryBelowCrashLoopThreshold',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const decision: CrashLoopDecision =
          CrashLoopGuard.decide(2000, [1000], 3, 60000, 300000);

        expect(decision.allowRestart).assertTrue();
        expect(decision.updatedTimestamps.length).assertEqual(2);
        expect(decision.updatedTimestamps[1]).assertEqual(2000);
      });

    it('blocksRecoveryAtCrashLoopThreshold',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const decision: CrashLoopDecision =
          CrashLoopGuard.decide(3000, [1000, 2000], 3, 60000, 300000);

        expect(decision.allowRestart).assertFalse();
        expect(decision.updatedTimestamps.length).assertEqual(3);
      });

    it('allowsRecoveryAfterCrashLoopWindowExpires',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const decision: CrashLoopDecision =
          CrashLoopGuard.decide(62001, [1000, 2000, 3000], 4, 60000, 300000);

        expect(decision.allowRestart).assertTrue();
        expect(decision.updatedTimestamps.length).assertEqual(2);
        expect(decision.updatedTimestamps[0]).assertEqual(3000);
        expect(decision.updatedTimestamps[1]).assertEqual(62001);
      });

    it('clearsCrashLoopHistoryAfterCooldown',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const decision: CrashLoopDecision =
          CrashLoopGuard.decide(303000, [1000, 2000, 3000], 3, 600000, 300000);

        expect(decision.allowRestart).assertTrue();
        expect(decision.updatedTimestamps.length).assertEqual(1);
        expect(decision.updatedTimestamps[0]).assertEqual(303000);
      });

    it('toleratesEmptyAndCorruptedCrashLoopHistory',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(CrashLoopGuard.parseHistory('').length).assertEqual(0);
        expect(CrashLoopGuard.parseHistory('{broken').length).assertEqual(0);

        const decision: CrashLoopDecision =
          CrashLoopGuard.decide(1000, CrashLoopGuard.parseHistory('{broken'), 3, 60000, 300000);
        expect(decision.allowRestart).assertTrue();
        expect(decision.updatedTimestamps.length).assertEqual(1);
      });

    it('keepsBlockingImmediateCrashAfterLoopTrips',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const tripped: CrashLoopDecision =
          CrashLoopGuard.decide(3000, [1000, 2000], 3, 60000, 300000);
        const next: CrashLoopDecision =
          CrashLoopGuard.decide(3001, tripped.updatedTimestamps, 3, 60000, 300000);

        expect(tripped.allowRestart).assertFalse();
        expect(next.allowRestart).assertFalse();
        expect(next.updatedTimestamps.length).assertEqual(3);
      });

    it('keepsTrippedGuardBlockedAfterWindowUntilCooldown',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const decision: CrashLoopDecision =
          CrashLoopGuard.decide(63001, [1000, 2000, 3000], 3, 60000, 300000);

        expect(decision.allowRestart).assertFalse();
        expect(decision.updatedTimestamps.length).assertEqual(3);
        expect(decision.updatedTimestamps[2]).assertEqual(63001);
      });

    it('blockedCrashExtendsCrashLoopCooldown',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const blocked: CrashLoopDecision =
          CrashLoopGuard.decide(200000, [1000, 2000, 3000], 3, 60000, 300000);
        const stillBlocked: CrashLoopDecision =
          CrashLoopGuard.decide(400000, blocked.updatedTimestamps, 3, 60000, 300000);
        const cooledDown: CrashLoopDecision =
          CrashLoopGuard.decide(700000, stillBlocked.updatedTimestamps, 3, 60000, 300000);

        expect(blocked.allowRestart).assertFalse();
        expect(stillBlocked.allowRestart).assertFalse();
        expect(cooledDown.allowRestart).assertTrue();
      });

    it('roundTripsCrashLoopHistory',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const serialized: string = CrashLoopGuard.serializeHistory([1000, 2000, 3000]);
        const parsed: number[] = CrashLoopGuard.parseHistory(serialized);

        expect(parsed.length).assertEqual(3);
        expect(parsed[0]).assertEqual(1000);
        expect(parsed[1]).assertEqual(2000);
        expect(parsed[2]).assertEqual(3000);
      });
  });
}
