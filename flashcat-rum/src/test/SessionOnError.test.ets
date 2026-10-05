import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import {
  WithheldEventBuffer, computeReleaseDelay, WITHHELD_BUFFER_BYTES_LIMIT, WITHHELD_BUFFER_EVENTS_LIMIT,
  WITHHELD_BUFFER_VIEWS_LIMIT, WITHHELD_BUFFER_DURATION_MS, WITHHELD_BUFFER_RELEASE_MAX_DELAY_MS
} from '../main/ets/internal/scope/WithheldEvents';
import { RemoteConfigStore, RemoteConfigValues } from '../main/ets/internal/remoteconfig/RemoteConfigStore';
import { RemoteConfigController, RemoteConfigChangeListener } from '../main/ets/internal/remoteconfig/RemoteConfigController';
import { RemoteConfigFetcher, RemoteConfigResponse } from '../main/ets/internal/remoteconfig/RemoteConfigFetcher';
import { RumEventMapperHolder } from '../main/ets/internal/RumEventMapperHolder';
import { LastViewSnapshot } from '../main/ets/internal/LastViewSnapshot';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { BeforeSamplingContext } from '../main/ets/RumTypes';
import { RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumErrorSource } from '../main/ets/RumTypes';

const MIN_15: number = 15 * 60 * 1000;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

function testContext(): FlashcatContext {
  return {
    env: 'prod',
    variant: '',
    service: 'svc',
    version: '1.0.0',
    bundleId: 'com.example.demo',
    source: 'harmony',
    sdkVersion: '0.6.0',
    device: {
      brand: 'HUAWEI', model: 'Pura', osName: 'HarmonyOS', osVersion: 'NEXT',
      apiVersion: 18, deviceType: 'phone'
    },
    user: {},
    anonymousId: 'anon-device-1',
    network: { status: 'connected', interfaces: ['wifi'] },
    featureContext: {}
  };
}

class FakeCore implements SdkCore {
  readonly name: string = 'test';
  readonly featureContext: Record<string, Object> = {};
  readonly settings: Map<string, string> = new Map<string, string>();
  consent: TrackingConsent = TrackingConsent.GRANTED;

  registerFeature(_feature: Feature): void {}
  getFeature(_featureName: string): FeatureScope | null {
    return null;
  }
  setEventReceiver(_featureName: string, _receiver: FeatureEventReceiver): void {}
  removeEventReceiver(_featureName: string): void {}
  updateFeatureContext(_featureName: string, update: Record<string, Object>): void {
    for (const k of Object.keys(update)) {
      this.featureContext[k] = update[k];
    }
  }
  getContext(): FlashcatContext {
    return testContext();
  }
  getTrackingConsent(): TrackingConsent {
    return this.consent;
  }
  isActive(): boolean {
    return true;
  }
  setUserInfo(_user: UserInfo): void {}
  clearUserInfo(): void {}
  getIntakeTarget(): IntakeTarget {
    return { host: 'https://intake.example.com', clientToken: 'token' };
  }
  readSetting(key: string): string | null {
    const value: string | undefined = this.settings.get(key);
    return value === undefined ? null : value;
  }
  writeSetting(key: string, value: string | null): void {
    if (value === null) {
      this.settings.delete(key);
    } else {
      this.settings.set(key, value);
    }
  }
}

/** Records what reaches storage, and which writes asked for an upload. */
class CapturingScope implements FeatureScope {
  readonly written: Array<Record<string, Object>> = [];
  readonly flushes: boolean[] = [];
  /** Storage's per-event size limit: a larger event is refused, as the core's persistence refuses it. */
  rejectAbove: number = Number.MAX_SAFE_INTEGER;

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    callback(testContext(), new CapturingWriter(this));
  }

  sendEvent(_event: Record<string, Object>): void {}

  ofType(type: string): Array<Record<string, Object>> {
    return this.written.filter((e: Record<string, Object>) => e['type'] === type);
  }
}

class CapturingWriter implements EventWriter {
  private readonly scope: CapturingScope;

  constructor(scope: CapturingScope) {
    this.scope = scope;
  }

  write(event: Record<string, Object>, forceFlush?: boolean): boolean {
    if (JSON.stringify(event).length > this.scope.rejectAbove) {
      return false;
    }
    this.scope.written.push(event);
    this.scope.flushes.push(forceFlush === true);
    return true;
  }
}

class SilentFetcher implements RemoteConfigFetcher {
  fetch(_url: string, _ifNoneMatch: string | null): Promise<RemoteConfigResponse> {
    return Promise.resolve({ code: 304, body: '', etag: null } as RemoteConfigResponse);
  }
}

function raw(kind: string, timestampMs: number, key?: string): RumRawEvent {
  const e: RumRawEvent = { kind, attributes: {}, timestampMs };
  if (key !== undefined) {
    e.key = key;
  }
  return e;
}

function startView(app: RumApplicationScope, atMs: number, key: string = 'home'): void {
  const e: RumRawEvent = raw('startView', atMs, key);
  e.name = key;
  app.handleEvent(e);
}

function addError(app: RumApplicationScope, atMs: number, message: string = 'boom'): void {
  const e: RumRawEvent = raw('addError', atMs);
  e.errorMessage = message;
  e.errorSource = 'source';
  app.handleEvent(e);
}

function addAction(app: RumApplicationScope, atMs: number, name: string = 'tap'): void {
  const e: RumRawEvent = raw('addAction', atMs);
  e.name = name;
  e.actionType = 'tap';
  e.actionId = `${name}-${atMs}`;
  app.handleEvent(e);
}

