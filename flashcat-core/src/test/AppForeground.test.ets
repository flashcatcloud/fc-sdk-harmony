import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common, appManager, ApplicationStateChangeCallback, AbilityLifecycleCallback, UIAbility } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { TrackingConsent } from '../main/ets/privacy/TrackingConsent';
import { FlashcatCore } from '../main/ets/internal/FlashcatCore';
import { FeatureEventReceiver, RUM_FEATURE_NAME } from '../main/ets/api/feature/Feature';

let instanceSeq: number = 0;

/** An application context whose state callback the test fires, and whose
 * process probe answers `state` for this process. */
class FakeApp {
  callback: ApplicationStateChangeCallback | null = null;
  abilities: AbilityLifecycleCallback | null = null;
  abilitiesOff: number = 0;
  state: appManager.ProcessState;

  constructor(state: appManager.ProcessState) {
    this.state = state;
  }

  context(): common.Context {
    const ctx: Record<string, Object> = {
      'filesDir': `/tmp/flashcat-foreground-test-${Date.now()}-${instanceSeq++}`,
      'getApplicationContext': (): Record<string, Object> => {
        return {
          'on': (type: string, callback: Object): number => {
            if (type === 'abilityLifecycle') {
              this.abilities = callback as AbilityLifecycleCallback;
              return 7;
            }
            this.callback = callback as ApplicationStateChangeCallback;
            return 0;
          },
          'off': (type: string, id?: number): void => {
            if (type === 'abilityLifecycle' && id === 7) {
              this.abilitiesOff += 1;
            }
          },
          'getRunningProcessInformation': (): Promise<Array<Record<string, Object>>> => {
            const info: Record<string, Object> = { 'pid': process.pid, 'state': this.state };
            return Promise.resolve([info]);
          }
        } as Record<string, Object>;
      }
    };
    return ctx as Object as common.Context;
  }
}

function build(app: FakeApp, received: string[],
  consent: TrackingConsent = TrackingConsent.GRANTED): FlashcatCore {
  const core: FlashcatCore = new FlashcatCore(`fg-${instanceSeq++}`, app.context(),
    new ConfigurationBuilder('token', 'prod').build(), consent, false);
  const receiver: FeatureEventReceiver = {
    onReceive: (event: Record<string, Object>): void => {
      received.push(event['type'] as string);
    }
  };
  core.setEventReceiver(RUM_FEATURE_NAME, receiver);
  core.initialize();
  return core;
}

function settle(): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, 5));
}

export default function appForegroundTests(): void {
  describe('AppForeground', (): void => {
    it('anSdkInitializedInTheForegroundKnowsIt', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // Initialized after the app reached the foreground: no callback comes.
      const received: string[] = [];
      const core: FlashcatCore = build(new FakeApp(appManager.ProcessState.STATE_ACTIVE), received);
      expect(core.isAppInForeground()).assertFalse();
      await settle();
      expect(core.isAppInForeground()).assertTrue();
      expect(received.indexOf('app_foreground_detected') !== -1).assertTrue();
      // Not a return from the background: RUM must not refresh its remote
      // configuration for it, so the app_foreground message is not sent.
      expect(received.indexOf('app_foreground')).assertEqual(-1);
      expect(received.indexOf('app_background')).assertEqual(-1);
      core.stop();
    });

    it('aLaunchingProcessIsNeitherForegroundNorBackground', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // Initialized in onCreate: the probe sees the process still being created.
      const received: string[] = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_CREATE);
      const core: FlashcatCore = build(app, received);
      await settle();
      expect(received.indexOf('app_foreground_detected')).assertEqual(-1);
      expect(received.indexOf('app_background')).assertEqual(-1);
      core.stop();
    });

    it('aBackgroundLaunchIsNotForeground', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const received: string[] = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = build(app, received);
      await settle();
      expect(core.isAppInForeground()).assertFalse();
      expect(received.indexOf('app_foreground_detected')).assertEqual(-1);
      // Announced like a move to the background: the process can be frozen.
      expect(received.filter((t: string) => t === 'app_background').length).assertEqual(1);

      (app.callback as ApplicationStateChangeCallback).onApplicationForeground();
      expect(core.isAppInForeground()).assertTrue();
      (app.callback as ApplicationStateChangeCallback).onApplicationBackground();
      expect(core.isAppInForeground()).assertFalse();
      expect(received.filter((t: string) => t === 'app_background').length).assertEqual(2);
      core.stop();
    });

    it('aStateCallbackOutranksTheStartupProbe', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      // The probe answered "foreground" but the app went away before it landed.
      const received: string[] = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_FOREGROUND);
      const core: FlashcatCore = build(app, received);
      (app.callback as ApplicationStateChangeCallback).onApplicationBackground();
      await settle();
      expect(core.isAppInForeground()).assertFalse();
      core.stop();
    });

    it('backgroundIsAnnouncedBeforeTheFlushWritesTheViews', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const received: string[] = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = build(app, received);
      (app.callback as ApplicationStateChangeCallback).onApplicationForeground();
      received.length = 0;
      (app.callback as ApplicationStateChangeCallback).onApplicationBackground();
      expect(received.join(',')).assertEqual('app_background,keep_alive');
      core.stop();
    });

    it('abilityCreationAndDestructionReachRum', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const received: string[] = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = build(app, received);
      const abilities: AbilityLifecycleCallback = app.abilities as AbilityLifecycleCallback;
      received.length = 0;
      abilities.onAbilityCreate({} as UIAbility);
      abilities.onAbilityForeground({} as UIAbility);
      abilities.onAbilityDestroy({} as UIAbility);
      expect(received.join(',')).assertEqual('ability_created,ability_destroyed');
      core.stop();
      expect(app.abilitiesOff).assertEqual(1);
    });

    it('userAndConsentChangesAreAnnouncedToRum', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const received: string[] = [];
      const core: FlashcatCore =
        build(new FakeApp(appManager.ProcessState.STATE_CREATE), received, TrackingConsent.PENDING);
      core.setUserInfo({ id: 'u1' });
      core.clearUserInfo();
      expect(received.filter((t: string) => t === 'user_changed').length).assertEqual(2);
      core.setTrackingConsent(TrackingConsent.GRANTED);
      expect(received.indexOf('consent_granted') !== -1).assertTrue();
      core.stop();
    });
  });
}
