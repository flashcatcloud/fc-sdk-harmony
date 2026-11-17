import { FlashcatLog } from '@flashcatcloud/core';

/** `vital.startup_type`. Cold and warm as on Android; hot is a return from the background. */
export enum StartupType {
  COLD = 'cold_start',
  WARM = 'warm_start',
  HOT = 'hot_start'
}

// Android's rule: a process whose first ability is created more than 10 s
// after the process started was not started for it — the launch is warm.
const COLD_START_MAX_PROCESS_AGE_MS: number = 10_000;
// Android's caps: a first frame more than 60 s after the launch's start is no
// time to initial display, a full display more than 90 s after it no time to
// full display.
export const MAX_INITIAL_DISPLAY_MS: number = 60_000;
export const MAX_FULL_DISPLAY_MS: number = 90_000;
// Android has no automatic page loading time; this SDK's waits at most as long
// as a full display may take.
export const MAX_VIEW_LOAD_MS: number = MAX_FULL_DISPLAY_MS;
const MS_TO_NS: number = 1e6;
const NOT_OBSERVED: string = 'rum.launch: first frame not observed';

/** Where measured launches and page loads go. */
export interface AppLaunchSink {
  /**
   * Time to initial display: from the launch's start to the first frame drawn
   * after it. `fullyDisplayed`: `reportAppFullyDisplayed` came before that
   * frame, so time to full display is the same value (Android parity).
   */
  initialDisplay: (type: StartupType, startMs: number, durationNs: number, atMs: number,
    fullyDisplayed: boolean) => void;
  /** Time to full display: from the launch's start to `reportAppFullyDisplayed`. */
  fullDisplay: (type: StartupType, startMs: number, durationNs: number, atMs: number) => void;
  /** The first frame drawn after the router showed the page `viewKey`. */
  viewLoaded: (viewKey: string, atMs: number) => void;
}

/**
 * Hooks the frames drawn for one context and returns how to unhook them, or
 * null when nothing could be hooked. `firstDrawFrame` is the system's answer
 * to "is this the window's first frame" where it gives one, null where the
 * frame source cannot tell.
 */
export type FrameHookFactory =
  (context: Object, onFrame: (firstDrawFrame: boolean | null) => void) => (() => void) | null;

class Launch {
  readonly type: StartupType;
  // Wall-clock start: the vital's date.
  readonly startMs: number;
  // Elapsed-clock start: what the launch's duration is measured from.
  readonly startElapsedMs: number;
  // Which launch this is: contexts handed over since it began carry the same number.
  readonly seq: number;
  // Its time to initial display has been measured.
  displayed: boolean = false;
  // Its time to initial display, once measured: no full display is shorter.
  initialDisplayMs: number = 0;
  // `reportAppFullyDisplayed` was called for it (before or after its first frame).
  fullyDisplayed: boolean = false;
  // A context was handed over after this launch began.
  hookedDuringLaunch: boolean = false;
  // A view started before any context of this launch was handed over: a frame
  // source that cannot name the first frame then cannot be trusted with it.
  viewBeforeHook: boolean = false;

  constructor(type: StartupType, startMs: number, startElapsedMs: number, seq: number) {
    this.type = type;
    this.startMs = startMs;
    this.startElapsedMs = startElapsedMs;
    this.seq = seq;
  }
}

/** One subscription to a context's frames; a callback from an older one is ignored. */
class Hook {
  unhook: () => void = (): void => {};
}

/** A context handed over by `startViewTracking`, hooked only while frames are awaited. */
class Watched {
  // The launch that was the latest when the context was handed over.
  readonly seq: number;
  hook: Hook | null = null;
  // Its frames cannot be hooked at all (API level, window gone): never retried.
  unsupported: boolean = false;

  constructor(seq: number) {
    this.seq = seq;
  }
}

/** Where the app is, as far as the tracker has been told. */
enum AppState {
  /** No foreground or background seen yet (the process is still starting). */
  UNKNOWN,
  FOREGROUND,
  /** Sent to the background and not back since. */
  BACKGROUND
}

class PendingViewLoad {
  readonly key: string;
  readonly sinceMs: number;

  constructor(key: string, sinceMs: number) {
    this.key = key;
    this.sinceMs = sinceMs;
  }
}

