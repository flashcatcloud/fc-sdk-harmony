import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { TrackingConsent } from '../main/ets/privacy/TrackingConsent';
import { FlashcatCore } from '../main/ets/internal/FlashcatCore';
import { FeatureEventReceiver, RUM_FEATURE_NAME } from '../main/ets/api/feature/Feature';
import { UserInfo } from '../main/ets/api/context/FlashcatContext';

let instanceSeq: number = 0;

function fakeContext(): common.Context {
  const ctx: Record<string, Object> = {
    'filesDir': `/tmp/flashcat-user-properties-test-${Date.now()}-${instanceSeq++}`,
    'getApplicationContext': (): Record<string, Object> => {
      return {
        'on': (): void => {},
        'off': (): void => {}
      } as Record<string, Object>;
    }
  };
  return ctx as Object as common.Context;
}

function build(received: string[]): FlashcatCore {
  const core: FlashcatCore = new FlashcatCore(`up-${instanceSeq++}`, fakeContext(),
    new ConfigurationBuilder('token', 'prod').build(), TrackingConsent.GRANTED);
  const receiver: FeatureEventReceiver = {
    onReceive: (event: Record<string, Object>): void => {
      received.push(event['type'] as string);
    }
  };
  core.setEventReceiver(RUM_FEATURE_NAME, receiver);
  core.initialize();
  return core;
}

export default function userPropertiesTests(): void {
  describe('core-add-user-properties', (): void => {
    it('mergesIntoTheExtraInfoAndKeepsTheIdentity', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FlashcatCore = build([]);
      core.setUserInfo({ id: 'u1', name: 'Ann', email: 'ann@example.com', extraInfo: { 'plan': 'free', 'age': 30 } });
      core.addUserProperties({ 'plan': 'pro', 'team': 'blue' });
      const user: UserInfo = core.getContext().user;
      expect(user.id).assertEqual('u1');
      expect(user.name).assertEqual('Ann');
      expect(user.email).assertEqual('ann@example.com');
      const extra: Record<string, Object> = user.extraInfo as Record<string, Object>;
      expect(extra['plan']).assertEqual('pro'); // a key already set is replaced
      expect(extra['age']).assertEqual(30); // the others are kept
      expect(extra['team']).assertEqual('blue');
      // Control: setUserInfo replaces the whole user, so the probe can tell the two apart.
      core.setUserInfo({ id: 'u2', extraInfo: { 'only': true } });
      const replaced: UserInfo = core.getContext().user;
      expect(replaced.name).assertUndefined();
      expect(Object.keys(replaced.extraInfo as Record<string, Object>).join(',')).assertEqual('only');
      core.stop();
    });

    it('withNoUserSetItAddsExtraInfoOnly', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FlashcatCore = build([]);
      core.addUserProperties({ 'plan': 'pro' });
      core.addUserProperties({ 'team': 'blue' });
      const user: UserInfo = core.getContext().user;
      expect(user.id).assertUndefined();
      expect(user.name).assertUndefined();
      expect(user.email).assertUndefined();
      expect(JSON.stringify(user.extraInfo)).assertEqual('{"plan":"pro","team":"blue"}');
      core.stop();
    });

    it('leavesTheHostRecordsAndEarlierSnapshotsAlone', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FlashcatCore = build([]);
      const extra: Record<string, Object> = { 'plan': 'free' };
      const given: UserInfo = { id: 'u1', extraInfo: extra };
      core.setUserInfo(given);
      const before: UserInfo = core.getContext().user;
      const added: Record<string, Object> = { 'team': 'blue' };
      core.addUserProperties(added);
      added['team'] = 'changed after the call';
      expect(JSON.stringify(extra)).assertEqual('{"plan":"free"}');
      expect(JSON.stringify(given)).assertEqual('{"id":"u1","extraInfo":{"plan":"free"}}');
      expect(JSON.stringify(before.extraInfo)).assertEqual('{"plan":"free"}');
      expect((core.getContext().user.extraInfo as Record<string, Object>)['team']).assertEqual('blue');
      core.stop();
    });

    it('drainsRumFirstAndAnnouncesNoUserChange', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const received: string[] = [];
      const core: FlashcatCore = build(received);
      received.length = 0;
      core.addUserProperties({ 'plan': 'pro' });
      expect(received.join(',')).assertEqual('drain_pending');
      core.stop();
    });

    it('ignoresAnExtraInfoThatIsNotAnObject', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FlashcatCore = build([]);
      core.setUserInfo({ id: 'u1', extraInfo: { 'plan': 'free' } });
      core.addUserProperties(null as Object as Record<string, Object>);
      core.addUserProperties(['x'] as Object as Record<string, Object>);
      expect(JSON.stringify(core.getContext().user)).assertEqual('{"id":"u1","extraInfo":{"plan":"free"}}');
      core.stop();
    });
  });
}
