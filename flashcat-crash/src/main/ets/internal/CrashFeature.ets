import {
  SdkCore,
  Feature,
  FeatureScope,
  FeatureEventReceiver,
  FlashcatContext,
  CRASH_FEATURE_NAME,
  RUM_FEATURE_NAME,
  FlashcatLog
} from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import appRecovery from '@ohos.app.ability.appRecovery';
import { CrashConfiguration, JsCrashPolicy } from '../CrashConfiguration';
import { CrashEventMapper } from './CrashEventMapper';
import {
  ConsumedCrashIncident,
  CrashDeduplication,
  CrashExceptionParts,
  CrashFingerprint,
  CrashIncidentRecord,
  CrashLoopDecision,
  CrashLoopGuard,
  LiveCrashIncidentGuard
} from './CrashIncident';

const WATCHER_NAME: string = 'flashcat_crash_watcher';
// Internal core receiver. This is a MessageBus contract, not public SDK API.
const CRASH_STORAGE_TARGET: string = '__flashcat_crash_storage';
const LIVE_DEDUP_WINDOW_MS: number = 2000;
const CROSS_LAUNCH_WINDOW_MS: number = 30000;
const CONSUMED_RETENTION_MS: number = 24 * 60 * 60 * 1000;

/**
 * Crash feature. Owns JS crash policy, durable incident replay, and hiAppEvent
 * APP_CRASH/APP_FREEZE capture. All callbacks are contained: crash reporting
 * must never introduce a second host failure.
 */
export class CrashFeature implements Feature, FeatureEventReceiver {
  readonly name: string = CRASH_FEATURE_NAME;
  private readonly core: SdkCore;
  private readonly configuration: CrashConfiguration;
  private readonly liveGuard: LiveCrashIncidentGuard =
    new LiveCrashIncidentGuard(LIVE_DEDUP_WINDOW_MS);
  private activePolicy: JsCrashPolicy;
  private consumed: ConsumedCrashIncident[] = [];
  private watching: boolean = false;

  constructor(core: SdkCore, configuration: CrashConfiguration) {
    this.core = core;
    this.configuration = configuration;
    this.activePolicy = configuration.jsCrashPolicy;
  }

  onInitialize(): void {
    this.core.setEventReceiver(CRASH_FEATURE_NAME, this);
    this.enableRecovery();
    this.consumed = CrashDeduplication.retainRecent(
      this.loadConsumed(), Date.now(), CONSUMED_RETENTION_MS);
    // Rewrite on every crash-feature start so expired or corrupt sidecar entries
    // do not accumulate when no new pending incident is replayed.
    this.persistConsumed();
    this.publishPolicy();
    this.replayPendingIncidents();
    this.registerWatcher();
  }

  onReceive(event: Record<string, Object>): void {
    try {
      const type: string = CrashFeature.stringValue(event['type']);
      if (type === 'js_crash_callback') {
        this.handleLiveCallback(event);
      } else if (type === 'js_crash_policy_request') {
        // RUM pulls the policy on its own start so enable order does not
        // matter: crash-then-RUM pulls here, RUM-then-crash gets the push
        // from publishPolicy().
        event['policy'] = this.activePolicy as string;
      }
    } catch (error) {
      // Never let a policy failure keep a process alive after a REPORT_* crash.
      event['report_async'] = true;
      event['policy'] = this.activePolicy as string;
      event['recover'] = false;
      event['should_exit'] = this.activePolicy !== JsCrashPolicy.OBSERVE_ONLY;
      FlashcatLog.e(`crash.js: live callback failed: ${CrashFeature.errorText(error)}`);
    }
  }

