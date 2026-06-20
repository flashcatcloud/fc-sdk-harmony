import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { RumNavigationTracker } from '../main/ets/internal/RumNavigationTracker';
import { RumEventMapperHolder } from '../main/ets/internal/RumEventMapperHolder';
import { RumAutoInstrumentation } from '../main/ets/internal/RumAutoInstrumentation';
import { RumEventMapper } from '../main/ets/RumTypes';

/** Phase-2 auto-instrumentation + event-mapper pure-logic tests. */
export default function phase2Tests(): void {
  describe('Phase2Navigation', (): void => {
    it('viewKeyPrefersPageId', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumNavigationTracker.viewKeyFor('page_42', 'pages/Detail', 1)).assertEqual('page_42');
    });

    it('viewKeyFallsBackToPathThenIndex', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumNavigationTracker.viewKeyFor('', 'pages/Detail', 1)).assertEqual('pages/Detail');
      expect(RumNavigationTracker.viewKeyFor('', '', 3)).assertEqual('page-3');
    });

    it('viewNamePrefersRouteName', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumNavigationTracker.viewNameFor('Detail', 'pages/PageDetail.ets')).assertEqual('Detail');
    });

    it('viewNameFallsBackToLastPathSegmentWithoutExt', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(RumNavigationTracker.viewNameFor('', 'pages/PageDetail.ets')).assertEqual('PageDetail');
      expect(RumNavigationTracker.viewNameFor('', 'Index')).assertEqual('Index');
      expect(RumNavigationTracker.viewNameFor('', '')).assertEqual('unknown');
    });
  });

  describe('Phase2EventMapper', (): void => {
    it('passesThroughWhenNoMapper', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      RumEventMapperHolder.reset();
      const event: Record<string, Object> = { 'type': 'view', 'x': 1 };
      const out: Record<string, Object> | null = RumEventMapperHolder.apply(event);
      expect(out).assertEqual(event);
    });

    it('appliesRedactionFromMapper', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const mapper: RumEventMapper = (e: Record<string, Object>): Record<string, Object> | null => {
        e['redacted'] = true;
        return e;
      };
      RumEventMapperHolder.configure(mapper);
      const out: Record<string, Object> | null = RumEventMapperHolder.apply({ 'type': 'resource' });
      expect(out !== null).assertTrue();
      if (out !== null) {
        expect(out['redacted']).assertEqual(true);
      }
      RumEventMapperHolder.reset();
    });

    it('dropsEventWhenMapperReturnsNull', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const mapper: RumEventMapper = (_e: Record<string, Object>): Record<string, Object> | null => null;
      RumEventMapperHolder.configure(mapper);
      const out: Record<string, Object> | null = RumEventMapperHolder.apply({ 'type': 'action' });
      expect(out).assertNull();
      RumEventMapperHolder.reset();
    });

    it('containsThrowingMapperAndPassesEventThrough', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const mapper: RumEventMapper = (_e: Record<string, Object>): Record<string, Object> | null => {
        throw new Error('mapper bug');
      };
      RumEventMapperHolder.configure(mapper);
      const event: Record<string, Object> = { 'type': 'error' };
      const out: Record<string, Object> | null = RumEventMapperHolder.apply(event);
      // A throwing mapper must NOT drop the event — it passes through unmodified.
      expect(out).assertEqual(event);
      RumEventMapperHolder.reset();
    });
  });

  describe('Phase2TapGating', (): void => {
    it('tapTrackingDisabledByDefault', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      RumAutoInstrumentation.reset();
      expect(RumAutoInstrumentation.isTapTrackingEnabled()).assertFalse();
      expect(RumAutoInstrumentation.isNavigationTrackingEnabled()).assertFalse();
      // No-op + never-throw when not configured.
      RumAutoInstrumentation.trackTap('anything');
    });
  });
}
