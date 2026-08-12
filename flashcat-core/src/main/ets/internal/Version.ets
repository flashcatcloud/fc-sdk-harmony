/**
 * Single source of truth for the SDK version reported on every event
 * (`_dd.sdk_version`) and in the upload User-Agent / intake tags.
 *
 * Keep this in sync with the `version` field of each module's
 * `oh-package.json5` on every release bump.
 */
export const SDK_VERSION: string = '0.4.0';
