/**
 * Sink a feature writes serialized events into. The core implementation batches
 * writes to disk and hands batches to the upload scheduler. `T` is the feature's
 * event model (a `rum-events-format`-derived type for RUM).
 */
export interface DataWriter<T> {
  /** Serialize and persist one event. Returns false if it was dropped. */
  write(element: T): boolean;
}
