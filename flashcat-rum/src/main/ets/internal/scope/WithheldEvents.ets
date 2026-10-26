import { FeatureScope, FlashcatContext, EventWriter, SdkCore, TrackingConsent, FlashcatLog } from '@flashcatcloud/core';
import { util } from '@kit.ArkTS';
import { LastViewSnapshot } from '../LastViewSnapshot';

/**
 * How much history a withheld session keeps: an error session shows the minute
 * leading up to its error, and a session that never errors holds no more than that.
 */
export const WITHHELD_BUFFER_DURATION_MS: number = 60 * 1000;
/** Memory bound for detail events (views excluded). Over it the least valuable go first. */
export const WITHHELD_BUFFER_BYTES_LIMIT: number = 64 * 1024;
export const WITHHELD_BUFFER_EVENTS_LIMIT: number = 200;
/**
 * Views are the containers their events hang from — the backend builds the session
 * row out of view events — so they stay out of the detail budget and are only
 * bounded against pathological navigation counts.
 */
export const WITHHELD_BUFFER_VIEWS_LIMIT: number = 50;
/**
 * Correlated failures make every client release at the same instant, right when
 * the backend is already under strain. Releases are spread over this window.
 */
export const WITHHELD_BUFFER_RELEASE_MAX_DELAY_MS: number = 3000;

const ENCODER: util.TextEncoder = new util.TextEncoder();

/** What is dropped first when the buffer is over budget. Lower goes first. */
enum EvictionTier {
  /** Requests that succeeded without complaint. */
  FIRST = 0,
  /** Actions, failed requests and everything else: they explain what the user did. */
  LAST = 1,
  /** Errors are why the session is kept at all; even then the newest goes first. */
  LAST_RESORT = 2
}

/**
 * What is held is the event's serialized form, taken as it was written: an
 * event object shares the attribute values the app passed in, and the app may
 * go on changing those. A collected session uploads what the values were at the
 * write; an on-error session must release the same, not what they became.
 */
class HeldEvent {
  readonly line: string;
  /** '' for an error raised before any view started: it has no container to lose. */
  readonly viewId: string;
  readonly timeMs: number;
  readonly bytes: number;
  readonly tier: EvictionTier;

  constructor(line: string, viewId: string, timeMs: number, bytes: number, tier: EvictionTier) {
    this.line = line;
    this.viewId = viewId;
    this.timeMs = timeMs;
    this.bytes = bytes;
    this.tier = tier;
  }
}

class HeldView {
  readonly line: string;
  /** The view's start date, which orders the release. */
  readonly date: number;
  /** Its document version: a document is superseded only by a newer one. */
  readonly version: number;

  constructor(line: string, date: number, version: number) {
    this.line = line;
    this.date = date;
    this.version = version;
  }
}

/**
 * The events of one on-error session, held in memory until the session reports an
 * error or ends. Holds the latest document of each view plus a rolling minute of
 * detail events, and hands them over in the order the backend needs to rebuild
 * the session from them.
 */
export class WithheldEventBuffer {
  /** Latest document per view, in the order they were last updated. */
  private views: Map<string, HeldView> = new Map<string, HeldView>();
  private details: HeldEvent[] = [];
  private bytes: number = 0;
  private droppedCount: number = 0;
  private currentViewId: string = '';
  private currentViewDate: number = -Infinity;
  /** When the release was scheduled; 0 while none is. Freezes the window, see prune. */
  private frozenAtMs: number = 0;

