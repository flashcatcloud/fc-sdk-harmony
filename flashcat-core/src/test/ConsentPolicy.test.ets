import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { TrackingConsent } from '../main/ets/privacy/TrackingConsent';
import { FlashcatCore } from '../main/ets/internal/FlashcatCore';

// NOTE (headless runner): Preferences are process-wide per name, so two
// FlashcatCore constructions in one test behave like two app launches sharing
// persisted state — exactly the cross-launch semantics under test.

let instanceSeq: number = 0;

function fakeContext(): common.Context {
  const ctx: Record<string, Object> = {
    'filesDir': `/tmp/flashcat-consent-test-${Date.now()}-${instanceSeq++}`,
    'getApplicationContext': (): Record<string, Object> => {
      return {
        'on': (): void => {},
        'off': (): void => {}
      } as Record<string, Object>;
    }
  };
  return ctx as Object as common.Context;
}

function build(consent: TrackingConsent, background: boolean = false): FlashcatCore {
  const config = new ConfigurationBuilder('token', 'prod').build();
  const core: FlashcatCore =
    new FlashcatCore(`c-${instanceSeq++}`, fakeContext(), config, consent, background);
  core.initialize();
  return core;
}

export default function consentPolicyTests(): void {
  describe('ConsentPolicy', (): void => {
    it('revocationIsStickyAcrossLaunches',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const launch1: FlashcatCore = build(TrackingConsent.GRANTED);
        launch1.setTrackingConsent(TrackingConsent.NOT_GRANTED);
        launch1.stop();

        // Launch 2 passes its usual GRANTED literal — revocation must hold.
        const launch2: FlashcatCore = build(TrackingConsent.GRANTED);
        expect(launch2.getTrackingConsent() === TrackingConsent.NOT_GRANTED).assertTrue();
        launch2.stop();

        // Only an explicit re-grant lifts it.
        const launch3: FlashcatCore = build(TrackingConsent.GRANTED);
        launch3.setTrackingConsent(TrackingConsent.GRANTED);
        launch3.stop();
        const launch4: FlashcatCore = build(TrackingConsent.GRANTED);
        expect(launch4.getTrackingConsent() === TrackingConsent.GRANTED).assertTrue();
        launch4.stop();
      });

    it('literalIsTrustedWhenNotRevoked',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Persisted GRANTED must NOT override a deliberate PENDING literal
        // (the app is the consent authority for anything but revocation).
        const launch1: FlashcatCore = build(TrackingConsent.GRANTED);
        launch1.stop();
        const launch2: FlashcatCore = build(TrackingConsent.PENDING);
        expect(launch2.getTrackingConsent() === TrackingConsent.PENDING).assertTrue();
        launch2.stop();
      });

    it('backgroundProcessReadsPersistedConsentAndNeverWrites',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const main: FlashcatCore = build(TrackingConsent.PENDING);
        main.stop();

        // Extension "process": hardcoded literal must be ignored in favor of
        // the persisted PENDING, and setTrackingConsent must be refused.
        const ext: FlashcatCore = build(TrackingConsent.GRANTED, true);
        expect(ext.getTrackingConsent() === TrackingConsent.PENDING).assertTrue();
        ext.setTrackingConsent(TrackingConsent.GRANTED);
        expect(ext.getTrackingConsent() === TrackingConsent.PENDING).assertTrue();
        ext.stop();

        // The extension wrote nothing back: the main app still sees PENDING.
        const main2: FlashcatCore = build(TrackingConsent.PENDING);
        expect(main2.getTrackingConsent() === TrackingConsent.PENDING).assertTrue();
        main2.stop();
      });

    it('stopDeactivatesTheCore',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FlashcatCore = build(TrackingConsent.GRANTED);
        expect(core.isActive()).assertTrue();
        core.stop();
        expect(core.isActive()).assertFalse();
      });
  });
}
