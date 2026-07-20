import { JsCrashPolicy } from '../CrashConfiguration';

const FNV_OFFSET_BASIS: number = 2166136261;
const FNV_PRIME: number = 16777619;
const MAX_STACK_CHARS: number = 16000;

/** Parsed exception fields shared by live callbacks and hiAppEvent replay. */
export class CrashExceptionParts {
  readonly name: string;
  readonly message: string;
  readonly stack: string;

  constructor(name: string, message: string, stack: string) {
    this.name = name;
    this.message = message;
    this.stack = stack;
  }
}

/** Pure normalized fingerprint logic; intentionally has no device dependencies. */
export class CrashFingerprint {
  static fromText(text: string): string {
    const parts: CrashExceptionParts = CrashFingerprint.partsFromText(text);
    return CrashFingerprint.fromParts(parts.name, parts.message, parts.stack);
  }

  static fromParts(name: string, message: string, stack: string): string {
    const normalizedName: string = name.trim().toLowerCase();
    const normalizedMessage: string = message.trim();
    const frame: string = CrashFingerprint.normalizeFrame(CrashFingerprint.firstFrame(stack));
    return CrashFingerprint.fnv1a(`${normalizedName}\n${normalizedMessage}\n${frame}`);
  }

  static partsFromText(text: string): CrashExceptionParts {
    const stack: string = CrashFingerprint.truncate(text, MAX_STACK_CHARS);
    const lines: string[] = text.split('\n');
    // errorManager.on('error') callback text uses a labeled three-part format
    // ("Error name:<n>\nError message:<m>\nStacktrace:\n..."). Parse it
    // field-wise so the live fingerprint matches the hiAppEvent fault, whose
    // exception name/message arrive already separated. Falling through to the
    // header heuristic here made the two sides disagree ("Error name:Error"
    // became the message) and broke cross-launch deduplication.
    if (lines.length >= 2 && lines[0].startsWith('Error name:') && lines[1].startsWith('Error message:')) {
      return new CrashExceptionParts(
        lines[0].substring('Error name:'.length).trim(),
        lines[1].substring('Error message:'.length).trim(),
        stack);
    }
    const header: string = lines.length > 0 ? lines[0].trim() : '';
    const separator: number = header.indexOf(':');
    if (separator > 0) {
      const candidate: string = header.substring(0, separator).trim();
      if (candidate.endsWith('Error') || candidate.endsWith('Exception')) {
        return new CrashExceptionParts(
          candidate,
          header.substring(separator + 1).trim(),
          stack);
      }
    }
    return new CrashExceptionParts('Error', header, stack);
  }

  private static firstFrame(stack: string): string {
    const lines: string[] = stack.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.startsWith('at ') || line.startsWith('#')) {
        return line;
      }
    }
    return lines.length > 1 ? lines[1].trim() : '';
  }

  private static normalizeFrame(frame: string): string {
    const value: string = frame.trim();
    const open: number = value.indexOf('(');
    const close: number = value.lastIndexOf(')');
    if (open >= 0 && close > open) {
      const prefix: string = value.substring(0, open + 1);
      const path: string = CrashFingerprint.normalizePath(value.substring(open + 1, close));
      return `${prefix}${path})`;
    }
    const space: number = value.lastIndexOf(' ');
    if (space >= 0) {
      const token: string = value.substring(space + 1);
      return `${value.substring(0, space + 1)}${CrashFingerprint.normalizePath(token)}`;
    }
    return CrashFingerprint.normalizePath(value);
  }

  private static normalizePath(value: string): string {
    let path: string = CrashFingerprint.stripLocation(value);
    if (path.startsWith('/')) {
      const slash: number = path.lastIndexOf('/');
      if (slash >= 0) {
        path = path.substring(slash + 1);
      }
    }
    return path;
  }

  private static stripLocation(value: string): string {
    let result: string = value;
    for (let i: number = 0; i < 2; i++) {
      const colon: number = result.lastIndexOf(':');
      if (colon < 0 || !CrashFingerprint.isDigits(result.substring(colon + 1))) {
        break;
      }
      result = result.substring(0, colon);
    }
    return result;
  }

  private static isDigits(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    for (let i: number = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }

  private static fnv1a(value: string): string {
    let hash: number = FNV_OFFSET_BASIS;
    for (let i: number = 0; i < value.length; i++) {
      hash = Math.imul(hash ^ value.charCodeAt(i), FNV_PRIME) >>> 0;
    }
    return hash.toString(16).padStart(8, '0');
  }

  private static truncate(value: string, max: number): string {
    return value.length <= max ? value : value.substring(0, max);
  }
}

