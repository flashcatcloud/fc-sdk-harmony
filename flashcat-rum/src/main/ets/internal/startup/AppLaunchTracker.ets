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
// Nothing measured here is believed past 90 s: a first frame or a fully
// displayed report that comes later is dropped (Android caps TTFD the same).
export const MAX_LAUNCH_DURATION_MS: number = 90_000;
const MS_TO_NS: number = 1e6;
const NOT_OBSERVED: string = 'rum.launch: first frame not observed';

/** Where measured launches go. */
export interface AppLaunchSink {
  /** Time to initial display: from the launch's start to the first frame drawn after it. */
  initialDisplay: (type: StartupType, startMs: number, durationNs: number, atMs: number) => void;
  /** Time to full display: from the launch's start to `reportAppFullyDisplayed`. */
  fullDisplay: (type: StartupType, startMs: number, durationNs: number, atMs: number) => void;
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
  readonly startMs: number;
  // Which launch this is: frame hooks attached since it began carry the same number.
  readonly seq: number;
  // Its time to initial display has been measured.
  displayed: boolean = false;
  fullyDisplayed: boolean = false;
  // A frame hook was attached after this launch began.
  hookedDuringLaunch: boolean = false;
  // A view started before any frame hook of this launch was attached: a frame
  // source that cannot name the first frame then cannot be trusted with it.
  viewBeforeHook: boolean = false;

  constructor(type: StartupType, startMs: number, seq: number) {
    this.type = type;
    this.startMs = startMs;
    this.seq = seq;
  }
}

class Hook {
  // The launch that was the latest when this hook was attached.
  readonly seq: number;
  unhook: () => void = (): void => {};

  constructor(seq: number) {
    this.seq = seq;
  }
}

/**
 * Decides what kind of launch is happening and when it is over.
 *
 * - Cold / warm: the first ability created while none is alive and the app is
 *   not in the foreground (an ability created in front of the user, by an SDK
 *   that missed the ones before it, is no launch). The first one of the process
 *   is cold when the process is at most 10 s old, and starts when the process
 *   started; otherwise, and for any later one, it is warm and starts at the
 *   ability's creation. Its first frame is the first one of a window hooked
 *   after it began: windows hooked before belong to abilities that went away.
 * - Hot: the app comes back to the foreground with its process and abilities
 *   alive; it starts at that moment. Time to full display belongs to the last
 *   cold or warm launch, never to a hot one (as on Android, which has none).
 *
 * Every launch ends at the first frame drawn after it. Where that frame cannot
 * be observed — the SDK started after the ability, frames were hooked after
 * the first one, no frames are hooked at all, the app went back to the
 * background first, or 90 s passed — nothing is reported, and the reason is
 * logged. No other moment stands in for the frame.
 *
 * Pure bookkeeping: the clock, the process age and the frame hooks are
 * injected; nothing here calls the system.
 */
export class AppLaunchTracker {
  private readonly sink: AppLaunchSink;
  private readonly hookFrames: FrameHookFactory;
  private readonly processAgeMs: () => number | null;
  private readonly nowMs: () => number;
  private readonly hooks: Map<Object, Hook> = new Map<Object, Hook>();
  // The launch waiting for (or ended by) its first frame.
  private launch: Launch | null = null;
  // The last cold or warm launch: the one `reportAppFullyDisplayed` completes.
  private abilityLaunch: Launch | null = null;
  private launchSeq: number = 0;
  private foreground: boolean = false;
  private liveAbilities: number = 0;
  private abilitySeen: boolean = false;
  // The app was sent to the background and has not come back since.
  private backgrounded: boolean = false;
  // An ability launch began since the app last went to the background: the
  // return to the foreground that goes with it is that launch, not a hot one.
  private launchedSinceBackground: boolean = false;
  private stopped: boolean = false;

  constructor(sink: AppLaunchSink, hookFrames: FrameHookFactory, processAgeMs: () => number | null,
    nowMs: () => number = (): number => Date.now()) {
    this.sink = sink;
    this.hookFrames = hookFrames;
    this.processAgeMs = processAgeMs;
    this.nowMs = nowMs;
  }

  onAbilityCreated(): void {
    this.liveAbilities += 1;
    if (this.stopped || this.liveAbilities !== 1) {
      return; // another ability is already on screen: not a launch
    }
    const nowMs: number = this.nowMs();
    const first: boolean = !this.abilitySeen;
    this.abilitySeen = true;
    // In front of the user already: the SDK missed the ability that is showing.
    // Unless this is the ability of a return to the foreground still waiting
    // for its frame — then that return is this ability's warm launch.
    const pendingHot: boolean =
      this.launch !== null && this.launch.type === StartupType.HOT && !this.launch.displayed;
    if (this.foreground && !pendingHot) {
      FlashcatLog.d('rum.launch: ability created while the app is in the foreground; not a launch');
      return;
    }
    this.launchedSinceBackground = true;
    if (!first) {
      this.begin(StartupType.WARM, nowMs);
      return;
    }
    const ageMs: number | null = this.processAgeMs();
    if (ageMs === null) {
      this.launch = null;
      FlashcatLog.d('rum.launch: process start time unavailable; this launch is not measured');
      return;
    }
    if (ageMs <= COLD_START_MAX_PROCESS_AGE_MS) {
      this.begin(StartupType.COLD, nowMs - ageMs);
    } else {
      this.begin(StartupType.WARM, nowMs);
    }
  }

