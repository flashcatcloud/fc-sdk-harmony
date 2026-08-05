/**
 * A network request that has been registered as a RUM resource and, when
 * allowed, given a trace context. Returned by
 * {@link FlashcatTrace.startTracedResource}.
 */
export class TracedResource {
  /**
   * Identifies this request until it is closed. Pass it to
   * `stopTracedResource` or `failTracedResource`.
   */
  readonly key: string;

  /**
   * Trace headers to add to the outgoing request — `traceparent` and
   * `tracestate`.
   *
   * Empty when no trace context was generated: tracking consent is not
   * GRANTED, the host is not first-party, or the caller asked not to inject.
   * The resource is still tracked in every case, so send the request either
   * way and just merge whatever is here.
   */
  readonly headers: Record<string, string>;

  constructor(key: string, headers: Record<string, string>) {
    this.key = key;
    this.headers = headers;
  }
}
