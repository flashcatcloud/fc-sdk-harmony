import { FlashcatLog } from '@flashcatcloud/core';
import { RemoteConfigStore, RemoteConfigValues } from './RemoteConfigStore';
import { RemoteConfigFetcher, RemoteConfigResponse } from './RemoteConfigFetcher';

const DEFAULT_TTL_SECONDS: number = 300;
const ACTIVATION_IMMEDIATE: string = 'immediate';
const RETRY_DELAYS_SECONDS: number[] = [5, 60];
const JITTER_FRACTION: number = 0.2;
const MAX_RATE: number = 100;
const MS_PER_SECOND: number = 1000;
const HTTP_NOT_MODIFIED: number = 304;
/**
 * The contract this SDK reads. Not the SDK version and not the settings version: it names the
 * SHAPE of the body, and the server bumps it only when a body would be misread by a reader
 * written against the previous shape.
 */
const SUPPORTED_SCHEMA_VERSION: number = 1;

/**
 * What reading one response body came to. Only UNREADABLE is worth asking again for: the other
 * two are answers, whether or not this SDK can act on them.
 */
export enum ApplyOutcome {
  /** The body was read and its values are now stored. */
  APPLIED = 'applied',
  /**
   * The body was not a configuration at all — not JSON, or truncated. A captive portal answering
   * 200 with a login page looks exactly like this, so it is treated as a request that did not
   * arrive rather than as a configuration saying nothing.
   */
  UNREADABLE = 'unreadable',
  /**
   * The body is a configuration written to a contract this SDK does not know. Refused whole: a
   * payload shaped for a newer reader can be misread field by field while every individual field
   * still parses, and half-understood sampling settings are worse than none.
   */
  UNSUPPORTED_SCHEMA = 'unsupported_schema'
}

const FIELD_SCHEMA_VERSION: string = 'schema_version';
const FIELD_VERSION: string = 'version';
const FIELD_TTL: string = 'ttl';
const FIELD_ENABLED: string = 'enabled';
const FIELD_ACTIVATION: string = 'activation';
const FIELD_REFRESH_ON_FOREGROUND: string = 'refresh_on_foreground';
const FIELD_RUM: string = 'rum';
const FIELD_CUSTOM: string = 'custom';
const FIELD_SESSION_SAMPLE_RATE: string = 'sessionSampleRate';

/**
 * Keeps the stored remote configuration in step with what the console says.
 *
 * Fetching follows the rhythm of the sessions that read it: once at start-up
 * and once whenever a new session begins — a change can only matter at the next
 * draw, so asking more often than sessions are drawn would be requests for
 * nothing. There is no timer between sessions; the server's `ttl` only bounds
 * how stale the stored values may be when the console allows a foreground
 * refresh.
 *
 * Nothing here can hold up the SDK or interrupt collection: a trigger never
 * waits on the request, and a request that fails, times out or comes back
 * unreadable leaves the stored values exactly as they were. Wiping them on a
 * bad minute would swing a whole fleet back to the values it was built with,
 * the opposite of what someone who turned a knob deliberately wants.
 */
export class RemoteConfigController {
  private readonly store: RemoteConfigStore;
  private readonly fetcher: RemoteConfigFetcher;
  private readonly configUrl: string;
  private readonly initialSessionSampleRate: number;
  private readonly restartSession: () => void;

  private lastFetchAtMs: number = 0;
  private ttlSeconds: number = DEFAULT_TTL_SECONDS;
  private refreshOnForeground: boolean = false;
  private inFlight: boolean = false;
  private failedAttempts: number = 0;
  private pendingRetryId: number = -1;
  private stopped: boolean = false;

  constructor(
    store: RemoteConfigStore,
    fetcher: RemoteConfigFetcher,
    configUrl: string,
    initialSessionSampleRate: number,
    restartSession: () => void
  ) {
    this.store = store;
    this.fetcher = fetcher;
    this.configUrl = configUrl;
    this.initialSessionSampleRate = initialSessionSampleRate;
    this.restartSession = restartSession;
  }

  start(): void {
    this.triggerFetch();
  }

  /**
   * A new session is the one moment a changed configuration can matter: its
   * draw has just happened with whatever was stored, and this response lands in
   * storage for the next draw. It never waits for the request — a session is
   * never delayed by the network.
   */
  onSessionStarted(): void {
    this.triggerFetch();
  }

