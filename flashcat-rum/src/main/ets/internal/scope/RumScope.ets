/**
 * Internal raw event passed down the scope hierarchy. Scopes react to these and
 * emit assembled RUM events (view / error) to the writer.
 * Mirrors Android's RumRawEvent sealed hierarchy (phase-1 subset).
 */
export interface RumRawEvent {
  kind: string;                 // 'startView' | 'stopView' | 'addAction' | 'addError'
                                // | 'startResource' | 'stopResource' | 'stopResourceWithError'
                                // | 'keepAlive' | 'markCrash'
                                // markCrash: bump the active view's error+crash counts without
                                // writing an error event (the error itself is delivered by the
                                // durable pending-incident replay at next launch).
  key?: string;                 // view key, or resource key
  name?: string;
  attributes: Record<string, Object>;
  timestampMs: number;          // epoch ms

  // action specifics (kind === 'addAction')
  actionType?: string;          // RumActionType value, e.g. 'tap'
  actionId?: string;            // unique action id
  actionDurationNs?: number;    // 0 for instantaneous (addAction), measured for start/stop

  // error specifics (kind === 'addError' | 'stopResourceWithError')
  errorMessage?: string;
  errorSource?: string;
  errorStack?: string;
  errorHandling?: string;       // 'handled' | 'unhandled'
  isCrash?: boolean;
  // false ONLY for replayed crashes from a previous run: the error event keeps
  // is_crash for the error list, but the crash must not bump the CURRENT
  // view's crash count (it was already counted in the crashed run's view doc,
  // and it did not happen in this session).
  countInView?: boolean;

  // resource specifics (kind === 'startResource' | 'stopResource')
  url?: string;
  method?: string;              // 'GET' | 'POST' | ...
  statusCode?: number;
  sizeBytes?: number;
  resourceKind?: string;        // RumResourceKind value, e.g. 'native'
}

/**
 * A node in the App → Session → View hierarchy. Each scope handles an event,
 * possibly forwards it to children, and returns itself or null when it has
 * expired (so the parent can prune it).
 */
export interface RumScope {
  handleEvent(event: RumRawEvent): RumScope | null;
}
