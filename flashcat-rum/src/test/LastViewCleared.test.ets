import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import { LastViewSnapshot, LastView, SessionRecord } from '../main/ets/internal/LastViewSnapshot';

function testContext(): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: '1.0.0',
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.7.5',
    device: {
      brand: 'HUAWEI', model: 'Pura', osName: 'HarmonyOS', osVersion: 'NEXT',
      apiVersion: 22, deviceType: 'phone'
    },
    user: {},
    anonymousId: 'anon-device-1',
    network: { status: 'connected', interfaces: ['wifi'] },
    featureContext: {}
  };
}

class CapturingScope implements FeatureScope {
  readonly written: Array<Record<string, Object>> = [];

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    const sink: Array<Record<string, Object>> = this.written;
    const writer: EventWriter = {
      write: (event: Record<string, Object>, _forceFlush?: boolean): boolean => {
        sink.push(event);
        return true;
      }
    };
    callback(testContext(), writer);
  }

  sendEvent(_event: Record<string, Object>): void {}

  views(): Array<Record<string, Object>> {
    return this.written
      .filter((e: Record<string, Object>) => e['type'] === 'view')
      .map((e: Record<string, Object>) => e['view'] as Record<string, Object>);
  }

  /** The newest document of the view named `name`. */
  last(name: string): Record<string, Object> {
    const docs: Array<Record<string, Object>> =
      this.views().filter((v: Record<string, Object>) => v['name'] === name);
    return docs[docs.length - 1];
  }
}

class FakeCore implements SdkCore {
  readonly name: string = 'test';

  registerFeature(_feature: Feature): void {}
  getFeature(_featureName: string): FeatureScope | null {
    return null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, _update: Record<string, Object>): void {}
  getContext(): FlashcatContext {
    return testContext();
  }
  getTrackingConsent(): TrackingConsent {
    return TrackingConsent.GRANTED;
  }
  isActive(): boolean {
    return true;
  }
  isAppInForeground(): boolean {
    return false;
  }
  isAppStateKnown(): boolean {
    return true;
  }

  liveWindowContexts(): Array<Object> {
    return [];
  }
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'ct-123' };
  }
  readSetting(_key: string): string | null {
    return null;
  }
  writeSetting(_key: string, _value: string | null): void {}
}


function raw(kind: string, timestampMs: number, key?: string): RumRawEvent {
  const e: RumRawEvent = { kind, attributes: {}, timestampMs };
  if (key !== undefined) {
    e.key = key;
    e.name = key;
  }
  return e;
}

/** The core's crash storage, as RumFeature wires it: one file, deleted by the core's wipe. */
class SnapshotFile {
  stored: string = '';

  configure(): void {
    LastViewSnapshot.configure((serialized: string): boolean => {
      this.stored = serialized;
      return true;
    }, (): string => this.stored, (): void => {
      this.stored = '';
    });
  }
}

export default function clearedSnapshotTests(): void {
  describe('rum-last-view-cleared', (): void => {
    it('theRunningSessionGoesBackOnFileWithoutItsView', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const file: SnapshotFile = new SnapshotFile();
      file.configure();
      try {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
        const t0: number = Date.now();
        app.handleEvent(raw('startView', t0, 'home'));
        const before: LastView = LastViewSnapshot.read() as LastView;
        expect(before.view !== null).assertTrue(); // control: the view is on file
        const sessionId: string = (before.session as SessionRecord).id;

        file.stored = ''; // the core's wipe deleted the file
        LastViewSnapshot.cleared();

        const after: LastView = LastViewSnapshot.read() as LastView;
        expect((after.session as SessionRecord).id).assertEqual(sessionId);
        expect(after.view === null).assertTrue();
        expect(LastViewSnapshot.current() === null).assertTrue();

        // The session's next view document goes on file at once, not after the write delay.
        app.handleEvent(raw('keepAlive', t0 + 100));
        const next: LastView = LastViewSnapshot.read() as LastView;
        expect(next.view !== null).assertTrue();
        expect((next.session as SessionRecord).id).assertEqual(sessionId);
      } finally {
        LastViewSnapshot.reset();
      }
    });

    it('withNoSessionNothingIsWritten', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const file: SnapshotFile = new SnapshotFile();
      file.configure();
      try {
        LastViewSnapshot.cleared();
        expect(file.stored).assertEqual('');
      } finally {
        LastViewSnapshot.reset();
      }
    });
  });
}
