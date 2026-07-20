import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { JsCrashPolicy } from '../main/ets/CrashConfiguration';
import {
  ConsumedCrashIncident,
  CrashDeduplication,
  CrashFingerprint,
  CrashIncidentRecord,
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
        '0.1.3',
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
        expect(parsed.sdkVersion).assertEqual('0.1.3');
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
  });
}
