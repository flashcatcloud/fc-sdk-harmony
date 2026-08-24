import { SdkCore, FlashcatContext } from '@flashcatcloud/core';

/**
 * The values one configuration response carried. `null` means the console did
 * not set that knob, so whatever was passed to init keeps applying — an absent
 * knob and a knob set to zero are different answers, and collapsing them would
 * silently switch a customer's collection off.
 */
export class RemoteConfigValues {
  readonly sessionSampleRate: number | null;
  readonly version: number | null;
  /** Raw JSON object string of the console's custom bag, delivered verbatim. */
  readonly custom: string | null;
  /** Validator echoed back as If-None-Match, quoted exactly as the server sent it. */
  readonly etag: string | null;

  constructor(
    sessionSampleRate: number | null,
    version: number | null = null,
    custom: string | null = null,
    etag: string | null = null
  ) {
    this.sessionSampleRate = sessionSampleRate;
    this.version = version;
    this.custom = custom;
    this.etag = etag;
  }
}

/**
 * The configuration a session was drawn under: the rate actually used at the
 * draw (the console's where it set one, the init value where it did not, the
 * hook's where it overrode both) and the settings version it came from. Events
 * carry these instead of the init values, so an audit lines up with the draw
 * that kept the session — a session is never re-judged, so the metadata must
 * come from its creation, not from whatever has arrived since.
 */
export class DrawnConfiguration {
  /** 0 when no configuration was ever fetched. */
  readonly version: number;
  readonly sessionSampleRate: number;

  constructor(version: number, sessionSampleRate: number) {
    this.version = version;
    this.sessionSampleRate = sessionSampleRate;
  }
}

const FIELD_RATE: string = 'rate';
const FIELD_VERSION: string = 'version';
const FIELD_CUSTOM: string = 'custom';
const FIELD_ETAG: string = 'etag';
const MAX_RATE: number = 100;

/**
 * Keeps the console's configuration across launches. Feature modules get no
 * HarmonyOS Context of their own, so the bytes go through the core's settings
 * store; everything above that line is this module's business.
 *
 * Storage that cannot be read is not an error state: the SDK simply runs on the
 * values the app was initialised with.
 */
export class RemoteConfigStore {
  private readonly core: SdkCore;
  private readonly storeKey: string;

  constructor(core: SdkCore, storeKey: string) {
    this.core = core;
    this.storeKey = storeKey;
  }

  /** What the last readable response left here, or null before the first one. */
  read(): RemoteConfigValues | null {
    const serialized: string | null = this.core.readSetting(this.valuesKey());
    if (serialized === null) {
      return null;
    }
    return RemoteConfigStore.parseValues(serialized);
  }

  /**
   * Replaces what is stored with what the response carried. A knob the response
   * omitted is dropped rather than left behind, so turning a knob off in the
   * console really does hand it back to the value the app was initialised with.
   */
  write(values: RemoteConfigValues): void {
    const record: Record<string, Object> = {};
    if (values.sessionSampleRate !== null) {
      record[FIELD_RATE] = values.sessionSampleRate;
    }
    // Kept even when no rates resolved — that is what "remote configuration is
    // off, use your own settings" looks like — so the console can still see
    // this client is up to date with the change that turned them off.
    if (values.version !== null) {
      record[FIELD_VERSION] = values.version;
    }
    if (values.custom !== null) {
      record[FIELD_CUSTOM] = values.custom;
    }
    if (values.etag !== null) {
      record[FIELD_ETAG] = values.etag;
    }
    this.core.writeSetting(this.valuesKey(), JSON.stringify(record));
  }

  /**
   * The console's custom bag, decoded. A body we cannot parse reads as nothing
   * published rather than as an error: the bag is application-defined, and no
   * rate or decision of ours depends on it.
   */
  static decodeCustom(raw: string | null): Record<string, Object> | null {
    if (raw === null) {
      return null;
    }
    return RemoteConfigStore.parseObject(raw);
  }

  /** Which version the stored values came from, or null before the first answer.
   * Reported back on the next request so the console can say how far a change
   * has reached — a question events cannot answer, because a session that was
   * not kept sends none, and the miss rate is set by the very rate being changed. */
  appliedVersion(): number | null {
    const values: RemoteConfigValues | null = this.read();
    return values === null ? null : values.version;
  }

  private valuesKey(): string {
    return `${this.storeKey}.values`;
  }


  /**
   * Identifies whose configuration this is. It covers everything that can
   * change the answer — which host is asked, which application, in which
   * environment, at which app version — so an app that ships a new version, or
   * two applications on one device, never read each other's values.
   *
   * The SDK version is deliberately left out: including it would discard the
   * stored values on every SDK upgrade and put the first session after an
   * upgrade back on the init values. The storage FORMAT version lives in the
   * prefix instead, so only a real format change orphans the cache.
   */
  static buildStoreKey(context: FlashcatContext, host: string, applicationId: string): string {
    const parts: string[] = [
      RemoteConfigStore.hostOf(host), applicationId, context.service, context.env, context.version
    ];
    return `_fc_rc_1_${parts.join('|')}`;
  }

  private static hostOf(url: string): string {
    const schemeEnd: number = url.indexOf('://');
    const afterScheme: string = schemeEnd >= 0 ? url.substring(schemeEnd + 3) : url;
    const pathStart: number = afterScheme.indexOf('/');
    return pathStart >= 0 ? afterScheme.substring(0, pathStart) : afterScheme;
  }

  private static parseValues(serialized: string): RemoteConfigValues | null {
    const record: Record<string, Object> | null = RemoteConfigStore.parseObject(serialized);
    if (record === null) {
      return null;
    }
    return new RemoteConfigValues(
      RemoteConfigStore.rateOf(record[FIELD_RATE]),
      RemoteConfigStore.intOf(record[FIELD_VERSION]),
      RemoteConfigStore.stringOf(record[FIELD_CUSTOM]),
      RemoteConfigStore.stringOf(record[FIELD_ETAG])
    );
  }

  private static parseObject(serialized: string): Record<string, Object> | null {
    try {
      const value: Object = JSON.parse(serialized) as Object;
      if (typeof value !== 'object' || value === null || Array.isArray(value)) {
        return null;
      }
      return value as Record<string, Object>;
    } catch (_e) {
      return null;
    }
  }

  /** An out-of-range rate is treated as absent rather than clamped: a rate we
   * cannot trust is not a rate to sample a customer's traffic with. */
  private static rateOf(value: Object | undefined): number | null {
    if (typeof value !== 'number' || Number.isNaN(value) || value < 0 || value > MAX_RATE) {
      return null;
    }
    return value as number;
  }

  private static intOf(value: Object | undefined): number | null {
    if (typeof value !== 'number' || Number.isNaN(value)) {
      return null;
    }
    return Math.trunc(value as number);
  }

  private static stringOf(value: Object | undefined): string | null {
    return typeof value === 'string' && (value as string).length > 0 ? value as string : null;
  }
}