/**
 * Decides what kind of launch is happening and when it is over.
 *
 * - Cold / warm: the first ability created while none is alive, unless it
 *   opens in front of the user: the app was found already in the foreground,
 *   or showed something since it came there (an SDK that missed the abilities
 *   before it). The system announces the foreground just before it creates the
 *   launched ability, so a foreground with nothing shown yet is the launch's. The first one of the process
 *   is cold when the process is at most 10 s old, and starts when the process
 *   started; otherwise, and for any later one, it is warm and starts at the
 *   ability's creation. Its first frame is the first one of a window handed
 *   over after it began: windows handed over before belong to abilities that
 *   went away.
 * - Hot: the app comes back to the foreground with its process and abilities
 *   alive; it starts at that moment. Time to full display belongs to the last
 *   cold or warm launch, never to a hot one (as on Android, which has none).
 *
 * Every launch ends at the first frame drawn after it. Where that frame cannot
 * be observed — the SDK started after the ability, frames were hooked after
 * the first one, no frames are hooked at all, the app went back to the
 * background first, or 60 s passed — nothing is reported, and the reason is
 * logged. No other moment stands in for the frame.
 *
 * Frames are app-wide: a hot start and a shown page's load end at the next
 * frame of any watched window (only a cold or warm launch looks at which
 * window it was). Frames are hooked only while something waits for one — a launch's first
 * frame or a shown page's — and unhooked as soon as nothing does; a launch or
 * a page shown hooks them again.
 *
 * Durations are measured on an elapsed clock, which the user or the network
 * time cannot set: a wall clock set back mid-launch would otherwise report a
 * negative launch, and one set forward a launch over the cap. The wall clock
 * only dates the launch.
 *
 * Pure bookkeeping: the clocks, the process age and the frame hooks are
 * injected; nothing here calls the system.
 */
export class AppLaunchTracker {
  private readonly sink: AppLaunchSink;
  private readonly hookFrames: FrameHookFactory;
  private readonly processAgeMs: () => number | null;
  private readonly nowMs: () => number;
  private readonly elapsedMs: () => number;
  private readonly contexts: Map<Object, Watched> = new Map<Object, Watched>();
  // The launch waiting for (or ended by) its first frame.
  private launch: Launch | null = null;
  // The last cold or warm launch: the one `reportAppFullyDisplayed` completes.
  private abilityLaunch: Launch | null = null;
  private launchSeq: number = 0;
  private appState: AppState = AppState.UNKNOWN;
  private liveAbilities: number = 0;
  private abilitySeen: boolean = false;
  // An ability launch began since the app last went to the background: the
  // return to the foreground that goes with it is that launch, not a hot one.
  private launchedSinceBackground: boolean = false;
  // The app came to the foreground with no ability alive (a transition seen,
  // not found by the startup probe) and has shown nothing since: an ability
  // created now is the one the foreground was for. A foreground with abilities
  // alive is a return to them, never awaiting one.
  private foregroundAwaitsAbility: boolean = false;
  private pendingViewLoad: PendingViewLoad | null = null;
  private stopped: boolean = false;

  /** `nowMs`: the wall clock (epoch ms). `elapsedMs`: a clock that only moves forwards (ms since boot). */
  constructor(sink: AppLaunchSink, hookFrames: FrameHookFactory, processAgeMs: () => number | null,
    nowMs: () => number, elapsedMs: () => number) {
    this.sink = sink;
    this.hookFrames = hookFrames;
    this.processAgeMs = processAgeMs;
    this.nowMs = nowMs;
    this.elapsedMs = elapsedMs;
  }

  onAbilityCreated(): void {
    this.abilityCreated();
    this.reconcileHooks();
  }

  private abilityCreated(): void {
    this.liveAbilities += 1;
    if (this.stopped || this.liveAbilities !== 1) {
      return; // another ability is already on screen: not a launch
    }
    const nowMs: number = this.nowMs();
    const elapsedMs: number = this.elapsedMs();
    const first: boolean = !this.abilitySeen;
    this.abilitySeen = true;
    // In front of the user already: the SDK missed the ability that is showing.
    // Unless the foreground was announced for this ability, as the system does
    // for cold and warm launches (a hot start begun by that foreground becomes
    // this warm launch).
    const awaited: boolean = this.foregroundAwaitsAbility;
    this.foregroundAwaitsAbility = false;
    if (this.appState === AppState.FOREGROUND && !awaited) {
      FlashcatLog.d('rum.launch: ability created while the app is in the foreground; not a launch');
      return;
    }
    this.launchedSinceBackground = true;
    if (!first) {
      this.begin(StartupType.WARM, nowMs, elapsedMs);
      return;
    }
    const ageMs: number | null = this.processAgeMs();
    if (ageMs === null) {
      this.launch = null;
      FlashcatLog.d('rum.launch: process start time unavailable; this launch is not measured');
      return;
    }
    if (ageMs <= COLD_START_MAX_PROCESS_AGE_MS) {
      this.begin(StartupType.COLD, nowMs - ageMs, elapsedMs - ageMs);
    } else {
      this.begin(StartupType.WARM, nowMs, elapsedMs);
    }
  }

  onAbilityDestroyed(): void {
    this.liveAbilities = Math.max(0, this.liveAbilities - 1);
  }

