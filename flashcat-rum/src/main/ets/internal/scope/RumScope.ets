/**
 * Internal raw event passed down the scope hierarchy. Scopes react to these and
 * emit assembled RUM events (view / error) to the writer.
 * Mirrors Android's RumRawEvent sealed hierarchy (phase-1 subset).
 */
export interface RumRawEvent {
  kind: string;                 // 'startView' | 'stopView' | 'addAction' | 'addError'
                                // | 'startResource' | 'stopResource' | 'stopResourceWithError'
                                // | 'keepAlive' | 'markCrash' | 'appLaunch' | 'addViewLoadingTime'
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
  // An error of a process that already died, replayed into whichever session is
  // current because nothing identifies the one it happened in.
  inherited?: boolean;

  // app launch vital (kind === 'appLaunch'); timestampMs is when it was measured
  launchMetric?: string;        // 'ttid' | 'ttfd'
  startupType?: string;         // StartupType value
  launchStartMs?: number;       // epoch ms the launch started: the vital's date
  launchDurationNs?: number;
  launchFullyDisplayed?: boolean; // ttid: also report it as the ttfd (fully displayed first)

  // view loading time (kind === 'addViewLoadingTime'); timestampMs is when the view loaded
  overwrite?: boolean;          // manual: replace a value an earlier manual call set
  loadingTimeAuto?: boolean;    // measured by the SDK for the router page `key`

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
