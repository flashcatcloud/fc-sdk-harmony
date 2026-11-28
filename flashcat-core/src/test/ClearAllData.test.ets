import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { TrackingConsent } from '../main/ets/privacy/TrackingConsent';
import { FlashcatCore } from '../main/ets/internal/FlashcatCore';
import { CrashPendingStore } from '../main/ets/internal/persistence/CrashPendingStore';
import {
  EventWriter, Feature, FeatureEventReceiver, FeatureScope, RUM_FEATURE_NAME
} from '../main/ets/api/feature/Feature';
import { FlashcatContext } from '../main/ets/api/context/FlashcatContext';
import { Flashcat } from '../main/ets/Flashcat';
import { SdkCore } from '../main/ets/api/SdkCore';

let instanceSeq: number = 0;

function fakeContext(): common.Context {
  const ctx: Record<string, Object> = {
    'filesDir': `/tmp/flashcat-clear-all-data-test-${Date.now()}-${instanceSeq++}`,
    'getApplicationContext': (): Record<string, Object> => {
      return {
        'on': (): void => {},
        'off': (): void => {}
      } as Record<string, Object>;
    }
  };
  return ctx as Object as common.Context;
}

function filesDirOf(context: common.Context): string {
  return (context as Object as Record<string, Object>)['filesDir'] as string;
}

class NamedFeature implements Feature {
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }
  onInitialize(): void {}
  onStop(): void {}
}

function build(context: common.Context, consent: TrackingConsent, received: string[] = [],
  background: boolean = false): FlashcatCore {
  const core: FlashcatCore = new FlashcatCore(`cad-${instanceSeq++}`, context,
    new ConfigurationBuilder('token', 'prod').build(), consent, background);
  const receiver: FeatureEventReceiver = {
    onReceive: (event: Record<string, Object>): void => {
      received.push(event['type'] as string);
    }
  };
  core.setEventReceiver(RUM_FEATURE_NAME, receiver);
  core.initialize();
  core.registerFeature(new NamedFeature('rum'));
  core.registerFeature(new NamedFeature('trace'));
  return core;
}

function write(core: FlashcatCore, feature: string, marker: string, forceFlush: boolean): void {
  const scope: FeatureScope | null = core.getFeature(feature);
  if (scope !== null) {
    scope.withWriteContext((_context: FlashcatContext, writer: EventWriter) => {
      writer.write({ 'type': 'action', 'date': Date.now(), 'marker': marker }, forceFlush);
    });
  }
}

/** Everything the feature has on disk: batches (plain and claimed) and the pending buffer. */
function onDisk(context: common.Context, feature: string): string {
  const dir: string = `${filesDirOf(context)}/flashcat/${feature}`;
  let text: string = '';
  const read = (d: string): void => {
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(d);
    } catch (_e) {
      return;
    }
    for (const name of names) {
      if (name === 'pending') {
        read(`${d}/${name}`);
      } else if (name.endsWith('.ndjson') || name.endsWith('.uploading')) {
        text += fileIo.readTextSync(`${d}/${name}`);
      }
    }
  };
  read(dir);
  return text;
}

function crashStore(context: common.Context): (fields: Record<string, Object>) => Record<string, Object> {
  // A second store over the same dir stands in for the crash and RUM features.
  const store: CrashPendingStore = new CrashPendingStore(context, false);
  return (fields: Record<string, Object>): Record<string, Object> => {
    store.onReceive(fields);
    return fields;
  };
}