function sessionOf(event: Record<string, Object>): Record<string, Object> {
  return event['session'] as Record<string, Object>;
}

function sampleRateOf(event: Record<string, Object>): Object | undefined {
  const dd: Record<string, Object> = event['_dd'] as Record<string, Object>;
  const configuration: Record<string, Object> | undefined = dd['configuration'] as Record<string, Object>;
  return configuration === undefined ? undefined : configuration['session_sample_rate'];
}

function newStore(core: FakeCore): RemoteConfigStore {
  return new RemoteConfigStore(core, RemoteConfigStore.buildStoreKey(core.getContext(), 'https://intake.example.com', 'app-1'));
}

/** A scope that keeps only the sessions that error (rate 0 + `sessionOnError`). */
function onErrorApp(scope: CapturingScope, core: FakeCore = new FakeCore(),
  store: RemoteConfigStore | null = null): RumApplicationScope {
  return new RumApplicationScope(scope, core, 'app-1', 0, store, null, null, true);
}

function resource(status: number): Record<string, Object> {
  return {
    'type': 'resource',
    'view': { 'id': 'v1' } as Record<string, Object>,
    'resource': { 'status_code': status } as Record<string, Object>
  };
}

function statusOf(event: Record<string, Object>): number {
  return (event['resource'] as Record<string, Object>)['status_code'] as number;
}

function detail(type: string, viewId: string = 'v1', tag: string = ''): Record<string, Object> {
  return { 'type': type, 'view': { 'id': viewId } as Record<string, Object>, 'tag': tag };
}

function view(viewId: string, dateMs: number): Record<string, Object> {
  return { 'type': 'view', 'date': dateMs, 'view': { 'id': viewId } as Record<string, Object> };
}

/** Holds `event` as the write path would, with the size the test wants it charged for. */
function hold(buffer: WithheldEventBuffer, event: Record<string, Object>, bytes: number, nowMs: number): boolean {
  return buffer.hold(event, JSON.stringify(event), bytes, nowMs);
}

function released(buffer: WithheldEventBuffer, nowMs: number): Array<Record<string, Object>> {
  const scope: CapturingScope = new CapturingScope();
  scope.withWriteContext((_context: FlashcatContext, writer: EventWriter) => {
    buffer.release(writer, nowMs);
  });
  return scope.written;
}