  private handleLiveCallback(event: Record<string, Object>): void {
    const callback: string = CrashFeature.stringValue(event['callback']);
    const text: string = CrashFeature.stringValue(event['text']);
    const nowMs: number = CrashFeature.positiveNumber(event['timestamp_ms'], Date.now());
    const fingerprint: string = CrashFingerprint.fromText(text);
    event['fingerprint'] = fingerprint;

    if (callback === 'exception') {
      if (this.liveGuard.isDuplicate(fingerprint, nowMs)) {
        event['duplicate'] = true;
        event['report_async'] = false;
        FlashcatLog.d(`crash.js: suppressed duplicate onException fingerprint=${fingerprint}`);
      } else {
        // Defensive OS-build fallback: onException may be the only callback.
        event['report_async'] = true;
      }
      return;
    }

    if (callback !== 'unhandled') {
      event['report_async'] = true;
      return;
    }

    this.liveGuard.remember(fingerprint, nowMs);
    event['policy'] = this.activePolicy as string;
    event['recover'] = false;
    if (this.activePolicy === JsCrashPolicy.OBSERVE_ONLY) {
      event['report_async'] = true;
      event['should_exit'] = false;
      return;
    }

    // JS policy reporting is intentionally independent of the hiAppEvent watcher
    // enablement/sample rate: both REPORT_* policies promise a synchronous report.
    const parts: CrashExceptionParts = CrashFingerprint.partsFromText(text);
    const context: FlashcatContext = this.core.getContext();
    const rumContext: Record<string, Object> = context.featureContext[RUM_FEATURE_NAME] ?? {};
    // Only record the crashed run's session/view when that session was sampled
    // in: the replay stamps these ids onto the reported error, and stamping an
    // unsampled session would surface a session that emitted no other events.
    const sessionSampled: boolean = rumContext['session.sampled'] !== false;
    const originSessionId: string = sessionSampled ? CrashFeature.stringValue(rumContext['session.id']) : '';
    const originViewId: string = sessionSampled ? CrashFeature.stringValue(rumContext['view.id']) : '';
    const originViewName: string = sessionSampled ? CrashFeature.stringValue(rumContext['view.name']) : '';
    const originViewUrl: string = sessionSampled ? CrashFeature.stringValue(rumContext['view.url']) : '';
    const incidentId: string = util.generateRandomUUID(true);
    // Persist a conservative exit outcome first. Recovery policy is written to
    // the same incident only after loop history is durable and restart is allowed,
    // so crash.recovered never labels a known clean-exit fallback.
    const initialPolicy: JsCrashPolicy = this.activePolicy === JsCrashPolicy.REPORT_AND_RECOVER ?
      JsCrashPolicy.REPORT_THEN_EXIT : this.activePolicy;
    const incident: CrashIncidentRecord = new CrashIncidentRecord(
      incidentId,
      nowMs,
      parts.name,
      parts.message,
      parts.stack,
      fingerprint,
      initialPolicy,
      context.sdkVersion,
      originSessionId,
      originViewId,
      originViewName,
      originViewUrl);

    let written: boolean = this.persistPendingIncident(incident);
    if (this.activePolicy === JsCrashPolicy.REPORT_AND_RECOVER) {
      const decision: CrashLoopDecision = CrashLoopGuard.decide(
        nowMs,
        this.loadLoopHistory(),
        this.configuration.crashLoopThreshold,
        this.configuration.crashLoopWindowMs,
        this.configuration.crashLoopCooldownMs);
      const loopPersisted: boolean = this.persistLoopHistory(decision.updatedTimestamps);
      if (!loopPersisted) {
        FlashcatLog.e('crash.loop: history write failed; degrading to exit');
      }
      if (!decision.allowRestart) {
        FlashcatLog.e(
          `crash.loop: threshold reached (${decision.updatedTimestamps.length} in ` +
          `${this.configuration.crashLoopWindowMs / 1000}s); degrading to exit`);
      } else if (loopPersisted) {
        const recoveryIncident: CrashIncidentRecord = new CrashIncidentRecord(
          incidentId,
          nowMs,
          parts.name,
          parts.message,
          parts.stack,
          fingerprint,
          JsCrashPolicy.REPORT_AND_RECOVER,
          context.sdkVersion,
          originSessionId,
          originViewId,
          originViewName,
          originViewUrl);
        written = this.persistPendingIncident(recoveryIncident);
        if (written) {
          event['recover'] = true;
        } else {
          FlashcatLog.e('crash.recovery: incident update failed; degrading to exit');
        }
      }
    }
    event['pending_written'] = written;
    // Termination is policy-driven, not write-driven: a rare pending-write
    // failure must not silently revert to keep-alive semantics. The report
    // still survives via the flushed async event and the next-launch
    // hiAppEvent APP_CRASH replay (unmatched, since no consumed record).
    event['report_async'] = !written;
    event['should_exit'] = true;
    if (written) {
      FlashcatLog.d(
        `crash.js: synchronously persisted incident=${incident.incidentId} fingerprint=${fingerprint}`);
    } else {
      FlashcatLog.e('crash.js: pending write failed; async report + exit per policy');
    }
  }

  private persistPendingIncident(incident: CrashIncidentRecord): boolean {
    const command: Record<string, Object> = {
      'type': 'crash_storage_write',
      'target': CRASH_STORAGE_TARGET,
      'incident_id': incident.incidentId,
      'serialized': incident.serialize(),
      'success': false
    };
    this.sendStorageCommand(command);
    return command['success'] === true;
  }

  private enableRecovery(): void {
    if (this.activePolicy !== JsCrashPolicy.REPORT_AND_RECOVER) {
      return;
    }
    try {
      appRecovery.enableAppRecovery(
        appRecovery.RestartFlag.RESTART_WHEN_JS_CRASH,
        appRecovery.SaveOccasionFlag.SAVE_WHEN_ERROR,
        appRecovery.SaveModeFlag.SAVE_WITH_FILE
      );
      FlashcatLog.d('crash.recovery: app recovery enabled');
    } catch (error) {
      this.activePolicy = JsCrashPolicy.REPORT_THEN_EXIT;
      FlashcatLog.e(
        `crash.recovery: enableAppRecovery failed: ${CrashFeature.errorText(error)}; ` +
        'degrading session policy to REPORT_THEN_EXIT');
    }
  }

