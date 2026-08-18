/**
 * Batching and upload-pacing vocabulary, shared with the Android, iOS, and
 * Flutter SDKs. The names and the behaviour behind each case are identical
 * across platforms, so tuning advice transfers verbatim.
 *
 * Each case's numeric value IS the quantity it stands for — the batch window in
 * milliseconds, the cycle interval in milliseconds, or a batch count — so the
 * upload layer consumes these directly with no lookup table in between.
 */

/**
 * How often an upload cycle starts. Mirrors `UploadFrequency` on Android/iOS.
 * Value is the interval in milliseconds.
 */
export enum UploadFrequency {
  /** Try to upload batch data frequently. */
  FREQUENT = 500,
  /** Try to upload batch data with a medium frequency. Default. */
  AVERAGE = 2000,
  /** Try to upload batch data rarely. */
  RARE = 5000
}

/**
 * How long the active batch stays open before it is rolled and becomes
 * drainable. Mirrors `BatchSize` on Android/iOS. Value is the window duration
 * in milliseconds.
 *
 * Larger windows pack more events into each request and compress better, so the
 * same events cost fewer bytes on the wire. The cost is latency: an event can
 * wait this long before it is eligible to ship.
 *
 * Cross-process note: a batch created by another process may only be claimed
 * once it is older than the LARGEST window here (plus slack), so the deferred
 * upload process stays safe even when the two processes were built with
 * different Configurations. See `FilePersistenceStrategy`.
 */
export enum BatchSize {
  /** Prefer small batches. */
  SMALL = 3000,
  /** Prefer medium sized batches. Default. */
  MEDIUM = 10000,
  /** Prefer large batches. */
  LARGE = 35000
}

/**
 * How many batches one upload cycle ships back-to-back before it yields for one
 * interval. Mirrors `BatchProcessingLevel` on Android/iOS. Value is the batch
 * count.
 *
 * Without a bound a backlog is drained in one uninterrupted burst, which starves
 * an app's own latency-sensitive requests on a narrow uplink. Choose LOW when the
 * app has such requests.
 */
export enum BatchProcessingLevel {
  /** Only 1 batch will be sent in a single upload cycle. */
  LOW = 1,
  /** 20 batches will be sent in a single upload cycle. Default. */
  MEDIUM = 20,
  /** 100 batches will be sent in a single upload cycle. */
  HIGH = 100
}
