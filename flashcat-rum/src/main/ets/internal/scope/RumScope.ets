/** The view that holds what a session records before its first view. */
export const APPLICATION_LAUNCH_VIEW: string = 'ApplicationLaunch';

/**
 * Internal raw event passed down the scope hierarchy. Scopes react to these and
 * emit assembled RUM events (view / error) to the writer.
 * Mirrors Android's RumRawEvent sealed hierarchy (phase-1 subset).
 */
export interface RumRawEvent {
  kind: string;                 // 'startView' | 'stopView' | 'addAction' | 'addError'
                                // | 'startResource' | 'stopResource' | 'stopResourceWithError'
                                // | 'keepAlive' | 'markCrash'
                                // | 'openLaunchView'
                                // markCrash: bump the active view's error+crash counts without
                                // writing an error event (the error itself is delivered by the
                                // durable pending-incident replay at next launch).
                                // openLaunchView: a JS fault is about to be handled; a session
                                // that has never had a view opens the ApplicationLaunch view for it.
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