  /**
   * Holds `line`, the serialized form of `event` as it was written; `bytes` is
   * its size, which views are not charged for. Returns false when the event was
   * dropped rather than held.
   */
  hold(event: Record<string, Object>, line: string, bytes: number, nowMs: number): boolean {
    const viewId: string = WithheldEventBuffer.viewIdOf(event);
    if (event['type'] === 'view') {
      // Upsert: a view document is cumulative, so the newest supersedes the rest.
      // Newest by document version, not by arrival: a document is assembled
      // before its mapper runs, and a mapper that reports into the SDK has the
      // next version written first. Deleting first moves the entry to the back,
      // so the oldest entry is the least recently updated one.
      const date: number = typeof event['date'] === 'number' ? event['date'] as number : 0;
      const version: number = WithheldEventBuffer.documentVersionOf(event);
      const held: HeldView | undefined = this.views.get(viewId);
      if (held === undefined || version >= held.version) {
        this.views.delete(viewId);
        this.views.set(viewId, new HeldView(line, date, version));
      }
      // The view's own start date decides which one is current, not arrival order:
      // a late update of a view that already ended must not make it current again,
      // or prune would drop the view the next error hangs from.
      if (date >= this.currentViewDate) {
        this.currentViewDate = date;
        this.currentViewId = viewId;
      }
      while (this.views.size > WITHHELD_BUFFER_VIEWS_LIMIT) {
        const oldest: string = this.views.keys().next().value as string;
        const evicted: HeldView = this.views.get(oldest) as HeldView;
        this.views.delete(oldest);
        if (oldest === this.currentViewId) {
          // The view in progress is never evicted: move it to the back instead.
          this.views.set(oldest, evicted);
        }
      }
      this.prune(nowMs);
      return true;
    }
    if (bytes > WITHHELD_BUFFER_BYTES_LIMIT) {
      // Could never be part of a release, and making room for it would evict the
      // whole minute before it. Keep the history instead.
      this.droppedCount += 1;
      return false;
    }
    this.details.push(new HeldEvent(line, viewId, nowMs, bytes, WithheldEventBuffer.tierOf(event)));
    this.bytes += bytes;
    this.prune(nowMs);
    while (this.details.length > WITHHELD_BUFFER_EVENTS_LIMIT || this.bytes > WITHHELD_BUFFER_BYTES_LIMIT) {
      if (!this.evictOne()) {
        break;
      }
    }
    return true;
  }

  /**
   * A release was scheduled: stop the window from moving. The timer carrying the
   * release can be held back while the app is in the background, and pruning
   * against a later time would throw away exactly the minute before the error.
   */
  freeze(nowMs: number): void {
    if (this.frozenAtMs === 0) {
      this.frozenAtMs = nowMs;
    }
  }

  /**
   * Writes everything still held: views oldest first (the backend creates the
   * session row from the first view it receives), then errors, then the rest
   * oldest first. A release often happens right before the app goes away, and
   * only the first writes are sure to leave — the error must not ride in the last.
   *
   * Every detail goes out whether or not its view is held: views only decide
   * the order. An error before the first view, with view tracking off, or whose
   * view document the mapper dropped is still the error the session is kept for.
   */
  release(writer: EventWriter, nowMs: number, sessionId: string): void {
    this.prune(nowMs);
    const views: HeldView[] = [];
    this.views.forEach((view: HeldView) => {
      views.push(view);
    });
    views.sort((left: HeldView, right: HeldView) => left.date - right.date);
    const ordered: string[] = views.map((view: HeldView) => view.line);
    for (const held of this.details) {
      if (held.tier === EvictionTier.LAST_RESORT) {
        ordered.push(held.line);
      }
    }
    for (const held of this.details) {
      if (held.tier !== EvictionTier.LAST_RESORT) {
        ordered.push(held.line);
      }
    }
    let persisted: number = 0;
    for (let i: number = 0; i < ordered.length; i++) {
      // One batch, uploaded as soon as the last event is in. A write storage
      // refuses is gone, as it is for a collected session: nothing retries it.
      if (writer.write(JSON.parse(ordered[i]) as Record<string, Object>, i === ordered.length - 1)) {
        persisted += 1;
      }
    }
    FlashcatLog.d(`rum.withheld: released session=${sessionId} ${this.describe()} persisted=${persisted} failed=${ordered.length - persisted}`);
    this.clear();
  }

  /** What is held right now, for the log lines that account for it. */
  describe(): string {
    return `views=${this.views.size} details=${this.details.length} dropped=${this.droppedCount} detail_bytes=${this.bytes}`;
  }

