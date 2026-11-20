import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import {
  FlashcatContext, FeatureScope, EventWriter, SdkCore, TrackingConsent,
  Feature, FeatureEventReceiver, UserInfo, IntakeTarget, MAX_EVENT_BYTES
} from '@flashcatcloud/core';
import { RumApplicationScope } from '../main/ets/internal/scope/RumApplicationScope';
import { RumRawEvent } from '../main/ets/internal/scope/RumScope';
import {
  WithheldEventBuffer, computeReleaseDelay, WITHHELD_BUFFER_BYTES_LIMIT, WITHHELD_BUFFER_EVENTS_LIMIT,
  WITHHELD_BUFFER_VIEWS_LIMIT, WITHHELD_BUFFER_VIEW_BYTES_LIMIT, WITHHELD_BUFFER_SAME_ACTION_LIMIT, WITHHELD_BUFFER_DURATION_MS,
  WITHHELD_BUFFER_RELEASE_MAX_DELAY_MS
} from '../main/ets/internal/scope/WithheldEvents';
import { RemoteConfigStore, RemoteConfigValues } from '../main/ets/internal/remoteconfig/RemoteConfigStore';
import { RemoteConfigController, RemoteConfigChangeListener } from '../main/ets/internal/remoteconfig/RemoteConfigController';
import { RemoteConfigFetcher, RemoteConfigResponse } from '../main/ets/internal/remoteconfig/RemoteConfigFetcher';
import { RumEventMapperHolder } from '../main/ets/internal/RumEventMapperHolder';
import { LastView, LastViewSnapshot, SessionRecord } from '../main/ets/internal/LastViewSnapshot';
import { RumFeature } from '../main/ets/internal/RumFeature';
import { BeforeSamplingContext } from '../main/ets/RumTypes';
import { RumConfiguration, RumConfigurationBuilder } from '../main/ets/RumConfiguration';
import { FlashcatRum } from '../main/ets/FlashcatRum';
import { DefaultRumMonitor } from '../main/ets/internal/monitor/DefaultRumMonitor';
import { RumActionType, RumErrorSource, RumResourceMethod, RumResourceKind } from '../main/ets/RumTypes';
import { StartupType } from '../main/ets/internal/startup/AppLaunchTracker';
import { APP_LAUNCH_TTID } from '../main/ets/internal/assembly/RumEventAssembler';
import { errorManager } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';

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
    sdkVersion: '0.8.1',
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

  /** What getFeature hands out: the RUM scope (storage commands included) and the crash feature. */
  rumScope: CapturingScope | null = null;
  crashScope: FakeCrashScope | null = null;
  /** What getContext reports for this launch: change them to model an app update or a sign-out. */
  appVersion: string = '1.0.0';
  user: UserInfo = {};
  /** What the system has said about the app's state: unknown until `stateKnown`. */
  foreground: boolean = false;
  stateKnown: boolean = true;

  registerFeature(_feature: Feature): void {}
  getFeature(featureName: string): FeatureScope | null {
    if (featureName === 'rum') {
      return this.rumScope;
    }
    if (featureName === 'crash') {
      return this.crashScope;
    }
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
    const context: FlashcatContext = testContext();
    context.version = this.appVersion;
    context.user = this.user;
    return context;
  }
  getTrackingConsent(): TrackingConsent {
    return this.consent;
  }
  isActive(): boolean {
    return true;
  }
  isAppInForeground(): boolean {
    return this.foreground;
  }
  isAppStateKnown(): boolean {
    return this.stateKnown;
  }

  liveWindowContexts(): Array<Object> {
    return [];
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
  /** Events of this type are refused, as a storage failure on that one write would. */
  refuseType: string = '';
  /** View documents of this view id are refused. */
  refuseViewId: string = '';

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    callback(this.core !== null ? this.core.getContext() : testContext(), new CapturingWriter(this));
  }

  /** The last-view snapshot file the crash storage would hold. */
  lastView: string = '';
  lastViewDeletes: number = 0;
  /** The crash storage fails every last-view write (a full disk). */
  refuseLastView: boolean = false;
  /** Last-view writes asked of the crash storage, refused ones included. */
  lastViewAttempts: number = 0;
  /** The core whose context events are written with (the default test context when unset). */
  core: FakeCore | null = null;

  sendEvent(event: Record<string, Object>): void {
    const type: Object | undefined = event['type'];
    if (type === 'crash_storage_write_last_view') {
      this.lastViewAttempts += 1;
      if (this.refuseLastView) {
        event['success'] = false;
        return;
      }
      this.lastView = event['serialized'] as string;
      event['success'] = true;
    } else if (type === 'crash_storage_read_last_view') {
      event['serialized'] = this.lastView;
    } else if (type === 'crash_storage_delete_last_view') {
      this.lastView = '';
      this.lastViewDeletes += 1;
    }
  }

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
    // Storage stores a line: the newline counts toward its limit.
    if (JSON.stringify(event).length + 1 > this.scope.rejectAbove || event['type'] === this.scope.refuseType ||
      (this.scope.refuseViewId.length > 0 && event['type'] === 'view' &&
        (event['view'] as Record<string, Object>)['id'] === this.scope.refuseViewId)) {
      return false;
    }
    this.scope.written.push(event);
    this.scope.flushes.push(forceFlush === true);
    return true;
  }
}

/**
 * Stands in for the crash feature on the bus: answers the policy pull and the
 * live crash callback the way CrashFeature does, minus the process exit. For a
 * terminating policy it persists nothing but asks RUM, as the real feature does,
 * whether the event the next launch would replay survives the app's mapper.
 */
class FakeCrashScope implements FeatureScope {
  readonly controls: Array<Record<string, Object>> = [];
  readonly probes: Array<Record<string, Object>> = [];
  policy: string = 'report_then_exit';
  /** The restart the loop guard would allow: the replay carries `crash.recovered`. */
  recover: boolean = false;
  rum: RumFeature | null = null;
  private readonly core: FakeCore;

  constructor(core: FakeCore) {
    this.core = core;
  }

  withWriteContext(_callback: (context: FlashcatContext, writer: EventWriter) => void): void {}

  sendEvent(event: Record<string, Object>): void {
    const type: Object | undefined = event['type'];
    if (type === 'js_crash_policy_request') {
      event['policy'] = this.policy;
      return;
    }
    if (type !== 'js_crash_callback') {
      return;
    }
    this.controls.push(event);
    if (event['callback'] === 'unhandled' && this.policy === 'report_and_continue') {
      // No incident: RUM reports the crash into the live session.
      event['report_async'] = false;
      event['report_crash'] = true;
      event['should_exit'] = false;
      return;
    }
    if (event['callback'] !== 'unhandled' || this.policy === 'observe_only') {
      // No incident: the live report is the only report.
      event['report_async'] = true;
      event['should_exit'] = false;
      return;
    }
    // What CrashEventMapper.fromPendingIncident rebuilds from the persisted
    // record: name/message/stack parts, the crash time, the ids the record
    // took from the RUM context, and the recovery outcome.
    const text: string = event['text'] as string;
    const lines: string[] = text.split('\n');
    const name: string = lines[0].substring('Error name:'.length);
    const message: string = lines[1].substring('Error message:'.length);
    const stack: string = lines.slice(3).join('\n');
    const probe: Record<string, Object> = {
      'type': 'crash_mapper_probe',
      'target': 'rum',
      'crash_type': 'JsError',
      'crash_kind': 'crash',
      'message': `${name}: ${message}`,
      'stack': stack,
      'timestamp_ms': event['timestamp_ms'] as number,
      'incident_id': 'incident-under-test',
      'fingerprint': 'fp',
      'original_session_id': (this.core.featureContext['session.id'] ?? '') as string,
      'original_view_id': (this.core.featureContext['view.id'] ?? '') as string,
      'original_view_name': (this.core.featureContext['view.name'] ?? '') as string,
      'original_view_url': (this.core.featureContext['view.url'] ?? '') as string
    };
    if (this.recover) {
      probe['crash.recovered'] = true;
    }
    this.probes.push(probe);
    if (this.rum !== null) {
      this.rum.onReceive(probe);
    }
    const kept: boolean = probe['kept'] !== false;
    event['suppressed'] = !kept;
    event['pending_written'] = kept;
    event['report_async'] = false;
    event['should_exit'] = false; // the test process stays alive
  }
}

function fireUnhandledException(text: string): void {
  const observers: Record<string, Object> = (errorManager as Object as Record<string, Object>)['lastObservers'] as Record<string, Object>;
  (observers['error'] as errorManager.ErrorObserver).onUnhandledException(text);
}

function fireException(error: Error): void {
  const observers: Record<string, Object> = (errorManager as Object as Record<string, Object>)['lastObservers'] as Record<string, Object>;
  (observers['error'] as errorManager.ErrorObserver).onException?.(error);
}

function fireUnhandledRejection(reason: Object): void {
  const observers: Record<string, Object> = (errorManager as Object as Record<string, Object>)['lastObservers'] as Record<string, Object>;
  (observers['unhandledRejection'] as errorManager.UnhandledRejectionObserver)(reason, Promise.resolve());
}

/** A RUM feature wired to the fake core, with its monitor attached. */
function featureWith(core: FakeCore, scope: CapturingScope, rate: number, sessionOnError: boolean): DefaultRumMonitor {
  core.rumScope = scope;
  scope.core = core;
  const configuration: RumConfiguration =
    new RumConfigurationBuilder('app-1').setSessionSampleRate(rate).setSessionOnError(sessionOnError).build();
  const feature: RumFeature = new RumFeature(core, configuration);
  feature.onInitialize();
  const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
  monitor.stopKeepAlive();
  feature.attachMonitor(monitor);
  if (core.crashScope !== null) {
    core.crashScope.rum = feature;
  }
  return monitor;
}

/** A RUM feature on a rate-0 + switch configuration. */
function onErrorFeature(core: FakeCore, scope: CapturingScope): DefaultRumMonitor {
  return featureWith(core, scope, 0, true);
}

/** A mapper that drops crashes (or, with `on`, events carrying that context key) and counts what it saw. */
class CountingMapper {
  crashesSeen: number = 0;
  errorsSeen: number = 0;
  readonly dropKey: string;

  constructor(dropKey: string = '') {
    this.dropKey = dropKey;
  }

  install(): void {
    RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> | null => {
      if (event['type'] !== 'error') {
        return event;
      }
      const error: Record<string, Object> = event['error'] as Record<string, Object>;
      const context: Record<string, Object> = (event['context'] ?? {}) as Record<string, Object>;
      if (error['is_crash'] === true) {
        this.crashesSeen += 1;
      } else {
        this.errorsSeen += 1;
      }
      if (this.dropKey.length > 0) {
        return context[this.dropKey] === true ? null : event;
      }
      return error['is_crash'] === true ? null : event;
    });
  }
}

const CRASH_TEXT: string = 'Error name:Error\nError message:fatal\nStacktrace:\nat a (b.ets:1:1)';

class SilentFetcher implements RemoteConfigFetcher {
  fetch(_url: string, _ifNoneMatch: string | null): Promise<RemoteConfigResponse> {
    return Promise.resolve({ code: 304, body: '', etag: null } as RemoteConfigResponse);
  }
}

