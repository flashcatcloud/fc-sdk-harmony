import { common } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';

const PREFERENCES_NAME: string = 'fc_spike_phase0';
const MODE_KEY: string = 'mode';
const LAUNCH_COUNTER_KEY: string = 'launch_counter';
const LAST_CRASH_TIMESTAMP_KEY: string = 'last_crash_timestamp';

export const SPIKE_RECOVERY_STORAGE_KEY: string = 'fcSpikeRecoveredPayload';
export const SPIKE_RECOVERY_MARKER_KEY: string = 'fc_spike_recovery_marker';
export const SPIKE_RECOVERY_TIMESTAMP_KEY: string = 'fc_spike_recovery_timestamp';

export enum SpikeMode {
  OFF = 'OFF',
  OBSERVE_ONLY = 'OBSERVE_ONLY',
  RECOVER = 'RECOVER'
}

export interface SpikeLaunchCounterUpdate {
  count: number;
  persistence: Promise<void>;
}

/** Synchronous reads plus explicitly flushed writes for the Phase 0 harness. */
export class SpikeModeStore {
  static readMode(context: common.Context): SpikeMode {
    const store: preferences.Preferences = SpikeModeStore.open(context);
    const value: preferences.ValueType = store.getSync(MODE_KEY, 'OFF');
    if (value === 'OBSERVE_ONLY') {
      return SpikeMode.OBSERVE_ONLY;
    }
    if (value === 'RECOVER') {
      return SpikeMode.RECOVER;
    }
    return SpikeMode.OFF;
  }

  static writeMode(context: common.Context, mode: SpikeMode): Promise<void> {
    const store: preferences.Preferences = SpikeModeStore.open(context);
    store.putSync(MODE_KEY, `${mode}`);
    return store.flush();
  }

  static incrementLaunchCounter(context: common.Context): SpikeLaunchCounterUpdate {
    const store: preferences.Preferences = SpikeModeStore.open(context);
    const stored: preferences.ValueType = store.getSync(LAUNCH_COUNTER_KEY, 0);
    const current: number = typeof stored === 'number' ? stored : 0;
    const next: number = current + 1;
    store.putSync(LAUNCH_COUNTER_KEY, next);
    const update: SpikeLaunchCounterUpdate = {
      count: next,
      persistence: store.flush()
    };
    return update;
  }

  static readLaunchCounter(context: common.Context): number {
    const store: preferences.Preferences = SpikeModeStore.open(context);
    const value: preferences.ValueType = store.getSync(LAUNCH_COUNTER_KEY, 0);
    return typeof value === 'number' ? value : 0;
  }

  static writeLastCrashTimestamp(context: common.Context, timestamp: number): Promise<void> {
    const store: preferences.Preferences = SpikeModeStore.open(context);
    store.putSync(LAST_CRASH_TIMESTAMP_KEY, timestamp);
    return store.flush();
  }

  static readLastCrashTimestamp(context: common.Context): number {
    const store: preferences.Preferences = SpikeModeStore.open(context);
    const value: preferences.ValueType = store.getSync(LAST_CRASH_TIMESTAMP_KEY, 0);
    return typeof value === 'number' ? value : 0;
  }

  private static open(context: common.Context): preferences.Preferences {
    const options: preferences.Options = { name: PREFERENCES_NAME };
    return preferences.getPreferencesSync(context, options);
  }
}
