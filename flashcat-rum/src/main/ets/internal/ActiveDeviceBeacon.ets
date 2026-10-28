import { http } from '@kit.NetworkKit';
import { SdkCore, FlashcatContext, IntakeTarget, TrackingConsent, FlashcatLog } from '@flashcatcloud/core';
import { RumEventAssembler } from './assembly/RumEventAssembler';

const ACTIVE_PATH: string = '/api/v2/rum/active';
// Settings keys (the core namespaces them). Both hold the anonymous and user
// ids, so both go when consent is revoked.
const SENT_KEY: string = 'rum.active.sent';
const PENDING_KEY: string = 'rum.active.pending';
// The intake refuses a late beacon older than this; it is dropped here instead.
const MAX_AGE_MS: number = 72 * 60 * 60 * 1000;
const RETRY_DELAYS_MS: number[] = [2000, 8000];
const TIMEOUT_MS: number = 10000;
/** What a sender answers when no HTTP status came back at all. */
export const NETWORK_ERROR: number = 0;

/** Delivers one beacon body and answers the HTTP status. A seam for tests. */
export interface ActiveBeaconSender {
  send(url: string, body: string): Promise<number>;
}

/** Real sender, on the same NetworkKit stack the intake uploads run on. */
export class HttpActiveBeaconSender implements ActiveBeaconSender {
  private readonly userAgent: string;

  constructor(userAgent: string) {
    this.userAgent = userAgent;
  }

  async send(url: string, body: string): Promise<number> {
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'User-Agent': this.userAgent } as Record<string, string>,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS
      });
      FlashcatLog.d(`rum.active: POST ${ACTIVE_PATH} -> ${response.responseCode}`);
      return response.responseCode as number;
    } catch (e) {
      FlashcatLog.d(`rum.active: POST ${ACTIVE_PATH} failed: ${e instanceof Error ? e.message : 'network error'}`);
      return NETWORK_ERROR;
    } finally {
      if (request !== null) {
        try {
          request.destroy();
        } catch (_e) {
          // Nothing left to release.
        }
      }
    }
  }
}

/** One beacon: the body without its age, when the app was in use, and the
 * day/identity it reports (the dedup key). */
interface Beacon {
  payload: Record<string, Object>;
  usedAtMs: number;
  key: string;
}

enum Outcome {
  SENT,
  REJECTED,   // a 4xx other than 429: this body will never be accepted
  FAILED,     // retries exhausted (or the SDK stopped while waiting)
  ABORTED     // consent is no longer granted
}

/**
 * Tells the intake, once a day per device and user, that the app is in use.
 *
 * Sent on its own request rather than through the batch pipeline: a session of
 * a few seconds never reaches its first upload, and the device would not count
 * as active that day. "Already sent today" is judged on the device's local
 * date and only saves requests — the intake keeps one row per day either way,
 * and dates it by its own clock.
 *
 * Gated on GRANTED consent and on the app being in the foreground; session
 * sampling does not apply. A beacon still undelivered after the retries is
 * stored (one at most) and sent on a later trigger with its age.
 */
export class ActiveDeviceBeacon {
  private readonly core: SdkCore;
  private readonly sender: ActiveBeaconSender;
  private readonly retryDelaysMs: number[];
  private readonly now: () => number;
  private running: boolean = false;
  private again: boolean = false;
  private stopped: boolean = false;
  private retryTimer: number = -1;
  private wake: (() => void) | null = null;

  constructor(core: SdkCore, sender: ActiveBeaconSender, retryDelaysMs: number[] = RETRY_DELAYS_MS,
    now: () => number = (): number => Date.now()) {
    this.core = core;
    this.sender = sender;
    this.retryDelaysMs = retryDelaysMs;
    this.now = now;
  }

  /** Launch, return to foreground, consent granted, user changed. */
  trigger(): void {
    if (this.stopped) {
      return;
    }
    try {
      if (!this.consentGranted() || !this.core.isAppInForeground()) {
        return;
      }
      if (this.running) {
        this.again = true; // e.g. a new user set while the launch beacon is on the wire
        return;
      }
      this.running = true;
      this.run().then(() => {
        this.running = false;
      }, (e: Object) => {
        this.running = false;
        FlashcatLog.e(`rum.active: failed: ${e instanceof Error ? e.message : 'error'}`);
      });
    } catch (e) {
      FlashcatLog.e(`rum.active: trigger failed: ${e instanceof Error ? e.message : 'error'}`);
    }
  }

  /** Consent revoked: what is stored names the device and the user. */
  forget(): void {
    if (this.core.readSetting(PENDING_KEY) !== null) {
      this.core.writeSetting(PENDING_KEY, null);
    }
    if (this.core.readSetting(SENT_KEY) !== null) {
      this.core.writeSetting(SENT_KEY, null);
    }
  }

  /** SDK stop. A request on the wire finishes; a retry waiting is cut short and
   * the beacon is stored for the next launch instead. */
  stop(): void {
    this.stopped = true;
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const wake: (() => void) | null = this.wake;
    this.wake = null;
    if (wake !== null) {
      wake();
    }
  }

  private async run(): Promise<void> {
    do {
      this.again = false;
      const usedAtMs: number = this.now();
      if (!(await this.deliverStored())) {
        return; // the intake is unreachable: the live beacon would fail the same way
      }
      const context: FlashcatContext = this.core.getContext();
      const key: string = ActiveDeviceBeacon.keyFor(context, usedAtMs);
      if (key.length === 0 || this.core.readSetting(SENT_KEY) === key) {
        continue;
      }
      const beacon: Beacon = { payload: ActiveDeviceBeacon.payloadFor(context), usedAtMs: usedAtMs, key: key };
      const outcome: Outcome = await this.deliver(beacon, false);
      if (outcome === Outcome.SENT) {
        this.core.writeSetting(SENT_KEY, key);
      } else if (outcome === Outcome.FAILED && this.consentGranted()) {
        this.core.writeSetting(PENDING_KEY, ActiveDeviceBeacon.serialize(beacon));
      }
    } while (this.again && !this.stopped && this.consentGranted());
  }

