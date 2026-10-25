import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  EventWriter, Feature, FeatureEventReceiver, FeatureScope, FlashcatContext, IntakeTarget, SdkCore,
  TrackingConsent, UserInfo
} from '@flashcatcloud/core';
import { CrashConfigurationBuilder, JsCrashPolicy } from '../main/ets/CrashConfiguration';
import { CrashFeature } from '../main/ets/internal/CrashFeature';
import { CrashFingerprint, CrashExceptionParts } from '../main/ets/internal/CrashIncident';
import { FlashcatCrash } from '../main/ets/FlashcatCrash';

const CRASH_TEXT: string = 'Error name:Error\nError message:fatal\nStacktrace:\nat a (b.ets:1:1)';

/** The crash feature's own scope: records the storage commands it is sent. */
class CommandScope implements FeatureScope {
  readonly commands: Array<Record<string, Object>> = [];

  withWriteContext(_callback: (context: FlashcatContext, writer: EventWriter) => void): void {}

  sendEvent(event: Record<string, Object>): void {
    this.commands.push(event);
    event['success'] = true;
  }

  ofType(type: string): Array<Record<string, Object>> {
    return this.commands.filter((c: Record<string, Object>) => c['type'] === type);
  }
}

class FakeCore implements SdkCore {
  readonly name: string = 'test';
  readonly crashScope: CommandScope = new CommandScope();

  registerFeature(_feature: Feature): void {}
  getFeature(featureName: string): FeatureScope | null {
    return featureName === 'crash' ? this.crashScope : null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, _update: Record<string, Object>): void {}
  getContext(): FlashcatContext {
    throw new Error('a keep-alive policy must not snapshot the context');
  }
  getTrackingConsent(): TrackingConsent {
    return TrackingConsent.GRANTED;
  }
  isActive(): boolean {
    return true;
  }
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'token' };
  }
  readSetting(_key: string): string | null {
    return null;
  }
  writeSetting(_key: string, _value: string | null): void {}
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
}

function liveCallback(feature: CrashFeature, callback: string, atMs: number = Date.now()): Record<string, Object> {
  const control: Record<string, Object> = {
    'type': 'js_crash_callback',
    'target': 'crash',
    'callback': callback,
    'text': CRASH_TEXT,
    'timestamp_ms': atMs,
    'report_async': true,
    'should_exit': false
  };
  feature.onReceive(control);
  return control;
}

function featureWith(core: FakeCore, policy: JsCrashPolicy): CrashFeature {
  return new CrashFeature(core, new CrashConfigurationBuilder().setJsCrashPolicy(policy).build());
}

