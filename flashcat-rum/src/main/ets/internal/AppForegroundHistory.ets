/**
 * What the process has seen of the app's foreground state, for telling whether
 * a measured time span crossed a stay in the background.
 *
 * HarmonyOS freezes a backgrounded app's process within seconds. Timers and
 * network callbacks then do not run until the app is brought back, possibly
 * hours later, so a wall-clock delta that covers such a stay measures the
 * freeze rather than the work. The core reports each return to the foreground
 * (`app_foreground`) and the initial detection of an app already in the
 * foreground (`app_foreground_detected`); this keeps the count of returns.
 *
 * The first foreground entry of a launch is not a return: a request started
 * while the app was still launching (before its first window reached the
 * foreground) never ran in a frozen process.
 *
 * Process-wide, like the app state it records.
 */
export class AppForegroundHistory {
  private static seenInForeground: boolean = false;
  private static returns: number = 0;

  /** The core reported an entry into the foreground (`app_foreground`). */
  static enteredForeground(): void {
    if (AppForegroundHistory.seenInForeground) {
      AppForegroundHistory.returns += 1;
    }
    AppForegroundHistory.seenInForeground = true;
  }

  /** The app was found already in the foreground; no transition took place. */
  static foundInForeground(): void {
    AppForegroundHistory.seenInForeground = true;
  }

  /** Returns from the background seen so far; compare two readings to detect one in between. */
  static returnCount(): number {
    return AppForegroundHistory.returns;
  }

  /**
   * Whether the app has been in the foreground. Before that, "not in the
   * foreground" means the app is still launching, not that it was sent away.
   */
  static hasBeenInForeground(): boolean {
    return AppForegroundHistory.seenInForeground;
  }

  /** @internal tests only: forget what was seen. */
  static reset(): void {
    AppForegroundHistory.seenInForeground = false;
    AppForegroundHistory.returns = 0;
  }
}
