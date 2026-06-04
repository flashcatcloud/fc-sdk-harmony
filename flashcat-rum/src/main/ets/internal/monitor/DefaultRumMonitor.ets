import { SdkCore, FeatureScope } from '@flashcatcloud/core';
import { systemDateTime } from '@kit.BasicServicesKit';
import { RumMonitor } from '../../RumMonitor';
import { RumConfiguration } from '../../RumConfiguration';
import { RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from '../../RumTypes';
import { RumApplicationScope } from '../scope/RumApplicationScope';
import { RumRawEvent } from '../scope/RumScope';

/**
 * Default RumMonitor. Translates the public API into RumRawEvents fed to the
 * application scope, which assembles + writes View / Error events.
 * Equivalent to Android's DatadogRumMonitor.
 *
 * Phase 1 scope: View + Error. Action/Resource methods exist for API parity but
 * actions only bump the view's action count and resources are no-ops.
 */
export class DefaultRumMonitor implements RumMonitor {
  private readonly applicationScope: RumApplicationScope;
  private readonly globalAttributes: Map<string, Object> = new Map<string, Object>();

  constructor(core: SdkCore, featureScope: FeatureScope, configuration: RumConfiguration) {
    this.applicationScope = new RumApplicationScope(
      featureScope, core, configuration.applicationId, configuration.sessionSampleRate);
  }

  startView(key: string, name: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('startView', attributes);
    e.key = key;
    e.name = name;
    this.applicationScope.handleEvent(e);
  }

  stopView(key: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('stopView', attributes);
    e.key = key;
    this.applicationScope.handleEvent(e);
  }

  addAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('addAction', attributes);
    e.name = name;
    this.applicationScope.handleEvent(e);
  }

  // Long-running actions are not distinguished in phase 1.
  startAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {
    this.addAction(type, name, attributes);
  }

  stopAction(type: RumActionType, name: string, attributes?: Record<string, Object>): void {
    // no-op in phase 1
  }

  // Resources are out of scope for phase 1 (no network performance events yet).
  startResource(key: string, method: RumResourceMethod, url: string, attributes?: Record<string, Object>): void {
    // no-op in phase 1
  }

  stopResource(key: string, statusCode: number, size: number, kind: RumResourceKind,
    attributes?: Record<string, Object>): void {
    // no-op in phase 1
  }

  addError(message: string, source: RumErrorSource, stack?: string, attributes?: Record<string, Object>): void {
    this.reportError(message, source, stack, false, 'handled', attributes);
  }

  /** Internal: used by the unhandled-exception hook to flag errors as unhandled. */
  reportError(message: string, source: RumErrorSource, stack: string | undefined,
    isCrash: boolean, handling: string, attributes?: Record<string, Object>): void {
    const e: RumRawEvent = this.raw('addError', attributes);
    e.errorMessage = message;
    e.errorSource = source as string;
    e.errorStack = stack;
    e.isCrash = isCrash;
    e.errorHandling = handling;
    this.applicationScope.handleEvent(e);
  }

  addAttribute(key: string, value: Object): void {
    this.globalAttributes.set(key, value);
  }

  removeAttribute(key: string): void {
    this.globalAttributes.delete(key);
  }

  getCurrentSessionId(callback: (sessionId: string | undefined) => void): void {
    callback(this.applicationScope.getCurrentSessionId());
  }

  private raw(kind: string, attributes?: Record<string, Object>): RumRawEvent {
    const attrs: Record<string, Object> = {};
    this.globalAttributes.forEach((v: Object, k: string) => {
      attrs[k] = v;
    });
    if (attributes !== undefined) {
      for (const k of Object.keys(attributes)) {
        attrs[k] = attributes[k];
      }
    }
    return { kind, attributes: attrs, timestampMs: systemDateTime.getTime() };
  }
}
