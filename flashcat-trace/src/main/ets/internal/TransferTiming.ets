import { http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';

/**
 * The network kit's timing of one request, as it travels to the RUM feature on
 * `network_request_completed`. Every mark is in milliseconds, counted from the
 * start of the request: each one is the time at which a stage ENDED, not how
 * long the stage took. A mark the request never reached (TLS on plain http) is
 * absent.
 *
 * Both kits run the request on libcurl and hand its transfer times through
 * unchanged, so the marks carry libcurl's own names and meaning:
 *
 * | mark          | @ohos.net.http `performanceTiming` | rcp `timeInfo`        |
 * |---------------|------------------------------------|-----------------------|
 * | namelookup    | dnsTiming                          | nameLookupTimeMs      |
 * | connect       | tcpTiming                          | connectTimeMs         |
 * | appconnect    | tlsTiming                          | tlsHandshakeTimeMs    |
 * | pretransfer   | firstSendTiming                    | preTransferTimeMs     |
 * | starttransfer | firstReceiveTiming                 | startTransferTimeMs   |
 * | total         | totalFinishTiming                  | totalTimeMs           |
 * | redirect      | redirectTiming                     | redirectTimeMs        |
 *
 * The kit documentation says so for both ("time taken from startup to DNS
 * resolution completion", "from the start until the remote host name was
 * resolved", ...), and requests on the emulator agree: for an https request
 * through @ohos.net.http, every value equals, to the microsecond, the
 * `namelookup_time` / `connect_time` / `appconnect_time` / `pretransfer_time` /
 * `starttransfer_time` / `total_time` netstack logs for it (e.g. dns 1.476,
 * tcp 1.939, tls 520.172, first send 520.62, first receive 1118.865, total
 * 1120.23); through both kits the values grow through the request, and against
 * a server that waits 150 ms before answering and 120 ms before finishing the
 * body, starttransfer − pretransfer and total − starttransfer come out at those
 * two waits, give or take a few ms. A request that reuses a connection reports
 * 0 for connect and appconnect.
 *
 * After a redirect libcurl sums each mark over all the requests it made, each
 * counted from that request's own start, so the marks are no longer points on
 * one timeline; only `redirect` (start of the request to start of the final
 * one) and `total` still are. The RUM feature accounts for that.
 *
 * `responseHeaderTiming`, `responseBodyTiming` and `totalTiming` of
 * `performanceTiming` are measured by the kit itself around its own parsing
 * and callback, not by libcurl, and are not used.
 */
export type TransferTiming = Record<string, number>;

/** @ohos.net.http: `response.performanceTiming`, present on every response. */
export function transferTimingOfHttp(timing: http.PerformanceTiming | undefined): TransferTiming | undefined {
  if (timing === undefined || timing === null) {
    return undefined;
  }
  return marks(timing.dnsTiming, timing.tcpTiming, timing.tlsTiming, timing.firstSendTiming,
    timing.firstReceiveTiming, timing.totalFinishTiming, timing.redirectTiming);
}

/**
 * rcp: `response.timeInfo`, present only when the host's session collects it
 * (`requestConfiguration.tracing.collectTimeInfo`, off by
 * default). The session is the host's, so the SDK reports the timing when it is
 * there and leaves the request untimed otherwise.
 */
export function transferTimingOfRcp(timing: rcp.TimeInfo | undefined): TransferTiming | undefined {
  if (timing === undefined || timing === null) {
    return undefined;
  }
  return marks(timing.nameLookupTimeMs, timing.connectTimeMs, timing.tlsHandshakeTimeMs,
    timing.preTransferTimeMs, timing.startTransferTimeMs, timing.totalTimeMs, timing.redirectTimeMs);
}

function marks(namelookup: number, connect: number, appconnect: number, pretransfer: number,
  starttransfer: number, total: number, redirect: number): TransferTiming | undefined {
  const timing: TransferTiming = {};
  put(timing, 'namelookup', namelookup);
  put(timing, 'connect', connect);
  put(timing, 'appconnect', appconnect);
  put(timing, 'pretransfer', pretransfer);
  put(timing, 'starttransfer', starttransfer);
  put(timing, 'total', total);
  put(timing, 'redirect', redirect);
  return Object.keys(timing).length > 0 ? timing : undefined;
}

/** libcurl reports a stage the request never reached as 0. */
function put(timing: TransferTiming, mark: string, value: number): void {
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
    timing[mark] = value;
  }
}
