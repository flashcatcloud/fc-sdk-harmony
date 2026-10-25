import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xF1A7; // "FlAt" — grep-friendly fixed domain
const TAG: string = 'Flashcat';

/**
 * Gated internal logger. The SDK is silent by default (production must not spam
 * HiLog, and the crash path must never throw). Turn it on with
 * `ConfigurationBuilder.setVerbose(true)` to trace init / event writes / upload
 * status / crash capture while debugging.
 *
 * View it: DevEco "Log" panel filtered by tag `Flashcat` (domain 0xF1A7), or
 * `hdc shell hilog | grep Flashcat`.
 */
export class FlashcatLog {
  private static enabled: boolean = false;

  static setEnabled(enabled: boolean): void {
    FlashcatLog.enabled = enabled;
  }

  static d(message: string): void {
    if (FlashcatLog.enabled) {
      hilog.info(DOMAIN, TAG, '%{public}s', message);
    }
  }

  static e(message: string): void {
    // Errors are logged only in verbose mode too — never surface SDK noise by default.
    if (FlashcatLog.enabled) {
      hilog.error(DOMAIN, TAG, '%{public}s', message);
    }
  }

  /**
   * Always logged, verbose or not: the host called the SDK in a way it cannot
   * honour (before initialize, after stop) or the SDK failed to start. Rare by
   * construction, and the only way an integrator learns the SDK is not running.
   */
  static usage(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
  }
}
