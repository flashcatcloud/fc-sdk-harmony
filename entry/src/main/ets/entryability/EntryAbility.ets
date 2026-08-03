import { AbilityConstant, errorManager, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import appRecovery from '@ohos.app.ability.appRecovery';
import {
  SPIKE_RECOVERY_MARKER_KEY,
  SPIKE_RECOVERY_STORAGE_KEY,
  SPIKE_RECOVERY_TIMESTAMP_KEY,
  SpikeLaunchCounterUpdate,
  SpikeMode,
  SpikeModeStore
} from '../common/SpikeMode';

const DOMAIN: number = 0x0000;
const TAG: string = 'FlashcatDemo';
const SPIKE_TAG: string = 'FCSpike';
const SPIKE_PAGE_MARKER: string = 'pages/Index';

/**
 * Demo entry ability. Loads the single Index page where the SDK is initialized
 * (via the "Initialize SDK" button) so the environment can be chosen at runtime.
 *
 * In a production app you would instead initialize the SDK in
 * `AbilityStage.onCreate` so network / lifecycle auto-instrumentation is in place
 * before any app code runs.
 */
export default class EntryAbility extends UIAbility {
  private spikeMode: SpikeMode = SpikeMode.OFF;
  private recoveryStarted: boolean = false;
  private spikeObserverId: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    AppStorage.setOrCreate<string>(SPIKE_RECOVERY_STORAGE_KEY, '');

    try {
      this.spikeMode = SpikeModeStore.readMode(this.context);
      const launchUpdate: SpikeLaunchCounterUpdate =
        SpikeModeStore.incrementLaunchCounter(this.context);
      const lastCrashTimestamp: number = SpikeModeStore.readLastCrashTimestamp(this.context);
      hilog.info(DOMAIN, SPIKE_TAG,
        'onCreate mode=%{public}s launch=%{public}d lastCrash=%{public}s reason=%{public}d',
        this.spikeMode, launchUpdate.count, `${lastCrashTimestamp}`, launchParam.launchReason);
      launchUpdate.persistence.then((): void => {
        hilog.info(DOMAIN, SPIKE_TAG, 'launch counter persisted=%{public}d', launchUpdate.count);
      }).catch((error: Object): void => {
        hilog.error(DOMAIN, SPIKE_TAG, 'launch counter persistence failed: %{public}s',
          EntryAbility.errorText(error));
      });
    } catch (error) {
      this.spikeMode = SpikeMode.OFF;
      hilog.error(DOMAIN, SPIKE_TAG, 'preferences read failed; using OFF: %{public}s',
        EntryAbility.errorText(error));
    }

    this.captureRecoveryPayload(want, launchParam, 'onCreate');

    if (this.spikeMode === SpikeMode.RECOVER) {
      try {
        appRecovery.enableAppRecovery(
          appRecovery.RestartFlag.RESTART_WHEN_JS_CRASH,
          appRecovery.SaveOccasionFlag.SAVE_WHEN_ERROR,
          appRecovery.SaveModeFlag.SAVE_WITH_FILE
        );
        hilog.info(DOMAIN, SPIKE_TAG, 'app recovery enabled');
      } catch (error) {
        hilog.error(DOMAIN, SPIKE_TAG, 'enableAppRecovery failed: %{public}s',
          EntryAbility.errorText(error));
      }
    }

    if (this.spikeMode !== SpikeMode.OFF) {
      this.registerSpikeObserver();
    } else {
      hilog.info(DOMAIN, SPIKE_TAG, 'spike observer not registered (OFF)');
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, SPIKE_TAG, 'onNewWant reason=%{public}d', launchParam.launchReason);
    this.captureRecoveryPayload(want, launchParam, 'onNewWant');
  }

  onSaveState(reason: AbilityConstant.StateType,
    wantParam: Record<string, Object>): AbilityConstant.OnSaveResult {
    const timestamp: number = Date.now();
    wantParam[SPIKE_RECOVERY_MARKER_KEY] = SPIKE_PAGE_MARKER;
    wantParam[SPIKE_RECOVERY_TIMESTAMP_KEY] = timestamp;
    hilog.info(DOMAIN, SPIKE_TAG,
      'onSaveState reason=%{public}d marker=%{public}s timestamp=%{public}s',
      reason, SPIKE_PAGE_MARKER, `${timestamp}`);
    return AbilityConstant.OnSaveResult.ALL_AGREE;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onDestroy(): void {
    // Unregister per-ability state: re-created ability instances would stack
    // one observer per create/destroy cycle within the process otherwise.
    if (this.spikeObserverId !== -1) {
      try {
        errorManager.off('error', this.spikeObserverId, (_err) => {
        });
      } catch (_e) {
        // already removed
      }
      this.spikeObserverId = -1;
    }
  }

  private registerSpikeObserver(): void {
    const observer: errorManager.ErrorObserver = {
      onUnhandledException: (errMsg: string): void => {
        this.handleSpikeException('onUnhandledException', 'UnhandledException', errMsg, errMsg);
      },
      onException: (errObject: Error): void => {
        const stack: string = typeof errObject.stack === 'string' ? errObject.stack : '(no stack)';
        this.handleSpikeException('onException', errObject.name, errObject.message, stack);
      }
    };
    try {
      const observerId: number = errorManager.on('error', observer);
      this.spikeObserverId = observerId;
      hilog.info(DOMAIN, SPIKE_TAG, 'observer registered id=%{public}d mode=%{public}s',
        observerId, this.spikeMode);
    } catch (error) {
      hilog.error(DOMAIN, SPIKE_TAG, 'observer registration failed: %{public}s',
        EntryAbility.errorText(error));
    }
  }

  private handleSpikeException(callback: string, name: string, message: string, stack: string): void {
    const timestamp: number = Date.now();
    hilog.error(DOMAIN, SPIKE_TAG, 'callback=%{public}s mode=%{public}s', callback, this.spikeMode);
    hilog.error(DOMAIN, SPIKE_TAG, 'exception name=%{public}s', name);
    hilog.error(DOMAIN, SPIKE_TAG, 'exception message=%{public}s', message);
    hilog.error(DOMAIN, SPIKE_TAG, 'exception stack=%{public}s', stack);
    hilog.error(DOMAIN, SPIKE_TAG, 'last crash timestamp=%{public}s', `${timestamp}`);

    // Persist the crash record best-effort. putSync updates the in-memory cache
    // immediately; flush() persistence is fire-and-forget because recovery must
    // NOT depend on a microtask running after this callback returns — whether
    // the runtime keeps running after the callback is exactly what this spike
    // measures (Q1), so restartApp() has to be invoked synchronously here.
    try {
      const persistence: Promise<void> =
        SpikeModeStore.writeLastCrashTimestamp(this.context, timestamp);
      persistence.then((): void => {
        hilog.info(DOMAIN, SPIKE_TAG, 'last crash timestamp persisted');
      }).catch((error: Object): void => {
        hilog.error(DOMAIN, SPIKE_TAG, 'last crash persistence failed: %{public}s',
          EntryAbility.errorText(error));
      });
    } catch (error) {
      hilog.error(DOMAIN, SPIKE_TAG, 'last crash write failed: %{public}s',
        EntryAbility.errorText(error));
    }

    if (this.spikeMode === SpikeMode.RECOVER) {
      this.recoverNow();
    } else {
      hilog.info(DOMAIN, SPIKE_TAG,
        'OBSERVE_ONLY: callback returns without exit or restart by design');
    }
  }

  private recoverNow(): void {
    if (this.recoveryStarted) {
      hilog.info(DOMAIN, SPIKE_TAG, 'recovery already started; duplicate callback ignored');
      return;
    }
    this.recoveryStarted = true;
    try {
      const saved: boolean = appRecovery.saveAppState();
      hilog.info(DOMAIN, SPIKE_TAG, 'saveAppState result=%{public}s', `${saved}`);
    } catch (error) {
      hilog.error(DOMAIN, SPIKE_TAG, 'saveAppState failed: %{public}s',
        EntryAbility.errorText(error));
    }
    try {
      hilog.info(DOMAIN, SPIKE_TAG, 'calling restartApp');
      appRecovery.restartApp();
    } catch (error) {
      hilog.error(DOMAIN, SPIKE_TAG, 'restartApp failed: %{public}s',
        EntryAbility.errorText(error));
    }
  }

  private captureRecoveryPayload(want: Want, launchParam: AbilityConstant.LaunchParam,
    lifecycle: string): void {
    let marker: string = '';
    let timestamp: number = 0;
    if (want.parameters !== undefined) {
      const markerValue: Object | undefined = want.parameters[SPIKE_RECOVERY_MARKER_KEY];
      const timestampValue: Object | undefined = want.parameters[SPIKE_RECOVERY_TIMESTAMP_KEY];
      marker = typeof markerValue === 'string' ? markerValue : '';
      timestamp = typeof timestampValue === 'number' ? timestampValue : 0;
    }
    const recoveryReason: boolean =
      launchParam.launchReason === AbilityConstant.LaunchReason.APP_RECOVERY;
    if (!recoveryReason && marker.length === 0) {
      hilog.info(DOMAIN, SPIKE_TAG, '%{public}s is not a recovery launch', lifecycle);
      return;
    }
    const payload: string =
      `marker=${marker.length > 0 ? marker : '(missing)'}; savedAt=${timestamp}; ` +
      `launchReason=${recoveryReason ? 'APP_RECOVERY' : launchParam.launchReason}`;
    AppStorage.setOrCreate<string>(SPIKE_RECOVERY_STORAGE_KEY, payload);
    hilog.info(DOMAIN, SPIKE_TAG, '%{public}s recovered payload=%{public}s', lifecycle, payload);
  }

  private static errorText(value: Object): string {
    return value instanceof Error ? value.message : `${value}`;
  }
}
