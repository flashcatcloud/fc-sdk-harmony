import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent, Feature, FeatureEventReceiver, UserInfo,
  IntakeTarget
} from '@flashcatcloud/core';
import { resourcePhases } from '../main/ets/internal/assembly/ResourcePhases';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import {
  FIRST_PARTY_HOST_ATTRIBUTE, TRANSFER_TIMING_ATTRIBUTE
} from '../main/ets/internal/scope/RumResourceScope';
import { AppForegroundHistory } from '../main/ets/internal/AppForegroundHistory';

const MS: number = 1e6;

function phase(phases: Record<string, Object>, name: string): Record<string, number> {
  return phases[name] as Record<string, number>;
}

/** The marks of a fresh https request, as the network kit reported them on the emulator. */
function freshHttps(): Record<string, Object> {
  return {
    'namelookup': 1.476, 'connect': 1.939, 'appconnect': 520.172,
    'pretransfer': 520.62, 'starttransfer': 1118.865, 'total': 1120.23
  };
}

function testContext(): FlashcatContext {
  return {
    env: 'prod', variant: '', service: 'svc', version: '1.0.0', bundleId: 'com.example.demo',
    source: 'harmony', sdkVersion: '0.0.0',
    device: {
      brand: 'HUAWEI', model: 'Pura', osName: 'HarmonyOS', osVersion: 'NEXT', apiVersion: 18, deviceType: 'phone'
    },
    user: {}, anonymousId: 'anon', network: { status: 'connected', interfaces: ['wifi'] }, featureContext: {}
  };
}

class CapturingScope implements FeatureScope {
  readonly written: Array<Record<string, Object>> = [];

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    const sink: Array<Record<string, Object>> = this.written;
    callback(testContext(), {
      write: (event: Record<string, Object>, _forceFlush?: boolean): boolean => {
        sink.push(event);
        return true;
      }
    });
  }

  sendEvent(_event: Record<string, Object>): void {}

  resource(): Record<string, Object> {
    const events: Array<Record<string, Object>> = this.written.filter(
      (e: Record<string, Object>): boolean => e['type'] === 'resource');
    return events[0];
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
    return true;
  }
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'token' };
  }
  readSetting(_key: string): string | null {
    return null;
  }
  writeSetting(_key: string, _value: string | null): void {}
}

/** One request through the scope tree, the way RumFeature hands it over. */
function track(start: Record<string, Object>, stop: Record<string, Object>, durationMs: number,
  backgroundBetween: boolean = false): Record<string, Object> {
  AppForegroundHistory.reset();
  const scope: CapturingScope = new CapturingScope();
  const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
  const t0: number = Date.now() - 1000;
  const view: RumRawEvent = { kind: 'startView', key: 'home', name: 'Home', attributes: {}, timestampMs: t0 };
  app.handleEvent(view);
  const startEvent: RumRawEvent = {
    kind: 'startResource', key: 'r1', attributes: start, timestampMs: t0 + 10,
    url: 'https://api.example.com/items', method: 'GET'
  };
  app.handleEvent(startEvent);
  if (backgroundBetween) {
    AppForegroundHistory.enteredBackground();
    AppForegroundHistory.enteredForeground();
  }
  const stopEvent: RumRawEvent = {
    kind: 'stopResource', key: 'r1', attributes: stop, timestampMs: t0 + 10 + durationMs,
    statusCode: 200, sizeBytes: 128, resourceKind: 'native'
  };
  app.handleEvent(stopEvent);
  AppForegroundHistory.reset();
  return scope.resource();
}

/** One request that fails without a response: a network error event. */
function failed(start: Record<string, Object>): Record<string, Object> {
  AppForegroundHistory.reset();
  const scope: CapturingScope = new CapturingScope();
  const app: RumApplicationScope = new RumApplicationScope(scope, new FakeCore(), 'app-1', 100);
  const t0: number = Date.now() - 1000;
  const view: RumRawEvent = { kind: 'startView', key: 'home', name: 'Home', attributes: {}, timestampMs: t0 };
  app.handleEvent(view);
  const startEvent: RumRawEvent = {
    kind: 'startResource', key: 'r1', attributes: start, timestampMs: t0 + 10,
    url: 'https://api.example.com/items', method: 'GET'
  };
  app.handleEvent(startEvent);
  const failEvent: RumRawEvent = {
    kind: 'stopResourceWithError', key: 'r1', attributes: {}, timestampMs: t0 + 50,
    errorMessage: 'request timed out'
  };
  app.handleEvent(failEvent);
  return scope.written.filter((e: Record<string, Object>): boolean => e['type'] === 'error')[0];
}

