const MS_TO_NS: number = 1e6;

/**
 * The phases of a resource in the RUM schema — `resource.dns`, `connect`,
 * `ssl`, `first_byte`, `download`, `redirect` — each `{ start, duration }` in
 * nanoseconds, `start` counted from the start of the request. Same meaning as
 * the browser and Android SDKs: `connect` runs until the connection is usable
 * and so contains `ssl`; `first_byte` is the wait from sending the request to
 * the first response byte; `download` is the rest of the response.
 *
 * Built from the network kit's transfer marks (see the trace module's
 * TransferTiming): libcurl times, in milliseconds from the start of the
 * request, at which each stage ENDED. A phase is the span between two marks:
 *
 *   dns        0             → namelookup
 *   connect    namelookup    → appconnect (TLS) or connect (plain http)
 *   ssl        connect       → appconnect
 *   first_byte pretransfer   → starttransfer
 *   download   starttransfer → total
 *
 * A request that reused a connection has no connect mark (libcurl reports 0),
 * and no dns phase either: its namelookup mark is only the few microseconds
 * libcurl took to find the open connection.
 *
 * After a redirect only `redirect` is reported, from the start of the request
 * to the start of the final one. libcurl then adds up each mark over all the
 * requests it made (each counted from that request's own start) — measured on
 * the emulator with a 100 ms redirect: pretransfer 0.13 ms, starttransfer
 * 254 ms, redirect 101.7 ms — so the marks no longer lie on one timeline and
 * the final request's phases cannot be told apart.
 *
 * A phase is left out rather than reported wrong when a mark it needs is
 * missing (TLS on plain http, a stage never reached), when it took no time, or
 * when it does not fit in the resource's own duration. The SDK times the
 * resource in whole milliseconds around the kit's call, so the duration is
 * never shorter than the kit's own measure by more than that one millisecond:
 * within it a phase is cut to the duration, past it the phase is dropped.
 *
 * @param timing the transfer marks, as received from the trace module
 * @param durationNs the resource's duration; a resource reported without one
 *        (it spanned a stay in the background) has no phases either
 */
export function resourcePhases(timing: Record<string, Object>, durationNs: number): Record<string, Object> {
  const phases: Record<string, Object> = {};
  const redirect: number | undefined = markNs(timing, 'redirect');
  if (redirect !== undefined) {
    addPhase(phases, 'redirect', 0, redirect, durationNs);
    return phases;
  }
  const namelookup: number | undefined = markNs(timing, 'namelookup');
  const connect: number | undefined = markNs(timing, 'connect');
  const appconnect: number | undefined = markNs(timing, 'appconnect');
  const pretransfer: number | undefined = markNs(timing, 'pretransfer');
  const starttransfer: number | undefined = markNs(timing, 'starttransfer');
  const total: number | undefined = markNs(timing, 'total');

  if (connect !== undefined) {
    addPhase(phases, 'dns', 0, namelookup, durationNs);
    addPhase(phases, 'connect', namelookup ?? 0, appconnect ?? connect, durationNs);
    addPhase(phases, 'ssl', connect, appconnect, durationNs);
  }
  addPhase(phases, 'first_byte', pretransfer, starttransfer, durationNs);
  addPhase(phases, 'download', starttransfer, total, durationNs);
  return phases;
}

function markNs(timing: Record<string, Object>, mark: string): number | undefined {
  const value: Object | undefined = timing[mark];
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value * MS_TO_NS : undefined;
}

function addPhase(phases: Record<string, Object>, name: string, startNs: number | undefined,
  endNs: number | undefined, durationNs: number): void {
  if (startNs === undefined || endNs === undefined || endNs > durationNs + MS_TO_NS) {
    return;
  }
  const start: number = Math.round(startNs);
  const end: number = Math.round(Math.min(endNs, durationNs));
  if (end <= start) {
    return;
  }
  const phase: Record<string, Object> = {};
  phase['start'] = start;
  phase['duration'] = end - start;
  phases[name] = phase;
}