  /** The app came back to the foreground (not the startup probe of a running app). */
  onForeground(): void {
    this.foregrounded();
    this.reconcileHooks();
  }

  private foregrounded(): void {
    const returning: boolean = this.appState === AppState.BACKGROUND;
    if (this.appState !== AppState.FOREGROUND) {
      this.foregroundAwaitsAbility = this.liveAbilities === 0;
    }
    this.appState = AppState.FOREGROUND;
    if (this.stopped || !returning || this.launchedSinceBackground) {
      return; // the launch's own first foreground, or an ability launch is measuring it
    }
    if (!this.hasFrameSource()) {
      this.launch = null;
      FlashcatLog.d(`${NOT_OBSERVED}: no frame hook; call FlashcatRum.startViewTracking`);
      return;
    }
    this.begin(StartupType.HOT, this.nowMs(), this.elapsedMs());
  }

  /** The SDK started in an app already in the foreground: no return, no launch.
   * A startup probe: once a real foreground or background was seen, it is older news. */
  onForegroundDetected(): void {
    if (this.appState === AppState.UNKNOWN) {
      this.appState = AppState.FOREGROUND;
    }
  }

  onBackground(): void {
    this.appState = AppState.BACKGROUND;
    this.launchedSinceBackground = false;
    this.foregroundAwaitsAbility = false;
    this.pendingViewLoad = null;
    if (this.launch !== null && !this.launch.displayed) {
      this.launch = null;
      FlashcatLog.d(`${NOT_OBSERVED}: the app went to the background first`);
    }
    this.reconcileHooks();
  }

  /** A view started (any view, manual or tracked). */
  onViewStarted(): void {
    this.foregroundAwaitsAbility = false;
    const launch: Launch | null = this.launch;
    if (launch !== null && !launch.displayed && !launch.hookedDuringLaunch) {
      launch.viewBeforeHook = true;
    }
  }

  /** Watch the frames drawn for `context` (hooked while one is awaited). Once per context. */
  attachContext(context: Object): void {
    if (this.stopped || this.contexts.has(context)) {
      return;
    }
    this.contexts.set(context, new Watched(this.launchSeq));
    if (this.launch !== null && !this.launch.displayed) {
      this.launch.hookedDuringLaunch = true;
    }
    if (!this.abilitySeen) {
      FlashcatLog.d(`${NOT_OBSERVED}: no ability creation was seen; initialize the SDK in AbilityStage.onCreate`);
    }
    this.reconcileHooks();
  }

  detachContext(context: Object): void {
    const watched: Watched | undefined = this.contexts.get(context);
    if (watched !== undefined) {
      this.contexts.delete(context);
      AppLaunchTracker.unhook(watched);
    }
  }

  /** Stop watching every context (`stopViewTracking()` without one); later ones are watched again. */
  detachAllContexts(): void {
    this.contexts.forEach((watched: Watched) => AppLaunchTracker.unhook(watched));
    this.contexts.clear();
  }

  /** The router showed the page `key`: its first frame is its loading time. */
  expectViewLoad(key: string): void {
    this.pendingViewLoad = new PendingViewLoad(key, this.nowMs());
    this.reconcileHooks();
  }

  /** The page `key` was hidden before it drew. */
  cancelViewLoad(key: string): void {
    if (this.pendingViewLoad !== null && this.pendingViewLoad.key === key) {
      this.pendingViewLoad = null;
    }
    this.reconcileHooks();
  }

  /**
   * `RumMonitor.reportAppFullyDisplayed`. As on Android: called before the
   * launch's first frame, it is remembered and reported with that frame, with
   * the time to initial display as its value.
   */
  onFullyDisplayed(): void {
    const launch: Launch | null = this.abilityLaunch;
    if (this.stopped || launch === null) {
      FlashcatLog.usage('reportAppFullyDisplayed ignored: called before an app launch was detected');
      return;
    }
    if (launch.fullyDisplayed) {
      return;
    }
    launch.fullyDisplayed = true;
    if (!launch.displayed) {
      FlashcatLog.usage('reportAppFullyDisplayed called before the first frame: it is reported with the time to initial display');
      return;
    }
    const durationMs: number = this.elapsedMs() - launch.startElapsedMs;
    if (!AppLaunchTracker.isDuration(durationMs)) {
      FlashcatLog.d('rum.launch: reportAppFullyDisplayed not measured: the elapsed clock ran backwards');
      return;
    }
    if (durationMs < launch.initialDisplayMs) {
      FlashcatLog.d('rum.launch: reportAppFullyDisplayed not measured: shorter than the time to initial display');
      return;
    }
    if (durationMs > MAX_FULL_DISPLAY_MS) {
      FlashcatLog.usage('reportAppFullyDisplayed ignored: more than 90 s after the launch started');
      return;
    }
    this.sink.fullDisplay(launch.type, launch.startMs, durationMs * MS_TO_NS, this.nowMs());
  }