export default function clearAllDataTests(): void {
  describe('core-clear-all-data', (): void => {
    it('deletesEveryFeatureBatchAndThePendingCrashData', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const context: common.Context = fakeContext();
      const core: FlashcatCore = build(context, TrackingConsent.GRANTED);
      write(core, 'rum', 'rolled-rum', true);
      write(core, 'rum', 'active-rum', false);
      write(core, 'trace', 'rolled-trace', true);
      const storage: (fields: Record<string, Object>) => Record<string, Object> = crashStore(context);
      storage({ 'type': 'crash_storage_write', 'incident_id': 'a1', 'serialized': '{"stack":"s"}' });
      storage({ 'type': 'crash_storage_write_last_view', 'serialized': '{"view":{}}' });
      storage({ 'type': 'crash_storage_write_loop', 'serialized': '[1]' });
      // Control: everything is on disk before the call, except the active batch's
      // event, which is still in the write buffer.
      expect(onDisk(context, 'rum').indexOf('rolled-rum') >= 0).assertTrue();
      expect(onDisk(context, 'rum').indexOf('active-rum') >= 0).assertFalse();
      expect(onDisk(context, 'trace').indexOf('rolled-trace') >= 0).assertTrue();
      expect((storage({ 'type': 'crash_storage_list' })['files'] as Array<Object>).length).assertEqual(1);
      expect((storage({ 'type': 'crash_storage_read_last_view' })['serialized'] as string).length > 0).assertTrue();

      core.clearAllData();

      expect(onDisk(context, 'rum')).assertEqual('');
      expect(onDisk(context, 'trace')).assertEqual('');
      expect((storage({ 'type': 'crash_storage_list' })['files'] as Array<Object>).length).assertEqual(0);
      expect(storage({ 'type': 'crash_storage_read_last_view' })['serialized'] as string).assertEqual('');
      // The crash-loop guard's hashes and timestamps are not collected data: they stay.
      expect(storage({ 'type': 'crash_storage_read_loop' })['serialized'] as string).assertEqual('[1]');
      // stop() writes the write buffer synchronously: the buffered event was dropped too.
      core.stop();
      expect(onDisk(context, 'rum')).assertEqual('');
    });

    it('theSdkKeepsRunningAndKeepsWhatIsRecordedNext', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const context: common.Context = fakeContext();
      const core: FlashcatCore = build(context, TrackingConsent.GRANTED);
      write(core, 'rum', 'before', false);
      core.clearAllData();
      expect(core.isActive()).assertTrue();
      expect(core.getTrackingConsent() === TrackingConsent.GRANTED).assertTrue();
      write(core, 'rum', 'after-active', false);
      write(core, 'rum', 'after-rolled', true);
      const text: string = onDisk(context, 'rum');
      expect(text.indexOf('after-active') >= 0).assertTrue();
      expect(text.indexOf('after-rolled') >= 0).assertTrue();
      expect(text.indexOf('before')).assertEqual(-1);
      core.stop();
    });

    it('deletesEventsBufferedWhileConsentIsPending', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const context: common.Context = fakeContext();
      const core: FlashcatCore = build(context, TrackingConsent.PENDING);
      write(core, 'rum', 'buffered-before', false);
      expect(onDisk(context, 'rum').indexOf('buffered-before') >= 0).assertTrue(); // control
      core.clearAllData();
      expect(onDisk(context, 'rum')).assertEqual('');
      write(core, 'rum', 'buffered-after', false);
      core.setTrackingConsent(TrackingConsent.GRANTED); // migrates the buffer into batches
      const text: string = onDisk(context, 'rum');
      expect(text.indexOf('buffered-after') >= 0).assertTrue();
      expect(text.indexOf('buffered-before')).assertEqual(-1);
      core.stop();
    });

    it('rumWritesItsQueueFirstThenLearnsOfTheClear', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const received: string[] = [];
      const core: FlashcatCore = build(fakeContext(), TrackingConsent.GRANTED, received);
      received.length = 0;
      core.clearAllData();
      expect(received.join(',')).assertEqual('drain_pending,data_cleared');
      core.stop();
    });

    it('isIgnoredInTheDeferredUploadProcess', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // The extension process only uploads; the main process owns the data.
      const context: common.Context = fakeContext();
      const main: FlashcatCore = build(context, TrackingConsent.GRANTED);
      write(main, 'rum', 'from-main', true);
      main.stop();
      const received: string[] = [];
      const ext: FlashcatCore = build(context, TrackingConsent.GRANTED, received, true);
      received.length = 0;
      ext.clearAllData();
      expect(received.length).assertEqual(0);
      expect(onDisk(context, 'rum').indexOf('from-main') >= 0).assertTrue();
      ext.stop();
    });

    it('theNextLaunchIsANewDeviceWhileTheRunningOneKeepsItsId', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // Preferences are process-wide in the headless runner: each core here is a launch.
      const first: FlashcatCore = build(fakeContext(), TrackingConsent.GRANTED);
      const before: string = first.getContext().anonymousId as string;
      first.stop();
      // Control: without a clear, the next launch is the same device.
      const second: FlashcatCore = build(fakeContext(), TrackingConsent.GRANTED);
      expect(second.getContext().anonymousId as string).assertEqual(before);
      second.clearAllData();
      // Android parity: the running process keeps its id, so its session stays one device.
      expect(second.getContext().anonymousId as string).assertEqual(before);
      second.stop();
      const third: FlashcatCore = build(fakeContext(), TrackingConsent.GRANTED);
      const after: string = third.getContext().anonymousId as string;
      expect(after.length > 0).assertTrue();
      expect(after === before).assertFalse();
      third.stop();
      // The new id is stored: the launch after is the same new device.
      const fourth: FlashcatCore = build(fakeContext(), TrackingConsent.GRANTED);
      expect(fourth.getContext().anonymousId as string).assertEqual(after);
      fourth.stop();
    });

    it('aLaterGrantDoesNotStoreTheClearedIdAgain', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const granted: FlashcatCore = build(fakeContext(), TrackingConsent.GRANTED);
      granted.stop();
      const refused: FlashcatCore = build(fakeContext(), TrackingConsent.NOT_GRANTED);
      const cleared: string = refused.getContext().anonymousId as string;
      refused.clearAllData();
      // GRANTED stores the in-memory id when none is stored: not the one just cleared.
      refused.setTrackingConsent(TrackingConsent.GRANTED);
      refused.stop();
      const next: FlashcatCore = build(fakeContext(), TrackingConsent.GRANTED);
      expect((next.getContext().anonymousId as string) === cleared).assertFalse();
      next.stop();
    });

    it('theFacadeActsOnTheNamedInstanceAndIgnoresAMissingOne', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      Flashcat.clearAllData('never-initialized'); // logged, not thrown
      const context: common.Context = fakeContext();
      const name: string = `cad-facade-${instanceSeq++}`;
      const core: SdkCore | null = Flashcat.initialize(context, new ConfigurationBuilder('token', 'prod').build(),
        TrackingConsent.GRANTED, name);
      expect(core !== null).assertTrue();
      (core as FlashcatCore).registerFeature(new NamedFeature('rum'));
      write(core as FlashcatCore, 'rum', 'facade', true);
      expect(onDisk(context, 'rum').indexOf('facade') >= 0).assertTrue();
      Flashcat.clearAllData(name);
      expect(onDisk(context, 'rum')).assertEqual('');
      Flashcat.stopInstance(name);
    });
  });
}