/** Busy-waits until the clock has moved past `ms`, so what follows is stamped later. */
function waitPast(ms: number): void {
  while (Date.now() <= ms) {
    // spin
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

/** A replayed crash that names no session: what a fault before the first view leaves. */
function launchCrash(crashedAtMs: number): Record<string, Object> {
  return {
    'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'crash_kind': 'crash',
    'crash_type': 'NativeCrash', 'timestamp_ms': crashedAtMs, 'incident_id': 'incident-1'
  } as Record<string, Object>;
}

/** A RUM feature (see featureWith) with the crash feature on the bus to replay incidents into it. */
function crashFeature(core: FakeCore, scope: CapturingScope, rate: number, sessionOnError: boolean): DefaultRumMonitor {
  core.crashScope = new FakeCrashScope(core);
  return featureWith(core, scope, rate, sessionOnError);
}

/** Deliver `replay` to the RUM feature the crash feature would hand it to. */
function replayCrash(core: FakeCore, replay: Record<string, Object>): void {
  ((core.crashScope as FakeCrashScope).rum as RumFeature).onReceive(replay);
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

/** A native crash of process `pid` reported on the next launch: no session or view ids of its own. */
function nativeCrash(atMs: number, pid: number = process.pid, extra: Record<string, Object> = {}): Record<string, Object> {
  const event: Record<string, Object> = {
    'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'crash_kind': 'crash',
    'crash_type': 'NativeCrash', 'timestamp_ms': atMs, 'process_id': pid
  };
  for (const key of Object.keys(extra)) {
    event[key] = extra[key];
  }
  return event;
}

/**
 * The next launch: a RUM feature starting on the crash storage `lastView` run 1 left, under
 * `rate` / `onError`, receives `crash`. Returns what it wrote.
 */
function nextLaunch(core: FakeCore, lastView: string, rate: number, onError: boolean,
  crash: Record<string, Object>): CapturingScope {
  const next: CapturingScope = new CapturingScope();
  next.lastView = lastView;
  next.core = core;
  core.rumScope = next;
  const configuration: RumConfiguration =
    new RumConfigurationBuilder('app-1').setSessionSampleRate(rate).setSessionOnError(onError).build();
  const feature: RumFeature = new RumFeature(core, configuration);
  feature.onInitialize();
  const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, next, configuration);
  monitor.stopKeepAlive();
  feature.attachMonitor(monitor);
  feature.onReceive(crash);
  return next;
}

/** A session that has no view: a launch vital is the first thing it records. */
function launchVital(monitor: DefaultRumMonitor): void {
  const nowMs: number = Date.now();
  monitor.reportAppLaunch(APP_LAUNCH_TTID, StartupType.COLD, nowMs, 1000000, nowMs);
}

/** Rewrites the file's write time, as if the process had written it `agoMs` ago. */
function writtenAgo(lastView: string, agoMs: number): string {
  const file: Record<string, Object> = JSON.parse(lastView) as Record<string, Object>;
  file['written_at'] = Date.now() - agoMs;
  return JSON.stringify(file);
}

function viewNameOf(event: Record<string, Object>): string {
  return (event['view'] as Record<string, Object>)['name'] as string;
}

/** `view.in_foreground` of an error: undefined when it has none (or no view). */
function inForegroundOf(event: Record<string, Object>): Object | undefined {
  const view: Object | undefined = event['view'];
  return view === undefined ? undefined : (view as Record<string, Object>)['in_foreground'];
}

function errorCountOf(event: Record<string, Object>): number {
  return ((event['view'] as Record<string, Object>)['error'] as Record<string, Object>)['count'] as number;
}

/** Neither marker leaks into the custom attributes. */
function markersStayOutOfTheContext(event: Record<string, Object>): void {
  const context: Record<string, Object> = event['context'] as Record<string, Object>;
  expect(context['view.in_foreground']).assertUndefined();
  expect(context['session.sampled']).assertUndefined();
}

function crashCountOf(event: Record<string, Object>): number {
  return ((event['view'] as Record<string, Object>)['crash'] as Record<string, Object>)['count'] as number;
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

    it('anHttpErrorStatusIsNotAnErrorAndReleasesNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A 500 is the server answering: a completed request, not an error of
        // the app, so the session stays withheld. A request that got no answer
        // at all is an error and releases it (aFailedRequestIsAnErrorThatReleases).
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const now: number = Date.now();
        startView(app, now);
        for (const status of [500, 503, 404]) {
          const key: string = `r${status}`;
          app.handleEvent(raw('startResource', now, key));
          const done: RumRawEvent = raw('stopResource', now + 5, key);
          done.statusCode = status;
          app.handleEvent(done);
        }
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(0);
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

    it('aLaunchCrashMeetingAWithheldSessionIsReportedInASessionOfItsOwn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A replayed crash nothing attributes to its own session (here: no ids, no last view)
        // meets a current session kept only on error. It is reported in a session of its own,
        // for every kind of fault that reaches this path.
        const kinds: Array<Record<string, Object>> = [
          { 'crash_kind': 'crash', 'crash_type': 'NativeCrash', 'category': 'Exception' },
          { 'crash_kind': 'crash', 'crash_type': 'JsError', 'category': 'Exception' },
          { 'crash_kind': 'freeze', 'crash_type': 'AppFreeze', 'category': 'ANR' }
        ];
        for (const kind of kinds) {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, true);
          monitor.startView('home', 'home');
          const current: string = core.featureContext['session.id'] as string;
          const crashedAtMs: number = Date.now() - 5000;
          const replay: Record<string, Object> = launchCrash(crashedAtMs);
          replay['crash_kind'] = kind['crash_kind'];
          replay['crash_type'] = kind['crash_type'];
          replayCrash(core, replay);
          expect(replay['delivered']).assertEqual(true);
          expect(scope.written.length).assertEqual(2);
          const error: Record<string, Object> = scope.ofType('error')[0];
          const view: Record<string, Object> = scope.ofType('view')[0];
          const errorBody: Record<string, Object> = error['error'] as Record<string, Object>;
          expect(errorBody['is_crash']).assertEqual(true);
          expect(errorBody['category']).assertEqual(kind['category'] as string);
          expect(errorBody['stack']).assertEqual('#00 pc');
          expect(error['date']).assertEqual(crashedAtMs);
          expect((error['context'] as Record<string, Object>)['crash.crashed_at_ms']).assertEqual(crashedAtMs);
          const session: string = sessionOf(error)['id'] as string;
          expect(session === current).assertFalse();
          expect(sessionOf(view)['id']).assertEqual(session);
          const errorView: Record<string, Object> = error['view'] as Record<string, Object>;
          const viewBody: Record<string, Object> = view['view'] as Record<string, Object>;
          expect(errorView['id']).assertEqual(viewBody['id']);
          expect(viewBody['name']).assertEqual('ApplicationLaunch');
          expect(viewBody['url']).assertEqual('ApplicationLaunch');
          expect(errorView['name']).assertEqual('ApplicationLaunch');
          expect(view['date']).assertEqual(crashedAtMs);
          expect(viewBody['is_active']).assertEqual(false);
          // A freeze is an error of the view, not one of its crashes.
          expect((viewBody['crash'] as Record<string, Object>)['count'])
            .assertEqual(kind['crash_kind'] === 'freeze' ? 0 : 1);
          expect((viewBody['error'] as Record<string, Object>)['count']).assertEqual(1);
          // Marked as a session kept on error: it exists only because of the crash.
          expect(sessionOf(view)['sampled_for_error']).assertEqual(true);
          expect(sampleRateOf(view)).assertEqual(0);
          // Not drawn: the crash says so.
          expect(sessionOf(error)['sampled']).assertEqual(false);
        }
      });

    it('aLaunchCrashLeavesTheWithheldCurrentSessionAsItWas',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, true);
        monitor.startView('home', 'home');
        monitor.addAction(RumActionType.TAP, 'before');
        const current: string = core.featureContext['session.id'] as string;
        const replay: Record<string, Object> = launchCrash(Date.now() - 5000);
        replayCrash(core, replay);
        monitor.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(2); // the standalone session only
        expect(monitor.isWithholding()).assertTrue();
        expect(core.featureContext['session.id']).assertEqual(current);
        for (const e of scope.written) {
          expect(sessionOf(e)['id'] === current).assertFalse();
        }
        // The current session's own error releases its untouched history: the
        // view never counted the replayed crash, and the action held before it is there.
        monitor.addError('own', RumErrorSource.SOURCE);
        monitor.releaseScheduledWithheld();
        const own: Array<Record<string, Object>> =
          scope.written.filter((e: Record<string, Object>) => sessionOf(e)['id'] === current);
        expect(own.filter((e: Record<string, Object>) => e['type'] === 'action').length).assertEqual(1);
        const ownErrors: Array<Record<string, Object>> =
          own.filter((e: Record<string, Object>) => e['type'] === 'error');
        expect(ownErrors.length).assertEqual(1);
        expect(((ownErrors[0]['error'] as Record<string, Object>)['message'])).assertEqual('own');
        for (const e of own.filter((e: Record<string, Object>) => e['type'] === 'view')) {
          const crash: Record<string, Object> = (e['view'] as Record<string, Object>)['crash'] as Record<string, Object>;
          expect(crash['count']).assertEqual(0);
        }
      });

    it('aLaunchCrashNeverJoinsATrackedCurrentSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The current session is collected outright. The crash did not happen in it, so it is
        // reported in a session of its own, at its real time, and the current session's views
        // never count it. Drawn by the rate, that session is an ordinary one: no on-error marker.
        for (const onError of [false, true]) {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = crashFeature(core, scope, 100, onError);
          monitor.startView('home', 'home');
          const current: string = core.featureContext['session.id'] as string;
          const crashedAtMs: number = Date.now() - 5000;
          const replay: Record<string, Object> = launchCrash(crashedAtMs);
          replayCrash(core, replay);
          expect(replay['delivered']).assertEqual(true);
          const errors: Array<Record<string, Object>> = scope.ofType('error');
          expect(errors.length).assertEqual(1);
          const session: string = sessionOf(errors[0])['id'] as string;
          expect(session === current).assertFalse();
          expect(errors[0]['date']).assertEqual(crashedAtMs);
          expect((errors[0]['view'] as Record<string, Object>)['name']).assertEqual('ApplicationLaunch');
          const launch: Array<Record<string, Object>> = scope.ofType('view')
            .filter((e: Record<string, Object>) => sessionOf(e)['id'] === session);
          expect(launch.length).assertEqual(1);
          const launchView: Record<string, Object> = launch[0]['view'] as Record<string, Object>;
          expect(launchView['name']).assertEqual('ApplicationLaunch');
          expect((launchView['crash'] as Record<string, Object>)['count']).assertEqual(1);
          expect(launch[0]['date']).assertEqual(crashedAtMs);
          expect(sessionOf(launch[0])['sampled_for_error'] === undefined).assertTrue();
          expect(sampleRateOf(launch[0])).assertEqual(100);
          // The current session is exactly as it was: still current, its views count nothing.
          expect(core.featureContext['session.id']).assertEqual(current);
          const own: Array<Record<string, Object>> = scope.ofType('view')
            .filter((e: Record<string, Object>) => sessionOf(e)['id'] === current);
          expect(own.length > 0).assertTrue();
          for (const e of own) {
            const body: Record<string, Object> = e['view'] as Record<string, Object>;
            expect((body['crash'] as Record<string, Object>)['count']).assertEqual(0);
            expect((body['error'] as Record<string, Object>)['count']).assertEqual(0);
          }
        }
      });

    it('aLaunchCrashLeavesAReleasedCurrentSessionAlone',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Kept on error and already released by its own error: it is collected, and still not
        // the crash's session.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, true);
        monitor.startView('home', 'home');
        monitor.addError('own', RumErrorSource.SOURCE);
        monitor.releaseScheduledWithheld();
        const current: string = core.featureContext['session.id'] as string;
        const replay: Record<string, Object> = launchCrash(Date.now() - 5000);
        replayCrash(core, replay);
        expect(replay['delivered']).assertEqual(true);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(2);
        const crash: Record<string, Object> = errors[1];
        expect(sessionOf(crash)['id'] === current).assertFalse();
        const launch: Record<string, Object> = scope.ofType('view')
          .filter((e: Record<string, Object>) => sessionOf(e)['id'] === sessionOf(crash)['id'])[0];
        // The rate would not draw it; the switch keeps it, as it keeps a new session on error.
        expect(sessionOf(launch)['sampled_for_error']).assertEqual(true);
        expect(sampleRateOf(launch)).assertEqual(0);
        for (const e of scope.ofType('view').filter((e: Record<string, Object>) => sessionOf(e)['id'] === current)) {
          expect(((e['view'] as Record<string, Object>)['crash'] as Record<string, Object>)['count']).assertEqual(0);
        }
      });

    it('aSessionOfItsOwnIsDrawnLikeANewSessionNotLikeTheCurrentOne',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Init rate 0; the app's hook decides each draw in turn (undefined keeps the rate): the
        // first is the current session's, the second the crash's own.
        const run = (rates: Array<number | undefined>, onError: boolean): CapturingScope => {
          let draws: number = 0;
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          core.crashScope = new FakeCrashScope(core);
          core.rumScope = scope;
          scope.core = core;
          const configuration: RumConfiguration = new RumConfigurationBuilder('app-1')
            .setSessionSampleRate(0).setSessionOnError(onError)
            .setBeforeSampling((_context: BeforeSamplingContext): number | undefined => rates[draws++])
            .build();
          const feature: RumFeature = new RumFeature(core, configuration);
          feature.onInitialize();
          core.crashScope.rum = feature;
          const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
          monitor.stopKeepAlive();
          feature.attachMonitor(monitor);
          monitor.startView('home', 'home');
          const replay: Record<string, Object> = launchCrash(Date.now() - 5000);
          replayCrash(core, replay);
          expect(replay['delivered']).assertEqual(true);
          expect(draws).assertEqual(2);
          return scope;
        };
        // Current session withheld, the crash's own drawn by the rate: an ordinary session.
        const tracked: CapturingScope = run([undefined, 100], true);
        expect(tracked.written.length).assertEqual(2);
        expect(sessionOf(tracked.ofType('view')[0])['sampled_for_error'] === undefined).assertTrue();
        expect(sampleRateOf(tracked.ofType('view')[0])).assertEqual(100);
        // Current session collected, the crash's own missed by the rate but kept by the switch.
        const kept: CapturingScope = run([100, undefined], true);
        const launch: Array<Record<string, Object>> = kept.ofType('view')
          .filter((e: Record<string, Object>) => (e['view'] as Record<string, Object>)['name'] === 'ApplicationLaunch');
        expect(launch.length).assertEqual(1);
        expect(sessionOf(launch[0])['sampled_for_error']).assertEqual(true);
        expect(sampleRateOf(launch[0])).assertEqual(0);
        // Missed by the rate and no switch: not reported, and not retried either.
        const dropped: CapturingScope = run([100, undefined], false);
        expect(dropped.ofType('error').length).assertEqual(0);
        for (const e of dropped.ofType('view')) {
          expect((e['view'] as Record<string, Object>)['name']).assertEqual('home');
        }
      });

    it('aSessionOfItsOwnIsDrawnUnderTheConsoleSettings',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Init says rate 0 with no switch; the console says 100 at version 7.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(100, 7));
        core.crashScope = new FakeCrashScope(core);
        core.rumScope = scope;
        scope.core = core;
        const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(0).build();
        const feature: RumFeature = new RumFeature(core, configuration);
        feature.onInitialize();
        core.crashScope.rum = feature;
        const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration, store);
        monitor.stopKeepAlive();
        feature.attachMonitor(monitor);
        const replay: Record<string, Object> = launchCrash(Date.now() - 5000);
        replayCrash(core, replay);
        expect(replay['delivered']).assertEqual(true);
        const views: Array<Record<string, Object>> = scope.ofType('view');
        expect(views.length).assertEqual(1);
        const dd: Record<string, Object> = views[0]['_dd'] as Record<string, Object>;
        const drawn: Record<string, Object> = dd['configuration'] as Record<string, Object>;
        expect(drawn['session_sample_rate']).assertEqual(100);
        expect(drawn['rc_version']).assertEqual(7);
        expect(sessionOf(views[0])['sampled_for_error'] === undefined).assertTrue();
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('aLaunchCrashWithNoSessionDrawnAndNoSwitchIsNotReported',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, false);
        monitor.startView('home', 'home');
        const replay: Record<string, Object> = launchCrash(Date.now() - 5000);
        replayCrash(core, replay);
        expect(scope.written.length).assertEqual(0);
        expect(replay['delivered']).assertEqual(true);
      });

    it('aLaunchCrashInASessionOfItsOwnRespectsConsentAndRetriesAFailedWrite',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Storage refuses the write: the incident stays for the next launch.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, true);
        monitor.startView('home', 'home');
        scope.rejectAbove = 0;
        const failed: Record<string, Object> = launchCrash(Date.now() - 5000);
        replayCrash(core, failed);
        expect(failed['delivered'] === true).assertFalse();
        expect(scope.written.length).assertEqual(0);
        expect(monitor.isWithholding()).assertTrue();
        // The next attempt lands, whole.
        scope.rejectAbove = Number.MAX_SAFE_INTEGER;
        const retried: Record<string, Object> = launchCrash(Date.now() - 5000);
        replayCrash(core, retried);
        expect(retried['delivered']).assertEqual(true);
        expect(scope.ofType('error').length).assertEqual(1);
        expect(scope.ofType('view').length).assertEqual(1);
        // Consent refused: the core writes nothing, and the incident is dropped on purpose
        // rather than retried every launch.
        const refusedCore: FakeCore = new FakeCore();
        const refused: CapturingScope = new CapturingScope();
        const monitor2: DefaultRumMonitor = crashFeature(refusedCore, refused, 0, true);
        monitor2.startView('home', 'home');
        refusedCore.consent = TrackingConsent.NOT_GRANTED;
        refused.rejectAbove = 0; // what the core's writer does under a refused consent
        const dropped: Record<string, Object> = launchCrash(Date.now() - 5000);
        replayCrash(refusedCore, dropped);
        expect(refused.written.length).assertEqual(0);
        expect(dropped['delivered']).assertEqual(true);
      });

    it('aCrashTooOldForItsViewIsReportedInAViewThatDoesNotCountItAgain',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // An incident with its own view, past the intake's window: its crash was counted in
        // that view's document when it happened. The session of its own still gets its view
        // (the backend builds sessions from view documents), counting nothing twice.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, true);
        monitor.startView('home', 'home');
        const crashedAtMs: number = Date.now() - 25 * 60 * 60 * 1000;
        const replay: Record<string, Object> = launchCrash(crashedAtMs);
        replay['original_session_id'] = 'old-session';
        replay['original_view_id'] = 'old-view';
        const before: number = Date.now();
        replayCrash(core, replay);
        expect(replay['delivered']).assertEqual(true);
        const views: Array<Record<string, Object>> = scope.ofType('view');
        expect(views.length).assertEqual(1);
        const view: Record<string, Object> = views[0]['view'] as Record<string, Object>;
        expect((view['crash'] as Record<string, Object>)['count']).assertEqual(0);
        expect((view['error'] as Record<string, Object>)['count']).assertEqual(0);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        expect((errors[0]['view'] as Record<string, Object>)['id']).assertEqual(view['id']);
        expect((errors[0]['date'] as number) >= before).assertTrue();
        expect((errors[0]['context'] as Record<string, Object>)['crash.crashed_at_ms']).assertEqual(crashedAtMs);
        expect(sessionOf(errors[0])['id'] === core.featureContext['session.id']).assertFalse();
        expect(monitor.isWithholding()).assertTrue();
      });

    it('aCrashOfASessionWithoutAViewIsCountedOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The crashed run had a session but no view yet: nothing counted the crash.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, true);
        monitor.startView('home', 'home');
        const replay: Record<string, Object> = launchCrash(Date.now() - 25 * 60 * 60 * 1000);
        replay['original_session_id'] = 'old-session';
        replayCrash(core, replay);
        const views: Array<Record<string, Object>> = scope.ofType('view');
        expect(views.length).assertEqual(1);
        const view: Record<string, Object> = views[0]['view'] as Record<string, Object>;
        expect((view['crash'] as Record<string, Object>)['count']).assertEqual(1);
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('twoFaultsWhoseFieldsSplitDifferentlyGetDifferentIdentities', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const base: Record<string, Object> = { 'crash_kind': 'native', 'crash_type': 'NativeCrash', 'timestamp_ms': 1000, 'process_id': 7 };
      const one: Record<string, Object> = { 'message': 'a|b', 'stack': 'c' };
      const two: Record<string, Object> = { 'message': 'a', 'stack': 'b|c' };
      for (const k of Object.keys(base)) {
        one[k] = base[k];
        two[k] = base[k];
      }
      expect(RumFeature.incidentIdentity(one) === RumFeature.incidentIdentity(two)).assertFalse();
      // Negative control: the same fault twice has one identity.
      const again: Record<string, Object> = { 'message': 'a|b', 'stack': 'c' };
      for (const k of Object.keys(base)) {
        again[k] = base[k];
      }
      expect(RumFeature.incidentIdentity(again)).assertEqual(RumFeature.incidentIdentity(one));
    });

    it('aRetryAfterAPartialWriteRewritesTheSameDocuments',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Either write of the standalone session can fail alone. The incident stays, and the
        // retry writes documents with the same ids, so the intake's id dedup keeps one of each.
        for (const failing of ['view', 'error', 'view@100', 'error@100']) {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          const rate: number = failing.endsWith('@100') ? 100 : 0;
          const monitor: DefaultRumMonitor = crashFeature(core, scope, rate, true);
          monitor.startView('home', 'home');
          const current: string = core.featureContext['session.id'] as string;
          const crashedAtMs: number = Date.now() - 5000;
          scope.refuseType = failing.split('@')[0];
          const first: Record<string, Object> = launchCrash(crashedAtMs);
          replayCrash(core, first);
          expect(first['delivered'] === true).assertFalse();
          // An error must never be on record without its view.
          expect(scope.ofType('error').length <= scope.ofType('view').length).assertTrue();
          scope.refuseType = '';
          const retry: Record<string, Object> = launchCrash(crashedAtMs); // the same incident, next launch
          replayCrash(core, retry);
          expect(retry['delivered']).assertEqual(true);
          const errorIds: Set<string> = new Set<string>();
          for (const e of scope.ofType('error')) {
            errorIds.add((e['error'] as Record<string, Object>)['id'] as string);
          }
          const viewIds: Set<string> = new Set<string>();
          const sessionIds: Set<string> = new Set<string>();
          for (const e of scope.written.filter((e: Record<string, Object>) => sessionOf(e)['id'] !== current)) {
            sessionIds.add(sessionOf(e)['id'] as string);
            if (e['type'] === 'view') {
              viewIds.add((e['view'] as Record<string, Object>)['id'] as string);
            }
          }
          expect(errorIds.size).assertEqual(1);
          expect(viewIds.size).assertEqual(1);
          expect(sessionIds.size).assertEqual(1);
        }
        // Negative control: another incident is another session.
        expect(RumFeature.derivedUuid('incident:a') === RumFeature.derivedUuid('incident:b')).assertFalse();
        expect(RumFeature.derivedUuid('incident:a')).assertEqual(RumFeature.derivedUuid('incident:a'));
      });

    it('aRetryAtAFractionalRateDrawsTheSameWay',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Rate 50, no switch: each incident's session is drawn or not, and its retry after a
        // failed error write must agree, or a view would land without its error.
        let drawnCount: number = 0;
        for (let i: number = 0; i < 16; i++) {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          crashFeature(core, scope, 50, false);
          const crashedAtMs: number = Date.now() - 5000;
          const first: Record<string, Object> = launchCrash(crashedAtMs);
          first['incident_id'] = `incident-${i}`;
          scope.refuseType = 'error';
          replayCrash(core, first);
          scope.refuseType = '';
          const retry: Record<string, Object> = launchCrash(crashedAtMs);
          retry['incident_id'] = `incident-${i}`;
          replayCrash(core, retry);
          expect(retry['delivered']).assertEqual(true);
          if (first['delivered'] === true) {
            expect(scope.written.length).assertEqual(0); // not drawn, on both attempts
          } else {
            drawnCount += 1;
            expect(scope.ofType('error').length).assertEqual(1);
            expect(scope.ofType('view').length >= 1).assertTrue();
          }
        }
        // Both outcomes occur: the rate is applied, not bypassed.
        expect(drawnCount > 0 && drawnCount < 16).assertTrue();
      });

    it('aMapperThatDropsTheLaunchViewStillKeepsTheCrash',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 0, true);
        monitor.startView('home', 'home');
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> | null =>
          event['type'] === 'view' && (event['view'] as Record<string, Object>)['name'] === 'ApplicationLaunch' ?
            null : event);
        try {
          const replay: Record<string, Object> = launchCrash(Date.now() - 5000);
          replayCrash(core, replay);
          expect(replay['delivered']).assertEqual(true);
          expect(scope.ofType('view').length).assertEqual(0);
          expect(scope.ofType('error').length).assertEqual(1);
          // A mapper that drops the crash drops the whole session.
          new CountingMapper().install();
          const dropped: Record<string, Object> = launchCrash(Date.now() - 4000);
          replayCrash(core, dropped);
          expect(dropped['delivered']).assertEqual(true);
          expect(scope.written.length).assertEqual(1);
        } finally {
          RumEventMapperHolder.reset();
        }
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

    it('boundsHeldViewsInBytesAndKeepsTheCurrentOne',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Large host attributes make every view document large; the count
        // limit alone would let 50 of them sit in memory.
        const now: number = 1_000_000;
        const size: number = Math.floor(WITHHELD_BUFFER_VIEW_BYTES_LIMIT / 3) + 1;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        for (let i: number = 0; i < 5; i++) {
          expect(hold(buffer, view(`v${i}`, now + i * 10), size, now + i * 10)).assertTrue();
          hold(buffer, detail('action', `v${i}`, `a${i}`), 10, now + i * 10 + 1);
        }
        const ids: string[] = released(buffer, now + 100)
          .filter((e: Record<string, Object>) => e['type'] === 'view')
          .map((e: Record<string, Object>) => (e['view'] as Record<string, Object>)['id'] as string);
        expect(ids.join(',')).assertEqual('v3,v4');
      });

    it('aViewStorageWouldRefuseIsNotHeldAndTheOlderDocumentStays',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        const first: Record<string, Object> = view('v1', now);
        first['_dd'] = { 'document_version': 1 } as Record<string, Object>;
        first['tag'] = 'first';
        const huge: Record<string, Object> = view('v1', now);
        huge['_dd'] = { 'document_version': 2 } as Record<string, Object>;
        expect(hold(buffer, first, 100, now)).assertTrue();
        // Exactly the cap: storage adds a newline and refuses it.
        expect(hold(buffer, huge, MAX_EVENT_BYTES, now + 1)).assertFalse();
        hold(buffer, detail('error', 'v1', 'e'), 10, now + 2);
        const views: Array<Record<string, Object>> = released(buffer, now + 3)
          .filter((e: Record<string, Object>) => e['type'] === 'view');
        expect(views.length).assertEqual(1);
        expect(views[0]['tag']).assertEqual('first');
      });
  });

  describe('rum-session-on-error-session-id', (): void => {
    it('reportsNoSessionIdWhileWithheldAndTheRealOneOnceReleased',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope,
          new RumConfigurationBuilder('app-1').setSessionSampleRate(0).setSessionOnError(true).build());
        monitor.stopKeepAlive();
        monitor.startView('home', 'home');
        let reported: string | undefined = 'unset';
        monitor.getCurrentSessionId((id: string | undefined): void => {
          reported = id;
        });
        // Withheld: the backend has no session under this id, so the app gets none.
        expect(reported).assertUndefined();
        monitor.addError('boom', RumErrorSource.SOURCE);
        monitor.getCurrentSessionId((id: string | undefined): void => {
          reported = id;
        });
        expect(reported).assertUndefined(); // still behind the jitter
        monitor.releaseScheduledWithheld();
        monitor.getCurrentSessionId((id: string | undefined): void => {
          reported = id;
        });
        expect(reported).assertEqual(core.featureContext['session.id'] as string);
        expect(sessionOf(scope.ofType('view')[0])['id']).assertEqual(reported);

        // Negative control: a session the rate collects reports its id from the start.
        const sampledCore: FakeCore = new FakeCore();
        const sampled: DefaultRumMonitor = new DefaultRumMonitor(sampledCore, new CapturingScope(),
          new RumConfigurationBuilder('app-1').setSessionSampleRate(100).setSessionOnError(true).build());
        sampled.stopKeepAlive();
        sampled.startView('home', 'home');
        sampled.getCurrentSessionId((id: string | undefined): void => {
          reported = id;
        });
        expect(reported).assertEqual(sampledCore.featureContext['session.id'] as string);
      });
  });

  describe('rum-session-on-error-stop', (): void => {
    it('sdkStopCancelsAReleaseStillWaitingOnItsJitter',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const delays: number[] = [];
        const scopes: CapturingScope[] = [];
        for (const stop of [true, false]) {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope,
            new RumConfigurationBuilder('app-1').setSessionSampleRate(0).setSessionOnError(true).build());
          monitor.stopKeepAlive();
          monitor.startView('home', 'home');
          monitor.addError('boom', RumErrorSource.SOURCE);
          // The public API withholds the id along with the events; the context carries it.
          delays.push(computeReleaseDelay(core.featureContext['session.id'] as string));
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

    it('aBurstOfOneActionKeepsOnlyItsNewestAndLeavesTheRestOfTheHistory',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        const t0: number = Date.now();
        startView(app, t0);
        addAction(app, t0 + 1, 'before');
        app.handleEvent(raw('startResource', t0 + 2, 'r1'));
        const failed: RumRawEvent = raw('stopResource', t0 + 3, 'r1');
        failed.statusCode = 503;
        app.handleEvent(failed);
        for (let i: number = 0; i < 150; i++) {
          if (i === 75) {
            startView(app, t0 + 10 + i, 'second');
          }
          addAction(app, t0 + 10 + i, 'scroll');
          if (i % 50 === 0) {
            addAction(app, t0 + 10 + i, 'Scroll'); // another name: case matters
          }
        }
        addAction(app, t0 + 200, 'after');
        addError(app, t0 + 201);
        app.releaseScheduledWithheld();
        const named = (name: string): Array<Record<string, Object>> => scope.ofType('action').filter(
          (e: Record<string, Object>) =>
            ((e['action'] as Record<string, Object>)['target'] as Record<string, Object>)['name'] === name);
        const burst: Array<Record<string, Object>> = named('scroll');
        expect(burst.length).assertEqual(WITHHELD_BUFFER_SAME_ACTION_LIMIT);
        for (let i: number = 0; i < burst.length; i++) {
          // The newest of the burst, in order.
          expect((burst[i]['action'] as Record<string, Object>)['id'])
            .assertEqual(`scroll-${t0 + 10 + 150 - WITHHELD_BUFFER_SAME_ACTION_LIMIT + i}`);
        }
        expect(named('Scroll').length).assertEqual(3);
        expect(named('before').length).assertEqual(1);
        expect(named('after').length).assertEqual(1);
        expect(scope.ofType('resource').length).assertEqual(1);
        expect(scope.ofType('error').length).assertEqual(1);
        const viewNames: Set<string> = new Set<string>();
        for (const e of scope.ofType('view')) {
          viewNames.add((e['view'] as Record<string, Object>)['name'] as string);
        }
        expect(viewNames.has('home')).assertTrue();
        expect(viewNames.has('second')).assertTrue();
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

    it('theCoreAnnouncementOfARefusalReachesTheSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The whole path from the bus message the core sends to the buffer.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const configuration: RumConfiguration =
          new RumConfigurationBuilder('app-1').setSessionSampleRate(0).setSessionOnError(true).build();
        const feature: RumFeature = new RumFeature(core, configuration);
        const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
        monitor.stopKeepAlive();
        feature.attachMonitor(monitor);
        monitor.startView('home', 'home');
        monitor.addAction(RumActionType.TAP, 'before-refusal');
        core.consent = TrackingConsent.NOT_GRANTED;
        feature.onReceive({ 'type': 'consent_revoked' } as Record<string, Object>);
        core.consent = TrackingConsent.GRANTED;
        monitor.addError('boom', RumErrorSource.SOURCE);
        monitor.releaseScheduledWithheld();
        expect(scope.ofType('action').length).assertEqual(0);
        expect(scope.ofType('error').length).assertEqual(1);
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

    it('aLateUpdateOfAnEndedViewDoesNotMakeItCurrentAgain',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        hold(buffer, view('ended', now), 50, now);
        hold(buffer, detail('action', 'ended', 'act'), 10, now + 1);
        hold(buffer, view('current', now + 2), 50, now + 2); // in progress, no detail of its own yet
        // The ended view's final document arrives after the current view started.
        hold(buffer, view('ended', now), 50, now + 3);
        // Prune keeps the current view only by being current: the detail-less
        // one that survives must be `current`, not `ended`.
        hold(buffer, detail('error', 'ended', 'error'), 10, now + 4);
        const out: Array<Record<string, Object>> = released(buffer, now + 5);
        const ids: string[] = out.filter((e: Record<string, Object>) => e['type'] === 'view')
          .map((e: Record<string, Object>) => (e['view'] as Record<string, Object>)['id'] as string);
        expect(ids.join(',')).assertEqual('ended,current');

        // Negative control: with the late update to a view that never had detail
        // and is not current, that view is dropped.
        const other: WithheldEventBuffer = new WithheldEventBuffer();
        hold(other, view('stale', now), 50, now);
        hold(other, view('current', now + 2), 50, now + 2);
        hold(other, view('stale', now), 50, now + 3);
        hold(other, detail('error', 'current', 'error'), 10, now + 4);
        const ids2: string[] = released(other, now + 5).filter((e: Record<string, Object>) => e['type'] === 'view')
          .map((e: Record<string, Object>) => (e['view'] as Record<string, Object>)['id'] as string);
        expect(ids2.join(',')).assertEqual('current');
      });

    it('keepsTheNewestDocumentVersionOfAViewWhateverOrderTheyArriveIn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A document is assembled before its mapper runs; a mapper that reports
        // into the SDK has the next version written first.
        const now: number = 1_000_000;
        const buffer: WithheldEventBuffer = new WithheldEventBuffer();
        const v3: Record<string, Object> = view('v1', now);
        v3['_dd'] = { 'document_version': 3 } as Record<string, Object>;
        const v2: Record<string, Object> = view('v1', now);
        v2['_dd'] = { 'document_version': 2 } as Record<string, Object>;
        hold(buffer, v3, 50, now + 1);
        hold(buffer, v2, 50, now + 2);
        hold(buffer, detail('error', 'v1', 'error'), 10, now + 3);
        const views: Array<Record<string, Object>> = released(buffer, now + 4)
          .filter((e: Record<string, Object>) => e['type'] === 'view');
        expect(views.length).assertEqual(1);
        expect((views[0]['_dd'] as Record<string, Object>)['document_version']).assertEqual(3);
        // Negative control: in order, the later version supersedes.
        const ordered: WithheldEventBuffer = new WithheldEventBuffer();
        hold(ordered, v2, 50, now + 1);
        hold(ordered, v3, 50, now + 2);
        hold(ordered, detail('error', 'v1', 'error'), 10, now + 3);
        const kept: Array<Record<string, Object>> = released(ordered, now + 4)
          .filter((e: Record<string, Object>) => e['type'] === 'view');
        expect((kept[0]['_dd'] as Record<string, Object>)['document_version']).assertEqual(3);
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

    it('anOversizedErrorIsReleasedAtOnceBehindItsView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Too large to hold, but it must still reach storage after the view its
        // session is built from — written ahead, its batch would upload first.
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        addAction(app, Date.now());
        addError(app, Date.now(), 'x'.repeat(WITHHELD_BUFFER_BYTES_LIMIT + 10));
        // The release is one batch, flushed with its last event; the view's
        // own update for the error follows it straight through.
        const types: string[] = scope.written.map((e: Record<string, Object>) => e['type'] as string);
        expect(types.slice(0, 3).join(',')).assertEqual('view,error,action');
        expect(scope.flushes.slice(0, 3).join(',')).assertEqual('false,false,true');
        const written: number = scope.written.length;
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(written);
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

    it('anErrorExactlyAtTheStorageLimitReleasesNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Storage adds a newline, so an error line of exactly the limit is refused.
        const scope: CapturingScope = new CapturingScope();
        scope.rejectAbove = MAX_EVENT_BYTES;
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        const probe: CapturingScope = new CapturingScope();
        const probeApp: RumApplicationScope = onErrorApp(probe);
        startView(probeApp, Date.now());
        addError(probeApp, Date.now(), 'x'.repeat(WITHHELD_BUFFER_BYTES_LIMIT + 10));
        const overhead: number = JSON.stringify(probe.ofType('error')[0]).length - (WITHHELD_BUFFER_BYTES_LIMIT + 10);
        addError(app, Date.now(), 'x'.repeat(MAX_EVENT_BYTES - overhead));
        expect(scope.written.length).assertEqual(0);
      });

    it('anOversizedErrorStorageRefusesReleasesNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = new CapturingScope();
        scope.rejectAbove = MAX_EVENT_BYTES;
        const app: RumApplicationScope = onErrorApp(scope);
        startView(app, Date.now());
        addAction(app, Date.now());
        addError(app, Date.now(), 'x'.repeat(MAX_EVENT_BYTES + 10));
        app.releaseScheduledWithheld();
        expect(scope.written.length).assertEqual(0); // no error reached storage, so no history either
        app.stopCurrentSession(Date.now());
        expect(scope.written.length).assertEqual(0);
        // Negative control: an oversized error storage accepts releases the history.
        const kept: CapturingScope = new CapturingScope();
        kept.rejectAbove = MAX_EVENT_BYTES;
        const app2: RumApplicationScope = onErrorApp(kept);
        startView(app2, Date.now());
        addError(app2, Date.now(), 'x'.repeat(WITHHELD_BUFFER_BYTES_LIMIT * 3));
        app2.releaseScheduledWithheld();
        expect(kept.ofType('error').length).assertEqual(1);
        expect(kept.written[0]['type']).assertEqual('view');
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

    it('aSwitchChangeDoesNotTurnADeferredRateIntoAnImmediateRedraw',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Rate 50 was announced for the next session; republished beside a
        // changed switch under `immediate`, it is still the same announcement.
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
        controller.apply('{"version":1,"enabled":true,"activation":"next_session",' +
          '"rum":{"sessionSampleRate":50,"sessionOnError":false}}', null);
        expect(app.getCurrentSessionId()).assertEqual(id);
        controller.apply('{"version":2,"enabled":true,"activation":"immediate",' +
          '"rum":{"sessionSampleRate":50,"sessionOnError":true}}', null);
        expect(app.getCurrentSessionId()).assertEqual(id);
        // Negative control: a rate that really moved under `immediate` is re-decided.
        controller.apply('{"version":3,"enabled":true,"activation":"immediate",' +
          '"rum":{"sessionSampleRate":60,"sessionOnError":true}}', null);
        expect(app.getCurrentSessionId()).assertUndefined();

        // The same for a session the switch kept: turning the switch off beside
        // a deferred rate does not throw its history away.
        let found: boolean = false;
        for (let attempt: number = 0; attempt < 20 && !found; attempt++) {
          const core2: FakeCore = new FakeCore();
          const store2: RemoteConfigStore = newStore(core2);
          const scope2: CapturingScope = new CapturingScope();
          const app2: RumApplicationScope = new RumApplicationScope(scope2, core2, 'app-1', 1, store2, null, null, true);
          const controller2: RemoteConfigController = new RemoteConfigController(
            store2, new SilentFetcher(), 'https://x/config',
            (activation: string, before: number | null, after: number | null): void => {
              app2.onConfigurationChanged(activation, before, after, Date.now());
            });
          startView(app2, Date.now());
          if (scope2.written.length > 0) {
            continue; // won the 1% draw
          }
          const id2: string = app2.getCurrentSessionId() as string;
          controller2.apply('{"version":1,"enabled":true,"activation":"next_session",' +
            '"rum":{"sessionSampleRate":50,"sessionOnError":true}}', null);
          controller2.apply('{"version":2,"enabled":true,"activation":"immediate",' +
            '"rum":{"sessionSampleRate":50,"sessionOnError":false}}', null);
          expect(app2.getCurrentSessionId()).assertEqual(id2);
          addError(app2, Date.now());
          app2.releaseScheduledWithheld();
          expect(scope2.ofType('error').length).assertEqual(1);
          found = true;
        }
        expect(found).assertTrue();
      });

    it('aCacheWrittenByAnSdkWithoutTheSwitchKeepsItsRateButNotItsValidator',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // An entry written before the switch existed carries a validator for a
        // response whose switch was never read; a 304 against it would keep the
        // switch unknown for as long as the console leaves the configuration
        // alone. The rate it stored — an emergency stop, say — stays in force.
        const core: FakeCore = new FakeCore();
        const key: string = RemoteConfigStore.buildStoreKey(core.getContext(), 'https://intake.example.com', 'app-1');
        core.writeSetting(`${key}.values`, '{"rate":0,"version":10,"etag":"\\"v10\\"","ttl":300,"refresh_on_foreground":false}');
        const legacy: RemoteConfigValues = newStore(core).read() as RemoteConfigValues;
        expect(legacy.sessionSampleRate).assertEqual(0);
        expect(legacy.version).assertEqual(10);
        expect(legacy.etag).assertNull();
        expect(legacy.sessionOnError).assertNull();
        // Negative control: an entry this SDK wrote keeps its validator.
        const store: RemoteConfigStore = newStore(core);
        store.write(new RemoteConfigValues(0, 11, null, '"v11"', 300, false, true));
        const current: RemoteConfigValues = store.read() as RemoteConfigValues;
        expect(current.etag).assertEqual('"v11"');
        expect(current.sessionOnError).assertEqual(true);
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
        LastViewSnapshot.configure((serialized: string): boolean => {
          stored = serialized;
          return true;
        }, (): string => stored, (): void => {
          stored = '';
        });
        try {
          const scope: CapturingScope = new CapturingScope();
          const app: RumApplicationScope = onErrorApp(scope);
          startView(app, Date.now());
          LastViewSnapshot.flush(); // writes are coalesced; a flush puts the latest on file
          expect(scope.written.length).assertEqual(0); // nothing uploaded...
          const snapshot: Record<string, Object> = (LastViewSnapshot.read() as LastView).view;
          expect(snapshot['type']).assertEqual('view'); // ...but the local snapshot is kept
          // What a native crash replays next launch: the crash-marked view keeps the markers.
          const crashed: Record<string, Object> = RumFeature.viewEventWithCrash(snapshot, true);
          expect(sessionOf(crashed)['sampled_for_error']).assertEqual(true);
          expect(sampleRateOf(crashed)).assertEqual(0);
          expect(sessionOf(crashed)['id']).assertEqual(app.getCurrentSessionId() as string);
        } finally {
          LastViewSnapshot.reset();
        }
      });
  });

  describe('rum-session-on-error-discard-and-crash', (): void => {
    it('throwingASessionAwayAlsoThrowsAwayItsLastViewSnapshot',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let stored: string = '';
        let deletes: number = 0;
        LastViewSnapshot.configure((serialized: string): boolean => {
          stored = serialized;
          return true;
        }, (): string => stored, (): void => {
          stored = '';
          deletes += 1;
        });
        try {
          const scope: CapturingScope = new CapturingScope();
          const app: RumApplicationScope = onErrorApp(scope);
          startView(app, Date.now());
          const kept: LastView = LastViewSnapshot.read() as LastView;
          expect(kept.view !== null).assertTrue();
          expect((kept.session as SessionRecord).sampled).assertTrue();
          expect((kept.session as SessionRecord).sampledForError).assertTrue();
          app.stopCurrentSession(Date.now()); // ended without an error: discarded
          // The record stays and says the session is not collected; its view is gone.
          const discarded: LastView = LastViewSnapshot.read() as LastView;
          expect(discarded.view === null).assertTrue();
          expect((discarded.session as SessionRecord).id).assertEqual((kept.session as SessionRecord).id);
          expect((discarded.session as SessionRecord).sampled).assertFalse();
          expect(deletes).assertEqual(0);

          // Negative control: a released session keeps its view and stays collected.
          const released: CapturingScope = new CapturingScope();
          const app2: RumApplicationScope = onErrorApp(released);
          startView(app2, Date.now());
          addError(app2, Date.now());
          app2.stopCurrentSession(Date.now());
          const after: LastView = LastViewSnapshot.read() as LastView;
          expect(after.view !== null).assertTrue();
          expect((after.session as SessionRecord).sampled).assertTrue();
          // ...and the discard of a session that is not the recorded one leaves the file alone.
          const other: CapturingScope = new CapturingScope();
          const app3: RumApplicationScope = onErrorApp(other);
          startView(app3, Date.now());
          const before: string = stored;
          LastViewSnapshot.invalidateFor('another-session');
          expect(stored).assertEqual(before);
          expect(deletes).assertEqual(0);
        } finally {
          LastViewSnapshot.reset();
        }
      });

    it('aNextLaunchCrashCannotResurrectAThrownAwaySession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Run 1: a session kept on error, thrown away without one.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = onErrorFeature(core, scope);
        monitor.startView('home', 'home');
        const discarded: string = core.featureContext['session.id'] as string;
        LastViewSnapshot.flush(); // writes are coalesced; a flush puts the latest on file
        expect(scope.lastView.length > 0).assertTrue();
        monitor.stopSession();
        expect(scope.written.length).assertEqual(0);
        // Run 2: the process died of a native crash in the gap; the replay carries no ids
        // (the JS incident path leaves `session.sampled` true and the id empty: same replay).
        const next: CapturingScope = new CapturingScope();
        next.lastView = scope.lastView; // whatever run 1 left in the crash storage
        const monitor2: DefaultRumMonitor = onErrorFeature(core, next);
        monitor2.startView('home', 'home');
        const feature: RumFeature = new RumFeature(core,
          new RumConfigurationBuilder('app-1').setSessionSampleRate(0).setSessionOnError(true).build());
        feature.onInitialize();
        feature.attachMonitor(monitor2);
        feature.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'process_id': process.pid, 'crash_kind': 'crash',
          'timestamp_ms': Date.now() } as Record<string, Object>);
        for (const e of next.written) {
          expect(sessionOf(e)['id'] === discarded).assertFalse();
        }
        // Negative control: a session that errored keeps its snapshot, and the crash lands in it.
        const core2: FakeCore = new FakeCore();
        const scope2: CapturingScope = new CapturingScope();
        const monitor3: DefaultRumMonitor = onErrorFeature(core2, scope2);
        monitor3.startView('home', 'home');
        const released: string = core2.featureContext['session.id'] as string;
        monitor3.addError('boom', RumErrorSource.SOURCE);
        const faultAtMs: number = Date.now();
        waitPast(faultAtMs); // the session ends after the fault
        monitor3.stopSession();
        LastViewSnapshot.flush();
        const snapshot: string = scope2.lastView;
        expect(snapshot.length > 0).assertTrue();
        const next2: CapturingScope = new CapturingScope();
        next2.lastView = snapshot;
        const feature2: RumFeature = new RumFeature(core2,
          new RumConfigurationBuilder('app-1').setSessionSampleRate(0).setSessionOnError(true).build());
        core2.rumScope = next2;
        feature2.onInitialize();
        feature2.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'process_id': process.pid, 'crash_kind': 'crash',
          'timestamp_ms': faultAtMs } as Record<string, Object>);
        expect(next2.ofType('error').length).assertEqual(1);
        expect(sessionOf(next2.ofType('error')[0])['id']).assertEqual(released);
      });

    it('aCrashReplayedFromTheLastViewCarriesTheCrashedRunsContext',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Run 1: version 1.0.0, signed in, a session attribute; the process dies of a native crash.
        const core: FakeCore = new FakeCore();
        const signedIn: UserInfo = { id: 'u-1' };
        core.user = signedIn;
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.addAttribute('channel', 'store');
        monitor.startView('home', 'home');
        const crashed: string = core.featureContext['session.id'] as string;
        LastViewSnapshot.flush();
        // Run 2: the app was updated and the user signed out before the relaunch.
        core.appVersion = '2.0.0';
        core.user = {};
        const next: CapturingScope = new CapturingScope();
        next.lastView = scope.lastView;
        next.core = core;
        core.rumScope = next;
        const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
        feature.onInitialize();
        feature.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'process_id': process.pid,
          'crash_kind': 'crash', 'timestamp_ms': Date.now(),
          'memory': { 'rss_kb': 1 } as Record<string, Object> } as Record<string, Object>);
        const errors: Array<Record<string, Object>> = next.ofType('error');
        expect(errors.length).assertEqual(1);
        expect(sessionOf(errors[0])['id']).assertEqual(crashed);
        expect(errors[0]['version']).assertEqual('1.0.0');
        expect((errors[0]['usr'] as Record<string, Object>)['id']).assertEqual('u-1');
        const context: Record<string, Object> = errors[0]['context'] as Record<string, Object>;
        expect(context['channel']).assertEqual('store');
        expect(context['crash.memory.rss_kb']).assertEqual(1);
        // Negative control: with no snapshot the crash goes to a session of its own, as the current run.
        const orphan: CapturingScope = new CapturingScope();
        const monitor2: DefaultRumMonitor = featureWith(core, orphan, 100, false);
        monitor2.startView('home', 'home');
        const feature2: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
        feature2.onInitialize();
        feature2.attachMonitor(monitor2);
        feature2.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'process_id': process.pid,
          'crash_kind': 'crash', 'timestamp_ms': Date.now() } as Record<string, Object>);
        const orphans: Array<Record<string, Object>> = orphan.ofType('error');
        expect(orphans.length).assertEqual(1);
        expect(orphans[0]['version']).assertEqual('2.0.0');
        expect((orphans[0]['context'] as Record<string, Object>)['channel'] === undefined).assertTrue();
      });

    it('aFaultOlderThanTheLastViewIsNotAttributedToItsRun',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A fault reported now but dated before the snapshot's view started did not happen in
        // that view: neither its session nor that run's user, version and attributes are the
        // crash's. It goes to a session of its own, as the current run.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.addAttribute('channel', 'store');
        monitor.startView('home', 'home');
        const snapshotted: string = core.featureContext['session.id'] as string;
        LastViewSnapshot.flush();
        core.appVersion = '2.0.0';
        const next: CapturingScope = new CapturingScope();
        next.lastView = scope.lastView;
        next.core = core;
        core.rumScope = next;
        const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
        const feature: RumFeature = new RumFeature(core, configuration);
        feature.onInitialize(); // loads the snapshot
        const monitor2: DefaultRumMonitor = new DefaultRumMonitor(core, next, configuration);
        monitor2.stopKeepAlive();
        feature.attachMonitor(monitor2);
        monitor2.startView('home', 'home');
        const replay = (faultAtMs: number): Record<string, Object> => {
          feature.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'process_id': process.pid,
            'crash_kind': 'crash', 'timestamp_ms': faultAtMs } as Record<string, Object>);
          const errors: Array<Record<string, Object>> = next.ofType('error');
          return errors[errors.length - 1];
        };
        const older: Record<string, Object> = replay(Date.now() - 60 * 1000);
        expect(sessionOf(older)['id'] === snapshotted).assertFalse();
        expect(older['version']).assertEqual('2.0.0');
        expect((older['context'] as Record<string, Object>)['channel'] === undefined).assertTrue();
        // Negative control: the same snapshot takes a fault dated inside its view.
        const inside: Record<string, Object> = replay(Date.now());
        expect(sessionOf(inside)['id']).assertEqual(snapshotted);
        expect(inside['version']).assertEqual('1.0.0');
      });

    it('aFaultOfALaterProcessIsNotAttributedToTheLastView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Run 1 writes its last view. Run 2 crashes before RUM starts, writing nothing, so the
        // file still holds run 1's view. Run 3 receives run 2's fault: it is not run 1's.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.addAttribute('channel', 'store');
        monitor.startView('home', 'home');
        const run1: string = core.featureContext['session.id'] as string;
        LastViewSnapshot.flush();
        core.appVersion = '2.0.0';
        const replay = (faultPid: number): Record<string, Object> => {
          const next: CapturingScope = new CapturingScope();
          next.lastView = scope.lastView;
          next.core = core;
          core.rumScope = next;
          const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').build();
          const feature: RumFeature = new RumFeature(core, configuration);
          feature.onInitialize(); // loads run 1's view
          const live: DefaultRumMonitor = new DefaultRumMonitor(core, next, configuration);
          live.stopKeepAlive();
          feature.attachMonitor(live);
          live.startView('home', 'home');
          feature.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc',
            'crash_kind': 'crash', 'timestamp_ms': Date.now(), 'process_id': faultPid } as Record<string, Object>);
          const errors: Array<Record<string, Object>> = next.ofType('error');
          expect(errors.length).assertEqual(1);
          return errors[0];
        };
        const later: Record<string, Object> = replay(process.pid + 1);
        expect(sessionOf(later)['id'] === run1).assertFalse();
        expect(later['version']).assertEqual('2.0.0');
        expect((later['context'] as Record<string, Object>)['channel'] === undefined).assertTrue();
        // Negative control: run 1's own fault is attributed to its last view.
        const own: Record<string, Object> = replay(process.pid);
        expect(sessionOf(own)['id']).assertEqual(run1);
        expect(own['version']).assertEqual('1.0.0');
      });

    it('aLastViewFileWithoutTheWritingProcessIsNotUsed',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A file in the earlier format (the bare view) cannot say which process wrote it.
        let stored: string = JSON.stringify({ 'type': 'view', 'session': { 'id': 's-1' } } as Record<string, Object>);
        LastViewSnapshot.configure((serialized: string): boolean => {
          stored = serialized;
          return true;
        }, (): string => stored, (): void => {
          stored = '';
        });
        try {
          expect(LastViewSnapshot.read() === null).assertTrue();
          // Negative control: the current format reads back with its process.
          LastViewSnapshot.record({ 'type': 'view', 'session': { 'id': 's-2' } } as Record<string, Object>);
          LastViewSnapshot.flush();
          const read: LastView = LastViewSnapshot.read() as LastView;
          expect(read.pid).assertEqual(process.pid);
          expect(sessionOf(read.view)['id']).assertEqual('s-2');
        } finally {
          LastViewSnapshot.reset();
        }
      });

    it('aJsIncidentReplayedIntoItsSessionCarriesThatRunsContext',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.addAttribute('channel', 'store');
        monitor.startView('home', 'home');
        const crashed: string = core.featureContext['session.id'] as string;
        const view: string = core.featureContext['view.id'] as string;
        LastViewSnapshot.flush();
        core.appVersion = '2.0.0';
        const replay = (sessionId: string, viewId: string): Record<string, Object> => {
          const next: CapturingScope = new CapturingScope();
          next.lastView = scope.lastView;
          next.core = core;
          core.rumScope = next;
          const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
          feature.onInitialize();
          feature.onReceive({ 'type': 'crash_report', 'message': 'Error: boom', 'stack': 'at f',
            'crash_kind': 'crash', 'timestamp_ms': Date.now() - 1000, 'incident_id': 'i-1',
            'original_session_id': sessionId, 'original_view_id': viewId,
            'original_view_name': 'home' } as Record<string, Object>);
          const errors: Array<Record<string, Object>> = next.ofType('error');
          expect(errors.length).assertEqual(1);
          return errors[0];
        };
        const own: Record<string, Object> = replay(crashed, view);
        expect(own['version']).assertEqual('1.0.0');
        expect((own['context'] as Record<string, Object>)['channel']).assertEqual('store');
        // Negative controls: the previous run's view belongs to another session, or is not the
        // view the crash happened in (a crash right after a view change) — nothing is borrowed.
        for (const ids of [['another-session', view], [crashed, 'another-view']]) {
          const other: Record<string, Object> = replay(ids[0], ids[1]);
          expect(other['version']).assertEqual('2.0.0');
          expect((other['context'] as Record<string, Object>)['channel'] === undefined).assertTrue();
        }
      });

    it('theMapperJudgesAPersistedCrashOnTheSameEventItWillBeReplayedAs',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Asked at crash time for a session that withholds its events, the mapper must see the
        // session's attributes the replay will carry — or it keeps here what it drops there.
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> | null =>
          event['type'] === 'error' && (event['context'] as Record<string, Object>)['channel'] === 'store'
            ? null : event);
        try {
          const crashWith = (channel: string): FakeCore => {
            const core: FakeCore = new FakeCore();
            core.crashScope = new FakeCrashScope(core);
            const scope: CapturingScope = new CapturingScope();
            const monitor: DefaultRumMonitor = onErrorFeature(core, scope);
            monitor.addAttribute('channel', channel);
            monitor.startView('home', 'home');
            fireUnhandledException('Error name:Error\nError message:fatal\nStacktrace:\nat a (b.ets:1:1)');
            return core;
          };
          const dropped: FakeCore = crashWith('store');
          expect((dropped.crashScope as FakeCrashScope).controls[0]['suppressed']).assertEqual(true);
          // Negative control: an attribute the mapper does not drop on.
          const kept: FakeCore = crashWith('web');
          expect((kept.crashScope as FakeCrashScope).controls[0]['suppressed'] === true).assertFalse();
        } finally {
          RumEventMapperHolder.reset();
        }
      });

    it('aTerminatingCrashTheMapperDropsReleasesNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> | null =>
          event['type'] === 'error' ? null : event);
        try {
          const core: FakeCore = new FakeCore();
          core.crashScope = new FakeCrashScope(core);
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = onErrorFeature(core, scope);
          monitor.startView('home', 'home');
          monitor.addAction(RumActionType.TAP, 'before');
          fireUnhandledException('Error name:Error\nError message:fatal\nStacktrace:\nat a (b.ets:1:1)');
          expect(scope.written.length).assertEqual(0);
          // The crash feature was told, so nothing is persisted for a replay either.
          expect(core.crashScope.controls.length).assertEqual(1);
          expect(core.crashScope.controls[0]['suppressed']).assertEqual(true);
        } finally {
          RumEventMapperHolder.reset();
        }
        // Negative control: a crash the mapper keeps releases the history at once.
        const core2: FakeCore = new FakeCore();
        core2.crashScope = new FakeCrashScope(core2);
        const kept: CapturingScope = new CapturingScope();
        const monitor2: DefaultRumMonitor = onErrorFeature(core2, kept);
        monitor2.startView('home', 'home');
        monitor2.addAction(RumActionType.TAP, 'before');
        fireUnhandledException('Error name:Error\nError message:fatal\nStacktrace:\nat a (b.ets:1:1)');
        expect(kept.ofType('view').length >= 1).assertTrue();
        expect(kept.ofType('action').length).assertEqual(1);
        expect(core2.crashScope.controls[0]['suppressed'] === true).assertFalse();
      });

    it('typesAnUncaughtErrorByItsExceptionName',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The one error the scenario writes, with the crash feature answering in `policy` ('' = no crash feature).
        const reported = (policy: string, fire: () => void): Record<string, Object> => {
          const core: FakeCore = new FakeCore();
          if (policy.length > 0) {
            core.crashScope = new FakeCrashScope(core);
            core.crashScope.policy = policy;
          }
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
          monitor.startView('home', 'home');
          fire();
          const errors: Array<Record<string, Object>> = scope.ofType('error');
          expect(errors.length).assertEqual(1);
          return errors[0];
        };
        const typeOf = (policy: string, fire: () => void): Object | undefined =>
          (reported(policy, fire)['error'] as Record<string, Object>)['type'];
        const typeError = (): void =>
          fireUnhandledException('Error name:TypeError\nError message:x is undefined\nStacktrace:\nat a (b.ets:1:1)');
        // Every live path: RUM's own crash report, the crash feature's live crash, the plain error.
        expect(typeOf('', typeError)).assertEqual('TypeError');
        expect(typeOf('report_and_continue', typeError)).assertEqual('TypeError');
        expect(typeOf('observe_only', typeError)).assertEqual('TypeError');
        expect(typeOf('observe_only', (): void => fireException(new RangeError('out of range'))))
          .assertEqual('RangeError');
        expect(typeOf('', (): void => fireUnhandledRejection(new SyntaxError('bad json')))).assertEqual('SyntaxError');
        // The type is the error's, not a custom attribute.
        const event: Record<string, Object> = reported('', typeError);
        expect((event['context'] as Record<string, Object>)['error.type']).assertUndefined();
        // Negative control: a rejection with a reason that is not an Error has no type, as in the browser SDK.
        expect(typeOf('', (): void => fireUnhandledRejection('plain refusal'))).assertUndefined();
      });

    it('typesAReportedCrashWithTheTypeTheCrashFeatureGaveIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const typeOf = (crash: Record<string, Object>): Object | undefined => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          core.rumScope = scope;
          const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(100).build();
          const feature: RumFeature = new RumFeature(core, configuration);
          feature.onInitialize();
          const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
          monitor.stopKeepAlive();
          feature.attachMonitor(monitor);
          monitor.startView('home', 'home');
          feature.onReceive(crash);
          const errors: Array<Record<string, Object>> = scope.ofType('error');
          expect(errors.length).assertEqual(1);
          return (errors[0]['error'] as Record<string, Object>)['type'];
        };
        expect(typeOf({ 'type': 'crash_report', 'message': 'SIGSEGV(SEGV_MAPERR)', 'error_type': 'SIGSEGV',
          'stack': '#00 pc', 'crash_kind': 'crash' } as Record<string, Object>)).assertEqual('SIGSEGV');
        // Negative control: a report without a type (an older crash module) leaves the type unset.
        expect(typeOf({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc',
          'crash_kind': 'crash' } as Record<string, Object>)).assertUndefined();
      });

    it('anUncaughtExceptionWithoutTheCrashFeatureReleasesAtOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = onErrorFeature(core, scope);
        monitor.startView('home', 'home');
        monitor.addAction(RumActionType.TAP, 'before');
        fireUnhandledException('Error name:Error\nError message:fatal\nStacktrace:\nat a (b.ets:1:1)');
        // No jitter: the process may not live that long.
        expect(scope.ofType('error').length).assertEqual(1);
        expect(scope.ofType('action').length).assertEqual(1);
        // Negative control: an unhandled rejection keeps the jitter.
        const core2: FakeCore = new FakeCore();
        const quiet: CapturingScope = new CapturingScope();
        const monitor2: DefaultRumMonitor = onErrorFeature(core2, quiet);
        monitor2.startView('home', 'home');
        fireUnhandledRejection(new Error('later'));
        expect(quiet.written.length).assertEqual(0);
        monitor2.releaseScheduledWithheld();
        expect(quiet.ofType('error').length).assertEqual(1);
      });

    it('anImmediateRateRiseKeepsASessionTheSwitchKept',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        expect(RumApplicationScope.shouldEndSession(true, 0, 50, 'immediate', true, true)).assertFalse();
        // Negative control: a session the rate drew is still re-decided.
        expect(RumApplicationScope.shouldEndSession(true, 20, 50, 'immediate', false, true)).assertTrue();

        const core: FakeCore = new FakeCore();
        const store: RemoteConfigStore = newStore(core);
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core, store);
        const controller: RemoteConfigController = new RemoteConfigController(
          store, new SilentFetcher(), 'https://x/config',
          (activation: string, before: number | null, after: number | null): void => {
            app.onConfigurationChanged(activation, before, after, Date.now());
          });
        const now: number = Date.now();
        startView(app, now);
        addAction(app, now + 1, 'held');
        const id: string = core.featureContext['session.id'] as string;
        controller.apply('{"version":1,"enabled":true,"activation":"immediate",' +
          '"rum":{"sessionSampleRate":50,"sessionOnError":true}}', null);
        expect(core.featureContext['session.id']).assertEqual(id); // kept, history included
        addError(app, now + 2);
        app.releaseScheduledWithheld();
        expect(scope.ofType('action').length).assertEqual(1);
        expect(scope.ofType('error').length).assertEqual(1);
      });
  });

  describe('rum-session-on-error-crash-mapper', (): void => {
    it('observeOnlyReportsTheLiveErrorOnceThroughTheMapperWhateverTheSwitch',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A mapper that drops crashes but keeps ordinary errors: OBSERVE_ONLY
        // reports the exception as an ordinary error, exactly once, and no
        // incident is ever involved — with the switch off...
        const mapper: CountingMapper = new CountingMapper();
        mapper.install();
        try {
          const core: FakeCore = new FakeCore();
          core.crashScope = new FakeCrashScope(core);
          core.crashScope.policy = 'observe_only';
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
          monitor.startView('home', 'home');
          fireUnhandledException(CRASH_TEXT);
          expect(scope.ofType('error').length).assertEqual(1);
          expect(mapper.crashesSeen).assertEqual(0);
          expect(mapper.errorsSeen).assertEqual(1);
          expect(core.crashScope.probes.length).assertEqual(0);
          expect(core.crashScope.controls[0]['suppressed'] === true).assertFalse();
          // ...and with the switch on, where the session was withholding.
          const core2: FakeCore = new FakeCore();
          core2.crashScope = new FakeCrashScope(core2);
          core2.crashScope.policy = 'observe_only';
          const scope2: CapturingScope = new CapturingScope();
          const monitor2: DefaultRumMonitor = featureWith(core2, scope2, 0, true);
          monitor2.startView('home', 'home');
          fireUnhandledException(CRASH_TEXT);
          expect(scope2.ofType('error').length).assertEqual(1);
          expect(mapper.crashesSeen).assertEqual(0);
          expect(core2.crashScope.probes.length).assertEqual(0);
        } finally {
          RumEventMapperHolder.reset();
        }
      });

    it('aTerminatingCrashInACollectedSessionLeavesTheMapperToTheReplay',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Not withheld: nothing the crash does in this process depends on the
        // mapper, so it is not asked now — the replay asks it once, as before.
        const mapper: CountingMapper = new CountingMapper();
        mapper.install();
        try {
          const core: FakeCore = new FakeCore();
          core.crashScope = new FakeCrashScope(core);
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
          monitor.startView('home', 'home');
          fireUnhandledException(CRASH_TEXT);
          expect(mapper.crashesSeen).assertEqual(0);
          expect(core.crashScope.controls[0]['suppressed'] === true).assertFalse();
          expect(core.crashScope.controls[0]['pending_written']).assertEqual(true);
          // The crash is counted on the view, as on a run without the switch.
          const views: Array<Record<string, Object>> = scope.ofType('view');
          const last: Record<string, Object> = views[views.length - 1];
          expect(((last['view'] as Record<string, Object>)['crash'] as Record<string, Object>)['count']).assertEqual(1);
        } finally {
          RumEventMapperHolder.reset();
        }
      });

    it('theCrashTheMapperJudgesIsTheOneTheReplayWillCarry',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A mapper keyed on a field only the replayed event carries
        // (`crash.recovered`): the verdict at crash time must be the replay's.
        const mapper: CountingMapper = new CountingMapper('crash.recovered');
        mapper.install();
        try {
          const core: FakeCore = new FakeCore();
          core.crashScope = new FakeCrashScope(core);
          core.crashScope.recover = true;
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = onErrorFeature(core, scope);
          monitor.startView('home', 'home');
          monitor.addAction(RumActionType.TAP, 'before');
          fireUnhandledException(CRASH_TEXT);
          expect(mapper.crashesSeen).assertEqual(1);
          expect(core.crashScope.controls[0]['suppressed']).assertEqual(true);
          expect(scope.written.length).assertEqual(0); // no release, nothing billed
          // Negative control: the same crash without a recovery is kept and released.
          const core2: FakeCore = new FakeCore();
          core2.crashScope = new FakeCrashScope(core2);
          const kept: CapturingScope = new CapturingScope();
          const monitor2: DefaultRumMonitor = onErrorFeature(core2, kept);
          monitor2.startView('home', 'home');
          monitor2.addAction(RumActionType.TAP, 'before');
          fireUnhandledException(CRASH_TEXT);
          expect(core2.crashScope.controls[0]['suppressed'] === true).assertFalse();
          expect(kept.ofType('action').length).assertEqual(1);
        } finally {
          RumEventMapperHolder.reset();
        }
      });
  });

  describe('rum-js-crash-continue', (): void => {
    /** A sampled RUM feature with error capture switched off, under the given crash policy. */
    function trackErrorsOff(policy: string, viewClosed: boolean = false): CapturingScope {
      const core: FakeCore = new FakeCore();
      core.crashScope = new FakeCrashScope(core);
      core.crashScope.policy = policy;
      const scope: CapturingScope = new CapturingScope();
      core.rumScope = scope;
      const configuration: RumConfiguration =
        new RumConfigurationBuilder('app-1').setSessionSampleRate(100).setTrackErrors(false).build();
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
      monitor.stopKeepAlive();
      feature.attachMonitor(monitor);
      monitor.startView('home', 'home');
      if (viewClosed) {
        monitor.stopView('home');
      }
      fireUnhandledException(CRASH_TEXT);
      return scope;
    }

    it('aContinuedCrashIsACrashOfTheLiveViewEvenWithErrorCaptureOff',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const scope: CapturingScope = trackErrorsOff('report_and_continue');
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        const error: Record<string, Object> = errors[0]['error'] as Record<string, Object>;
        expect(error['is_crash']).assertEqual(true);
        expect(error['message']).assertEqual('Error: fatal');
        expect(error['category']).assertEqual('Exception');
        const views: Array<Record<string, Object>> = scope.ofType('view');
        const last: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
        expect((last['crash'] as Record<string, Object>)['count']).assertEqual(1);
        // Negative control: OBSERVE_ONLY reports nothing once error capture is off.
        expect(trackErrorsOff('observe_only').ofType('error').length).assertEqual(0);
      });

    it('aContinuedCrashInAWithheldSessionReleasesAtOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Another observer (e.g. a crash reporter exiting from onException) may
        // still end the process: what the session held must not wait for a jitter.
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        core.crashScope.policy = 'report_and_continue';
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = onErrorFeature(core, scope);
        monitor.startView('home', 'home');
        monitor.addAction(RumActionType.TAP, 'before');
        fireUnhandledException(CRASH_TEXT);

        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        expect((errors[0]['error'] as Record<string, Object>)['is_crash']).assertEqual(true);
        expect(scope.ofType('action').length).assertEqual(1);
      });

    it('aPreviousLaunchCrashInAViewGapStaysOffThisLaunchsViews',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A native crash of an earlier launch, delivered with no last-view
        // snapshot, while this launch sits between two views.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        core.rumScope = scope;
        const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(100).build();
        const feature: RumFeature = new RumFeature(core, configuration);
        feature.onInitialize();
        const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
        monitor.stopKeepAlive();
        feature.attachMonitor(monitor);
        monitor.startView('home', 'home');
        monitor.stopView('home');
        feature.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'crash_kind': 'crash',
          'timestamp_ms': Date.now() - 1000 } as Record<string, Object>);

        const current: string = core.featureContext['session.id'] as string;
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        expect(sessionOf(errors[0])['id'] === current).assertFalse();
        expect((errors[0]['view'] as Record<string, Object>)['name']).assertEqual('ApplicationLaunch');
        const views: Array<Record<string, Object>> = scope.ofType('view')
          .filter((e: Record<string, Object>) => sessionOf(e)['id'] === current);
        const last: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
        expect(last['name']).assertEqual('home');
        expect((last['crash'] as Record<string, Object>)['count']).assertEqual(0);
      });

    it('aContinuedCrashAfterThePageClosedCountsOnTheLastClosedView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // e.g. a timer throwing after the page was hidden by backgrounding.
        const scope: CapturingScope = trackErrorsOff('report_and_continue', true);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        expect((errors[0]['error'] as Record<string, Object>)['is_crash']).assertEqual(true);
        const views: Array<Record<string, Object>> = scope.ofType('view');
        const last: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
        expect(last['name']).assertEqual('home');
        expect((last['crash'] as Record<string, Object>)['count']).assertEqual(1);
        expect((errors[0]['view'] as Record<string, Object>)['id']).assertEqual(last['id']);
      });
  });
  describe('rum-host-safety', (): void => {
    it('aMapperThatReportsIntoTheSdkGetsControlBack',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // An event the mapper causes would be mapped again, and cause another:
        // the host's call never returned. It is dropped instead.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        let calls: number = 0;
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> => {
          calls += 1;
          if (calls < 50) { // bounds the loop when the guard is missing
            monitor.addError('from mapper', RumErrorSource.CUSTOM);
          }
          return event;
        });
        try {
          monitor.startView('v', 'V');
          monitor.addAction(RumActionType.TAP, 'a');
          expect(calls <= 4).assertTrue();
          const fromMapper: Array<Record<string, Object>> = scope.ofType('error').filter(
            (e: Record<string, Object>) => (e['error'] as Record<string, Object>)['message'] === 'from mapper');
          expect(fromMapper.length).assertEqual(0);
          expect(scope.ofType('action').length).assertEqual(1);
        } finally {
          RumEventMapperHolder.reset();
        }
        // The ignored call changed nothing: no error is counted on the view.
        monitor.stopView('v');
        const views: Array<Record<string, Object>> = scope.ofType('view');
        const last: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
        expect((last['error'] as Record<string, Object>)['count']).assertEqual(0);
      });

    it('aMapperCannotEndTheSessionItIsMapping',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('v', 'V');
        let before: string | undefined = undefined;
        monitor.getCurrentSessionId((id: string | undefined): void => {
          before = id;
        });
        RumEventMapperHolder.configure((event: Record<string, Object>): Record<string, Object> => {
          monitor.stopSession();
          return event;
        });
        try {
          monitor.addAction(RumActionType.TAP, 'a');
        } finally {
          RumEventMapperHolder.reset();
        }
        let after: string | undefined = undefined;
        monitor.getCurrentSessionId((id: string | undefined): void => {
          after = id;
        });
        expect(before !== undefined).assertTrue();
        expect(after).assertEqual(before);
      });

    it('hostileAttributesAndKeysNeverThrowIntoTheHost',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        const hostile: Record<string, Object> = {};
        Object.defineProperty(hostile, 'boom', {
          enumerable: true,
          get: (): Object => {
            throw new Error('getter');
          }
        });
        const badKey: Object = {
          toString: (): string => {
            throw new Error('toString');
          }
        };
        let threw: boolean = false;
        try {
          monitor.startView('v', 'V', hostile);
          monitor.stopView('v', hostile);
          monitor.addAction(RumActionType.TAP, 'a', hostile);
          monitor.startResource('r', RumResourceMethod.GET, 'https://a.example', hostile);
          monitor.stopResource('r', 200, 1, RumResourceKind.NATIVE, hostile);
          monitor.stopResourceWithError('r', 'x', 500, hostile);
          monitor.startAction(badKey as RumActionType, 'n');
          monitor.stopAction(badKey as RumActionType, 'n');
          monitor.addAttribute(badKey as string, 1);
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
        // A key that cannot be a property name is refused, so it cannot fail every later event.
        monitor.startView('w', 'W');
        monitor.addAction(RumActionType.TAP, 'after');
        expect(scope.ofType('action').filter(
          (e: Record<string, Object>) => (e['action'] as Record<string, Object>)['target'] !== undefined).length >= 1).assertTrue();
      });

    it('theGlobalErrorCallbacksNeverRaiseOnOddInput',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        featureWith(core, scope, 100, false);
        const observers: Record<string, Object> =
          (errorManager as Object as Record<string, Object>)['lastObservers'] as Record<string, Object>;
        const observer: errorManager.ErrorObserver = observers['error'] as errorManager.ErrorObserver;
        let threw: boolean = false;
        try {
          // A non-Error throw can reach onException as a plain value.
          (observer.onException as (e: Object) => void)(undefined as Object as Error);
          (observer.onException as (e: Object) => void)('a string' as Object as Error);
          observer.onUnhandledException(undefined as Object as string);
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
      });

    it('aReplayedCrashThatCannotBeWrittenIsNotMarkedDelivered',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Crash replay deletes the persisted incident once RUM says it was
        // delivered: a write that failed must not say so, or the crash is lost.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
        feature.onInitialize();
        feature.attachMonitor(monitor);
        monitor.startView('home', 'home');
        const cyclic: Record<string, Object> = {};
        cyclic['self'] = cyclic;
        monitor.addAttribute('cyclic', cyclic); // every write now fails
        const event: Record<string, Object> = { 'type': 'crash_report', 'message': 'NativeCrash',
          'stack': '#00 pc', 'crash_kind': 'crash', 'timestamp_ms': Date.now() - 1000 };
        try {
          feature.onReceive(event);
        } catch (_e) {
          // the bus contains this in production
        }
        expect(event['delivered'] === true).assertFalse();
      });

    it('withoutTheCrashModuleAnUncaughtExceptionIsACrashAndTheAppExits',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Enabling RUM alone must not keep a crashed app alive: the observer it
        // registers suppresses the platform's exit, so RUM restores it.
        const core: FakeCore = new FakeCore(); // no crash feature
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const shim: Record<string, Object> = process as Object as Record<string, Object>;
        const before: number = shim['exitRequests'] as number;
        fireUnhandledException(CRASH_TEXT);

        expect((shim['exitRequests'] as number) - before).assertEqual(1);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        expect((errors[0]['error'] as Record<string, Object>)['is_crash']).assertEqual(true);
      });

    it('withoutTheCrashModuleOneFaultExitsOnceAndCountsOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const shim: Record<string, Object> = process as Object as Record<string, Object>;
        const before: number = shim['exitRequests'] as number;
        // The test runner does not really exit, so the second callback of the
        // same fault arrives: it must not count the crash again.
        fireUnhandledException(CRASH_TEXT);
        const observers: Record<string, Object> =
          (errorManager as Object as Record<string, Object>)['lastObservers'] as Record<string, Object>;
        (observers['error'] as errorManager.ErrorObserver).onException(new Error('fatal'));

        expect((shim['exitRequests'] as number) - before).assertEqual(1);
        expect(scope.ofType('error').length).assertEqual(1);
      });

    it('withoutTheCrashModuleALaterFaultIsANewCrash',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // If the exit did not take (the runner never exits), a fault outside the
        // first one's callback window is a new crash: reported, and exited again.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const shim: Record<string, Object> = process as Object as Record<string, Object>;
        const before: number = shim['exitRequests'] as number;
        fireUnhandledException(CRASH_TEXT);
        // The window is time based: age the first exit past it.
        const realNow: () => number = Date.now;
        Date.now = (): number => realNow() + 5000;
        try {
          fireUnhandledException('Error name:Error\nError message:another\nStacktrace:\nat c (d.ets:2:2)');
        } finally {
          Date.now = realNow;
        }
        expect((shim['exitRequests'] as number) - before).assertEqual(2);
        expect(scope.ofType('error').length).assertEqual(2);
      });

    it('aCrashModuleWithoutAPublishedPolicyDecidesNotRum',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        core.crashScope.policy = ''; // registered, but no policy reached RUM
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const shim: Record<string, Object> = process as Object as Record<string, Object>;
        const before: number = shim['exitRequests'] as number;
        fireUnhandledException(CRASH_TEXT);
        expect((shim['exitRequests'] as number) - before).assertEqual(0);
      });

    it('enableBeforeInitializeIsANoOp',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let threw: boolean = false;
        try {
          FlashcatRum.enable(new RumConfigurationBuilder('app-1').build());
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
      });

    it('aFailureInsideTheSdkNeverThrowsIntoTheHost',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        // A host attribute holding a cycle: serializing any event that carries it throws.
        const cyclic: Record<string, Object> = {};
        cyclic['self'] = cyclic;
        let threw: boolean = false;
        try {
          monitor.startView('home', 'home');
          monitor.addAttribute('cyclic', cyclic);
          monitor.addAction(RumActionType.TAP, 'tap');
          monitor.addError('boom', RumErrorSource.SOURCE);
          monitor.stopView('home');
          monitor.stopSession();
        } catch (_e) {
          threw = true;
        }

        expect(threw).assertFalse();
        // The SDK keeps working once the bad attribute is gone.
        monitor.removeAttribute('cyclic');
        monitor.startView('next', 'next');
        monitor.addAction(RumActionType.TAP, 'after');
        expect(scope.ofType('action').length >= 1).assertTrue();
      });
  });
  describe('rum-last-view-coalescing', (): void => {
    it('manyViewUpdatesCostOneWriteAndAFlushPointLandsItAtOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let writes: number = 0;
        let stored: string = '';
        LastViewSnapshot.configure((serialized: string): boolean => {
          writes += 1;
          stored = serialized;
          return true;
        }, (): string => stored, (): void => {
          stored = '';
        });
        try {
          for (let i: number = 0; i < 100; i++) {
            LastViewSnapshot.record({ 'type': 'view', 'session': { 'id': 's-1' }, 'n': i } as Record<string, Object>);
          }
          expect(writes).assertEqual(0); // nothing synchronous on the event path
          // What the core's flush points (background, flush, pre-exit, stop) do via keep_alive.
          LastViewSnapshot.flush();
          expect(writes).assertEqual(1);
          const file: Record<string, Object> = JSON.parse(stored) as Record<string, Object>;
          expect((file['view'] as Record<string, Object>)['n']).assertEqual(99); // the latest one
          expect(file['pid']).assertEqual(process.pid); // and the process that wrote it
        } finally {
          LastViewSnapshot.reset();
        }
      });

    it('throwingASessionAwayCancelsItsPendingSnapshot',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let writes: number = 0;
        LastViewSnapshot.configure((_serialized: string): boolean => {
          writes += 1;
          return true;
        }, (): string => '', (): void => {});
        try {
          LastViewSnapshot.record({ 'type': 'view', 'session': { 'id': 's-gone' } } as Record<string, Object>);
          LastViewSnapshot.invalidateFor('s-gone');
          LastViewSnapshot.flush();
          expect(writes).assertEqual(0);
          // Negative control: another session's pending view is kept.
          LastViewSnapshot.record({ 'type': 'view', 'session': { 'id': 's-kept' } } as Record<string, Object>);
          LastViewSnapshot.invalidateFor('s-gone');
          LastViewSnapshot.flush();
          expect(writes).assertEqual(1);
        } finally {
          LastViewSnapshot.reset();
        }
      });

    it('aRevokedConsentDropsTheQueuedSnapshot',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
        feature.onInitialize();
        feature.attachMonitor(monitor);
        monitor.startView('home', 'home'); // a session's first view is on file at once
        monitor.addAction(RumActionType.TAP, 'tap'); // this update is queued, not yet written
        feature.onReceive({ 'type': 'consent_revoked' } as Record<string, Object>);
        scope.lastView = ''; // what the core's revocation deletes
        LastViewSnapshot.flush(); // a later flush point must find nothing to write
        expect(scope.lastView).assertEqual('');
        // Nor does a session that ends under the refused consent write its record.
        core.consent = TrackingConsent.NOT_GRANTED;
        monitor.stopSession();
        expect(scope.lastView).assertEqual('');
      });

    it('aKeepAliveFlushesTheSnapshot',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
        feature.onInitialize();
        feature.attachMonitor(monitor);
        scope.lastView = '';
        monitor.addAction(RumActionType.TAP, 'tap');
        expect(scope.lastView).assertEqual(''); // coalesced, not written yet
        feature.onReceive({ 'type': 'keep_alive' } as Record<string, Object>);
        expect(scope.lastView.length > 0).assertTrue();
      });
  });
  describe('rum-main-thread-jank', (): void => {
    const jank = (extra: Record<string, Object> = {}): Record<string, Object> => {
      const event: Record<string, Object> = {
        'type': 'crash_report', 'message': 'Main thread jank', 'stack': '#0 pc 00000000000160ec libuv.so (uv_run+180)',
        'source': 'source', 'is_crash': false, 'crash_kind': 'jank', 'source_type': 'harmony',
        'binary_images': [], 'arch': '', 'build_id': '', 'jank.duration_ms': 1001, 'jank.sampled_at': 1793317690154
      };
      for (const k of Object.keys(extra)) {
        event[k] = extra[k];
      }
      return event;
    };

    it('aJankIsAHandledErrorOfTheCurrentView', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(100).build();
      core.rumScope = scope;
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
      monitor.stopKeepAlive();
      feature.attachMonitor(monitor);
      monitor.startView('home', 'home');
      const sessionId: string = core.featureContext['session.id'] as string;
      const viewId: string = core.featureContext['view.id'] as string;

      feature.onReceive(jank());

      const errors: Array<Record<string, Object>> = scope.ofType('error');
      expect(errors.length).assertEqual(1);
      const error: Record<string, Object> = errors[0]['error'] as Record<string, Object>;
      expect(error['is_crash']).assertEqual(false);
      expect(error['handling']).assertEqual('handled');
      expect(error['category']).assertEqual('Jank');
      expect(error['type']).assertEqual('MAIN_THREAD_JANK');
      expect(error['source']).assertEqual('source');
      expect(error['source_type']).assertEqual('harmony');
      expect(error['message']).assertEqual('Main thread jank');
      expect(error['stack']).assertEqual('#0 pc 00000000000160ec libuv.so (uv_run+180)');
      expect(sessionOf(errors[0])['id']).assertEqual(sessionId);
      expect((errors[0]['view'] as Record<string, Object>)['id']).assertEqual(viewId);
      const context: Record<string, Object> = errors[0]['context'] as Record<string, Object>;
      expect(context['jank.duration_ms']).assertEqual(1001);
      expect(context['jank.sampled_at']).assertEqual(1793317690154);
      expect(context['error.type'] === undefined).assertTrue();
      // Counted as an error of the view, never as a crash.
      const views: Array<Record<string, Object>> = scope.ofType('view');
      const last: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
      expect((last['error'] as Record<string, Object>)['count']).assertEqual(1);
      expect((last['crash'] as Record<string, Object>)['count']).assertEqual(0);
      // Negative control: a native crash on the same path has no error.type.
      feature.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'crash_kind': 'crash',
        'timestamp_ms': Date.now() - 1000 } as Record<string, Object>);
      const crash: Record<string, Object> = scope.ofType('error')[1]['error'] as Record<string, Object>;
      expect(crash['type'] === undefined).assertTrue();
      expect(crash['is_crash']).assertEqual(true);
    });

    it('aJankIsNeverWrittenIntoAnotherSession', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // A previous launch left a last-view snapshot; a replay would land there.
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
      monitor.startView('home', 'home');
      const previous: string = core.featureContext['session.id'] as string;
      monitor.stopSession();
      LastViewSnapshot.flush();
      expect(scope.lastView.length > 0).assertTrue();

      const next: CapturingScope = new CapturingScope();
      next.lastView = scope.lastView;
      core.rumScope = next;
      const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(100).build();
      const feature: RumFeature = new RumFeature(core, configuration);
      feature.onInitialize();
      const monitor2: DefaultRumMonitor = new DefaultRumMonitor(core, next, configuration);
      monitor2.stopKeepAlive();
      feature.attachMonitor(monitor2);
      monitor2.startView('feed', 'feed');
      const current: string = core.featureContext['session.id'] as string;
      expect(current === previous).assertFalse();

      const event: Record<string, Object> = jank({ 'original_session_id': previous, 'timestamp_ms': Date.now() - 1000 });
      feature.onReceive(event);

      const errors: Array<Record<string, Object>> = next.ofType('error');
      expect(errors.length).assertEqual(1);
      expect(sessionOf(errors[0])['id']).assertEqual(current);
      expect(((errors[0]['view'] as Record<string, Object>)['name'])).assertEqual('feed');
      expect((errors[0]['error'] as Record<string, Object>)['is_crash']).assertEqual(false);
      // Negative control: a crash carrying the same ids is replayed into the old session.
      feature.onReceive({ 'type': 'crash_report', 'message': 'NativeCrash', 'stack': '#00 pc', 'crash_kind': 'crash',
        'original_session_id': previous, 'timestamp_ms': Date.now() - 1000 } as Record<string, Object>);
      const replayed: Array<Record<string, Object>> = next.ofType('error');
      expect(sessionOf(replayed[replayed.length - 1])['id']).assertEqual(previous);
    });

    it('aJankWithoutAMonitorIsDropped', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const core: FakeCore = new FakeCore();
      const scope: CapturingScope = new CapturingScope();
      core.rumScope = scope;
      const feature: RumFeature = new RumFeature(core,
        new RumConfigurationBuilder('app-1').setSessionSampleRate(100).build());
      feature.onInitialize();
      feature.onReceive(jank());
      expect(scope.ofType('error').length).assertEqual(0);
    });
  });

  describe('rum-crash-before-first-view', (): void => {
    /** A session with no view yet: an action mints it and is dropped for want of a view. */
    const sessionWithoutView = (monitor: DefaultRumMonitor, core: FakeCore): string => {
      monitor.addAction(RumActionType.TAP, 'tap');
      const sessionId: string = core.featureContext['session.id'] as string;
      expect(sessionId.length > 0).assertTrue();
      expect((core.featureContext['view.id'] ?? '') as string).assertEqual('');
      return sessionId;
    };
    const launchViewsOf = (scope: CapturingScope): Array<Record<string, Object>> =>
      scope.ofType('view').filter((v: Record<string, Object>) =>
        (v['view'] as Record<string, Object>)['url'] === 'ApplicationLaunch');
    const lastLaunchView = (scope: CapturingScope): Record<string, Object> => {
      const views: Array<Record<string, Object>> = launchViewsOf(scope);
      expect(views.length > 0).assertTrue();
      return views[views.length - 1];
    };

    it('aPersistedCrashBeforeTheFirstViewNamesTheLaunchViewItIsCountedOn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        const sessionId: string = sessionWithoutView(monitor, core);
        fireUnhandledException(CRASH_TEXT);
        const view: Record<string, Object> = lastLaunchView(scope);
        expect(sessionOf(view)['id']).assertEqual(sessionId);
        expect(((view['view'] as Record<string, Object>)['crash'] as Record<string, Object>)['count']).assertEqual(1);
        expect(sessionOf(view)['sampled_for_error']).assertUndefined();
        // The incident snapshots the context after the view opened: its replay joins this view.
        const probe: Record<string, Object> = core.crashScope.probes[0];
        expect(probe['original_session_id']).assertEqual(sessionId);
        expect(probe['original_view_id']).assertEqual((view['view'] as Record<string, Object>)['id']);
        // The error itself is the replay's, not this process's.
        expect(scope.ofType('error').length).assertEqual(0);
      });

    it('aWithheldSessionReleasesItsLaunchViewWithTheCrash',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 0, true);
        const sessionId: string = sessionWithoutView(monitor, core);
        expect(monitor.isWithholding()).assertTrue();
        fireUnhandledException(CRASH_TEXT);
        const view: Record<string, Object> = lastLaunchView(scope);
        expect(sessionOf(view)['id']).assertEqual(sessionId);
        expect(sessionOf(view)['sampled_for_error']).assertEqual(true);
        expect(sampleRateOf(view)).assertEqual(0);
        expect(((view['view'] as Record<string, Object>)['crash'] as Record<string, Object>)['count']).assertEqual(1);
        expect(core.crashScope.probes[0]['original_view_id'])
          .assertEqual((view['view'] as Record<string, Object>)['id']);
      });

    it('aLiveCrashBeforeTheFirstViewIsWrittenInTheLaunchViewThatTheFirstViewReplaces',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        core.crashScope.policy = 'report_and_continue';
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        sessionWithoutView(monitor, core);
        fireUnhandledException(CRASH_TEXT);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        const launchViewId: Object = (lastLaunchView(scope)['view'] as Record<string, Object>)['id'];
        expect((errors[0]['view'] as Record<string, Object>)['id']).assertEqual(launchViewId);
        // The app's first view takes over, as any view takes over from the one before.
        monitor.startView('home', 'home');
        const closed: Record<string, Object> = lastLaunchView(scope);
        expect((closed['view'] as Record<string, Object>)['id']).assertEqual(launchViewId);
        expect((closed['view'] as Record<string, Object>)['is_active']).assertEqual(false);
        expect(core.featureContext['view.name']).assertEqual('home');
      });

    it('aSecondFaultBeforeTheFirstViewOpensNoSecondLaunchView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        core.crashScope.policy = 'report_and_continue';
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        sessionWithoutView(monitor, core);
        fireUnhandledException(CRASH_TEXT);
        fireUnhandledException(CRASH_TEXT);
        const ids: Set<Object> = new Set<Object>(launchViewsOf(scope).map((v: Record<string, Object>) =>
          (v['view'] as Record<string, Object>)['id']));
        expect(ids.size).assertEqual(1);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(2);
        for (const error of errors) {
          expect(ids.has((error['view'] as Record<string, Object>)['id'])).assertTrue();
        }
      });

    it('theReplayedCrashJoinsTheLaunchViewWithoutCountingItAgain',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        const sessionId: string = sessionWithoutView(monitor, core);
        fireUnhandledException(CRASH_TEXT);
        const launchViewId: Object = (lastLaunchView(scope)['view'] as Record<string, Object>)['id'];
        const viewsBefore: number = scope.ofType('view').length;
        // The next launch replays the persisted incident: the very event the probe was built as.
        const replay: Record<string, Object> = core.crashScope.probes[0];
        replay['type'] = 'crash_report';
        replayCrash(core, replay);
        expect(replay['delivered']).assertEqual(true);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(1);
        expect(sessionOf(errors[0])['id']).assertEqual(sessionId);
        expect((errors[0]['view'] as Record<string, Object>)['id']).assertEqual(launchViewId);
        // Counted once, by markCrash in the crashed process; the replay writes no view.
        expect(scope.ofType('view').length).assertEqual(viewsBefore);
        expect(((lastLaunchView(scope)['view'] as Record<string, Object>)['crash'] as Record<string, Object>)['count'])
          .assertEqual(1);
      });

    it('aCrashBetweenTwoViewsStaysOnTheLastViewWithoutALaunchView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        monitor.stopView('home');
        fireUnhandledException(CRASH_TEXT);
        expect(launchViewsOf(scope).length).assertEqual(0);
        const views: Array<Record<string, Object>> = scope.ofType('view');
        const last: Record<string, Object> = views[views.length - 1]['view'] as Record<string, Object>;
        expect(last['url']).assertEqual('home');
        expect((last['crash'] as Record<string, Object>)['count']).assertEqual(1);
      });

    it('aCrashWithNoSessionMintsNeitherASessionNorAView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        const scope: CapturingScope = new CapturingScope();
        featureWith(core, scope, 100, false);
        fireUnhandledException(CRASH_TEXT);
        expect((core.featureContext['session.id'] ?? '') as string).assertEqual('');
        expect(scope.ofType('view').length).assertEqual(0);
        expect(core.crashScope.probes[0]['original_session_id']).assertEqual('');
      });

    it('aSessionThatExpiredWithoutAViewGivesTheCrashUp',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // An action minted a withheld session, no view ever opened, then 16 idle minutes.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core);
        const t0: number = Date.now();
        addAction(app, t0);
        expect((core.featureContext['session.id'] as string).length > 0).assertTrue();
        const crashAtMs: number = t0 + MIN_15 + 60 * 1000;
        app.handleEvent(raw('openLaunchView', crashAtMs));
        // Withdrawn before the crash feature snapshots it: the incident names no session.
        expect(core.featureContext['session.id']).assertEqual('');
        app.handleEvent(raw('markCrash', crashAtMs));
        // Nothing of the expired session goes out: no view, and the held action is discarded.
        expect(scope.written.length).assertEqual(0);
      });

    it('aSessionStillAliveWithoutAViewKeepsTheCrash',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Negative control for the expiry boundary: one idle minute, the launch view opens.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const app: RumApplicationScope = onErrorApp(scope, core);
        const t0: number = Date.now();
        addAction(app, t0);
        const sessionId: string = core.featureContext['session.id'] as string;
        app.handleEvent(raw('openLaunchView', t0 + 60 * 1000));
        expect(core.featureContext['session.id']).assertEqual(sessionId);
        app.handleEvent(raw('markCrash', t0 + 60 * 1000));
        const view: Record<string, Object> = lastLaunchView(scope);
        expect(sessionOf(view)['id']).assertEqual(sessionId);
        expect(((view['view'] as Record<string, Object>)['crash'] as Record<string, Object>)['count']).assertEqual(1);
      });

    it('anUnsampledSessionOpensNoLaunchView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.crashScope = new FakeCrashScope(core);
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 0, false);
        monitor.addAction(RumActionType.TAP, 'tap');
        fireUnhandledException(CRASH_TEXT);
        expect(scope.ofType('view').length).assertEqual(0);
        expect((core.featureContext['view.id'] ?? '') as string).assertEqual('');
      });
  });
  describe('rum-events-before-first-view', (): void => {
    /** RUM enabled while the app's first page is already on screen: no view has started. */
    const foregroundFeature = (core: FakeCore, scope: CapturingScope): DefaultRumMonitor => {
      core.foreground = true;
      core.stateKnown = true;
      return featureWith(core, scope, 100, false);
    };
    const viewOf = (event: Record<string, Object>): Record<string, Object> =>
      event['view'] as Record<string, Object>;
    const launchViewsOf = (scope: CapturingScope): Array<Record<string, Object>> =>
      scope.ofType('view').filter((v: Record<string, Object>) => viewOf(v)['url'] === 'ApplicationLaunch');
    const contextOf = (event: Record<string, Object>): Record<string, Object> =>
      (event['context'] ?? {}) as Record<string, Object>;

    it('anActionBeforeAnyViewIsWrittenInTheLaunchView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = foregroundFeature(core, scope);
        monitor.addAction(RumActionType.CUSTOM, 'login_start');
        monitor.addAction(RumActionType.CUSTOM, 'login_failed');
        const actions: Array<Record<string, Object>> = scope.ofType('action');
        expect(actions.length).assertEqual(2);
        const launch: Array<Record<string, Object>> = launchViewsOf(scope);
        expect(launch.length > 0).assertTrue();
        const launchViewId: Object = viewOf(launch[launch.length - 1])['id'];
        for (const action of actions) {
          expect(viewOf(action)['id']).assertEqual(launchViewId);
          expect(sessionOf(action)['id']).assertEqual(core.featureContext['session.id']);
        }
        expect((viewOf(launch[launch.length - 1])['action'] as Record<string, Object>)['count']).assertEqual(2);
      });

    it('anActionIsKeptWhileTheForegroundIsNotKnownYet',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A late-enabled SDK learns its foreground asynchronously, after the app's first calls.
        const core: FakeCore = new FakeCore();
        core.stateKnown = false;
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.addAction(RumActionType.TAP, 'tap');
        expect(scope.ofType('action').length).assertEqual(1);
        expect(launchViewsOf(scope).length > 0).assertTrue();
      });

    it('aRequestAndAnErrorBeforeAnyViewJoinTheLaunchView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = foregroundFeature(core, scope);
        monitor.startResource('r1', RumResourceMethod.POST, 'https://api.example.com/login');
        monitor.stopResource('r1', 401, 12, RumResourceKind.NATIVE);
        monitor.addError('login failed', RumErrorSource.SOURCE);
        const launch: Array<Record<string, Object>> = launchViewsOf(scope);
        expect(launch.length > 0).assertTrue();
        const launchViewId: Object = viewOf(launch[launch.length - 1])['id'];
        expect(scope.ofType('resource').length).assertEqual(1);
        expect(viewOf(scope.ofType('resource')[0])['id']).assertEqual(launchViewId);
        expect(scope.ofType('error').length).assertEqual(1);
        expect(viewOf(scope.ofType('error')[0])['id']).assertEqual(launchViewId);
      });

    it('theLaunchViewCarriesTheGlobalAttributesButNotTheActionsOwn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = foregroundFeature(core, scope);
        monitor.addAttribute('channel', 'store');
        monitor.addAction(RumActionType.CUSTOM, 'login_start', { 'step': 'submit' });
        monitor.addAction(RumActionType.CUSTOM, 'login_failed');
        const launch: Array<Record<string, Object>> = launchViewsOf(scope);
        const view: Record<string, Object> = launch[launch.length - 1];
        expect(contextOf(view)['channel']).assertEqual('store');
        expect(contextOf(view)['step']).assertUndefined();
        const second: Record<string, Object> = scope.ofType('action')[1];
        expect(contextOf(second)['step']).assertUndefined();
      });

    it('theFirstViewOfTheAppReplacesTheLaunchView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = foregroundFeature(core, scope);
        monitor.addAction(RumActionType.TAP, 'before');
        monitor.startView('home', 'home');
        monitor.addAction(RumActionType.TAP, 'after');
        const launch: Array<Record<string, Object>> = launchViewsOf(scope);
        expect(viewOf(launch[launch.length - 1])['is_active']).assertEqual(false);
        const after: Record<string, Object> = scope.ofType('action')[1];
        expect(viewOf(after)['url']).assertEqual('home');
      });

    it('aTimedActionBeforeAnyViewDoesNotDateTheLaunchViewBeforeItsSession',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = foregroundFeature(core, scope);
        const startedMs: number = Date.now();
        monitor.startAction(RumActionType.CUSTOM, 'login');
        waitPast(startedMs + 5);
        monitor.stopAction(RumActionType.CUSTOM, 'login');
        const action: Record<string, Object> = scope.ofType('action')[0];
        const launch: Array<Record<string, Object>> = launchViewsOf(scope);
        const viewDate: number = launch[launch.length - 1]['date'] as number;
        // The action keeps its start time; the session, minted at the stop, is later.
        expect((action['date'] as number) < viewDate).assertTrue();
        expect(viewDate > startedMs).assertTrue();
      });

    it('nothingOpensBetweenTwoViews',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = foregroundFeature(core, scope);
        monitor.startView('home', 'home');
        monitor.stopView('home');
        monitor.addAction(RumActionType.TAP, 'between');
        expect(scope.ofType('action').length).assertEqual(0);
        expect(launchViewsOf(scope).length).assertEqual(0);
      });

    it('nothingOpensInALaunchTheSystemReportedInTheBackground',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.foreground = false;
        core.stateKnown = true;
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.addAction(RumActionType.TAP, 'background');
        expect(scope.ofType('action').length).assertEqual(0);
        expect(launchViewsOf(scope).length).assertEqual(0);
      });

    it('anUnsampledSessionOpensNothing',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.foreground = true;
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 0, false);
        monitor.addAction(RumActionType.TAP, 'tap');
        expect(scope.written.filter((e: Record<string, Object>) =>
          e['type'] === 'view' || e['type'] === 'action').length).assertEqual(0);
      });
  });

  describe('rum-crash-session-record', (): void => {
    it('aNativeCrashAfterARenewalBeforeTheFirstViewIsTheNewSessions',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Session A had a view; it ended and B started with no view yet. The fault is B's.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const a: string = core.featureContext['session.id'] as string;
        monitor.stopSession();
        launchVital(monitor);
        const b: string = core.featureContext['session.id'] as string;
        expect(b === a).assertFalse();
        const next: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now()));
        const errors: Array<Record<string, Object>> = next.ofType('error');
        expect(errors.length).assertEqual(1);
        expect(sessionOf(errors[0])['id']).assertEqual(b);
        expect(viewNameOf(errors[0])).assertEqual('ApplicationLaunch');
        const views: Array<Record<string, Object>> = next.ofType('view');
        expect(views.length).assertEqual(1);
        expect(sessionOf(views[0])['id']).assertEqual(b);
        expect(crashCountOf(views[0])).assertEqual(1);
        for (const e of next.written) {
          expect(sessionOf(e)['id'] === a).assertFalse();
        }
        // Negative control: once B has a view, the fault joins that view.
        const core2: FakeCore = new FakeCore();
        const scope2: CapturingScope = new CapturingScope();
        const monitor2: DefaultRumMonitor = featureWith(core2, scope2, 100, false);
        monitor2.startView('home', 'home');
        monitor2.stopSession();
        launchVital(monitor2);
        const b2: string = core2.featureContext['session.id'] as string;
        monitor2.startView('cart', 'cart');
        const joined: CapturingScope = nextLaunch(core2, scope2.lastView, 100, false, nativeCrash(Date.now()));
        expect(sessionOf(joined.ofType('error')[0])['id']).assertEqual(b2);
        expect(viewNameOf(joined.ofType('error')[0])).assertEqual('cart');
      });

    it('aRenewedSessionsFirstViewIsOnFileAtOnce',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The view a renewed session restarts is the one a fault right after it belongs to:
        // it is on file without the snapshot's write delay.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        monitor.stopSession();
        monitor.addAction(RumActionType.TAP, 'tap'); // a new session, restarting 'home'
        const b: string = core.featureContext['session.id'] as string;
        const onFile: Record<string, Object> = (JSON.parse(scope.lastView) as Record<string, Object>)['view'] as Record<string, Object>;
        expect(sessionOf(onFile)['id']).assertEqual(b);
        // Negative control: a later update of that view waits for the write delay.
        const before: string = scope.lastView;
        monitor.addAction(RumActionType.TAP, 'again');
        expect(scope.lastView).assertEqual(before);
        LastViewSnapshot.flush();
        expect(scope.lastView === before).assertFalse();
      });

    it('aSampledSessionWithoutAViewKeepsItsCrashWithoutANewDraw',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Run 1 is collected (rate 100) and has no view yet. Run 2 would draw nothing (rate 0):
        // the crash still lands in run 1's session, drawn as that session was.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        launchVital(monitor);
        const crashed: string = core.featureContext['session.id'] as string;
        const crashedAtMs: number = Date.now();
        const next: CapturingScope = nextLaunch(core, scope.lastView, 0, false, nativeCrash(crashedAtMs));
        const errors: Array<Record<string, Object>> = next.ofType('error');
        expect(errors.length).assertEqual(1);
        expect(sessionOf(errors[0])['id']).assertEqual(crashed);
        expect(errors[0]['date']).assertEqual(crashedAtMs);
        const view: Record<string, Object> = next.ofType('view')[0];
        expect(viewNameOf(view)).assertEqual('ApplicationLaunch');
        expect(sessionOf(view)['id']).assertEqual(crashed);
        expect(sampleRateOf(view)).assertEqual(100);
        expect(sessionOf(view)['sampled_for_error'] === undefined).assertTrue();
        expect((errors[0]['view'] as Record<string, Object>)['id']).assertEqual((view['view'] as Record<string, Object>)['id']);
        // A retry rewrites the same documents.
        const retried: CapturingScope = nextLaunch(core, scope.lastView, 0, false, nativeCrash(crashedAtMs));
        expect((retried.ofType('view')[0]['view'] as Record<string, Object>)['id'])
          .assertEqual((view['view'] as Record<string, Object>)['id']);
        // Negative control: a fault of another process has no session on file; drawn again at
        // rate 0, it is not reported.
        const other: CapturingScope = nextLaunch(core, scope.lastView, 0, false, nativeCrash(crashedAtMs, process.pid + 1));
        expect(other.written.length).assertEqual(0);
      });

    it('aCrashOfASessionKeptOnErrorWithoutAViewKeepsItsMarkers',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 0, true);
        launchVital(monitor);
        const crashed: string = core.featureContext['session.id'] as string;
        const next: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now()));
        const view: Record<string, Object> = next.ofType('view')[0];
        expect(sessionOf(view)['id']).assertEqual(crashed);
        expect(sessionOf(view)['sampled_for_error']).assertEqual(true);
        expect(sampleRateOf(view)).assertEqual(0);
        // Negative control: a session drawn by the rate carries no on-error marker.
        const core2: FakeCore = new FakeCore();
        const scope2: CapturingScope = new CapturingScope();
        launchVital(featureWith(core2, scope2, 100, true));
        const drawn: CapturingScope = nextLaunch(core2, scope2.lastView, 0, true, nativeCrash(Date.now()));
        expect(sessionOf(drawn.ofType('view')[0])['sampled_for_error'] === undefined).assertTrue();
      });

    it('aBackgroundCrashOfASessionWithoutAViewIsInItsBackgroundView',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        launchVital(featureWith(core, scope, 100, false));
        const crashed: string = core.featureContext['session.id'] as string;
        const background: CapturingScope = nextLaunch(core, scope.lastView, 100, false,
          nativeCrash(Date.now(), process.pid, { 'in_foreground': false }));
        const error: Record<string, Object> = background.ofType('error')[0];
        expect(sessionOf(error)['id']).assertEqual(crashed);
        expect(viewNameOf(error)).assertEqual('Background');
        const view: Record<string, Object> = background.ofType('view')[0];
        expect(viewNameOf(view)).assertEqual('Background');
        expect((view['view'] as Record<string, Object>)['url']).assertEqual('Background');
        // Negative control: in the foreground, the ApplicationLaunch view.
        const foreground: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now()));
        expect(viewNameOf(foreground.ofType('error')[0])).assertEqual('ApplicationLaunch');
      });

    it('aCrashOfAnUnsampledSessionIsNotReported',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Missed by the rate, no switch: nothing of the session is collected, its crash neither.
        // The next launch would collect everything — the crash is not drawn again.
        for (const kind of ['crash', 'freeze']) {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = featureWith(core, scope, 0, false);
          monitor.startView('home', 'home');
          const crash: Record<string, Object> = nativeCrash(Date.now());
          crash['crash_kind'] = kind;
          const next: CapturingScope = nextLaunch(core, scope.lastView, 100, false, crash);
          expect(next.written.length).assertEqual(0);
          expect(crash['delivered']).assertEqual(true); // handled: not retried
        }
        // Negative control: the same session collected reports it.
        const core2: FakeCore = new FakeCore();
        const scope2: CapturingScope = new CapturingScope();
        featureWith(core2, scope2, 100, false).startView('home', 'home');
        expect(nextLaunch(core2, scope2.lastView, 100, false, nativeCrash(Date.now())).ofType('error').length)
          .assertEqual(1);
      });

    it('aCrashOfAnUnsampledSessionAfterASampledOneStaysOffTheSampledOne',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A collected session A, then an unsampled B in the same process. The view on file was
        // A's; the fault is B's, which is not collected.
        const run = (rates: number[]): CapturingScope => {
          let draws: number = 0;
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          core.rumScope = scope;
          scope.core = core;
          const configuration: RumConfiguration = new RumConfigurationBuilder('app-1').setSessionSampleRate(100)
            .setBeforeSampling((_context: BeforeSamplingContext): number | undefined => rates[draws++]).build();
          const feature: RumFeature = new RumFeature(core, configuration);
          feature.onInitialize();
          const monitor: DefaultRumMonitor = new DefaultRumMonitor(core, scope, configuration);
          monitor.stopKeepAlive();
          feature.attachMonitor(monitor);
          monitor.startView('home', 'home');
          monitor.stopSession();
          monitor.startView('cart', 'cart');
          return nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now()));
        };
        expect(run([100, 0]).written.length).assertEqual(0);
        // Negative control: B collected, the fault lands in B's view.
        const sampled: CapturingScope = run([100, 100]);
        expect(viewNameOf(sampled.ofType('error')[0])).assertEqual('cart');
      });

    it('aSessionKeptOnErrorKeepsANativeCrashWhileAThrownAwayOneDoesNot',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Kept on error (rate 0 + switch), the session's native crash is its error: reported in it.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 0, true);
        monitor.startView('home', 'home');
        const kept: string = core.featureContext['session.id'] as string;
        const crashedAtMs: number = Date.now();
        const next: CapturingScope = nextLaunch(core, scope.lastView, 0, true, nativeCrash(crashedAtMs));
        expect(sessionOf(next.ofType('error')[0])['id']).assertEqual(kept);
        expect(sessionOf(next.ofType('view')[0])['sampled_for_error']).assertEqual(true);
        // Thrown away without an error: nothing of it is collected, and a fault recorded in it
        // (dated before it ended) is not reported, nor drawn again.
        const core2: FakeCore = new FakeCore();
        const scope2: CapturingScope = new CapturingScope();
        const monitor2: DefaultRumMonitor = featureWith(core2, scope2, 0, true);
        monitor2.startView('home', 'home');
        const faultAtMs: number = Date.now();
        waitPast(faultAtMs);
        monitor2.stopSession();
        const dropped: Record<string, Object> = nativeCrash(faultAtMs);
        const after: CapturingScope = nextLaunch(core2, scope2.lastView, 0, true, dropped);
        expect(after.written.length).assertEqual(0);
        expect(dropped['delivered']).assertEqual(true);
      });

    it('aFaultAfterTheRecordedSessionEndedIsReportedInASessionOfItsOwn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const ended: string = core.featureContext['session.id'] as string;
        const insideMs: number = Date.now();
        waitPast(insideMs);
        monitor.stopSession();
        const afterMs: number = Date.now() + 1;
        const own: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(afterMs));
        const error: Record<string, Object> = own.ofType('error')[0];
        expect(sessionOf(error)['id'] === ended).assertFalse();
        expect(viewNameOf(error)).assertEqual('ApplicationLaunch');
        // Negative control: a fault dated inside the session joins its last view.
        const inside: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(insideMs));
        expect(sessionOf(inside.ofType('error')[0])['id']).assertEqual(ended);
        expect(viewNameOf(inside.ofType('error')[0])).assertEqual('home');
      });

    it('aFaultLongAfterTheLastWriteIsNotTheIdleSessionsOwn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The session went idle and expired without its process noticing: a file 20 minutes
        // old describes a session that no longer runs.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        featureWith(core, scope, 100, false).startView('home', 'home');
        const idle: string = core.featureContext['session.id'] as string;
        const stale: CapturingScope = nextLaunch(core, writtenAgo(scope.lastView, MIN_15 + 5 * 60 * 1000), 100, false,
          nativeCrash(Date.now()));
        expect(sessionOf(stale.ofType('error')[0])['id'] === idle).assertFalse();
        // Negative control: written five minutes before the fault, the session is still the one.
        const fresh: CapturingScope = nextLaunch(core, writtenAgo(scope.lastView, 5 * 60 * 1000), 100, false,
          nativeCrash(Date.now()));
        expect(sessionOf(fresh.ofType('error')[0])['id']).assertEqual(idle);
      });

    it('anUnsampledSessionsCrashIsDroppedHoweverOldItsRecord',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Not collected, the session writes its record only when it starts: hours later its
        // crash is still its own, and still not reported — never drawn again.
        for (const agoMs of [60 * 60 * 1000, 5 * 60 * 60 * 1000]) {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          featureWith(core, scope, 0, false).startView('home', 'home');
          const crash: Record<string, Object> = nativeCrash(Date.now());
          const next: CapturingScope = nextLaunch(core, writtenAgo(scope.lastView, agoMs), 100, false, crash);
          expect(next.written.length).assertEqual(0);
          expect(crash['delivered']).assertEqual(true);
        }
        // Negative control: a collected session without a view, past its lifetime, is no
        // session's any more — the crash goes to a session of its own, drawn at rate 100.
        const core2: FakeCore = new FakeCore();
        const scope2: CapturingScope = new CapturingScope();
        launchVital(featureWith(core2, scope2, 100, false));
        const old: string = core2.featureContext['session.id'] as string;
        const expired: CapturingScope = nextLaunch(core2, writtenAgo(scope2.lastView, 5 * 60 * 60 * 1000), 100, false,
          nativeCrash(Date.now()));
        expect(expired.ofType('error').length).assertEqual(1);
        expect(sessionOf(expired.ofType('error')[0])['id'] === old).assertFalse();
      });

    it('aFileOfTheEarlierFormatIsStillUsed',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A crash pending at the upgrade: the file holds the process and its last view only.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        featureWith(core, scope, 100, false).startView('home', 'home');
        const crashed: string = core.featureContext['session.id'] as string;
        const file: Record<string, Object> = JSON.parse(scope.lastView) as Record<string, Object>;
        const earlier: string = JSON.stringify({ 'pid': file['pid'], 'view': file['view'] } as Record<string, Object>);
        const next: CapturingScope = nextLaunch(core, earlier, 100, false, nativeCrash(Date.now()));
        expect(sessionOf(next.ofType('error')[0])['id']).assertEqual(crashed);
        expect(viewNameOf(next.ofType('error')[0])).assertEqual('home');
        // Negative control: another process's fault is not attributed to it.
        const other: CapturingScope = nextLaunch(core, earlier, 100, false, nativeCrash(Date.now(), process.pid + 1));
        expect(sessionOf(other.ofType('error')[0])['id'] === crashed).assertFalse();
      });

    it('aSessionRecordARefusedConsentKeptOffTheFileGoesOnItWhenGranted',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        core.consent = TrackingConsent.NOT_GRANTED;
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        launchVital(monitor);
        expect(scope.lastView).assertEqual(''); // refused: nothing on file
        core.consent = TrackingConsent.GRANTED;
        LastViewSnapshot.consentGranted();
        const granted: Record<string, Object> = (JSON.parse(scope.lastView) as Record<string, Object>)['session'] as Record<string, Object>;
        expect(granted['id']).assertEqual(core.featureContext['session.id'] as string);
        // Negative control: a grant with nothing kept off the file writes nothing.
        scope.lastView = '';
        LastViewSnapshot.consentGranted();
        expect(scope.lastView).assertEqual('');
      });

    it('anExpiredSessionEndsAtItsInactivityLimitNotWhenTheExpiryIsNoticed',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let stored: string = '';
        LastViewSnapshot.configure((serialized: string): boolean => {
          stored = serialized;
          return true;
        }, (): string => stored, (): void => {
          stored = '';
        });
        const endedAt = (): number => ((LastViewSnapshot.read() as LastView).session as SessionRecord).endedAtMs;
        try {
          // Idle since its start and stopped 45 minutes later: it had ended 15 minutes in.
          const idle: RumApplicationScope = new RumApplicationScope(new CapturingScope(), new FakeCore(), 'app-1', 100);
          const t0: number = Date.now();
          startView(idle, t0);
          idle.stopCurrentSession(t0 + 3 * MIN_15);
          const idleEnd: number = endedAt();
          expect(idleEnd >= t0 + MIN_15 && idleEnd < t0 + MIN_15 + 1000).assertTrue();
          // Negative control: stopped while running, it ends when it is stopped.
          const live: RumApplicationScope = new RumApplicationScope(new CapturingScope(), new FakeCore(), 'app-1', 100);
          const t1: number = Date.now();
          startView(live, t1);
          live.stopCurrentSession(t1 + 60 * 1000);
          expect(endedAt()).assertEqual(t1 + 60 * 1000);
        } finally {
          LastViewSnapshot.reset();
        }
      });

    it('aCorruptSessionRecordIsNotUsed',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let stored: string = JSON.stringify({ 'pid': 1, 'session': { 'id': 's-1' } } as Record<string, Object>);
        LastViewSnapshot.configure((serialized: string): boolean => {
          stored = serialized;
          return true;
        }, (): string => stored, (): void => {
          stored = '';
        });
        try {
          expect(LastViewSnapshot.read() === null).assertTrue(); // no `sampled`: neither session nor view
          stored = '{"pid":1,"session":{"id":"s-1","sampl'; // a truncated file
          expect(LastViewSnapshot.read() === null).assertTrue();
          // Negative control: with `sampled` the record reads back.
          stored = JSON.stringify({ 'pid': 1, 'session': { 'id': 's-1', 'sampled': false } } as Record<string, Object>);
          const read: LastView = LastViewSnapshot.read() as LastView;
          expect((read.session as SessionRecord).sampled).assertFalse();
          expect(read.view === null).assertTrue();
        } finally {
          LastViewSnapshot.reset();
        }
      });

    it('aRevokeThenGrantPutsTheSessionRecordBackOnFile',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The session was on file; revoking consent deletes the file; granting it again
        // must put the running session back, or a crash before its next view is drawn again.
        const run = (grant: boolean): CapturingScope => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = crashFeature(core, scope, 100, false);
          const feature: RumFeature = (core.crashScope as FakeCrashScope).rum as RumFeature;
          launchVital(monitor);
          expect(scope.lastView.length > 0).assertTrue(); // the prior file
          core.consent = TrackingConsent.NOT_GRANTED;
          feature.onReceive({ 'type': 'consent_revoked' } as Record<string, Object>);
          scope.lastView = ''; // what the core's revocation deletes
          if (grant) {
            core.consent = TrackingConsent.GRANTED;
            feature.onReceive({ 'type': 'consent_granted' } as Record<string, Object>);
          }
          const crashed: string = core.featureContext['session.id'] as string;
          const next: CapturingScope = nextLaunch(core, scope.lastView, 0, false, nativeCrash(Date.now()));
          if (grant) {
            expect(sessionOf(next.ofType('error')[0])['id']).assertEqual(crashed);
          }
          return next;
        };
        expect(run(true).ofType('error').length).assertEqual(1);
        // Negative control: still refused, nothing is on file — a session of its own, drawn
        // at rate 0: not reported.
        expect(run(false).written.length).assertEqual(0);
      });

    it('aRefusedSnapshotWriteIsRetriedAtTheBatchedCadence',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        monitor.startView('home', 'home');
        const actionsOnFile = (): number => {
          const file: Record<string, Object> = JSON.parse(scope.lastView) as Record<string, Object>;
          const body: Record<string, Object> = (file['view'] as Record<string, Object>)['view'] as Record<string, Object>;
          return (body['action'] as Record<string, Object>)['count'] as number;
        };
        scope.refuseLastView = true; // the storage keeps failing the write (success=false)
        monitor.addAction(RumActionType.TAP, 'one');
        LastViewSnapshot.flush();
        expect(actionsOnFile()).assertEqual(0); // the earlier file stays
        const attempts: number = scope.lastViewAttempts;
        for (let i: number = 0; i < 5; i++) {
          monitor.addAction(RumActionType.TAP, `again-${i}`);
        }
        // A failing storage is not asked again on every update: once per batched write.
        expect(scope.lastViewAttempts).assertEqual(attempts);
        LastViewSnapshot.flush();
        expect(scope.lastViewAttempts).assertEqual(attempts + 1);
        // Negative control: once the storage works, that batched write puts it on disk.
        scope.refuseLastView = false;
        monitor.addAction(RumActionType.TAP, 'two');
        LastViewSnapshot.flush();
        expect(actionsOnFile()).assertEqual(7);
      });

    it('aFaultWithoutATimeIsNotTakenForTheRecordedSessions',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Without a time the fault cannot be told apart from an earlier process's with the
        // same id: it goes to a session of its own, not into the recorded session.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        launchVital(featureWith(core, scope, 100, false));
        const recorded: string = core.featureContext['session.id'] as string;
        const undated: Record<string, Object> = {};
        const dated0: Record<string, Object> = nativeCrash(Date.now());
        for (const key of Object.keys(dated0)) {
          if (key !== 'timestamp_ms') {
            undated[key] = dated0[key];
          }
        }
        const own: CapturingScope = nextLaunch(core, scope.lastView, 100, false, undated);
        expect(own.ofType('error').length).assertEqual(1);
        expect(sessionOf(own.ofType('error')[0])['id'] === recorded).assertFalse();
        // Negative control: the same fault, dated, is the recorded session's.
        const dated: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now()));
        expect(sessionOf(dated.ofType('error')[0])['id']).assertEqual(recorded);
      });

    it('aFaultOlderThanTheRecordedSessionIsAnEarlierProcesssWithTheSameId',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // Process ids are reused: A crashed and its fault is still undelivered; B got the same
        // id, started a session with no view and died. The file is B's; A's fault is not.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        launchVital(featureWith(core, scope, 100, false));
        const b: string = core.featureContext['session.id'] as string;
        const startedAt: number = ((JSON.parse(scope.lastView) as Record<string, Object>)['session'] as Record<string, Object>)['started_at'] as number;
        const older: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(startedAt - 60 * 1000));
        expect(older.ofType('error').length).assertEqual(1);
        expect(sessionOf(older.ofType('error')[0])['id'] === b).assertFalse();
        // Negative control: a fault after B's session started is B's.
        const own: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(startedAt + 1000));
        expect(sessionOf(own.ofType('error')[0])['id']).assertEqual(b);
      });

    it('aCrashWhoseViewWriteFailsIsNotReportedASecondTime',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // The error lands in the session's view, its crash-counting view document does not:
        // the fault stays attributed, it is not also reported in a session of its own.
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        featureWith(core, scope, 100, false).startView('home', 'home');
        const crashed: string = core.featureContext['session.id'] as string;
        const next: CapturingScope = new CapturingScope();
        next.lastView = scope.lastView;
        next.core = core;
        // Only the document that counts the crash on the snapshot's view is refused.
        next.refuseViewId = (((JSON.parse(scope.lastView) as Record<string, Object>)['view'] as Record<string, Object>)['view'] as
          Record<string, Object>)['id'] as string;
        core.rumScope = next;
        const feature: RumFeature = new RumFeature(core, new RumConfigurationBuilder('app-1').build());
        feature.onInitialize();
        const live: DefaultRumMonitor = new DefaultRumMonitor(core, next, new RumConfigurationBuilder('app-1').build());
        live.stopKeepAlive();
        feature.attachMonitor(live);
        const crash: Record<string, Object> = nativeCrash(Date.now());
        feature.onReceive(crash);
        const errors: Array<Record<string, Object>> = next.ofType('error');
        expect(errors.length).assertEqual(1);
        expect(sessionOf(errors[0])['id']).assertEqual(crashed);
        expect(next.ofType('view').length).assertEqual(0); // no view of a session of its own either
        expect(crash['delivered'] === true).assertFalse();
        // Negative control: when both land, one error and its view document.
        const whole: CapturingScope = nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now()));
        expect(whole.ofType('error').length).assertEqual(1);
        expect(whole.ofType('view').length).assertEqual(1);
      });

    it('theSessionRecordIsWrittenAtOnceWhenASessionStartsAndEnds',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
        expect(scope.lastView).assertEqual(''); // no session yet: nothing on file
        launchVital(monitor);
        const started: Record<string, Object> = (JSON.parse(scope.lastView) as Record<string, Object>)['session'] as Record<string, Object>;
        expect(started['id']).assertEqual(core.featureContext['session.id'] as string);
        expect(started['sampled']).assertEqual(true);
        expect(started['ended_at']).assertEqual(0);
        monitor.stopSession();
        const ended: Record<string, Object> = (JSON.parse(scope.lastView) as Record<string, Object>)['session'] as Record<string, Object>;
        expect(ended['id']).assertEqual(started['id'] as string);
        expect((ended['ended_at'] as number) > 0).assertTrue();
      });
  });

  describe('rum-crash-foreground-and-sampled', (): void => {
    it('aCrashInItsViewSaysWhetherTheAppWasInTheForeground',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const replay = (extra: Record<string, Object>): Record<string, Object> => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          featureWith(core, scope, 100, false).startView('home', 'home');
          const error: Record<string, Object> =
            nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now(), process.pid, extra)).ofType('error')[0];
          expect(viewNameOf(error)).assertEqual('home');
          markersStayOutOfTheContext(error);
          return error;
        };
        expect(inForegroundOf(replay({ 'in_foreground': true }))).assertEqual(true);
        expect(inForegroundOf(replay({ 'in_foreground': false }))).assertEqual(false);
        // Negative control: the system did not say — nothing, not false.
        expect(inForegroundOf(replay({}))).assertUndefined();
      });

    it('aCrashSaysWhetherItsSessionWasDrawnWhereverItIsWritten',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // In the session's view, and in a session that had no view yet: drawn by the rate.
        const inView = (rate: number, onError: boolean): Record<string, Object> => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          featureWith(core, scope, rate, onError).startView('home', 'home');
          return nextLaunch(core, scope.lastView, 100, false, nativeCrash(Date.now())).ofType('error')[0];
        };
        const withoutView = (rate: number, onError: boolean): Record<string, Object> => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          launchVital(featureWith(core, scope, rate, onError));
          return nextLaunch(core, scope.lastView, 100, false,
            nativeCrash(Date.now(), process.pid, { 'in_foreground': false })).ofType('error')[0];
        };
        expect(sessionOf(inView(100, false))['sampled']).assertEqual(true);
        const background: Record<string, Object> = withoutView(100, false);
        expect(sessionOf(background)['sampled']).assertEqual(true);
        expect(viewNameOf(background)).assertEqual('Background');
        expect(inForegroundOf(background)).assertEqual(false);
        // Kept only because it errored: collected, not drawn.
        expect(sessionOf(inView(0, true))['sampled']).assertEqual(false);
        expect(sessionOf(withoutView(0, true))['sampled']).assertEqual(false);
        // A session of its own, drawn now (the kept-on-error case is in the draw tests).
        const core: FakeCore = new FakeCore();
        const scope: CapturingScope = new CapturingScope();
        crashFeature(core, scope, 100, false).startView('home', 'home');
        replayCrash(core, launchCrash(Date.now() - 5000));
        const own: Record<string, Object> = scope.ofType('error')[0];
        expect(viewNameOf(own)).assertEqual('ApplicationLaunch');
        expect(sessionOf(own)['sampled']).assertEqual(true);
        markersStayOutOfTheContext(own);
      });

    it('aReplayedJsCrashReportsWhatItsRunRecorded',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const replay = (extra: Record<string, Object>): Record<string, Object> => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          crashFeature(core, scope, 100, false).startView('home', 'home');
          const crash: Record<string, Object> = launchCrash(Date.now() - 5000);
          crash['crash_type'] = 'JsError';
          crash['original_session_id'] = 'crashed-session';
          crash['original_view_id'] = 'crashed-view';
          crash['original_view_name'] = 'cart';
          for (const key of Object.keys(extra)) {
            crash[key] = extra[key];
          }
          replayCrash(core, crash);
          const error: Record<string, Object> = scope.ofType('error')[0];
          expect(sessionOf(error)['id']).assertEqual('crashed-session');
          markersStayOutOfTheContext(error);
          return error;
        };
        // Not judged again by the replaying launch (drawn, in the foreground): as recorded.
        const kept: Record<string, Object> = replay({ 'in_foreground': false, 'session_sampled': false });
        expect(inForegroundOf(kept)).assertEqual(false);
        expect(sessionOf(kept)['sampled']).assertEqual(false);
        const drawn: Record<string, Object> = replay({ 'in_foreground': true, 'session_sampled': true });
        expect(inForegroundOf(drawn)).assertEqual(true);
        expect(sessionOf(drawn)['sampled']).assertEqual(true);
        // Negative control: an incident of an earlier version recorded neither.
        const legacy: Record<string, Object> = replay({});
        expect(inForegroundOf(legacy)).assertUndefined();
        expect(sessionOf(legacy)['sampled']).assertUndefined();
      });

    it('aCrashTooOldForItsSessionSaysHowItsOwnSessionWasDrawn',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A JS incident past the intake's window goes to a session of its own: that session's
        // draw, not the one the incident recorded for the session it can no longer join.
        const replay = (rate: number, onError: boolean, recorded: boolean): Record<string, Object> => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          crashFeature(core, scope, rate, onError).startView('home', 'home');
          const crash: Record<string, Object> = launchCrash(Date.now() - 25 * 60 * 60 * 1000);
          crash['crash_type'] = 'JsError';
          crash['original_session_id'] = 'crashed-session';
          crash['in_foreground'] = true;
          crash['session_sampled'] = recorded;
          replayCrash(core, crash);
          const error: Record<string, Object> = scope.ofType('error')[0];
          expect(sessionOf(error)['id'] === 'crashed-session').assertFalse();
          // The state at the fault is a fact of the fault: it stays.
          expect(inForegroundOf(error)).assertEqual(true);
          return error;
        };
        expect(sessionOf(replay(0, true, true))['sampled']).assertEqual(false);
        // Negative control: drawn now, though the incident's session was kept only on error.
        expect(sessionOf(replay(100, false, false))['sampled']).assertEqual(true);
      });

    it('aLiveCrashSaysWhereTheAppIsUnlessTheSystemHasNotSaidYet',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const live = (known: boolean, foreground: boolean, rate: number, onError: boolean): Record<string, Object> => {
          const core: FakeCore = new FakeCore();
          core.crashScope = new FakeCrashScope(core);
          core.crashScope.policy = 'report_and_continue';
          core.stateKnown = known;
          core.foreground = foreground;
          const scope: CapturingScope = new CapturingScope();
          featureWith(core, scope, rate, onError).startView('home', 'home');
          fireUnhandledException(CRASH_TEXT);
          const errors: Array<Record<string, Object>> = scope.ofType('error');
          expect(errors.length).assertEqual(1);
          expect((errors[0]['error'] as Record<string, Object>)['is_crash']).assertEqual(true);
          markersStayOutOfTheContext(errors[0]);
          return errors[0];
        };
        const foreground: Record<string, Object> = live(true, true, 100, false);
        expect(inForegroundOf(foreground)).assertEqual(true);
        expect(sessionOf(foreground)['sampled']).assertEqual(true);
        expect(inForegroundOf(live(true, false, 100, false))).assertEqual(false);
        expect(sessionOf(live(true, true, 0, true))['sampled']).assertEqual(false);
        // Negative control: early in a launch the system has not said — unknown, not background.
        const early: Record<string, Object> = live(false, false, 100, false);
        expect(inForegroundOf(early)).assertUndefined();
        expect(sessionOf(early)['sampled']).assertEqual(true);
      });

    it('aFreezeIsAnErrorOfItsViewButNotACrashOfIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const replay = (kind: string, withView: boolean): CapturingScope => {
          const core: FakeCore = new FakeCore();
          const scope: CapturingScope = new CapturingScope();
          const monitor: DefaultRumMonitor = featureWith(core, scope, 100, false);
          if (withView) {
            monitor.startView('home', 'home');
          } else {
            launchVital(monitor);
          }
          const crash: Record<string, Object> = nativeCrash(Date.now(), process.pid, { 'in_foreground': true });
          crash['crash_kind'] = kind;
          return nextLaunch(core, scope.lastView, 100, false, crash);
        };
        for (const withView of [true, false]) {
          const freeze: CapturingScope = replay('freeze', withView);
          const error: Record<string, Object> = freeze.ofType('error')[0];
          const errorBody: Record<string, Object> = error['error'] as Record<string, Object>;
          expect(errorBody['is_crash']).assertEqual(true);
          expect(errorBody['category']).assertEqual('ANR');
          // Fatal: it carries both markers.
          expect(inForegroundOf(error)).assertEqual(true);
          expect(sessionOf(error)['sampled']).assertEqual(true);
          const view: Record<string, Object> = freeze.ofType('view')[0];
          expect(crashCountOf(view)).assertEqual(0);
          expect(errorCountOf(view)).assertEqual(1);
          // Negative control: a crash of the same view counts as one.
          const crash: Record<string, Object> = replay('crash', withView).ofType('view')[0];
          expect(crashCountOf(crash)).assertEqual(1);
          expect(errorCountOf(crash)).assertEqual(1);
        }
      });

    it('neitherAJankNorAnErrorCarriesTheMarkers',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const core: FakeCore = new FakeCore();
        core.foreground = true;
        const scope: CapturingScope = new CapturingScope();
        const monitor: DefaultRumMonitor = crashFeature(core, scope, 100, false);
        monitor.startView('home', 'home');
        replayCrash(core, {
          'type': 'crash_report', 'crash_kind': 'jank', 'message': 'jank', 'stack': '#00 pc',
          'in_foreground': true, 'session_sampled': true
        } as Record<string, Object>);
        monitor.addError('handled', RumErrorSource.SOURCE);
        const errors: Array<Record<string, Object>> = scope.ofType('error');
        expect(errors.length).assertEqual(2);
        for (const error of errors) {
          expect((error['error'] as Record<string, Object>)['is_crash']).assertEqual(false);
          expect(inForegroundOf(error)).assertUndefined();
          expect(sessionOf(error)['sampled']).assertUndefined();
          markersStayOutOfTheContext(error);
        }
      });

    it('theSessionSaysWhetherItIsKeptOnlyOnError',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // What the crash module records at a JS crash.
        const drawn: FakeCore = new FakeCore();
        featureWith(drawn, new CapturingScope(), 100, true).startView('home', 'home');
        expect(drawn.featureContext['session.sampled_for_error']).assertEqual(false);
        const kept: FakeCore = new FakeCore();
        featureWith(kept, new CapturingScope(), 0, true).startView('home', 'home');
        expect(kept.featureContext['session.sampled_for_error']).assertEqual(true);
      });
  });
}