  /** Sends the stored beacon, if any. False when it is still undeliverable. */
  private async deliverStored(): Promise<boolean> {
    const raw: string | null = this.core.readSetting(PENDING_KEY);
    if (raw === null) {
      return true;
    }
    const stored: Beacon | null = ActiveDeviceBeacon.parse(raw);
    const outcome: Outcome = stored === null ? Outcome.REJECTED : await this.deliver(stored, true);
    if (outcome === Outcome.FAILED || outcome === Outcome.ABORTED) {
      return false;
    }
    this.core.writeSetting(PENDING_KEY, null); // sent, refused or too old
    if (outcome === Outcome.SENT && stored !== null
      && stored.key === ActiveDeviceBeacon.keyFor(this.core.getContext(), this.now())) {
      this.core.writeSetting(SENT_KEY, stored.key);
    }
    return true;
  }

  private async deliver(beacon: Beacon, late: boolean): Promise<Outcome> {
    for (let attempt: number = 0; ; attempt++) {
      if (!this.consentGranted()) {
        return Outcome.ABORTED;
      }
      const ageMs: number = late ? Math.max(0, this.now() - beacon.usedAtMs) : 0;
      if (ageMs > MAX_AGE_MS) {
        FlashcatLog.d('rum.active: stored beacon is older than 72h, dropped');
        return Outcome.REJECTED;
      }
      const body: Record<string, Object> = {};
      for (const k of Object.keys(beacon.payload)) {
        body[k] = beacon.payload[k];
      }
      body['age_ms'] = ageMs;
      const code: number = await this.sender.send(this.url(), JSON.stringify(body));
      if (code >= 200 && code < 300) {
        return Outcome.SENT;
      }
      if (code >= 400 && code < 500 && code !== 429) {
        return Outcome.REJECTED;
      }
      if (attempt >= this.retryDelaysMs.length || this.stopped) {
        return Outcome.FAILED;
      }
      await this.sleep(this.retryDelaysMs[attempt]);
      if (this.stopped) {
        return Outcome.FAILED;
      }
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.wake = resolve;
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        this.wake = null;
        resolve();
      }, ms);
    });
  }

  /** The intake host honours a custom endpoint, so a private deployment's own
   * host (or the proxy in front of it) receives the beacon. */
  private url(): string {
    const intake: IntakeTarget = this.core.getIntakeTarget();
    const host: string = intake.host.endsWith('/') ? intake.host.substring(0, intake.host.length - 1) : intake.host;
    return `${host}${ACTIVE_PATH}?dd-api-key=${encodeURIComponent(intake.clientToken)}`;
  }

  private consentGranted(): boolean {
    const consent: TrackingConsent = this.core.getTrackingConsent();
    if (consent === TrackingConsent.NOT_GRANTED) {
      this.forget();
    }
    return consent === TrackingConsent.GRANTED;
  }

  /** Local day + anonymous id + user id; empty when there is no identity to report. */
  static keyFor(context: FlashcatContext, atMs: number): string {
    const anonymousId: string = context.anonymousId ?? '';
    const userId: string = context.user.id ?? '';
    if (anonymousId.length === 0 && userId.length === 0) {
      return '';
    }
    const day: Date = new Date(atMs);
    const month: string = `${day.getMonth() + 1}`.padStart(2, '0');
    const date: string = `${day.getDate()}`.padStart(2, '0');
    return `${day.getFullYear()}-${month}-${date}|${anonymousId}|${userId}`;
  }

  static payloadFor(context: FlashcatContext): Record<string, Object> {
    const usr: Record<string, Object> = {};
    if (context.anonymousId !== undefined && context.anonymousId.length > 0) {
      usr['anonymous_id'] = context.anonymousId;
    }
    if (context.user.id !== undefined && context.user.id.length > 0) {
      usr['id'] = context.user.id;
    }
    const os: Record<string, Object> = {};
    os['name'] = context.device.osName;
    os['version'] = context.device.osVersion;
    const device: Record<string, Object> = {};
    device['type'] = RumEventAssembler.deviceTypeFor(context.device.deviceType);
    device['model'] = context.device.model;
    device['brand'] = context.device.brand;
    const payload: Record<string, Object> = {};
    payload['service'] = context.service;
    payload['env'] = context.env;
    payload['version'] = context.version;
    payload['build_version'] = context.buildVersion ?? '';
    payload['sdk_version'] = context.sdkVersion;
    payload['usr'] = usr;
    payload['os'] = os;
    payload['device'] = device;
    return payload;
  }

  private static serialize(beacon: Beacon): string {
    const record: Record<string, Object> = {};
    record['payload'] = beacon.payload;
    record['used_at'] = beacon.usedAtMs;
    record['key'] = beacon.key;
    return JSON.stringify(record);
  }

  private static parse(raw: string): Beacon | null {
    try {
      const record: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const payload: Object | undefined = record['payload'];
      const usedAt: Object | undefined = record['used_at'];
      const key: Object | undefined = record['key'];
      if (typeof payload !== 'object' || payload === null || typeof usedAt !== 'number' || typeof key !== 'string') {
        return null;
      }
      return { payload: payload as Record<string, Object>, usedAtMs: usedAt as number, key: key as string };
    } catch (_e) {
      return null;
    }
  }
}
