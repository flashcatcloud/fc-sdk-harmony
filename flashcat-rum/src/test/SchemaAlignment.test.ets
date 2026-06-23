import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { FlashcatContext } from '@flashcatcloud/core';
import { RumEventAssembler } from '../main/ets/internal/assembly/RumEventAssembler';

function testContext(): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: '1.0.0',
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.1.0',
    device: {
      brand: 'HUAWEI',
      model: 'Pura',
      osName: 'HarmonyOS',
      osVersion: 'NEXT',
      apiVersion: 18,
      deviceType: 'phone'
    },
    user: {},
    network: { connectivity: 'wifi' },
    featureContext: {}
  };
}

function record(value: Object | undefined): Record<string, Object> {
  return value as Record<string, Object>;
}

export default function schemaAlignmentTests(): void {
  describe('RumSchemaAlignment', (): void => {
    it('viewUrlUsesViewKeyAndDoesNotLeakInternalAttribute', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const attrs: Record<string, Object> = { 'view.url': 'pages/Home', 'custom': 'keep' };
      const event = RumEventAssembler.view(
        testContext(), 'app-1', 'session-1', 'view-id', 'Home',
        1000, 0, 0, 0, 0, 1, true, attrs);

      const view = record(event['view']);
      const ctx = record(event['context']);
      expect(view['url']).assertEqual('pages/Home');
      expect(view['name']).assertEqual('Home');
      expect(ctx['custom']).assertEqual('keep');
      expect(ctx['view.url']).assertUndefined();
    });

    it('ddSessionPlanIsPopulated', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event = RumEventAssembler.view(
        testContext(), 'app-1', 'session-1', 'view-id', 'Home',
        1000, 0, 0, 0, 0, 1, true, {});

      const dd = record(event['_dd']);
      const session = record(dd['session']);
      expect(session['plan']).assertEqual(1);
      expect(event['source']).assertEqual('harmony');
    });

    it('viewlessErrorOmitsViewObject', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event = RumEventAssembler.error(
        testContext(), 'app-1', 'session-1', undefined, undefined,
        'boom', 'source', 'stack', true, 'unhandled', 1000, {});

      expect(event['view']).assertUndefined();
    });

    it('errorWithViewUsesSchemaViewUrl', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const attrs: Record<string, Object> = { 'view.url': 'pages/Home' };
      const event = RumEventAssembler.error(
        testContext(), 'app-1', 'session-1', 'view-id', 'Home',
        'boom', 'source', 'stack', true, 'unhandled', 1000, attrs);

      const view = record(event['view']);
      expect(view['url']).assertEqual('pages/Home');
      expect(view['name']).assertEqual('Home');
    });
  });
}