export default function jsCrashLiveCallbackTests(): void {
  describe('JsCrashLiveCallback', (): void => {
    it('reportAndContinueReportsACrashAndKeepsTheProcess',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const control: Record<string, Object> = liveCallback(
          featureWith(core, JsCrashPolicy.REPORT_AND_CONTINUE), 'unhandled');

        expect(control['report_crash']).assertEqual(true);
        expect(control['report_async']).assertEqual(false);
        expect(control['should_exit']).assertEqual(false);
        expect(control['pending_written'] === undefined).assertTrue();
        // No incident to replay next launch: the live report is the only one.
        expect(core.crashScope.ofType('crash_storage_write').length).assertEqual(0);
        // The in-process watcher copy is marked consumed so it is not reported again.
        expect(core.crashScope.ofType('crash_storage_write_consumed').length).assertEqual(1);
      });

    it('reportAndContinueSuppressesTheSecondCallbackOfTheSameCrash',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const feature: CrashFeature = featureWith(new FakeCore(), JsCrashPolicy.REPORT_AND_CONTINUE);
        liveCallback(feature, 'unhandled');
        const second: Record<string, Object> = liveCallback(feature, 'exception');

        expect(second['duplicate']).assertEqual(true);
        expect(second['report_async']).assertEqual(false);
        expect(second['report_crash'] === true).assertFalse();
      });

    it('reportAndContinueCountsACrashOnlyOnExceptionCarries',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const feature: CrashFeature = featureWith(core, JsCrashPolicy.REPORT_AND_CONTINUE);
        const first: Record<string, Object> = liveCallback(feature, 'exception');

        expect(first['report_crash']).assertEqual(true);
        expect(first['report_async']).assertEqual(false);
        expect(first['should_exit']).assertEqual(false);
        expect(core.crashScope.ofType('crash_storage_write_consumed').length).assertEqual(1);
      });

    it('reportAndContinueCountsTheSameCrashAgainWhenItRecurs',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The process survives, so the same fault can really happen again at once.
        const feature: CrashFeature = featureWith(new FakeCore(), JsCrashPolicy.REPORT_AND_CONTINUE);
        liveCallback(feature, 'unhandled');
        liveCallback(feature, 'exception');
        const again: Record<string, Object> = liveCallback(feature, 'unhandled');

        expect(again['duplicate'] === true).assertFalse();
        expect(again['report_crash']).assertEqual(true);
      });

    it('reportAndContinueSuppressesOnUnhandledExceptionThatFollowsOnException',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const feature: CrashFeature = featureWith(new FakeCore(), JsCrashPolicy.REPORT_AND_CONTINUE);
        expect(liveCallback(feature, 'exception')['report_crash']).assertEqual(true);
        const second: Record<string, Object> = liveCallback(feature, 'unhandled');

        expect(second['duplicate']).assertEqual(true);
        expect(second['report_crash'] === true).assertFalse();
      });

    it('aCompletedCallbackPairDoesNotSwallowTheNextFault',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const feature: CrashFeature = featureWith(new FakeCore(), JsCrashPolicy.REPORT_AND_CONTINUE);
        liveCallback(feature, 'unhandled');
        expect(liveCallback(feature, 'exception')['duplicate']).assertEqual(true);
        // A new fault of the same kind, delivered through onException only.
        const next: Record<string, Object> = liveCallback(feature, 'exception');

        expect(next['duplicate'] === true).assertFalse();
        expect(next['report_crash']).assertEqual(true);
      });

    it('reportAndContinueCountsARepeatWhenOnlyOnExceptionFires',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const feature: CrashFeature = featureWith(new FakeCore(), JsCrashPolicy.REPORT_AND_CONTINUE);
        liveCallback(feature, 'exception');
        const again: Record<string, Object> = liveCallback(feature, 'exception');

        expect(again['duplicate'] === true).assertFalse();
        expect(again['report_crash']).assertEqual(true);
      });

    it('aFaultLoopKeepsOneConsumedEntryPerMatchWindow',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const feature: CrashFeature = featureWith(core, JsCrashPolicy.REPORT_AND_CONTINUE);
        for (let i: number = 0; i < 20; i++) {
          liveCallback(feature, 'unhandled');
          liveCallback(feature, 'exception');
        }

        // Every repeat is reported, but one entry already dedups every
        // watcher copy inside the window: the sidecar is written once.
        expect(core.crashScope.ofType('crash_storage_write_consumed').length).assertEqual(1);
      });

    it('otherPoliciesKeepTheOnExceptionFallbackAsAnError',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const control: Record<string, Object> = liveCallback(
          featureWith(new FakeCore(), JsCrashPolicy.OBSERVE_ONLY), 'exception');

        expect(control['report_async']).assertEqual(true);
        expect(control['report_crash'] === true).assertFalse();
      });

    it('observeOnlyStillReportsANonCrashError',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const control: Record<string, Object> = liveCallback(
          featureWith(core, JsCrashPolicy.OBSERVE_ONLY), 'unhandled');

        expect(control['report_async']).assertEqual(true);
        expect(control['report_crash']).assertEqual(false);
        expect(control['should_exit']).assertEqual(false);
        expect(core.crashScope.ofType('crash_storage_write').length).assertEqual(0);
      });

    it('aRepeatPastHalfTheMatchWindowGetsItsOwnConsumedEntry',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The watcher matches on the platform's fault time, which may trail the
        // callback: a repeat 20 s later must not rely on the first entry.
        const core: FakeCore = new FakeCore();
        const feature: CrashFeature = featureWith(core, JsCrashPolicy.REPORT_AND_CONTINUE);
        const t0: number = Date.now();
        liveCallback(feature, 'unhandled', t0);
        liveCallback(feature, 'unhandled', t0 + 10000);
        liveCallback(feature, 'unhandled', t0 + 20000);

        expect(core.crashScope.ofType('crash_storage_write_consumed').length).assertEqual(2);
      });

    it('aHugeExceptionMessageIsBoundedAndStillDeduplicates',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const message: string = 'x'.repeat(2 * 1024 * 1024);
        const stack: string = 'at a (b.ets:1:1)';
        const text: string = `Error name:Error\nError message:${message}\nStacktrace:\n${stack}`;
        const parts: CrashExceptionParts = CrashFingerprint.partsFromText(text);
        expect(parts.message.length <= 4096).assertTrue();
        // The APP_CRASH copy carries the full message; both sides must agree.
        expect(CrashFingerprint.fromText(text)).assertEqual(CrashFingerprint.fromParts('Error', message, stack));
      });

    it('enableBeforeInitializeIsANoOp',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let threw: boolean = false;
        try {
          FlashcatCrash.enable(new CrashConfigurationBuilder().build());
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
      });
  });
}
