import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common, appManager, ApplicationStateChangeCallback } from '@kit.AbilityKit';
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
  state: appManager.ProcessState;

  constructor(state: appManager.ProcessState) {
    this.state = state;
  }

  context(): common.Context {
    const ctx: Record<string, Object> = {
      'filesDir': `/tmp/flashcat-foreground-test-${Date.now()}-${instanceSeq++}`,
      'getApplicationContext': (): Record<string, Object> => {
        return {
          'on': (_type: string, callback: ApplicationStateChangeCallback): void => {
            this.callback = callback;
          },
          'off': (): void => {},
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
      expect(received.indexOf('app_foreground') !== -1).assertTrue();
      core.stop();
    });

    it('aBackgroundLaunchIsNotForeground', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
      const received: string[] = [];
      const app: FakeApp = new FakeApp(appManager.ProcessState.STATE_BACKGROUND);
      const core: FlashcatCore = build(app, received);
      await settle();
      expect(core.isAppInForeground()).assertFalse();
      expect(received.indexOf('app_foreground')).assertEqual(-1);

      (app.callback as ApplicationStateChangeCallback).onApplicationForeground();
      expect(core.isAppInForeground()).assertTrue();
      (app.callback as ApplicationStateChangeCallback).onApplicationBackground();
      expect(core.isAppInForeground()).assertFalse();
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