  /** SDK stop: unhook every frame source; nothing is measured afterwards. */
  stop(): void {
    this.stopped = true;
    this.launch = null;
    this.abilityLaunch = null;
    this.pendingViewLoad = null;
    this.detachAllContexts();
  }

  /** Called from the system's frame callback: nothing may escape into it. */
  private onFrameContained(watched: Watched, hook: Hook, firstDrawFrame: boolean | null): void {
    try {
      if (watched.hook !== hook) {
        return; // queued by a subscription that has since been unhooked
      }
      this.onFrame(watched, firstDrawFrame);
      this.reconcileHooks();
    } catch (e) {
      FlashcatLog.e(`rum.launch: frame handling failed: ${e instanceof Error ? e.message : 'error'}`);
    }
  }

  private onFrame(watched: Watched, firstDrawFrame: boolean | null): void {
    if (this.stopped) {
      return;
    }
    const nowMs: number = this.nowMs();
    this.resolveViewLoad(nowMs);
    const launch: Launch | null = this.launch;
    if (launch === null || launch.displayed) {
      return;
    }
    const durationMs: number = this.elapsedMs() - launch.startElapsedMs;
    if (!AppLaunchTracker.isDuration(durationMs)) {
      this.launch = null;
      FlashcatLog.d(`${NOT_OBSERVED}: the elapsed clock ran backwards`);
      return;
    }
    if (durationMs > MAX_INITIAL_DISPLAY_MS) {
      this.launch = null;
      FlashcatLog.d(`${NOT_OBSERVED} within 60 s of the launch`);
      return;
    }
    // A return to the foreground has no "first frame" of its own: the next frame
    // drawn ends it. An ability launch ends at its window's first frame.
    if (launch.type !== StartupType.HOT) {
      if (watched.seq !== launch.seq) {
        return; // a window of an ability from before this launch
      }
      if (firstDrawFrame === false) {
        this.launch = null;
        FlashcatLog.d(`${NOT_OBSERVED}: frames were hooked after the window's first frame`);
        return;
      }
      if (firstDrawFrame === null && launch.viewBeforeHook) {
        this.launch = null;
        FlashcatLog.d(`${NOT_OBSERVED}: a view started before frames were hooked`);
        return;
      }
    }
    launch.displayed = true;
    launch.initialDisplayMs = durationMs;
    this.sink.initialDisplay(launch.type, launch.startMs, durationMs * MS_TO_NS, nowMs, launch.fullyDisplayed);
  }

  private resolveViewLoad(nowMs: number): void {
    const pending: PendingViewLoad | null = this.pendingViewLoad;
    if (pending === null) {
      return;
    }
    this.pendingViewLoad = null;
    if (nowMs - pending.sinceMs <= MAX_VIEW_LOAD_MS) {
      this.sink.viewLoaded(pending.key, nowMs);
    }
  }

  private begin(type: StartupType, startMs: number, startElapsedMs: number): void {
    this.launchSeq += 1;
    const launch: Launch = new Launch(type, startMs, startElapsedMs, this.launchSeq);
    this.launch = launch;
    if (type !== StartupType.HOT) {
      this.abilityLaunch = launch;
    }
  }

  private static isDuration(ms: number): boolean {
    return Number.isFinite(ms) && ms >= 0;
  }

  /** Something waits for a frame: a launch's first one, or a shown page's. */
  private awaitsFrame(): boolean {
    return !this.stopped
      && ((this.launch !== null && !this.launch.displayed) || this.pendingViewLoad !== null);
  }

  private hasFrameSource(): boolean {
    let any: boolean = false;
    this.contexts.forEach((watched: Watched) => {
      any = any || !watched.unsupported;
    });
    return any;
  }

  /** Hook every watched context while a frame is awaited; unhook them otherwise. */
  private reconcileHooks(): void {
    const awaits: boolean = this.awaitsFrame();
    this.contexts.forEach((watched: Watched, context: Object) => {
      if (!awaits) {
        AppLaunchTracker.unhook(watched);
      } else if (watched.hook === null && !watched.unsupported) {
        const hook: Hook = new Hook();
        const unhook: (() => void) | null = this.hookFrames(context,
          (firstDrawFrame: boolean | null): void => this.onFrameContained(watched, hook, firstDrawFrame));
        if (unhook === null) {
          watched.unsupported = true;
        } else {
          hook.unhook = unhook;
          watched.hook = hook;
        }
      }
    });
  }

  private static unhook(watched: Watched): void {
    const hook: Hook | null = watched.hook;
    if (hook === null) {
      return;
    }
    watched.hook = null;
    try {
      hook.unhook();
    } catch (_e) {
      // already gone with its window
    }
  }
}