/** The most recent live JS incident, used to collapse the two platform callbacks. */
export class LiveCrashIncidentGuard {
  private readonly windowMs: number;
  private fingerprint: string = '';
  private timestampMs: number = 0;

  constructor(windowMs: number) {
    this.windowMs = windowMs;
  }

  remember(fingerprint: string, timestampMs: number): void {
    this.fingerprint = fingerprint;
    this.timestampMs = timestampMs;
  }

  isDuplicate(fingerprint: string, timestampMs: number): boolean {
    const elapsed: number = timestampMs - this.timestampMs;
    return this.fingerprint.length > 0 && this.fingerprint === fingerprint &&
      elapsed >= 0 && elapsed <= this.windowMs;
  }
}

/** Small persisted metadata entry for a pending incident already replayed to RUM. */
export class ConsumedCrashIncident {
  readonly incidentId: string;
  readonly fingerprint: string;
  readonly timestampMs: number;

  constructor(incidentId: string, fingerprint: string, timestampMs: number) {
    this.incidentId = incidentId;
    this.fingerprint = fingerprint;
    this.timestampMs = timestampMs;
  }

  toRecord(): Record<string, Object> {
    return {
      'incident_id': this.incidentId,
      'fingerprint': this.fingerprint,
      'timestamp_ms': this.timestampMs
    };
  }
}

/** Pure cross-launch window matching and retention helpers. */
export class CrashDeduplication {
  static serializeConsumed(consumed: ConsumedCrashIncident[]): string {
    const records: Array<Record<string, Object>> = [];
    for (let i: number = 0; i < consumed.length; i++) {
      records.push(consumed[i].toRecord());
    }
    return JSON.stringify(records);
  }

  static parseConsumed(serialized: string): ConsumedCrashIncident[] {
    const consumed: ConsumedCrashIncident[] = [];
    try {
      const value: Object = JSON.parse(serialized) as Object;
      if (!Array.isArray(value)) {
        return consumed;
      }
      const items: Array<Object> = value as Array<Object>;
      for (let i: number = 0; i < items.length; i++) {
        const item: Object = items[i];
        if (typeof item !== 'object' || item === null || Array.isArray(item)) {
          continue;
        }
        const record: Record<string, Object> = item as Record<string, Object>;
        const incidentId: string = CrashDeduplication.stringValue(record['incident_id']);
        const fingerprint: string = CrashDeduplication.stringValue(record['fingerprint']);
        const timestampMs: number = CrashDeduplication.numberValue(record['timestamp_ms']);
        if (incidentId.length > 0 && fingerprint.length > 0 && timestampMs > 0) {
          consumed.push(new ConsumedCrashIncident(incidentId, fingerprint, timestampMs));
        }
      }
    } catch (_error) {
      return [];
    }
    return consumed;
  }

  static matchesConsumed(
    fingerprint: string,
    eventTimestampMs: number,
    consumed: ConsumedCrashIncident[],
    windowMs: number
  ): boolean {
    for (let i: number = 0; i < consumed.length; i++) {
      const incident: ConsumedCrashIncident = consumed[i];
      if (incident.fingerprint === fingerprint &&
        Math.abs(eventTimestampMs - incident.timestampMs) <= windowMs) {
        return true;
      }
    }
    return false;
  }

  static retainRecent(
    consumed: ConsumedCrashIncident[],
    nowMs: number,
    retentionMs: number
  ): ConsumedCrashIncident[] {
    const recent: ConsumedCrashIncident[] = [];
    for (let i: number = 0; i < consumed.length; i++) {
      const incident: ConsumedCrashIncident = consumed[i];
      if (nowMs - incident.timestampMs <= retentionMs) {
        recent.push(incident);
      }
    }
    return recent;
  }