  /**
   * Asks again when the app returns to the foreground, where timers cannot be
   * trusted: the system may not have run them for hours.
   *
   * Off unless an operator turned it on for this application. Session starts
   * spread requests across the day; returning to the foreground does the
   * opposite, bunching them at the moment everyone opens the app — the same
   * shape as a release herd, arriving when the endpoint can least absorb it.
   * The staleness check is the second guard: it keeps switching between apps
   * from turning into a request each time.
   */
  refreshIfStale(): void {
    const ageMs: number = Date.now() - this.lastFetchAtMs;
    if (RemoteConfigController.shouldRefreshOnForeground(this.refreshOnForeground, ageMs, this.ttlSeconds)) {
      this.triggerFetch();
    }
  }

  stop(): void {
    this.stopped = true;
    this.cancelRetry();
  }

  /**
   * Runs a fetch now, dropping any retry still waiting: a natural trigger
   * re-arms the whole backoff, so a session starting in the middle of an outage
   * does not wait out the patient retry before asking again.
   */
  private triggerFetch(): void {
    if (this.stopped) {
      return;
    }
    this.cancelRetry();
    this.failedAttempts = 0;
    if (this.inFlight) {
      return;
    }
    this.inFlight = true;
    this.fetchOnce();
  }

  private fetchOnce(): void {
    // Stamped before the request goes out, so a request that never comes back
    // still counts as an attempt for the staleness gate instead of leaving the
    // app asking again on every foreground.
    this.lastFetchAtMs = Date.now();
    const applied: number | null = this.store.appliedVersion();
    const url: string = applied === null ? this.configUrl : `${this.configUrl}&applied_version=${applied}`;
    const stored: RemoteConfigValues | null = this.store.read();
    // The answer varies per caller, so the validator only means something
    // paired with the configuration it validated: stored beside it, echoed back
    // exactly as sent.
    const ifNoneMatch: string | null = stored === null ? null : stored.etag;

    this.fetcher.fetch(url, ifNoneMatch)
      .then((response: RemoteConfigResponse) => {
        this.inFlight = false;
        // A request already on the wire cannot be recalled, so the answer can
        // arrive after the SDK was stopped. Applying it then would write to
        // storage and restart a session on behalf of a torn-down feature.
        if (this.stopped) {
          return;
        }
        // Unchanged: what is stored is still the answer, so there is nothing to
        // apply — but the ask itself succeeded, and no retry is owed.
        if (response.code === HTTP_NOT_MODIFIED) {
          return;
        }
        if (response.code < 200 || response.code >= 300) {
          this.scheduleRetry();
          return;
        }
        // An unreadable body is the only outcome worth asking again for. A body we understood —
        // even one we must refuse because its schema is newer than this SDK — is an answered
        // question, and repeating it would just be the same refusal twice.
        if (this.apply(response.body, response.etag) === ApplyOutcome.UNREADABLE) {
          this.scheduleRetry();
        }
      })
      .catch((e: Object) => {
        this.inFlight = false;
        if (this.stopped) {
          return;
        }
        FlashcatLog.d(`rum.remoteconfig: fetch failed (${e instanceof Error ? e.message : 'network error'}); keeping the values already in use`);
        this.scheduleRetry();
      });
  }

  /**
   * A failed fetch is retried quickly, then patiently, then not at all until the
   * next natural trigger (a new session, or the next app start). The budget is
   * deliberately tiny — two extra requests per outage per client — so a fleet
   * can never turn an endpoint incident into a storm.
   */
  private scheduleRetry(): void {
    if (this.stopped || this.failedAttempts >= RETRY_DELAYS_SECONDS.length) {
      return;
    }
    const delaySeconds: number =
      RemoteConfigController.jittered(RETRY_DELAYS_SECONDS[this.failedAttempts], Math.random());
    this.failedAttempts++;
    this.pendingRetryId = setTimeout(() => {
      this.pendingRetryId = -1;
      if (this.stopped || this.inFlight) {
        return;
      }
      this.inFlight = true;
      this.fetchOnce();
    }, delaySeconds * MS_PER_SECOND);
  }

  private cancelRetry(): void {
    if (this.pendingRetryId !== -1) {
      clearTimeout(this.pendingRetryId);
      this.pendingRetryId = -1;
    }
  }

