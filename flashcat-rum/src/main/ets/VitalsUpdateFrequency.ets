/**
 * How often RUM samples the app's memory and CPU while the app is in the
 * foreground. Same values, and the same meaning, as `VitalsUpdateFrequency` in
 * the Android SDK — a value never means a different period on a different
 * device.
 */
export enum VitalsUpdateFrequency {
  /** Every 100 ms. */
  FREQUENT = 'frequent',
  /** Every 500 ms. */
  AVERAGE = 'average',
  /** Every 1000 ms. */
  RARE = 'rare',
  /** No memory or CPU is sampled, and views carry none of those fields. */
  NEVER = 'never'
}

/** What a configuration built without `setVitalsUpdateFrequency` uses. */
export const DEFAULT_VITALS_UPDATE_FREQUENCY: VitalsUpdateFrequency = VitalsUpdateFrequency.AVERAGE;

/** The sampling period, in milliseconds; 0 means do not sample. */
export function vitalsPeriodMs(frequency: VitalsUpdateFrequency): number {
  switch (frequency) {
    case VitalsUpdateFrequency.FREQUENT:
      return 100;
    case VitalsUpdateFrequency.AVERAGE:
      return 500;
    case VitalsUpdateFrequency.RARE:
      return 1000;
    default:
      return 0;
  }
}

/** The frequency a string names, or null for anything else (absent, mistyped, another type). */
export function parseVitalsUpdateFrequency(value: Object | undefined | null): VitalsUpdateFrequency | null {
  switch (value) {
    case VitalsUpdateFrequency.FREQUENT:
      return VitalsUpdateFrequency.FREQUENT;
    case VitalsUpdateFrequency.AVERAGE:
      return VitalsUpdateFrequency.AVERAGE;
    case VitalsUpdateFrequency.RARE:
      return VitalsUpdateFrequency.RARE;
    case VitalsUpdateFrequency.NEVER:
      return VitalsUpdateFrequency.NEVER;
    default:
      return null;
  }
}