  clear(): void {
    this.views = new Map<string, HeldView>();
    this.details = [];
    this.bytes = 0;
    this.droppedCount = 0;
    this.currentViewId = '';
    this.currentViewDate = -Infinity;
    this.frozenAtMs = 0;
  }

  /** Drops what aged out of the window, then every non-current view left without detail. */
  private prune(nowMs: number): void {
    const now: number = this.frozenAtMs > 0 ? this.frozenAtMs : nowMs;
    const oldestAllowedMs: number = now - WITHHELD_BUFFER_DURATION_MS;
    let cutoff: number = 0;
    while (cutoff < this.details.length && this.details[cutoff].timeMs < oldestAllowedMs) {
      this.bytes -= this.details[cutoff].bytes;
      this.droppedCount += 1;
      cutoff += 1;
    }
    if (cutoff > 0) {
      this.details = this.details.slice(cutoff);
    }
    const withDetail: Set<string> = new Set<string>();
    for (const held of this.details) {
      withDetail.add(held.viewId);
    }
    const stale: string[] = [];
    this.views.forEach((_view: HeldView, id: string) => {
      if (id !== this.currentViewId && !withDetail.has(id)) {
        stale.push(id);
      }
    });
    for (const id of stale) {
      this.views.delete(id);
    }
  }

  private evictOne(): boolean {
    const tiers: EvictionTier[] = [EvictionTier.FIRST, EvictionTier.LAST];
    for (const tier of tiers) {
      const index: number = this.details.findIndex((held: HeldEvent) => held.tier === tier);
      if (index !== -1) {
        this.evictAt(index);
        return true;
      }
    }
    // Only errors left: drop the newest, so an error storm never pushes out the
    // first error — the one that released the buffer.
    for (let index: number = this.details.length - 1; index >= 0; index--) {
      if (this.details[index].tier === EvictionTier.LAST_RESORT) {
        this.evictAt(index);
        return true;
      }
    }
    return false;
  }

  private evictAt(index: number): void {
    this.bytes -= this.details[index].bytes;
    this.droppedCount += 1;
    this.details.splice(index, 1);
  }

  private static tierOf(event: Record<string, Object>): EvictionTier {
    const type: Object | undefined = event['type'];
    if (type === 'error') {
      return EvictionTier.LAST_RESORT;
    }
    if (type === 'resource') {
      // A request that failed is part of how the error happened; one that succeeded rarely is.
      const resource: Object | undefined = event['resource'];
      const status: Object | undefined = typeof resource === 'object' && resource !== null ?
        (resource as Record<string, Object>)['status_code'] : undefined;
      const code: number = typeof status === 'number' ? status as number : -1;
      return code === 0 || code >= 400 ? EvictionTier.LAST : EvictionTier.FIRST;
    }
    return EvictionTier.LAST;
  }

  private static documentVersionOf(event: Record<string, Object>): number {
    const dd: Object | undefined = event['_dd'];
    const version: Object | undefined = typeof dd === 'object' && dd !== null ?
      (dd as Record<string, Object>)['document_version'] : undefined;
    return typeof version === 'number' ? version as number : 0;
  }

  private static viewIdOf(event: Record<string, Object>): string {
    const view: Object | undefined = event['view'];
    if (typeof view !== 'object' || view === null) {
      return '';
    }
    const id: Object | undefined = (view as Record<string, Object>)['id'];
    return typeof id === 'string' ? id as string : '';
  }
}

/**
 * Deterministic per session, so a client always spreads to the same offset.
 * Multiplicative rather than a running sum: session ids are same-length strings
 * over one small alphabet, and summing their character codes lands nearly every
 * session within a few hundred milliseconds of the same value.
 */
export function computeReleaseDelay(sessionId: string): number {
  let hash: number = 0;
  for (let i: number = 0; i < sessionId.length; i++) {
    hash = Math.imul(hash, 31) + sessionId.charCodeAt(i);
  }
  return Math.abs(hash) % WITHHELD_BUFFER_RELEASE_MAX_DELAY_MS;
}