  /**
   * Stores what the response carried and, when the console asked for it,
   * restarts the session so the new values take hold now instead of at the
   * visitor's next one.
   *
   * The session is only restarted when the values THIS client will draw with
   * really changed. Without that check, a console resending an unchanged
   * configuration would cut every session in two on every fetch.
   */
  apply(payload: string, etag: string | null): ApplyOutcome {
    const json: Record<string, Object> | null = RemoteConfigStore.parseObject(payload);
    if (json === null) {
      FlashcatLog.d('rum.remoteconfig: response was not readable; keeping the values already in use');
      return ApplyOutcome.UNREADABLE;
    }
    // Checked before anything is read out of the body. The server states the shape it wrote, and
    // a reader that guesses instead of checking is exactly what this field exists to prevent —
    // which is why it has to be honoured by the first SDK that ships, not by a later one: only
    // code already on the device can refuse.
    // No stamp at all is not a refusal: a body without one is, by construction, the shape that
    // existed before the stamp did, which is the shape this reader was written against. Refusing it
    // would switch remote configuration silently off against a server that merely predates the
    // field. Only a stamp we can see and do not recognise is a reason to refuse.
    const stamped: boolean = json[FIELD_SCHEMA_VERSION] !== undefined && json[FIELD_SCHEMA_VERSION] !== null;
    const schema: number | null = RemoteConfigController.positiveIntOf(json[FIELD_SCHEMA_VERSION]);
    if (stamped && schema !== SUPPORTED_SCHEMA_VERSION) {
      FlashcatLog.e(`rum.remoteconfig: ignoring a configuration written to schema version ${schema ?? 'none'}; `
        + `this SDK reads version ${SUPPORTED_SCHEMA_VERSION}. Update the SDK to take the console's settings again`);
      return ApplyOutcome.UNSUPPORTED_SCHEMA;
    }
    const enabled: boolean = json[FIELD_ENABLED] === true;
    const activation: string = RemoteConfigController.stringOf(json[FIELD_ACTIVATION]) ?? '';
    this.refreshOnForeground = json[FIELD_REFRESH_ON_FOREGROUND] === true;

    const before: number | null = this.storedRate();
    const version: number | null = RemoteConfigController.positiveIntOf(json[FIELD_VERSION]);
    const rate: number | null = enabled
      ? RemoteConfigController.readRate(RemoteConfigController.objectOf(json[FIELD_RUM]))
      : null;
    // Stored as the raw string: delivery is the platform's job, the meaning
    // belongs to the host application.
    const custom: string | null = enabled ? RemoteConfigController.rawObjectOf(json[FIELD_CUSTOM]) : null;
    this.store.write(new RemoteConfigValues(rate, version, custom, etag));

    if (activation === ACTIVATION_IMMEDIATE && this.changesThisClient(before, rate)) {
      this.restartSession();
    }

    // Remembered here rather than around the request, so a fetch that fails
    // keeps the ttl the server last asked for instead of falling back to ours.
    const ttl: number | null = RemoteConfigController.positiveIntOf(json[FIELD_TTL]);
    this.ttlSeconds = ttl ?? DEFAULT_TTL_SECONDS;
    return ApplyOutcome.APPLIED;
  }

  private storedRate(): number | null {
    const stored: RemoteConfigValues | null = this.store.read();
    return stored === null ? null : stored.sessionSampleRate;
  }

  private changesThisClient(before: number | null, after: number | null): boolean {
    return (before ?? this.initialSessionSampleRate) !== (after ?? this.initialSessionSampleRate);
  }

  /**
   * Whether returning to the foreground is a reason to ask again. Both halves
   * guard different things: the permission keeps the request pattern off unless
   * someone chose it, and the age keeps app switching from becoming a request
   * each time.
   */
  static shouldRefreshOnForeground(allowed: boolean, ageMs: number, ttlSeconds: number): boolean {
    return allowed && ageMs >= ttlSeconds * MS_PER_SECOND;
  }

  /**
   * Spreads a delay by ±20%. An endpoint incident aligns every failed client's
   * retry clock to the same moment; without this, recovery would be greeted by
   * the whole fleet at once.
   */
  static jittered(seconds: number, jitter: number): number {
    return seconds * (1 - JITTER_FRACTION + 2 * JITTER_FRACTION * jitter);
  }

  /** A value the response did not send stays absent, so the value passed to init
   * keeps applying. An out-of-range number is treated the same way rather than
   * clamped: a rate we cannot trust is not a rate to sample traffic with. */
  private static readRate(rum: Record<string, Object> | null): number | null {
    if (rum === null) {
      return null;
    }
    const value: Object | undefined = rum[FIELD_SESSION_SAMPLE_RATE];
    if (typeof value !== 'number' || Number.isNaN(value) || value < 0 || value > MAX_RATE) {
      return null;
    }
    return value as number;
  }


  private static objectOf(value: Object | undefined): Record<string, Object> | null {
    if (value === undefined || typeof value !== 'object' || value === null || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  private static rawObjectOf(value: Object | undefined): string | null {
    const record: Record<string, Object> | null = RemoteConfigController.objectOf(value);
    return record === null ? null : JSON.stringify(record);
  }

  private static positiveIntOf(value: Object | undefined): number | null {
    if (typeof value !== 'number' || Number.isNaN(value) || (value as number) <= 0) {
      return null;
    }
    return Math.trunc(value as number);
  }

  private static stringOf(value: Object | undefined): string | null {
    return typeof value === 'string' ? value as string : null;
  }

}
