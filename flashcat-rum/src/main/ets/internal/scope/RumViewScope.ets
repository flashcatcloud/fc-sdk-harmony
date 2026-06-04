import { FeatureScope, FlashcatContext, EventWriter, SdkCore } from '@flashcatcloud/core';
import { RumScope, RumRawEvent } from './RumScope';
import { RumEventAssembler } from '../assembly/RumEventAssembler';

const MS_TO_NS: number = 1e6;

/**
 * Tracks the lifetime of a single view (page): its action/error counts and
 * time-spent. Emits a ViewEvent on start (document_version 1) and on each update
 * (final version when stopped) — `date` stays the view start, `time_spent` and
 * `document_version` advance. Also assembles ErrorEvents for errors raised while
 * it is active.
 */
export class RumViewScope implements RumScope {
  private readonly featureScope: FeatureScope;
  private readonly core: SdkCore;
  private readonly applicationId: string;
  private readonly sessionId: string;
  private readonly key: string;
  private readonly viewName: string;
  private readonly viewId: string;
  private readonly startedAtMs: number;
  private readonly attributes: Record<string, Object>;
  private actionCount: number = 0;
  private errorCount: number = 0;
  private documentVersion: number = 0;
  private active: boolean = true;

  constructor(
    featureScope: FeatureScope,
    core: SdkCore,
    applicationId: string,
    sessionId: string,
    key: string,
    viewName: string,
    viewId: string,
    startedAtMs: number,
    attributes: Record<string, Object>
  ) {
    this.featureScope = featureScope;
    this.core = core;
    this.applicationId = applicationId;
    this.sessionId = sessionId;
    this.key = key;
    this.viewName = viewName;
    this.viewId = viewId;
    this.startedAtMs = startedAtMs;
    this.attributes = attributes;
    // Publish the active view so Logs/Trace can correlate.
    const update: Record<string, Object> = {};
    update['view.id'] = viewId;
    update['view.name'] = viewName;
    this.core.updateFeatureContext('rum', update);
    this.writeViewEvent(startedAtMs);
  }

  handleEvent(event: RumRawEvent): RumScope | null {
    switch (event.kind) {
      case 'stopView':
        if (event.key === this.key) {
          this.active = false;
          this.writeViewEvent(event.timestampMs);
          return null;
        }
        return this;
      case 'addAction':
        this.actionCount += 1;
        this.writeViewEvent(event.timestampMs);
        return this;
      case 'addError':
        this.errorCount += 1;
        this.writeError(event);
        this.writeViewEvent(event.timestampMs);
        return this;
      default:
        return this;
    }
  }

  /** Close this view (new view started, or session expired) and emit a final event. */
  forceStop(nowMs: number): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    this.writeViewEvent(nowMs);
  }

  isActive(): boolean {
    return this.active;
  }

  getViewId(): string {
    return this.viewId;
  }

  private writeViewEvent(nowMs: number): void {
    this.documentVersion += 1;
    const timeSpentNs: number = Math.max(0, nowMs - this.startedAtMs) * MS_TO_NS;
    const version: number = this.documentVersion;
    const actions: number = this.actionCount;
    const errors: number = this.errorCount;
    const isActive: boolean = this.active;
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.view(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        this.startedAtMs, timeSpentNs, actions, errors, version, isActive, this.attributes);
      writer.write(event);
    });
  }

  private writeError(raw: RumRawEvent): void {
    this.featureScope.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      const event: Record<string, Object> = RumEventAssembler.error(
        context, this.applicationId, this.sessionId, this.viewId, this.viewName,
        raw.errorMessage ?? '', raw.errorSource ?? 'source', raw.errorStack,
        raw.isCrash ?? false, raw.errorHandling ?? 'handled', raw.timestampMs, raw.attributes);
      // Error/crash events are force-flushed so they upload promptly (not after the
      // 5s/512KB batch threshold).
      writer.write(event, true);
    });
  }
}