export default function resourcePhasesTests(): void {
  describe('ResourcePhases', (): void => {
    it('aFreshHttpsRequestHasAllFivePhasesOnOneTimeline',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const phases: Record<string, Object> = resourcePhases(freshHttps(), 1124 * MS);
        expect(phase(phases, 'dns')['start']).assertEqual(0);
        expect(phase(phases, 'dns')['duration']).assertEqual(1476000);
        // connect lasts until the connection is usable: it contains the TLS handshake.
        expect(phase(phases, 'connect')['start']).assertEqual(1476000);
        expect(phase(phases, 'connect')['duration']).assertEqual(520172000 - 1476000);
        expect(phase(phases, 'ssl')['start']).assertEqual(1939000);
        expect(phase(phases, 'ssl')['duration']).assertEqual(520172000 - 1939000);
        expect(phase(phases, 'first_byte')['start']).assertEqual(520620000);
        expect(phase(phases, 'first_byte')['duration']).assertEqual(1118865000 - 520620000);
        expect(phase(phases, 'download')['start']).assertEqual(1118865000);
        expect(phase(phases, 'download')['duration']).assertEqual(1120230000 - 1118865000);
        expect(phases['redirect']).assertUndefined();
      });

    it('sequentialPhasesNeverAddUpToMoreThanTheResource',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const durationNs: number = 1124 * MS;
        const phases: Record<string, Object> = resourcePhases(freshHttps(), durationNs);
        let sum: number = 0;
        for (const name of ['dns', 'connect', 'first_byte', 'download']) {
          const p: Record<string, number> = phase(phases, name);
          sum += p['duration'];
          expect(p['start'] + p['duration'] <= durationNs).assertTrue();
          expect(Number.isInteger(p['start']) && Number.isInteger(p['duration'])).assertTrue();
        }
        expect(sum <= durationNs).assertTrue();
      });

    it('plainHttpHasNoSslAndConnectEndsWithTheTcpConnection',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // libcurl reports appconnect (and redirect) as 0: stages never reached.
        const timing: Record<string, Object> = {
          'namelookup': 0.176, 'connect': 1.616, 'appconnect': 0, 'pretransfer': 1.71, 'starttransfer': 161.015,
          'total': 284.947, 'redirect': 0
        };
        const phases: Record<string, Object> = resourcePhases(timing, 286 * MS);
        expect(phases['ssl']).assertUndefined();
        expect(phase(phases, 'connect')['start']).assertEqual(176000);
        expect(phase(phases, 'connect')['duration']).assertEqual(1616000 - 176000);
        expect(phase(phases, 'dns')['duration']).assertEqual(176000);
        expect(phase(phases, 'first_byte')['duration']).assertEqual(161015000 - 1710000);
        expect(phase(phases, 'download')['duration']).assertEqual(284947000 - 161015000);
      });

    it('aReusedConnectionHasNoDnsAndNoConnect', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // As reported for the second request on a host: connect and appconnect 0,
      // namelookup only the time to find the open connection.
      const timing: Record<string, Object> = {
        'namelookup': 0.024, 'connect': 0, 'appconnect': 0, 'pretransfer': 0.133, 'starttransfer': 323.385,
        'total': 323.569, 'redirect': 0
      };
      const phases: Record<string, Object> = resourcePhases(timing, 327 * MS);
      expect(Object.keys(phases).sort().join(',')).assertEqual('download,first_byte');
      expect(phase(phases, 'first_byte')['start']).assertEqual(133000);
      expect(phase(phases, 'first_byte')['duration']).assertEqual(323385000 - 133000);
    });

    it('aRedirectedRequestReportsOnlyTheRedirect', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // A 100 ms redirect: libcurl sums the marks over both requests, so
      // pretransfer (0.131) is no longer a point on the request's timeline.
      const timing: Record<string, Object> = {
        'namelookup': 0.031, 'connect': 0, 'appconnect': 0, 'pretransfer': 0.131, 'starttransfer': 254.067, 'total': 374.292, 'redirect': 101.676
      };
      const phases: Record<string, Object> = resourcePhases(timing, 376 * MS);
      expect(Object.keys(phases).join(',')).assertEqual('redirect');
      expect(phase(phases, 'redirect')['start']).assertEqual(0);
      expect(phase(phases, 'redirect')['duration']).assertEqual(101676000);
    });

    it('missingOrMalformedMarksLeaveTheirPhasesOut', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(Object.keys(resourcePhases({}, 100 * MS)).length).assertEqual(0);
      expect(Object.keys(resourcePhases({ 'total': 80 }, 100 * MS)).length).assertEqual(0);
      const bad: Record<string, Object> = {
        'namelookup': -1, 'connect': Number.NaN, 'appconnect': '5', 'pretransfer': 2,
        'starttransfer': Number.POSITIVE_INFINITY, 'total': 90
      };
      expect(Object.keys(resourcePhases(bad, 100 * MS)).length).assertEqual(0);
    });

    it('marksOutOfOrderGiveNoPhase', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const timing: Record<string, Object> = { 'pretransfer': 50, 'starttransfer': 40, 'total': 60 };
      const phases: Record<string, Object> = resourcePhases(timing, 100 * MS);
      expect(phases['first_byte']).assertUndefined();
      expect(phase(phases, 'download')['duration']).assertEqual(20 * MS);
    });

    it('aPhasePastTheResourceDurationIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // The kit says the request took 300 ms, the SDK measured 200 ms around it.
      const timing: Record<string, Object> = { 'pretransfer': 1, 'starttransfer': 150, 'total': 300 };
      const phases: Record<string, Object> = resourcePhases(timing, 200 * MS);
      expect(phase(phases, 'first_byte')['duration']).assertEqual(149 * MS);
      expect(phases['download']).assertUndefined();
    });

    it('aPhaseWithinTheDurationsMillisecondIsCutToIt', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // The SDK's whole-millisecond clock read 273 ms for a 273.5 ms transfer.
      const timing: Record<string, Object> = { 'pretransfer': 0.049, 'starttransfer': 152.448, 'total': 273.507 };
      const phases: Record<string, Object> = resourcePhases(timing, 273 * MS);
      const download: Record<string, number> = phase(phases, 'download');
      expect(download['start'] + download['duration']).assertEqual(273 * MS);
    });

    it('theResourceEventCarriesThePhasesAndNotTheMarks', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const stop: Record<string, Object> = { 'custom': 'kept' };
      stop[TRANSFER_TIMING_ATTRIBUTE] = freshHttps();
      const event: Record<string, Object> = track({}, stop, 1124);
      const resource: Record<string, Object> = event['resource'] as Record<string, Object>;
      expect(resource['duration'] as number).assertEqual(1124 * MS);
      for (const name of ['dns', 'connect', 'ssl', 'first_byte', 'download']) {
        expect(resource[name] !== undefined).assertTrue();
      }
      const context: Record<string, Object> = event['context'] as Record<string, Object>;
      expect(context['custom'] as string).assertEqual('kept');
      expect(JSON.stringify(event).indexOf(TRANSFER_TIMING_ATTRIBUTE)).assertEqual(-1);
      expect(JSON.stringify(event).indexOf('starttransfer')).assertEqual(-1);
    });

    it('aRequestSpanningTheBackgroundHasNeitherDurationNorPhases',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const stop: Record<string, Object> = {};
        stop[TRANSFER_TIMING_ATTRIBUTE] = freshHttps();
        const event: Record<string, Object> = track({}, stop, 1124, true);
        const resource: Record<string, Object> = event['resource'] as Record<string, Object>;
        expect(resource['duration']).assertUndefined();
        expect(resource['dns']).assertUndefined();
        expect(resource['download']).assertUndefined();
      });

    it('aRequestWithoutTimingHasNoPhases', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // axios, manual instrumentation, an rcp session that does not collect timing.
      const event: Record<string, Object> = track({}, {}, 120);
      const resource: Record<string, Object> = event['resource'] as Record<string, Object>;
      expect(resource['duration'] as number).assertEqual(120 * MS);
      expect(Object.keys(resource).sort().join(','))
        .assertEqual('duration,id,method,size,status_code,type,url');
    });

    it('aFirstPartyRequestNamesItsProvider', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const start: Record<string, Object> = {};
      start[FIRST_PARTY_HOST_ATTRIBUTE] = 'api.example.com';
      const event: Record<string, Object> = track(start, {}, 50);
      const resource: Record<string, Object> = event['resource'] as Record<string, Object>;
      const provider: Record<string, Object> = resource['provider'] as Record<string, Object>;
      expect(provider['type'] as string).assertEqual('first party');
      expect(provider['domain'] as string).assertEqual('api.example.com');
      expect(JSON.stringify(event).indexOf(FIRST_PARTY_HOST_ATTRIBUTE)).assertEqual(-1);
    });

    it('aFailedFirstPartyRequestNamesItsProvider', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const start: Record<string, Object> = {};
      start[FIRST_PARTY_HOST_ATTRIBUTE] = 'api.example.com';
      const error: Record<string, Object> = failed(start)['error'] as Record<string, Object>;
      expect(error['source'] as string).assertEqual('network');
      const resource: Record<string, Object> = error['resource'] as Record<string, Object>;
      expect(resource['url'] as string).assertEqual('https://api.example.com/items');
      const provider: Record<string, Object> = resource['provider'] as Record<string, Object>;
      expect(provider['type'] as string).assertEqual('first party');
      expect(provider['domain'] as string).assertEqual('api.example.com');
    });

    it('aFailedThirdPartyRequestHasNoProvider', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const error: Record<string, Object> = failed({})['error'] as Record<string, Object>;
      const resource: Record<string, Object> = error['resource'] as Record<string, Object>;
      expect(resource['url'] as string).assertEqual('https://api.example.com/items');
      expect(resource['provider']).assertUndefined();
    });

    it('anyOtherRequestHasNoProvider', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const event: Record<string, Object> = track({}, {}, 50);
      const resource: Record<string, Object> = event['resource'] as Record<string, Object>;
      expect(resource['provider']).assertUndefined();
    });
  });
}
