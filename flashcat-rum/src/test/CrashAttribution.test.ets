import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { RumFeature } from '../main/ets/internal/RumFeature';

/**
 * Pure-logic cover for replaying a crash against the last persisted ViewEvent.
 *
 * The document this builds is consumed by the intake as a DELTA against the last
 * value it saw for that view — there is no document_version guard server-side.
 * Two consequences these cases pin down:
 *   - error AND crash both advance, because a crash ships as an is_crash error
 *     (missing the error bump left every crashed session one error short);
 *   - every other counter must survive untouched, since a stale or dropped
 *     value here silently decrements the session's totals.
 */
function viewEvent(
  crashCount: number | undefined, documentVersion: number, extras?: Record<string, Object>
): Record<string, Object> {
  const view: Record<string, Object> = {
    'id': 'view-1',
    'name': 'pages/Index',
    'url': 'pages/Index.js',
    'is_active': true,
    'time_spent': 1234000000,
    'action': { 'count': 7 } as Record<string, Object>,
    'error': { 'count': 3 } as Record<string, Object>,
    'resource': { 'count': 5 } as Record<string, Object>
  };
  if (crashCount !== undefined) {
    view['crash'] = { 'count': crashCount } as Record<string, Object>;
  }
  const event: Record<string, Object> = {
    'type': 'view',
    'date': 1700000000000,
    'application': { 'id': 'app-1' } as Record<string, Object>,
    'session': { 'id': 'session-1', 'type': 'user' } as Record<string, Object>,
    'view': view,
    '_dd': {
      'format_version': 2,
      'document_version': documentVersion
    } as Record<string, Object>,
    'usr': { 'id': 'u-1' } as Record<string, Object>
  };
  if (extras !== undefined) {
    for (const k of Object.keys(extras)) {
      event[k] = extras[k];
    }
  }
  return event;
}

function viewOf(event: Record<string, Object>): Record<string, Object> {
  return event['view'] as Record<string, Object>;
}

function countOf(event: Record<string, Object>, key: string): number {
  const holder: Record<string, Object> = viewOf(event)[key] as Record<string, Object>;
  return holder['count'] as number;
}

