/**
 * Internal raw event passed down the scope hierarchy. Scopes react to these and
 * emit assembled RUM events (view / error) to the writer.
 * Mirrors Android's RumRawEvent sealed hierarchy (phase-1 subset).
 */
export interface RumRawEvent {
  kind: string;                 // 'startView' | 'stopView' | 'addAction' | 'addError'
  key?: string;
  name?: string;
  attributes: Record<string, Object>;
  timestampMs: number;          // epoch ms

  // error specifics (kind === 'addError')
  errorMessage?: string;
  errorSource?: string;
  errorStack?: string;
  errorHandling?: string;       // 'handled' | 'unhandled'
  isCrash?: boolean;
}

/**
 * A node in the App → Session → View hierarchy. Each scope handles an event,
 * possibly forwards it to children, and returns itself or null when it has
 * expired (so the parent can prune it).
 */
export interface RumScope {
  handleEvent(event: RumRawEvent): RumScope | null;
}