/**
 * The write path of a session kept only if it errors (`sessionOnError`). Its
 * scopes run exactly like a collected session's — the mapper included — but what
 * they write is held here instead of reaching storage, until:
 * - the session writes an error of its own (after the mapper, so an error the app
 *   dropped releases nothing): released after a per-session jitter;
 * - the process is about to die of a crash, or the app forces the session:
 *   released at once;
 * - the session ends: released if it errored, thrown away otherwise. A thrown-away
 *   session keeps dropping whatever its still-draining views write afterwards, so
 *   a request that completes after the session ended cannot resurrect it.
 * A refused tracking consent forgets everything held, the error included, and
 * the session starts withholding afresh. After a release the session writes
 * straight through, like any collected one.
 */
export class WithholdingFeatureScope implements FeatureScope {
  private readonly delegate: FeatureScope;
  private readonly core: SdkCore;
  private readonly sessionId: string;
  /** Null once released or discarded. */
  private buffer: WithheldEventBuffer | null = new WithheldEventBuffer();
  private discarded: boolean = false;
  private hasError: boolean = false;
  private releaseTimerId: number = -1;
  /** Writes in progress: the mapper runs inside one, and may end the session from there. */
  private writing: number = 0;
  private settleAfterWrite: boolean = false;

  constructor(delegate: FeatureScope, core: SdkCore, sessionId: string) {
    this.delegate = delegate;
    this.core = core;
    this.sessionId = sessionId;
  }

  withWriteContext(callback: (context: FlashcatContext, writer: EventWriter) => void): void {
    this.delegate.withWriteContext((context: FlashcatContext, writer: EventWriter) => {
      this.writing += 1;
      try {
        callback(context, new WithholdingWriter(this, writer));
      } finally {
        this.writing -= 1;
        if (this.writing === 0 && this.settleAfterWrite) {
          this.settleAfterWrite = false;
          this.settle();
        }
      }
    });
  }

  sendEvent(event: Record<string, Object>): void {
    this.delegate.sendEvent(event);
  }

  /** Still holding: nothing of this session has reached storage, so the backend has no session under its id. */
  isWithholding(): boolean {
    return this.buffer !== null;
  }

  /** The process is about to die of a crash: whatever is held must reach storage now. */
  releaseForCrash(): void {
    this.hasError = true;
    this.releaseNow();
  }

  /** RumMonitor.setForcedSession: the app asked for this visitor now, not on an error. */
  releaseForced(): void {
    this.releaseNow();
  }

  /** The app may be about to go away: a release already scheduled leaves now.
   * One not yet earned is kept — the app usually comes back. */
  releaseIfScheduled(): void {
    if (this.releaseTimerId !== -1) {
      this.releaseNow();
    }
  }

  /** SDK stop: nothing held may reach the core any more, earned or not. */
  stop(): void {
    const buffer: WithheldEventBuffer | null = this.buffer;
    this.cancelTimer();
    this.buffer = null;
    this.discarded = true;
    if (buffer !== null) {
      // What was held is gone for good: nothing of this session may be rebuilt
      // on the next launch either.
      LastViewSnapshot.invalidateFor(this.sessionId);
    }
  }

  /**
   * Tracking consent was refused: everything collected so far is forgotten, the
   * error included, exactly as the core wipes the batches it had collected. The
   * session goes on withholding, so a later consent and a later error release
   * only what was collected after both.
   */
  forget(): void {
    const buffer: WithheldEventBuffer | null = this.buffer;
    if (buffer === null) {
      return;
    }
    this.cancelTimer();
    buffer.clear();
    this.hasError = false;
  }