  private static stringValue(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private static numberValue(value: Object | undefined): number {
    return typeof value === 'number' ? value : 0;
  }
}

/** Dedicated durable record written before policy-driven process termination. */
export class CrashIncidentRecord {
  readonly incidentId: string;
  readonly timestampMs: number;
  readonly exceptionName: string;
  readonly message: string;
  readonly stack: string;
  readonly fingerprint: string;
  readonly policy: JsCrashPolicy;
  readonly sdkVersion: string;
  readonly sessionId: string;
  readonly viewId: string;
  readonly viewName: string;

  constructor(
    incidentId: string,
    timestampMs: number,
    exceptionName: string,
    message: string,
    stack: string,
    fingerprint: string,
    policy: JsCrashPolicy,
    sdkVersion: string,
    sessionId: string,
    viewId: string,
    viewName: string
  ) {
    this.incidentId = incidentId;
    this.timestampMs = timestampMs;
    this.exceptionName = exceptionName;
    this.message = message;
    this.stack = CrashFingerprint.partsFromText(stack).stack;
    this.fingerprint = fingerprint;
    this.policy = policy;
    this.sdkVersion = sdkVersion;
    this.sessionId = sessionId;
    this.viewId = viewId;
    this.viewName = viewName;
  }

  serialize(): string {
    const record: Record<string, Object> = {
      'incident_id': this.incidentId,
      'timestamp_ms': this.timestampMs,
      'exception_name': this.exceptionName,
      'message': this.message,
      'stack': this.stack,
      'fingerprint': this.fingerprint,
      'policy': this.policy as string,
      'sdk_version': this.sdkVersion,
      'session_id': this.sessionId,
      'view_id': this.viewId,
      'view_name': this.viewName
    };
    return JSON.stringify(record);
  }

  static parse(serialized: string): CrashIncidentRecord | null {
    try {
      const value: Object = JSON.parse(serialized) as Object;
      if (typeof value !== 'object' || value === null || Array.isArray(value)) {
        return null;
      }
      const record: Record<string, Object> = value as Record<string, Object>;
      const incidentId: string = CrashIncidentRecord.stringValue(record['incident_id']);
      const timestampMs: number = CrashIncidentRecord.numberValue(record['timestamp_ms']);
      const exceptionName: string = CrashIncidentRecord.stringValue(record['exception_name']);
      const message: string = CrashIncidentRecord.stringValue(record['message']);
      const stack: string = CrashIncidentRecord.stringValue(record['stack']);
      const fingerprint: string = CrashIncidentRecord.stringValue(record['fingerprint']);
      const policy: JsCrashPolicy | null = CrashIncidentRecord.policyValue(record['policy']);
      if (incidentId.length === 0 || timestampMs <= 0 || exceptionName.length === 0 ||
        fingerprint.length === 0 || policy === null) {
        return null;
      }
      return new CrashIncidentRecord(
        incidentId,
        timestampMs,
        exceptionName,
        message,
        stack,
        fingerprint,
        policy,
        CrashIncidentRecord.stringValue(record['sdk_version']),
        CrashIncidentRecord.stringValue(record['session_id']),
        CrashIncidentRecord.stringValue(record['view_id']),
        CrashIncidentRecord.stringValue(record['view_name']));
    } catch (_error) {
      return null;
    }
  }

  private static policyValue(value: Object | undefined): JsCrashPolicy | null {
    if (value === JsCrashPolicy.REPORT_THEN_EXIT) {
      return JsCrashPolicy.REPORT_THEN_EXIT;
    }
    if (value === JsCrashPolicy.REPORT_AND_RECOVER) {
      return JsCrashPolicy.REPORT_AND_RECOVER;
    }
    if (value === JsCrashPolicy.OBSERVE_ONLY) {
      return JsCrashPolicy.OBSERVE_ONLY;
    }
    return null;
  }

  private static stringValue(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private static numberValue(value: Object | undefined): number {
    return typeof value === 'number' ? value : 0;
  }
}