  private publishPolicy(): void {
    const rum: FeatureScope | null = this.core.getFeature(RUM_FEATURE_NAME);
    if (rum === null) {
      // Not fatal: RumFeature pulls the policy when it starts later.
      FlashcatLog.d('crash.js: RUM not enabled yet; policy will be pulled on RUM start');
      return;
    }
    rum.sendEvent({
      'type': 'js_crash_policy',
      'target': RUM_FEATURE_NAME,
      'policy': this.activePolicy as string
    });
    FlashcatLog.d(`crash.js: policy owner enabled policy=${this.activePolicy}`);
  }

  private replayPendingIncidents(): void {
    const rum: FeatureScope | null = this.core.getFeature(RUM_FEATURE_NAME);
    if (rum === null) {
      FlashcatLog.d('crash.pending: retained because RUM feature is missing');
      return;
    }
    const command: Record<string, Object> = {
      'type': 'crash_storage_list',
      'target': CRASH_STORAGE_TARGET
    };
    this.sendStorageCommand(command);
    const value: Object | undefined = command['files'];
    if (!Array.isArray(value)) {
      return;
    }
    const files: Array<Object> = value as Array<Object>;
    for (let i: number = 0; i < files.length; i++) {
      const file: Record<string, Object> = CrashFeature.recordValue(files[i]);
      const fileName: string = CrashFeature.stringValue(file['file_name']);
      const incident: CrashIncidentRecord | null =
        CrashIncidentRecord.parse(CrashFeature.stringValue(file['serialized']));
      if (incident === null) {
        FlashcatLog.e(`crash.pending: corrupted record deleted file=${fileName}`);
        this.deletePending(fileName);
        continue;
      }
      rum.sendEvent(CrashEventMapper.fromPendingIncident(incident));
      FlashcatLog.d(
        `crash.pending: reported incident=${incident.incidentId} fingerprint=${incident.fingerprint}`);
      this.consumed.push(new ConsumedCrashIncident(
        incident.incidentId, incident.fingerprint, incident.timestampMs));
      this.consumed = CrashDeduplication.retainRecent(
        this.consumed, Date.now(), CONSUMED_RETENTION_MS);
      this.persistConsumed();
      this.deletePending(fileName);
    }
  }

  private loadConsumed(): ConsumedCrashIncident[] {
    const command: Record<string, Object> = {
      'type': 'crash_storage_read_consumed',
      'target': CRASH_STORAGE_TARGET
    };
    this.sendStorageCommand(command);
    const serialized: string = CrashFeature.stringValue(command['serialized']);
    if (serialized.length === 0) {
      return [];
    }
    const parsed: ConsumedCrashIncident[] = CrashDeduplication.parseConsumed(serialized);
    if (parsed.length === 0 && serialized.trim() !== '[]') {
      FlashcatLog.e('crash.pending: corrupted consumed sidecar ignored');
    }
    return parsed;
  }

  private persistConsumed(): void {
    const command: Record<string, Object> = {
      'type': 'crash_storage_write_consumed',
      'target': CRASH_STORAGE_TARGET,
      'serialized': CrashDeduplication.serializeConsumed(this.consumed),
      'success': false
    };
    this.sendStorageCommand(command);
    if (command['success'] !== true) {
      FlashcatLog.e('crash.pending: consumed sidecar write failed');
    }
  }

  private loadLoopHistory(): number[] {
    const command: Record<string, Object> = {
      'type': 'crash_storage_read_loop',
      'target': CRASH_STORAGE_TARGET
    };
    this.sendStorageCommand(command);
    const serialized: string = CrashFeature.stringValue(command['serialized']);
    if (serialized.length === 0) {
      return [];
    }
    const timestamps: number[] = CrashLoopGuard.parseHistory(serialized);
    if (timestamps.length === 0 && serialized.trim() !== '[]') {
      FlashcatLog.e('crash.loop: corrupted loop sidecar ignored; resetting');
    }
    return timestamps;
  }

  private persistLoopHistory(timestamps: number[]): boolean {
    const command: Record<string, Object> = {
      'type': 'crash_storage_write_loop',
      'target': CRASH_STORAGE_TARGET,
      'serialized': CrashLoopGuard.serializeHistory(timestamps),
      'success': false
    };
    this.sendStorageCommand(command);
    return command['success'] === true;
  }

