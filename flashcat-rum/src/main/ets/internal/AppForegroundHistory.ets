/**
 * The app's stays in the background as reported by the core, for telling
 * whether a measured time span crossed one.
 *
 * HarmonyOS freezes a backgrounded app's process within seconds. Timers and
 * network callbacks then do not run until the app is brought back, possibly
 * hours later, so a wall-clock delta that covers a stay in the background
 * measures the freeze rather than the work. The core reports each move to the
 * background (`app_background`) and each time the app is (again) in the
 * foreground (`app_foreground`, `app_foreground_detected`).
 *
 * Process-wide, like the app state it records.
 */
export class AppForegroundHistory {
  private static backgrounds: number = 0;
  private static background: boolean = false;

  /** The core reported a move to the background (`app_background`). */
  static enteredBackground(): void {
    AppForegroundHistory.backgrounds += 1;
    AppForegroundHistory.background = true;
  }

  /** The core reported the app in the foreground (`app_foreground`, `app_foreground_detected`). */
  static enteredForeground(): void {
    AppForegroundHistory.background = false;
  }

  /** Moves to the background so far; compare two readings to detect one in between. */
  static backgroundCount(): number {
    return AppForegroundHistory.backgrounds;
  }

  /** In the background and not yet reported back in the foreground. */
  static inBackground(): boolean {
    return AppForegroundHistory.background;
  }

  /** @internal SDK stop: what a later core reports starts from scratch. */
  static reset(): void {
    AppForegroundHistory.backgrounds = 0;
    AppForegroundHistory.background = false;
  }
}