  /** The session ended: what it earned goes out, the rest is thrown away for good. */
  settle(): void {
    const buffer: WithheldEventBuffer | null = this.buffer;
    if (buffer === null) {
      return;
    }
    if (this.writing > 0) {
      // The session is being ended from inside a write — the app's mapper may
      // be looking at this session's first error. Whether that error is kept
      // is known only once the write lands, so the decision waits for it.
      this.settleAfterWrite = true;
      return;
    }
    if (this.hasError) {
      this.releaseNow();
      return;
    }
    this.cancelTimer();
    this.buffer = null;
    this.discarded = true;
    // The backend never saw this session; its last view must not let a crash
    // replayed on the next launch build it after all.
    LastViewSnapshot.invalidateFor(this.sessionId);
    FlashcatLog.d(`rum.withheld: discarded session=${this.sessionId} ${buffer.describe()} (ended without an error)`);
  }

  /** @internal the write path of {@link WithholdingWriter}. */
  route(writer: EventWriter, event: Record<string, Object>, forceFlush: boolean): boolean {
    if (this.discarded) {
      return false;
    }
    const buffer: WithheldEventBuffer | null = this.buffer;
    if (buffer === null) {
      return writer.write(event, forceFlush);
    }
    if (this.core.getTrackingConsent() === TrackingConsent.NOT_GRANTED) {
      // Every write is dropped under a refused consent. The core announces the
      // refusal too; this covers a core that predates the announcement.
      this.forget();
      return false;
    }
    let line: string;
    try {
      line = JSON.stringify(event);
    } catch (_e) {
      // An event carrying a value that cannot be serialized (a host attribute
      // with a cycle or a BigInt) is dropped here, as the core writer drops it.
      return false;
    }
    // Views stay out of the byte budget, so only details pay for the measurement.
    const bytes: number = event['type'] === 'view' ? 0 : ENCODER.encodeInto(line).byteLength;
    if (!this.isOwnError(event)) {
      return buffer.hold(event, line, bytes, Date.now());
    }
    if (bytes > WITHHELD_BUFFER_BYTES_LIMIT) {
      // An error too large for the buffer goes out on its own rather than
      // evicting the history it explains. Only an error storage accepted earns
      // the release: a history uploaded for an error the backend will never
      // see is a session nobody can explain.
      if (!writer.write(event, true)) {
        return false;
      }
      this.hasError = true;
      this.scheduleRelease(buffer);
      return true;
    }
    this.hasError = true;
    this.scheduleRelease(buffer);
    return buffer.hold(event, line, bytes, Date.now());
  }

  private isOwnError(event: Record<string, Object>): boolean {
    if (event['type'] !== 'error') {
      return false;
    }
    const session: Object | undefined = event['session'];
    return typeof session === 'object' && session !== null
      && (session as Record<string, Object>)['id'] === this.sessionId;
  }

  private scheduleRelease(buffer: WithheldEventBuffer): void {
    if (this.releaseTimerId !== -1) {
      return;
    }
    buffer.freeze(Date.now());
    this.releaseTimerId = setTimeout(() => {
      this.releaseTimerId = -1;
      this.releaseNow();
    }, computeReleaseDelay(this.sessionId));
  }

  private releaseNow(): void {
    const buffer: WithheldEventBuffer | null = this.buffer;
    if (buffer === null) {
      return;
    }
    this.cancelTimer();
    this.buffer = null;
    this.delegate.withWriteContext((_context: FlashcatContext, writer: EventWriter) => {
      buffer.release(writer, Date.now(), this.sessionId);
    });
  }

  private cancelTimer(): void {
    if (this.releaseTimerId !== -1) {
      clearTimeout(this.releaseTimerId);
      this.releaseTimerId = -1;
    }
  }
}

/** Hands each write of a withholding session's scopes to the session's decision. */
class WithholdingWriter implements EventWriter {
  private readonly owner: WithholdingFeatureScope;
  private readonly writer: EventWriter;

  constructor(owner: WithholdingFeatureScope, writer: EventWriter) {
    this.owner = owner;
    this.writer = writer;
  }

  write(event: Record<string, Object>, forceFlush?: boolean): boolean {
    return this.owner.route(this.writer, event, forceFlush === true);
  }
}