export default function crashAttributionTests(): void {
  describe('crashAttribution', (): void => {
    it('marksCrashAndAdvancesDocumentVersion', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const marked: Record<string, Object> = RumFeature.viewEventWithCrash(viewEvent(0, 4));
        expect(countOf(marked, 'crash')).assertEqual(1);
        expect((marked['_dd'] as Record<string, Object>)['document_version']).assertEqual(5);
        expect(viewOf(marked)['is_active']).assertEqual(false);
      });

    it('incrementsAnExistingCrashCount', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const marked: Record<string, Object> = RumFeature.viewEventWithCrash(viewEvent(2, 9));
        expect(countOf(marked, 'crash')).assertEqual(3);
        expect((marked['_dd'] as Record<string, Object>)['document_version']).assertEqual(10);
      });

    it('treatsAMissingCrashObjectAsZero', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const marked: Record<string, Object> = RumFeature.viewEventWithCrash(viewEvent(undefined, 1));
        expect(countOf(marked, 'crash')).assertEqual(1);
      });

    // A crash is delivered as an is_crash ERROR event, so the view owes it one
    // error as well as one crash — this is what RumViewScope does live. Bumping
    // crash alone left the session permanently one error short.
    it('countsTheCrashAsAnErrorToo', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const marked: Record<string, Object> = RumFeature.viewEventWithCrash(viewEvent(0, 4));
        expect(countOf(marked, 'error')).assertEqual(4); // 3 + this crash
        expect(countOf(marked, 'crash')).assertEqual(1);
      });

    // The intake applies these as deltas. Changing one here would decrement the
    // session's totals on the backend.
    it('leavesUnrelatedCountersUntouched', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const marked: Record<string, Object> = RumFeature.viewEventWithCrash(viewEvent(0, 4));
        expect(countOf(marked, 'action')).assertEqual(7);
        expect(countOf(marked, 'resource')).assertEqual(5);
        expect(viewOf(marked)['time_spent']).assertEqual(1234000000);
      });

    it('keepsIdentityAndViewStartDate', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const marked: Record<string, Object> = RumFeature.viewEventWithCrash(viewEvent(0, 4));
        expect((marked['session'] as Record<string, Object>)['id']).assertEqual('session-1');
        expect(viewOf(marked)['id']).assertEqual('view-1');
        expect(viewOf(marked)['url']).assertEqual('pages/Index.js');
        // date stays the view START so the backend treats this as the same
        // document rather than opening a new one.
        expect(marked['date']).assertEqual(1700000000000);
        expect(marked['type']).assertEqual('view');
      });

    it('doesNotMutateTheSourceSnapshot', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const source: Record<string, Object> = viewEvent(0, 4);
        RumFeature.viewEventWithCrash(source);
        expect(countOf(source, 'crash')).assertEqual(0);
        expect(countOf(source, 'error')).assertEqual(3);
        expect(viewOf(source)['is_active']).assertEqual(true);
        expect((source['_dd'] as Record<string, Object>)['document_version']).assertEqual(4);
      });

    // A second fault replayed in the same launch chains off the marked copy, so
    // it must land on the next version rather than re-issue a settled one.
    it('chainsASecondFaultOntoTheNextVersion', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const first: Record<string, Object> = RumFeature.viewEventWithCrash(viewEvent(0, 4));
        const second: Record<string, Object> = RumFeature.viewEventWithCrash(first);
        expect(countOf(second, 'crash')).assertEqual(2);
        expect(countOf(second, 'error')).assertEqual(5); // 3 + two crashes
        expect((second['_dd'] as Record<string, Object>)['document_version']).assertEqual(6);
      });

    // A replayed crash is assembled by the NEXT launch, which may run another app version or
    // user (an update or sign-out in between): the crashed run's own document is what counts.
    it('restampsAReplayedCrashWithTheCrashedRunsIdentity', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const snapshot: Record<string, Object> = viewEvent(0, 4, {
          'version': '1.0.0',
          'os': { 'name': 'HarmonyOS', 'version': '5.0.1' } as Record<string, Object>,
          'connectivity': { 'status': 'not_connected' } as Record<string, Object>
        });
        const error: Record<string, Object> = RumFeature.withCrashedRunContext(replayedError(), snapshot);
        expect(error['version']).assertEqual('1.0.0');
        expect((error['os'] as Record<string, Object>)['version']).assertEqual('5.0.1');
        expect((error['usr'] as Record<string, Object>)['id']).assertEqual('u-1');
        expect((error['connectivity'] as Record<string, Object>)['status']).assertEqual('not_connected');
        // What identifies the crash itself is untouched.
        expect((error['error'] as Record<string, Object>)['is_crash']).assertEqual(true);
        expect((error['session'] as Record<string, Object>)['id']).assertEqual('session-1');
      });

    it('mergesTheSessionAttributesUnderTheCrashsOwn', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const snapshot: Record<string, Object> = viewEvent(0, 4, {
          'context': { 'channel': 'store', 'crash.memory.rss_kb': 1 } as Record<string, Object>
        });
        const error: Record<string, Object> = RumFeature.withCrashedRunContext(replayedError(), snapshot);
        const context: Record<string, Object> = error['context'] as Record<string, Object>;
        expect(context['channel']).assertEqual('store');
        expect(context['crash.memory.rss_kb']).assertEqual(178544);
      });

    // The crashed run's document is authoritative: a field an event mapper removed from it
    // (a scrubbed user) must not come back from the replaying launch, another user's maybe.
    it('doesNotFillWhatTheCrashedRunsDocumentLacks', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const snapshot: Record<string, Object> = {};
        const full: Record<string, Object> = viewEvent(0, 4);
        for (const key of Object.keys(full)) {
          if (key !== 'usr') {
            snapshot[key] = full[key];
          }
        }
        const error: Record<string, Object> = RumFeature.withCrashedRunContext(replayedError(), snapshot);
        expect(error['usr'] === undefined).assertTrue();
        expect(error['version'] === undefined).assertTrue();
        expect((error['context'] as Record<string, Object>)['crash.memory.rss_kb']).assertEqual(178544);
      });

    // The snapshot goes on to be the crash-marked view document and the source of any further
    // replay: an event mapper editing the error in place must not reach it.
    it('leavesBothInputsUntouched', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0,
      (): void => {
        const snapshot: Record<string, Object> = viewEvent(0, 4, {
          'context': { 'channel': 'store' } as Record<string, Object>
        });
        const error: Record<string, Object> = replayedError();
        const out: Record<string, Object> = RumFeature.withCrashedRunContext(error, snapshot);
        (out['usr'] as Record<string, Object>)['id'] = 'scrubbed';
        (out['context'] as Record<string, Object>)['channel'] = 'scrubbed';
        expect((snapshot['usr'] as Record<string, Object>)['id']).assertEqual('u-1');
        expect((snapshot['context'] as Record<string, Object>)['channel']).assertEqual('store');
        expect((error['usr'] as Record<string, Object>)['id']).assertEqual('u-2');
        expect(error['version']).assertEqual('2.0.0');
      });
  });
}

/** A crash as the replaying launch assembles it: its own version and user, crash-only context. */
function replayedError(): Record<string, Object> {
  return {
    'type': 'error',
    'date': 1700000001000,
    'session': { 'id': 'session-1', 'type': 'user' } as Record<string, Object>,
    'version': '2.0.0',
    'os': { 'name': 'HarmonyOS', 'version': '5.1.0' } as Record<string, Object>,
    'usr': { 'id': 'u-2' } as Record<string, Object>,
    'connectivity': { 'status': 'connected' } as Record<string, Object>,
    'error': { 'is_crash': true, 'message': 'NativeCrash' } as Record<string, Object>,
    'context': { 'crash.memory.rss_kb': 178544 } as Record<string, Object>
  };
}