export default function sessionOnErrorTests(): void {
  describe('rum-session-on-error-draw', (): void => {
    it('withholdsEverythingFromASessionThatNeverErrors',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core);
        const now: number = Date.now();
        startView(app, now);
        addAction(app, now + 10);
        app.stopCurrentSession(now + 20);
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(0);
        // Tracked as far as the crash module is concerned: a crash in it is still reported.
        expect(core.featureContext['session.sampled']).assertEqual(true);
      });

    it('releasesTheMinuteBeforeTheErrorInOrderWithMarkers',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const now: number = Date.now();
        startView(app, now, 'first');
        addAction(app, now + 10, 'a1');
        startView(app, now + 20, 'second');
        addAction(app, now + 30, 'a2');
        addError(app, now + 40);
        expect(scope.written.length).assertEqual(0); // behind the jitter
        app.releaseScheduledWithheld(); // the app is flushed: what was earned leaves now

        const types: string[] = scope.written.map((e: Record<string, Object>) => e['type'] as string);
        // Views oldest first, then the error, then the rest oldest first.
        expect(types.join(',')).assertEqual('view,view,error,action,action');
        const views: Array<Record<string, Object>> = scope.ofType('view');
        expect((views[0]['view'] as Record<string, Object>)['name']).assertEqual('first');
        for (const v of views) {
          expect(sessionOf(v)['sampled_for_error']).assertEqual(true);
          expect(sampleRateOf(v)).assertEqual(0);
        }
        // Markers ride on views only.
        expect(sessionOf(scope.ofType('error')[0])['sampled_for_error']).assertUndefined();
        // One batch, uploaded once the last event is in.
        expect(scope.flushes[scope.flushes.length - 1]).assertTrue();

        // From now on the session writes straight through.
        addAction(app, now + 50, 'after');
        expect(scope.ofType('action').length).assertEqual(3);
      });

    it('aSampledSessionCarriesNoMarkerAndItsDrawnRate',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(
          scope, new FakeCore(), 'app-1', 100, null, null, null, true);
        startView(app, Date.now());
        const v: Record<string, Object> = scope.ofType('view')[0];
        expect(sessionOf(v)['sampled_for_error']).assertUndefined();
        expect(sampleRateOf(v)).assertEqual(100);
      });

    it('reportsRateZeroWhateverRateTheSessionLostItsDrawAt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Rate 1 + switch: nearly every session is an on-error one, and each must
        // stand for itself, not for a hundred sessions.
        let found: boolean = false;
        for (let attempt: number = 0; attempt < 20 && !found; attempt++) {
          const scope: CapturingScope = new CapturingScope();
          const app: RumApplicationScope = new RumApplicationScope(
            scope, new FakeCore(), 'app-1', 1, null, null, null, true);
          startView(app, Date.now());
          if (scope.written.length > 0) {
            continue; // won the 1% draw
          }
          addError(app, Date.now());
          app.releaseScheduledWithheld();
          const v: Record<string, Object> = scope.ofType('view')[0];
          expect(sampleRateOf(v)).assertEqual(0);
          expect(sessionOf(v)['sampled_for_error']).assertEqual(true);
          found = true;
        }
        expect(found).assertTrue();
      });

    it('isOffByDefaultAndForAnUnsampledSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(new RumConfigurationBuilder('app').build().sessionOnError).assertFalse();
        expect(new RumConfigurationBuilder('app').setSessionOnError(true).build().sessionOnError).assertTrue();
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0);
        startView(app, Date.now());
        addError(app, Date.now());
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(0);
        expect(core.featureContext['session.sampled']).assertEqual(false);
      });

    it('aRateTheHookSetsToZeroSwitchesItOff',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const zero: (context: BeforeSamplingContext) => number | undefined =
          (_context: BeforeSamplingContext): number | undefined => 0;
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(
          scope, new FakeCore(), 'app-1', 50, null, zero, null, true);
        startView(app, Date.now());
        addError(app, Date.now());
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(0);

        // Negative control: a hook that leaves the rate alone keeps the switch.
        const untouched: (context: BeforeSamplingContext) => number | undefined =
          (_context: BeforeSamplingContext): number | undefined => undefined;
        const kept: CapturingScope = new CapturingScope();
        const app2: RumApplicationScope = new RumApplicationScope(
          kept, new FakeCore(), 'app-1', 0, null, untouched, null, true);
        startView(app2, Date.now());
        addError(app2, Date.now());
        app2.releaseScheduledWithheld();
        expect(kept.ofType('error').length).assertEqual(1);
      });

    it('releasesOnItsOwnAfterTheSessionJitter',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        addError(app, Date.now());
        const delay: number = computeReleaseDelay(app.getCurrentSessionId() as string);
        expect(scope.written.length).assertEqual(0);
        await sleep(delay + 150);
        expect(scope.ofType('view').length).assertEqual(1);
        expect(scope.ofType('error').length).assertEqual(1);
      });
  });

  describe('rum-session-on-error-triggers', (): void => {
    it('anErrorTheMapperDropsReleasesNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> | null =>
          event['type'] === 'error' ? null : event);
        try {
          const scope: CapturingScope = new CapturingScope();
          const app: RumApplicationScope = onErrorApp(scope);
          startView(app, Date.now());
          addError(app, Date.now());
          app.releaseScheduledWithheld();
          app.stopCurrentSession(Date.now());
          expect(scope.written.length).assertEqual(0);
        } finally {
          RumEventMapperHolder.reset();
        }
        // Negative control: the same session shape with the error kept releases.
        const kept: CapturingScope = new CapturingScope();
        const app2: RumApplicationScope = onErrorApp(kept);
        startView(app2, Date.now());
        addError(app2, Date.now());
        app2.stopCurrentSession(Date.now());
        expect(kept.ofType('error').length).assertEqual(1);
      });

    it('aMapperThatEndsTheSessionOnItsErrorStillReleasesIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        // An app that ends the session from inside its mapper, say on an
        // authentication error, and keeps the error.
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> | null => {
          if (event['type'] === 'error') {
            app.stopCurrentSession(Date.now());
          }
          return event;
        });
        try {
          const now: number = Date.now();
          startView(app, now);
          addAction(app, now + 1);
          addError(app, now + 2);
          expect(app.getCurrentSessionId()).assertUndefined();
          // Ended with an error on record: released at once, history included.
          expect(scope.ofType('error').length).assertEqual(1);
          expect(scope.ofType('action').length).assertEqual(1);
          // The view's final document, then the one counting the error — written
          // straight through once released, as a collected session's would be.
          expect(scope.written[0]['type']).assertEqual('view');
          expect(scope.ofType('view').length).assertEqual(2);
        } finally {
          RumEventMapperHolder.reset();
        }
      });

    it('aFailedRequestIsAnErrorThatReleases',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const now: number = Date.now();
        startView(app, now);
        app.handleEvent(raw('startResource', now, 'r1'));
        const failed: RumRawEvent = raw('stopResourceWithError', now + 5, 'r1');
        failed.errorMessage = 'timeout';
        app.handleEvent(failed);
        app.releaseScheduledWithheld();
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('aCrashReleasesAtOnceWithTheCountingDocument',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        addAction(app, Date.now());
        app.handleEvent(raw('markCrash', Date.now()));
        // Synchronous: no jitter, the process is about to exit.
        const views: Array<Record<string, Object>> = scope.ofType('view');
        expect(views.length).assertEqual(1);
        const crash: Record<string, Object> = (views[0]['view'] as Record<string, Object>)['crash'] as Record<string, Object>;
        expect(crash['count']).assertEqual(1);
        expect(scope.ofType('action').length).assertEqual(1);
      });

    it('setForcedSessionReleasesWithoutAnError',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        const id: string = app.getCurrentSessionId() as string;
        app.forceSession(Date.now());
        expect(app.getCurrentSessionId()).assertEqual(id); // kept, not replaced
        expect(scope.ofType('view').length).assertEqual(1);
        expect(sessionOf(scope.ofType('view')[0])['sampled_for_error']).assertEqual(true);
        addAction(app, Date.now());
        expect(scope.ofType('action').length).assertEqual(1);
      });

    it('aFlushSendsAScheduledReleaseAtOnceAndTheTimerAddsNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        addError(app, Date.now());
        const delay: number = computeReleaseDelay(app.getCurrentSessionId() as string);
        expect(scope.written.length).assertEqual(0); // scheduled, waiting on its jitter
        app.releaseScheduledWithheld();
        const released: number = scope.written.length;
        expect(released).assertEqual(2); // view + error, without waiting
        await sleep(delay + 150);
        expect(scope.written.length).assertEqual(released); // the cancelled timer wrote nothing more
      });

    it('aSessionThatExpiresWhileItsReleaseWaitsIsReleasedOnceAtExpiry',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const t0: number = Date.now();
        startView(app, t0);
        addError(app, t0 + 1);
        const first: string = app.getCurrentSessionId() as string;
        const delay: number = computeReleaseDelay(first);
        expect(scope.written.length).assertEqual(0);
        startView(app, t0 + MIN_15 + 1000, 'later'); // detects the expiry
        const atExpiry: number = scope.written.length;
        expect(scope.ofType('error').length).assertEqual(1);
        for (const e of scope.written) {
          expect(sessionOf(e)['id']).assertEqual(first); // the new session holds its own
        }
        await sleep(delay + 150);
        expect(scope.written.length).assertEqual(atExpiry);
      });

    it('aCrashThatDetectsExpiryReleasesTheExpiredSessionAtOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const t0: number = Date.now();
        startView(app, t0);
        addAction(app, t0 + 1);
        const first: string = app.getCurrentSessionId() as string;
        // Backgrounded past the inactivity limit, then the process dies of a crash.
        app.handleEvent(raw('markCrash', t0 + MIN_15 + 1000));
        const views: Array<Record<string, Object>> = scope.ofType('view');
        expect(views.length).assertEqual(1);
        const crash: Record<string, Object> = (views[0]['view'] as Record<string, Object>)['crash'] as Record<string, Object>;
        expect(crash['count']).assertEqual(1);
        expect(scope.ofType('action').length).assertEqual(1);
        for (const e of scope.written) {
          expect(sessionOf(e)['id']).assertEqual(first);
        }
      });

    it('aKeepAliveThatDetectsExpiryThrowsAnUnerroredSessionAway',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const t0: number = Date.now();
        startView(app, t0);
        addAction(app, t0 + 1);
        const first: string = app.getCurrentSessionId() as string;
        // The flush on backgrounding, after the session sat idle past its limit.
        app.handleEvent(raw('keepAlive', t0 + MIN_15 + 1000));
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(0);
        // The next session's error releases only its own events.
        addError(app, t0 + MIN_15 + 2000);
        app.releaseScheduledWithheld();
        expect(scope.ofType('error').length).assertEqual(1);
        expect(scope.ofType('action').length).assertEqual(0);
        for (const e of scope.written) {
          expect(sessionOf(e)['id'] === first).assertFalse();
        }
      });

    it('aFlushKeepsWhatHasNotYetEarnedItsRelease',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const now: number = Date.now();
        startView(app, now);
        addAction(app, now + 1, 'before-background');
        app.releaseScheduledWithheld(); // backgrounded, no error yet
        expect(scope.written.length).assertEqual(0);
        addError(app, now + 2);
        app.releaseScheduledWithheld();
        // The history from before the background is still there.
        expect(scope.ofType('action').length).assertEqual(1);
      });
  });

  describe('rum-session-on-error-viewless', (): void => {
    it('releasesAnErrorRaisedBeforeAnyView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        addError(app, Date.now(), 'before any view');
        app.releaseScheduledWithheld();
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('releasesTheErrorWhenTheMapperDroppedEveryViewDocument',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> | null =>
          event['type'] === 'view' ? null : event);
        try {
          const scope: CapturingScope = new CapturingScope();
          const app: RumApplicationScope = onErrorApp(scope);
          startView(app, Date.now());
          addAction(app, Date.now());
          addError(app, Date.now());
          app.releaseScheduledWithheld();
          expect(scope.ofType('view').length).assertEqual(0);
          expect(scope.ofType('error').length).assertEqual(1);
          expect(scope.ofType('action').length).assertEqual(1);
        } finally {
          RumEventMapperHolder.reset();
        }
      });

    it('releasesDetailsWhoseViewIsNotHeld',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        hold(buffer, detail('error', 'unknown-view', 'error'), 10, now);
        hold(buffer, detail('action', 'unknown-view', 'act'), 10, now);
        const out: Array<Record<string, Object>> = released(buffer, now);
        expect(out.map((e: Record<string, Object>) => e['tag'] as string).join(',')).assertEqual('error,act');
      });

    it('stillDropsAViewLeftWithoutDetail',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        hold(buffer, view('old', now), 50, now);
        hold(buffer, view('current', now + 1), 50, now + 1);
        hold(buffer, detail('error', 'current', 'error'), 10, now + 2);
        const out: Array<Record<string, Object>> = released(buffer, now + 3);
        const ids: string[] = out.filter((e: Record<string, Object>) => e['type'] === 'view')
          .map((e: Record<string, Object>) => (e['view'] as Record<string, Object>)['id'] as string);
        expect(ids.join(',')).assertEqual('current');
      });
  });

  describe('rum-session-on-error-stop', (): void => {
    it('sdkStopCancelsAReleaseStillWaitingOnItsJitter',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const delays: number[] = [];
        const scopes: CapturingScope[] = [];
        for (const stop of [true, false]) {
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = new DefaultRumMonitor(new FakeCore(), scope,
            new RumConfigurationBuilder('app-1').setSessionSampleRate(0).setSessionOnError(true).build());
          monitor.stopKeepAlive();
          monitor.startView('home', 'home');
          monitor.addError('boom', RumErrorSource.SOURCE);
          monitor.getCurrentSessionId((id: string | undefined): void => {
            delays.push(computeReleaseDelay(id as string));
          });
          if (stop) {
            monitor.stopWithheld(); // what RumFeature.onStop does
          }
          scopes.push(scope);
        }
        await sleep(Math.max(delays[0], delays[1]) + 150);
        expect(scopes[0].written.length).assertEqual(0);
        // Negative control: the same session without the stop releases on its timer.
        expect(scopes[1].ofType('error').length).assertEqual(1);
      });
  });

  describe('rum-session-on-error-discard', (): void => {
    it('anExpiredSessionThatNeverErredIsThrownAwayWithItsStragglers',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const t0: number = Date.now();
        startView(app, t0);
        app.handleEvent(raw('startResource', t0 + 1, 'slow'));
        const first: string = app.getCurrentSessionId() as string;
        // Inactivity expiry: the next event mints a new session.
        startView(app, t0 + MIN_15 + 1000, 'later');
        expect(app.getCurrentSessionId() === first).assertFalse();
        // The slow request finishes after its session was discarded: dropped.
        const done: RumRawEvent = raw('stopResource', t0 + MIN_15 + 2000, 'slow');
        done.statusCode = 200;
        app.handleEvent(done);
        // The new session errors: only its own events are released.
        addError(app, t0 + MIN_15 + 3000);
        app.releaseScheduledWithheld();
        for (const e of scope.written) {
          expect(sessionOf(e)['id'] === first).assertFalse();
        }
        expect(scope.ofType('resource').length).assertEqual(0);
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('aStragglerOfAReleasedSessionStillGoesOut',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const t0: number = Date.now();
        startView(app, t0);
        app.handleEvent(raw('startResource', t0 + 1, 'slow'));
        addError(app, t0 + 2);
        const first: string = app.getCurrentSessionId() as string;
        startView(app, t0 + MIN_15 + 1000, 'later'); // expiry releases the errored session at once
        expect(scope.ofType('error').length).assertEqual(1);
        const done: RumRawEvent = raw('stopResource', t0 + MIN_15 + 2000, 'slow');
        done.statusCode = 200;
        app.handleEvent(done);
        const resources: Array<Record<string, Object>> = scope.ofType('resource');
        expect(resources.length).assertEqual(1);
        expect(sessionOf(resources[0])['id']).assertEqual(first);
      });

    it('stopSessionDiscardsAnUnerroredSessionAndReleasesAnErroredOne',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        app.stopCurrentSession(Date.now());
        expect(scope.written.length).assertEqual(0);
        addAction(app, Date.now()); // mints the next session
        addError(app, Date.now());
        app.stopCurrentSession(Date.now()); // released at once, no jitter to wait out
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('aRefusedConsentDropsWhatWasHeld',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core);
        const now: number = Date.now();
        startView(app, now);
        addAction(app, now + 1, 'consented');
        core.consent = TrackingConsent.NOT_GRANTED;
        addAction(app, now + 2, 'refused');
        core.consent = TrackingConsent.GRANTED;
        addError(app, now + 3);
        app.releaseScheduledWithheld();
        // Nothing collected before or during the refusal survives it.
        expect(scope.ofType('action').length).assertEqual(0);
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('aRefusedConsentForgetsWhatWasHeldEvenWhenNothingIsWrittenMeanwhile',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core);
        const now: number = Date.now();
        startView(app, now);
        addAction(app, now + 1, 'consented');
        // Refused and granted again with no RUM write in between: only the
        // core's announcement can tell the session.
        core.consent = TrackingConsent.NOT_GRANTED;
        app.forgetWithheld();
        core.consent = TrackingConsent.GRANTED;
        addError(app, now + 2);
        app.releaseScheduledWithheld();
        expect(scope.ofType('action').length).assertEqual(0);
        expect(scope.ofType('error').length).assertEqual(1);
        // The view is released as the error's container, from its post-consent document only.
        expect(scope.ofType('view').length).assertEqual(1);
      });

    it('aRefusedConsentForgetsTheErrorThatHadEarnedARelease',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core);
        const now: number = Date.now();
        startView(app, now);
        addError(app, now + 1);
        const delay: number = computeReleaseDelay(app.getCurrentSessionId() as string);
        core.consent = TrackingConsent.NOT_GRANTED;
        app.forgetWithheld();
        core.consent = TrackingConsent.GRANTED;
        // The error went with the refusal: the session is back to waiting for one.
        addAction(app, now + 2, 'after');
        await sleep(delay + 150);
        expect(scope.written.length).assertEqual(0); // the cancelled timer released nothing
        app.stopCurrentSession(now + 3);
        expect(scope.written.length).assertEqual(0); // ended without an error on record
      });
  });

  describe('rum-session-on-error-buffer', (): void => {
    it('evictsSuccessfulRequestsFirstAndKeepsTheFirstError',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        const now: number = 1_000_000;
        hold(buffer, view('v1', now), 50, now);
        const first: Record<string, Object> = detail('error', 'v1', 'first-error');
        hold(buffer, first, 2000, now);
        hold(buffer, resource(500), 4000, now);
        for (let i: number = 0; i < 40; i++) {
          hold(buffer, resource(200), 2000, now + i);
        }
        hold(buffer, detail('action', 'v1', 'act'), 2000, now + 50);
        const out: Array<Record<string, Object>> = released(buffer, now + 60);
        expect(out.findIndex((e: Record<string, Object>) => e['tag'] === 'first-error')).assertEqual(1); // right behind the view
        // The failed request and the action outlive the successful requests,
        // which give up exactly what the 64 KiB budget needs: (65536 - 8000) / 2000.
        expect(out.filter((e: Record<string, Object>) => e['tag'] === 'act').length).assertEqual(1);
        expect(out.filter((e: Record<string, Object>) => e['type'] === 'resource' && statusOf(e) === 500).length)
          .assertEqual(1);
        expect(out.filter((e: Record<string, Object>) => e['type'] === 'resource' && statusOf(e) === 200).length)
          .assertEqual(Math.floor((WITHHELD_BUFFER_BYTES_LIMIT - 8000) / 2000));
      });

    it('dropsTheNewestErrorWhenOnlyErrorsAreLeft',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        const now: number = 1_000_000;
        hold(buffer, view('v1', now), 50, now);
        for (let i: number = 0; i < WITHHELD_BUFFER_EVENTS_LIMIT + 5; i++) {
          hold(buffer, detail('error', 'v1', `e${i}`), 10, now + i);
        }
        const out: Array<Record<string, Object>> = released(buffer, now + 300);
        const errors: Array<Record<string, Object>> = out.filter((e: Record<string, Object>) => e['type'] === 'error');
        expect(errors.length).assertEqual(WITHHELD_BUFFER_EVENTS_LIMIT);
        // Exactly the oldest ones survive, in order: the five newest were evicted.
        const expected: string[] = [];
        for (let i: number = 0; i < WITHHELD_BUFFER_EVENTS_LIMIT; i++) {
          expected.push(`e${i}`);
        }
        expect(errors.map((e: Record<string, Object>) => e['tag'] as string).join(',')).assertEqual(expected.join(','));
      });

    it('keepsOnlyTheLastMinuteUntilAReleaseFreezesTheWindow',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        hold(buffer, view('v1', now), 50, now);
        hold(buffer, detail('action', 'v1', 'old'), 10, now);
        hold(buffer, detail('action', 'v1', 'recent'), 10, now + WITHHELD_BUFFER_DURATION_MS);
        hold(buffer, detail('error', 'v1', 'error'), 10, now + WITHHELD_BUFFER_DURATION_MS + 1);
        let out: Array<Record<string, Object>> = released(buffer, now + WITHHELD_BUFFER_DURATION_MS + 1);
        expect(out.filter((e: Record<string, Object>) => e['tag'] === 'old').length).assertEqual(0);
        expect(out.filter((e: Record<string, Object>) => e['tag'] === 'recent').length).assertEqual(1);

        // The release timer fires late (backgrounded app): the window stays where
        // the release was scheduled, so the minute before the error survives.
        const frozen: WithheldEventBuffer = new WithheldEventBuffer();
        hold(frozen, view('v1', now), 50, now);
        hold(frozen, detail('action', 'v1', 'before'), 10, now);
        hold(frozen, detail('error', 'v1', 'error'), 10, now + 1000);
        frozen.freeze(now + 1000);
        out = released(frozen, now + 10 * WITHHELD_BUFFER_DURATION_MS);
        expect(out.filter((e: Record<string, Object>) => e['tag'] === 'before').length).assertEqual(1);
      });

    it('boundsViewsButNeverDropsTheCurrentOne',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        // The current view starts first and keeps being updated late.
        for (let i: number = 0; i < WITHHELD_BUFFER_VIEWS_LIMIT + 10; i++) {
          hold(buffer, view(`v${i}`, now + i), 50, now + i);
          hold(buffer, detail('action', `v${i}`), 10, now + i);
        }
        // A late update of an old view must not make it current again.
        hold(buffer, view('v20', now + 20), 50, now + 100);
        hold(buffer, detail('error', `v${WITHHELD_BUFFER_VIEWS_LIMIT + 9}`, 'error'), 10, now + 101);
        const out: Array<Record<string, Object>> = released(buffer, now + 102);
        const views: Array<Record<string, Object>> = out.filter((e: Record<string, Object>) => e['type'] === 'view');
        expect(views.length <= WITHHELD_BUFFER_VIEWS_LIMIT).assertTrue();
        const ids: string[] = views.map((e: Record<string, Object>) => (e['view'] as Record<string, Object>)['id'] as string);
        expect(ids.indexOf(`v${WITHHELD_BUFFER_VIEWS_LIMIT + 9}`) !== -1).assertTrue();
        expect(out.filter((e: Record<string, Object>) => e['tag'] === 'error').length).assertEqual(1);
        // Oldest first, whatever order they were updated in.
        for (let i: number = 1; i < views.length; i++) {
          expect((views[i]['date'] as number) >= (views[i - 1]['date'] as number)).assertTrue();
        }
      });

    it('dropsADetailTooLargeToEverBeReleasedAndKeepsTheHistory',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        hold(buffer, view('v1', now), 50, now);
        hold(buffer, detail('action', 'v1', 'kept'), 10, now);
        expect(hold(buffer, detail('action', 'v1', 'huge'), WITHHELD_BUFFER_BYTES_LIMIT + 1, now)).assertFalse();
        const out: Array<Record<string, Object>> = released(buffer, now);
        expect(out.filter((e: Record<string, Object>) => e['tag'] === 'kept').length).assertEqual(1);
      });

    it('anOversizedErrorGoesOutAtOnceAndTheHistoryBehindTheJitter',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        addAction(app, Date.now());
        addError(app, Date.now(), 'x'.repeat(WITHHELD_BUFFER_BYTES_LIMIT + 10));
        expect(scope.written.length).assertEqual(1);
        expect(scope.written[0]['type']).assertEqual('error');
        app.releaseScheduledWithheld();
        expect(scope.ofType('view').length).assertEqual(1);
        expect(scope.ofType('action').length).assertEqual(1);
      });

    it('releasesWhatWasWrittenNotWhatTheAppChangedAfterwards',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const now: number = Date.now();
        startView(app, now);
        const payload: Record<string, Object> = { 'value': 'small' };
        const e: RumRawEvent = raw('addAction', now + 1);
        e.name = 'tap';
        e.actionType = 'tap';
        e.actionId = 'a1';
        e.attributes = { 'nested': payload };
        app.handleEvent(e);
        // The app keeps changing the object it passed in. A collected session
        // would have uploaded the value at the write; so must this one.
        payload['value'] = 'x'.repeat(WITHHELD_BUFFER_BYTES_LIMIT * 2);
        addError(app, now + 2);
        app.releaseScheduledWithheld();
        const action: Record<string, Object> = scope.ofType('action')[0];
        const nested: Record<string, Object> = (action['context'] as Record<string, Object>)['nested'] as Record<string, Object>;
        expect(nested['value']).assertEqual('small');
      });

    it('anOversizedErrorStorageRefusesReleasesNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        scope.rejectAbove = WITHHELD_BUFFER_BYTES_LIMIT * 2;
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        addAction(app, Date.now());
        addError(app, Date.now(), 'x'.repeat(WITHHELD_BUFFER_BYTES_LIMIT * 3));
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(0); // no error reached storage, so no history either
        app.stopCurrentSession(Date.now());
        expect(scope.written.length).assertEqual(0);
        // Negative control: an oversized error storage accepts releases the history.
        const kept: CapturingScope = new CapturingScope();
        kept.rejectAbove = WITHHELD_BUFFER_BYTES_LIMIT * 4;
        const app2: RumApplicationScope = onErrorApp(kept);
        startView(app2, Date.now());
        addError(app2, Date.now(), 'x'.repeat(WITHHELD_BUFFER_BYTES_LIMIT * 3));
        app2.releaseScheduledWithheld();
        expect(kept.ofType('error').length).assertEqual(1);
        expect(kept.ofType('view').length).assertEqual(1);
      });

    it('spreadsReleasesAcrossTheJitterWindow',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let min: number = WITHHELD_BUFFER_RELEASE_MAX_DELAY_MS;
        let max: number = 0;
        for (let i: number = 0; i < 200; i++) {
          const id: string = `${(0x10000000 + i * 7919).toString(16)}-1b2c-4d5e-8f90-a1b2c3d4e5f6`;
          const delay: number = computeReleaseDelay(id);
          expect(delay >= 0 && delay < WITHHELD_BUFFER_RELEASE_MAX_DELAY_MS).assertTrue();
          expect(computeReleaseDelay(id)).assertEqual(delay); // deterministic per session
          min = Math.min(min, delay);
          max = Math.max(max, delay);
        }
        // A character-code sum would bunch these into a few hundred milliseconds.
        expect(max - min > 2000).assertTrue();
      });
  });

  describe('rum-session-on-error-remote', (): void => {
    const ignore: RemoteConfigChangeListener = (_a: string, _b: number | null, _c: number | null): void => {};

    it('readsTheConsoleSwitchAndKeepsTheInitValueWhenAbsent',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new SilentFetcher(), 'https://x/config', ignore);
        controller.apply('{"version":1,"enabled":true,"rum":{"sessionSampleRate":0,"sessionOnError":true}}', null);
        expect((store.read() as RemoteConfigValues).sessionOnError).assertEqual(true);
        controller.apply('{"version":2,"enabled":true,"rum":{"sessionSampleRate":0,"sessionOnError":false}}', null);
        expect((store.read() as RemoteConfigValues).sessionOnError).assertEqual(false);
        controller.apply('{"version":3,"enabled":true,"rum":{"sessionSampleRate":0,"sessionOnError":"yes"}}', null);
        expect((store.read() as RemoteConfigValues).sessionOnError).assertNull();
        controller.apply('{"version":4,"enabled":false,"rum":{"sessionOnError":true}}', null);
        expect((store.read() as RemoteConfigValues).sessionOnError).assertNull();
      });

    it('theConsoleSwitchWinsOverInitAtTheNextDraw',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 1, null, null, 300, false, true));
        const scope: CapturingScope = new CapturingScope();
        // Init says off; the console says on.
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, store);
        startView(app, Date.now());
        addError(app, Date.now());
        app.releaseScheduledWithheld();
        expect(scope.ofType('error').length).assertEqual(1);

        // And the other way round: init on, console off.
        const core2: FakeCore = new FakeCore();
        const store2: RemoteConfigStore = newStore(core2);
        store2.write(new RemoteConfigValues(0, 1, null, null, 300, false, false));
        const scope2: CapturingScope = new CapturingScope();
        const app2: RumApplicationScope = onErrorApp(scope2, core2, store2);
        startView(app2, Date.now());
        addError(app2, Date.now());
        app2.releaseScheduledWithheld();
        expect(scope2.written.length).assertEqual(0);
      });

    it('rateZeroWithTheSwitchOnDoesNotStopTheSessionItKept',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core, store);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new SilentFetcher(), 'https://x/config',
          (activation: string, before: number | null, after: number | null): void => {
            app.onConfigurationChanged(activation, before, after, Date.now());
          });
        startView(app, Date.now());
        const id: string = app.getCurrentSessionId() as string;
        // First fetch of a fresh install: the console says exactly what init said.
        controller.apply('{"version":1,"enabled":true,"activation":"immediate",' +
          '"rum":{"sessionSampleRate":0,"sessionOnError":true}}', null);
        expect(app.getCurrentSessionId()).assertEqual(id);
        // The start-up error still releases.
        addError(app, Date.now());
        app.releaseScheduledWithheld();
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('turningTheSwitchOffAtRateZeroStopsTheSessionItKept',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core, store);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new SilentFetcher(), 'https://x/config',
          (activation: string, before: number | null, after: number | null): void => {
            app.onConfigurationChanged(activation, before, after, Date.now());
          });
        startView(app, Date.now());
        controller.apply('{"version":1,"enabled":true,"rum":{"sessionSampleRate":0,"sessionOnError":false}}', null);
        expect(app.getCurrentSessionId()).assertUndefined();
        expect(scope.written.length).assertEqual(0); // ended without an error: discarded
      });

    it('anImmediateSwitchOnlyChangeKeepsASessionTheRateKept',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(RumApplicationScope.shouldEndSession(true, 100, 100, 'immediate', false, true)).assertFalse();
        // Negative control: a rate that moved is still re-decided.
        expect(RumApplicationScope.shouldEndSession(true, 100, 50, 'immediate', false, true)).assertTrue();

        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 100, store);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new SilentFetcher(), 'https://x/config',
          (activation: string, before: number | null, after: number | null): void => {
            app.onConfigurationChanged(activation, before, after, Date.now());
          });
        startView(app, Date.now());
        const id: string = app.getCurrentSessionId() as string;
        controller.apply('{"version":1,"enabled":true,"activation":"immediate",' +
          '"rum":{"sessionSampleRate":100,"sessionOnError":true}}', null);
        expect(app.getCurrentSessionId()).assertEqual(id);
      });

    it('anImmediateSwitchOnlyChangeKeepsADarkSessionTheRateLost',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(RumApplicationScope.shouldEndSession(false, 20, 20, 'immediate', false, true)).assertFalse();
        // Negative control: a rate that moved is still re-decided.
        expect(RumApplicationScope.shouldEndSession(false, 20, 50, 'immediate', false, true)).assertTrue();

        // A session that lost its draw at 1% is not owed another one because
        // the console turned the switch on with `immediate`.
        let found: boolean = false;
        for (let attempt: number = 0; attempt < 20 && !found; attempt++) {
          const core: FakeCore = new FakeCore();
          const store: RemoteConfigStore = newStore(core);
          const scope: CapturingScope = new CapturingScope();
          const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 1, store);
          const controller: RemoteConfigController = new RemoteConfigController(
            store, new SilentFetcher(), 'https://x/config',
            (activation: string, before: number | null, after: number | null): void => {
              app.onConfigurationChanged(activation, before, after, Date.now());
            });
          startView(app, Date.now());
          if (scope.written.length > 0) {
            continue; // won the 1% draw
          }
          const id: string = app.getCurrentSessionId() as string;
          controller.apply('{"version":1,"enabled":true,"activation":"immediate",' +
            '"rum":{"sessionSampleRate":1,"sessionOnError":true}}', null);
          expect(app.getCurrentSessionId()).assertEqual(id);
          found = true;
        }
        expect(found).assertTrue();
      });

    it('decidesTheRunningSessionByTheStopTree',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Kept by the switch, rate 0 with the switch on: the switch's ordinary setting.
        expect(RumApplicationScope.shouldEndSession(true, 0, 0, 'next_session', true, true)).assertFalse();
        expect(RumApplicationScope.shouldEndSession(true, 20, 0, 'immediate', true, true)).assertFalse();
        // Kept by the switch, which is now off at rate 0: stopped.
        expect(RumApplicationScope.shouldEndSession(true, 0, 0, 'next_session', true, false)).assertTrue();
        // Drawn by the rate: an emergency stop even with the switch on.
        expect(RumApplicationScope.shouldEndSession(true, 100, 0, 'next_session', false, true)).assertTrue();
        // Dark and drawn at 0: the switch turning on is owed a new draw.
        expect(RumApplicationScope.shouldEndSession(false, 0, 0, 'next_session', false, true)).assertTrue();
        // Dark after a fair draw: the draw is locked for the session.
        expect(RumApplicationScope.shouldEndSession(false, 20, 20, 'next_session', false, true)).assertFalse();
      });

    it('aDarkSessionDrawnAtZeroIsRedrawnWhenTheSwitchTurnsOn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = new RumApplicationScope(scope, core, 'app-1', 0, store);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new SilentFetcher(), 'https://x/config',
          (activation: string, before: number | null, after: number | null): void => {
            app.onConfigurationChanged(activation, before, after, Date.now());
          });
        startView(app, Date.now());
        controller.apply('{"version":1,"enabled":true,"rum":{"sessionSampleRate":0,"sessionOnError":true}}', null);
        expect(app.getCurrentSessionId()).assertUndefined();
        startView(app, Date.now());
        addError(app, Date.now());
        app.releaseScheduledWithheld();
        expect(scope.ofType('error').length).assertEqual(1);
      });
  });

  describe('rum-session-on-error-crash', (): void => {
    it('snapshotsTheWithheldViewSoANextLaunchCrashStillReportsIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let stored: string = '';
        LastViewSnapshot.configure((serialized: string): void => {
          stored = serialized;
        }, (): string => stored);
        try {
          const scope: CapturingScope = new CapturingScope();
          const app: RumApplicationScope = onErrorApp(scope);
          startView(app, Date.now());
          expect(scope.written.length).assertEqual(0); // nothing uploaded...
          const snapshot: Record<string, Object> = LastViewSnapshot.read() as Record<string, Object>;
          expect(snapshot['type']).assertEqual('view'); // ...but the local snapshot is kept
          // What a native crash replays next launch: the crash-marked view keeps the markers.
          const crashed: Record<string, Object> = RumFeature.viewEventWithCrash(snapshot);
          expect(sessionOf(crashed)['sampled_for_error']).assertEqual(true);
          expect(sampleRateOf(crashed)).assertEqual(0);
          expect(sessionOf(crashed)['id']).assertEqual(app.getCurrentSessionId() as string);
        } finally {
          LastViewSnapshot.reset();
        }
      });
  });
}