  onAbilityDestroyed(): void {
    this.liveAbilities = Math.max(0, this.liveAbilities - 1);
  }

  /** The app came back to the foreground (not the startup probe of a running app). */
  onForeground(): void {
    const returning: boolean = this.backgrounded;
    this.backgrounded = false;
    this.foreground = true;
    if (this.stopped || !returning || this.launchedSinceBackground) {
      return; // the launch's own first foreground, or an ability launch is measuring it
    }
    if (this.hooks.size === 0) {
      this.launch = null;
      FlashcatLog.d(`${NOT_OBSERVED}: no frame hook; call FlashcatRum.startViewTracking`);
      return;
    }
    this.begin(StartupType.HOT, this.nowMs());
  }

  /** The SDK started in an app already in the foreground: no return, no launch. */
  onForegroundDetected(): void {
    this.foreground = true;
  }

  onBackground(): void {
    this.backgrounded = true;
    this.foreground = false;
    this.launchedSinceBackground = false;
    if (this.launch !== null && !this.launch.displayed) {
      this.launch = null;
      FlashcatLog.d(`${NOT_OBSERVED}: the app went to the background first`);
    }
  }

  /** A view started (any view, manual or tracked). */
  onViewStarted(): void {
    const launch: Launch | null = this.launch;
    if (launch !== null && !launch.displayed && !launch.hookedDuringLaunch) {
      launch.viewBeforeHook = true;
    }
  }

  /** Hook the frames drawn for `context`. Once per context. */
  attachContext(context: Object): void {
    if (this.stopped || this.hooks.has(context)) {
      return;
    }
    const hook: Hook = new Hook(this.launchSeq);
    const unhook: (() => void) | null = this.hookFrames(context,
      (firstDrawFrame: boolean | null): void => this.onFrameContained(hook, firstDrawFrame));
    if (unhook === null) {
      return;
    }
    hook.unhook = unhook;
    this.hooks.set(context, hook);
    if (this.launch !== null && !this.launch.displayed) {
      this.launch.hookedDuringLaunch = true;
    }
    if (!this.abilitySeen) {
      FlashcatLog.d(`${NOT_OBSERVED}: no ability creation was seen; initialize the SDK in AbilityStage.onCreate`);
    }
  }

  detachContext(context: Object): void {
    const hook: Hook | undefined = this.hooks.get(context);
    if (hook !== undefined) {
      this.hooks.delete(context);
      AppLaunchTracker.unhook(hook);
    }
  }

  /** `RumMonitor.reportAppFullyDisplayed`. */
  onFullyDisplayed(): void {
    const launch: Launch | null = this.abilityLaunch;
    if (this.stopped || launch === null) {
      FlashcatLog.usage('reportAppFullyDisplayed ignored: no cold or warm launch was seen');
      return;
    }
    if (!launch.displayed) {
      FlashcatLog.usage('reportAppFullyDisplayed ignored: the first frame of the launch was not measured (yet)');
      return;
    }
    if (launch.fullyDisplayed) {
      return;
    }
    const nowMs: number = this.nowMs();
    const elapsedMs: number = nowMs - launch.startMs;
    if (elapsedMs > MAX_LAUNCH_DURATION_MS) {
      FlashcatLog.usage('reportAppFullyDisplayed ignored: more than 90 s after the launch started');
      return;
    }
    launch.fullyDisplayed = true;
    this.sink.fullDisplay(launch.type, launch.startMs, elapsedMs * MS_TO_NS, nowMs);
  }

  /** SDK stop: unhook every frame source; nothing is measured afterwards. */
  stop(): void {
    this.stopped = true;
    this.launch = null;
    this.abilityLaunch = null;
    this.hooks.forEach((hook: Hook) => AppLaunchTracker.unhook(hook));
    this.hooks.clear();
  }

  /** Called from the system's frame callback: nothing may escape into it. */
  private onFrameContained(hook: Hook, firstDrawFrame: boolean | null): void {
    try {
      this.onFrame(hook, firstDrawFrame);
    } catch (e) {
      FlashcatLog.e(`rum.launch: frame handling failed: ${e instanceof Error ? e.message : 'error'}`);
    }
  }

  private onFrame(hook: Hook, firstDrawFrame: boolean | null): void {
    if (this.stopped) {
      return;
    }
    const nowMs: number = this.nowMs();
    const launch: Launch | null = this.launch;
    if (launch === null || launch.displayed) {
      return;
    }
    if (nowMs - launch.startMs > MAX_LAUNCH_DURATION_MS) {
      this.launch = null;
      FlashcatLog.d(`${NOT_OBSERVED} within 90 s of the launch`);
      return;
    }
    // A return to the foreground has no "first frame" of its own: the next frame
    // drawn ends it. An ability launch ends at its window's first frame.
    if (launch.type !== StartupType.HOT) {
      if (hook.seq !== launch.seq) {
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
    this.sink.initialDisplay(launch.type, launch.startMs, (nowMs - launch.startMs) * MS_TO_NS, nowMs);
  }

  private begin(type: StartupType, startMs: number): void {
    this.launchSeq += 1;
    const launch: Launch = new Launch(type, startMs, this.launchSeq);
    this.launch = launch;
    if (type !== StartupType.HOT) {
      this.abilityLaunch = launch;
    }
  }

  private static unhook(hook: Hook): void {
    try {
      hook.unhook();
    } catch (_e) {
      // already gone with its window
    }
  }
}
