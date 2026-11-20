import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common, appManager, ApplicationStateChangeCallback, AbilityLifecycleCallback, UIAbility } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
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

/** Like `build`, keeping each event RUM receives whole. */
function buildCapturing(app: FakeApp, events: Array<Record<string, Object>>): FlashcatCore {
  const core: FlashcatCore = new FlashcatCore(`fg-${instanceSeq++}`, app.context(),
    new ConfigurationBuilder('token', 'prod').build(), TrackingConsent.GRANTED, false);
  const receiver: FeatureEventReceiver = {
    onReceive: (event: Record<string, Object>): void => {
      events.push(event);
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
      // Not yet answered: unknown, not background.
      expect(core.isAppStateKnown()).assertFalse();
      await settle();
      expect(core.isAppInForeground()).assertTrue();
      expect(core.isAppStateKnown()).assertTrue();
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
      // Neither said: the state stays unknown until a callback says it.
      expect(core.isAppStateKnown()).assertFalse();
      (app.callback as ApplicationStateChangeCallback).onApplicationForeground();
      expect(core.isAppStateKnown()).assertTrue();
      core.stop();
    });

    it('aBackgroundLaunchIsNotForeground', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const received: string[] = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = build(app, received);
      await settle();
      expect(core.isAppInForeground()).assertFalse();
      // Said: background, not unknown.
      expect(core.isAppStateKnown()).assertTrue();
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

    it('windowStagesReachRumWithTheirAbilitysContext', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const events: Array<Record<string, Object>> = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = buildCapturing(app, events);
      const abilities: AbilityLifecycleCallback = app.abilities as AbilityLifecycleCallback;
      const context: Object = { 'name': 'entry' };
      const ability: UIAbility = { 'context': context } as Record<string, Object> as Object as UIAbility;
      const stage: window.WindowStage = {} as Object as window.WindowStage;
      events.length = 0;
      abilities.onWindowStageCreate(ability, stage);
      abilities.onWindowStageCreate(ability, stage); // the same stage again: one hook
      expect(core.liveWindowContexts().length).assertEqual(1);
      expect(core.liveWindowContexts()[0] === context).assertTrue();
      abilities.onWindowStageDestroy(ability, stage);
      abilities.onAbilityDestroy(ability); // already let go: no second destroy
      expect(events.map((e: Record<string, Object>) => e['type'] as string).join(','))
        .assertEqual('window_stage_created,window_stage_destroyed,ability_destroyed');
      expect(events[0]['context'] === context).assertTrue();
      expect(events[1]['context'] === context).assertTrue();
      expect(core.liveWindowContexts().length).assertEqual(0);
      core.stop();
    });

    it('anAbilityDestroyedWithItsWindowStageStillUpLetsTheWindowGo', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const events: Array<Record<string, Object>> = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = buildCapturing(app, events);
      const abilities: AbilityLifecycleCallback = app.abilities as AbilityLifecycleCallback;
      const ability: UIAbility = { 'context': { 'name': 'entry' } as Object } as Record<string, Object> as Object as UIAbility;
      abilities.onWindowStageCreate(ability, {} as Object as window.WindowStage);
      events.length = 0;
      abilities.onAbilityDestroy(ability);
      expect(events.map((e: Record<string, Object>) => e['type'] as string).join(','))
        .assertEqual('window_stage_destroyed,ability_destroyed');
      expect(core.liveWindowContexts().length).assertEqual(0);
      core.stop();
    });

    it('stoppingTheCoreForgetsTheWindows', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = buildCapturing(app, []);
      const ability: UIAbility = { 'context': { 'name': 'entry' } as Object } as Record<string, Object> as Object as UIAbility;
      (app.abilities as AbilityLifecycleCallback).onWindowStageCreate(ability, {} as Object as window.WindowStage);
      core.stop();
      expect(core.liveWindowContexts().length).assertEqual(0);
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

    it('rumDrainsItsQueueBeforeTheUserOrTheConsentChanges', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const received: string[] = [];
      const core: FlashcatCore =
        build(new FakeApp(appManager.ProcessState.STATE_CREATE), received, TrackingConsent.PENDING);
      received.length = 0;
      core.setUserInfo({ id: 'u1' });
      core.clearUserInfo();
      expect(received.join(',')).assertEqual('drain_pending,user_changed,drain_pending,user_changed');
      received.length = 0;
      core.setTrackingConsent(TrackingConsent.PENDING);
      expect(received.length).assertEqual(0);
      core.setTrackingConsent(TrackingConsent.GRANTED);
      expect(received[0]).assertEqual('drain_pending');
      expect(received.indexOf('consent_granted') > 0).assertTrue();
      core.stop();
    });
  });
}