  private deletePending(fileName: string): void {
    this.sendStorageCommand({
      'type': 'crash_storage_delete',
      'target': CRASH_STORAGE_TARGET,
      'file_name': fileName
    });
  }

  private sendStorageCommand(command: Record<string, Object>): void {
    const crashScope: FeatureScope | null = this.core.getFeature(CRASH_FEATURE_NAME);
    if (crashScope !== null) {
      crashScope.sendEvent(command);
    }
  }

  private registerWatcher(): void {
    const names: string[] = [];
    if (this.configuration.trackCrashes) {
      names.push(hiAppEvent.event.APP_CRASH);
    }
    if (this.configuration.trackAppHangs) {
      names.push(hiAppEvent.event.APP_FREEZE);
    }
    if (names.length === 0) {
      FlashcatLog.d('crash: watcher disabled by configuration');
      return;
    }
    try {
      hiAppEvent.addWatcher({
        name: WATCHER_NAME,
        appEventFilters: [{ domain: hiAppEvent.domain.OS, names: names }],
        onReceive: (_domain: string, groups: Array<hiAppEvent.AppEventGroup>) => {
          this.handle(groups);
        }
      });
      this.watching = true;
      FlashcatLog.d(`crash: watcher registered names=${names.join(',')}`);
    } catch (error) {
      this.watching = false;
      FlashcatLog.e(`crash: watcher registration failed: ${CrashFeature.errorText(error)}`);
    }
  }

  private handle(groups: Array<hiAppEvent.AppEventGroup>): void {
    try {
      FlashcatLog.d(`crash: received groups=${groups.length}`);
      const rum: FeatureScope | null = this.core.getFeature(RUM_FEATURE_NAME);
      if (rum === null) {
        FlashcatLog.d('crash: dropped because RUM feature is missing');
        return;
      }
      for (const group of groups) {
        const isFreeze: boolean = group.name === hiAppEvent.event.APP_FREEZE;
        FlashcatLog.d(`crash: group name=${group.name} events=${group.appEventInfos.length}`);
        for (const info of group.appEventInfos) {
          if (!CrashFeature.sampled(this.configuration.sampleRate)) {
            FlashcatLog.d('crash: dropped by sample rate');
            continue;
          }
          const params: Record<string, Object> = info.params as Record<string, Object>;
          const event: Record<string, Object> =
            isFreeze ? CrashEventMapper.fromAppFreeze(params) : CrashEventMapper.fromAppCrash(params);
          if (!isFreeze && CrashFeature.stringValue(params['crash_type']) === 'JsError') {
            const fingerprint: string = CrashFingerprint.fromText(
              `${CrashFeature.stringValue(event['message'])}\n${CrashFeature.stringValue(event['stack'])}`);
            const eventTimestampMs: number = CrashFeature.faultTimestamp(params, Date.now());
            if (CrashDeduplication.matchesConsumed(
              fingerprint, eventTimestampMs, this.consumed, CROSS_LAUNCH_WINDOW_MS)) {
              FlashcatLog.d(
                `crash: skipped duplicate APP_CRASH fingerprint=${fingerprint} timestamp=${eventTimestampMs}`);
              continue;
            }
          }
          FlashcatLog.d(`crash: send to RUM kind=${event['crash_kind']} message=${event['message']}`);
          rum.sendEvent(event);
        }
      }
    } catch (error) {
      FlashcatLog.e(`crash: handle failed: ${CrashFeature.errorText(error)}`);
    }
  }

  /** Sampling decision. 100 -> always, 0 -> never, else probabilistic. */
  static sampled(sampleRate: number): boolean {
    if (sampleRate >= 100) {
      return true;
    }
    if (sampleRate <= 0) {
      return false;
    }
    return Math.random() * 100 < sampleRate;
  }

  onStop(): void {
    this.core.removeEventReceiver(CRASH_FEATURE_NAME);
    if (this.watching) {
      try {
        hiAppEvent.removeWatcher({ name: WATCHER_NAME });
      } catch (_error) {
        // Already removed.
      }
      this.watching = false;
    }
  }

  private static faultTimestamp(params: Record<string, Object>, fallbackMs: number): number {
    const keys: string[] = ['timestamp_ms', 'timestamp', 'crash_time', 'time', 'time_'];
    for (let i: number = 0; i < keys.length; i++) {
      const value: Object | undefined = params[keys[i]];
      if (typeof value === 'number' && value > 0) {
        return value < 100000000000 ? value * 1000 : value;
      }
    }
    return fallbackMs;
  }

  private static recordValue(value: Object): Record<string, Object> {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return {};
  }

  private static stringValue(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private static positiveNumber(value: Object | undefined, fallback: number): number {
    return typeof value === 'number' && value > 0 ? value : fallback;
  }

  private static errorText(value: Object): string {
    return value instanceof Error ? value.message : `${value}`;
  }
}
