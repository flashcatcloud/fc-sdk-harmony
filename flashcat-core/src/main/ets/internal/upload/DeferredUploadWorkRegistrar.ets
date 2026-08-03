import { workScheduler } from '@kit.BackgroundTasksKit';
import { FlashcatLog } from '../FlashcatLog';

export interface DeferredUploadWorkOptions {
  workId: number;
  bundleName: string;
  abilityName: string;
  uploadOnWifiOnly: boolean;
  requiresCharging: boolean;
}

export interface DeferredUploadWorkSchedulerClient {
  startWork(work: workScheduler.WorkInfo): boolean;
  stopWork(work: workScheduler.WorkInfo): boolean;
}

// startWork throws 9700005 when the same persisted workId already exists (it
// does not upsert). For our purposes that IS a successful registration.
const WORK_ALREADY_EXISTS_MESSAGE: string = '9700005';
// Recurring delivery cadence. The system enforces a >= 2 h minimum for
// repeating deferred work; without isRepeat the persisted job fires exactly
// once per registration and background delivery silently degrades to
// once-per-app-launch.
const REPEAT_CYCLE_MS: number = 2 * 60 * 60 * 1000;

class SystemWorkSchedulerClient implements DeferredUploadWorkSchedulerClient {
  startWork(work: workScheduler.WorkInfo): boolean {
    try {
      workScheduler.startWork(work);
      return true;
    } catch (e) {
      const message: string = e instanceof Error ? e.message : `${e}`;
      if (message.includes(WORK_ALREADY_EXISTS_MESSAGE)) {
        return true; // already registered by an earlier launch — same outcome
      }
      FlashcatLog.e(`work.register failed: ${message}`);
      return false;
    }
  }

  stopWork(work: workScheduler.WorkInfo): boolean {
    try {
      workScheduler.stopWork(work, true); // needCancel: remove the persisted job
      return true;
    } catch (e) {
      FlashcatLog.e(`work.deregister failed: ${e instanceof Error ? e.message : `${e}`}`);
      return false;
    }
  }
}

export class DeferredUploadWorkRegistrar {
  private readonly client: DeferredUploadWorkSchedulerClient;
  private registered: boolean = false;

  constructor(client?: DeferredUploadWorkSchedulerClient) {
    this.client = client ?? new SystemWorkSchedulerClient();
  }

  register(options: DeferredUploadWorkOptions): void {
    if (this.registered || options.abilityName.length === 0 || options.bundleName.length === 0) {
      return;
    }
    try {
      if (!this.client.startWork(DeferredUploadWorkRegistrar.workInfoFor(options))) {
        return;
      }
      this.registered = true;
      FlashcatLog.d(`work.register: id=${options.workId} ability=${options.abilityName}`);
    } catch (e) {
      FlashcatLog.e(`work.register failed: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  /**
   * Cancel the persisted deferred-upload job. The job survives reboots and app
   * upgrades (`isPersisted: true`), so SDK stop and consent revocation MUST
   * remove it — otherwise the system keeps waking the extension to upload
   * after the user said no.
   *
   * Deliberately UNCONDITIONAL: the job may have been persisted by an EARLIER
   * launch (this process never called register), or register may have thrown
   * while the previous launch's job is still armed — an in-process
   * `registered` guard would make cross-launch cancellation a silent no-op.
   * stopWork on a non-existent job just logs and is harmless.
   */
  deregister(options: DeferredUploadWorkOptions): void {
    if (options.abilityName.length === 0 || options.bundleName.length === 0) {
      return;
    }
    try {
      this.client.stopWork(DeferredUploadWorkRegistrar.workInfoFor(options));
    } catch (e) {
      FlashcatLog.e(`work.deregister failed: ${e instanceof Error ? e.message : `${e}`}`);
    }
    this.registered = false; // allow re-register when consent is granted again
  }

  static workInfoFor(options: DeferredUploadWorkOptions): workScheduler.WorkInfo {
    return {
      workId: options.workId,
      bundleName: options.bundleName,
      abilityName: options.abilityName,
      isPersisted: true,
      isRepeat: true,
      repeatCycleTime: REPEAT_CYCLE_MS,
      networkType: options.uploadOnWifiOnly
        ? workScheduler.NetworkType.NETWORK_TYPE_WIFI
        : workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isCharging: options.requiresCharging
    };
  }
}
