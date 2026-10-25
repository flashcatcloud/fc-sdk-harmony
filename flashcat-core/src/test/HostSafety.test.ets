import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { TrackingConsent } from '../main/ets/privacy/TrackingConsent';
import { FlashcatCore } from '../main/ets/internal/FlashcatCore';
import { EventWriter, Feature, FeatureScope } from '../main/ets/api/feature/Feature';
import { FlashcatContext } from '../main/ets/api/context/FlashcatContext';

let instanceSeq: number = 0;

function fakeContext(): common.Context {
  const ctx: Record<string, Object> = {
    'filesDir': `/tmp/flashcat-host-safety-test-${Date.now()}-${instanceSeq++}`,
    'getApplicationContext': (): Record<string, Object> => {
      return {
        'on': (): void => {},
        'off': (): void => {}
      } as Record<string, Object>;
    }
  };
  return ctx as Object as common.Context;
}

class NoopFeature implements Feature {
  readonly name: string = 'rum';
  onInitialize(): void {}
  onStop(): void {}
}

function write(core: FlashcatCore, event: Record<string, Object>): boolean {
  const scope: FeatureScope | null = core.getFeature('rum');
  let written: boolean = false;
  if (scope !== null) {
    scope.withWriteContext((_context: FlashcatContext, writer: EventWriter) => {
      written = writer.write(event);
    });
  }
  return written;
}

export default function hostSafetyTests(): void {
  describe('HostSafety', (): void => {
    it('anEventThatCannotBeSerializedIsDroppedNotThrown',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FlashcatCore = new FlashcatCore(`hs-${instanceSeq++}`, fakeContext(),
          new ConfigurationBuilder('token', 'prod').build(), TrackingConsent.GRANTED);
        core.initialize();
        core.registerFeature(new NoopFeature());
        // A host attribute holding a cycle: JSON.stringify throws on it.
        const cyclic: Record<string, Object> = {};
        cyclic['self'] = cyclic;
        let threw: boolean = false;
        let written: boolean = true;
        try {
          written = write(core, { 'type': 'action', 'context': cyclic });
        } catch (_e) {
          threw = true;
        }

        expect(threw).assertFalse();
        expect(written).assertFalse();
        // Negative control: an ordinary event is still written.
        expect(write(core, { 'type': 'action', 'context': { 'k': 'v' } })).assertTrue();
        core.stop();
      });
  });
}
