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
}

class SystemWorkSchedulerClient implements DeferredUploadWorkSchedulerClient {
  startWork(work: workScheduler.WorkInfo): boolean {
    try {
      workScheduler.startWork(work);
      return true;
    } catch (e) {
      FlashcatLog.e(`work.register failed: ${e instanceof Error ? e.message : `${e}`}`);
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

  static workInfoFor(options: DeferredUploadWorkOptions): workScheduler.WorkInfo {
    return {
      workId: options.workId,
      bundleName: options.bundleName,
      abilityName: options.abilityName,
      isPersisted: true,
      networkType: options.uploadOnWifiOnly
        ? workScheduler.NetworkType.NETWORK_TYPE_WIFI
        : workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isCharging: options.requiresCharging
    };
  }
}
