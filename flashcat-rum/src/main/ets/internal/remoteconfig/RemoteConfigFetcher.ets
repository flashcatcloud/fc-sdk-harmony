import { http } from '@kit.NetworkKit';
import { FlashcatContext, FlashcatLog } from '@flashcatcloud/core';

const CONFIG_PATH: string = '/api/v2/rum/config';
const TIMEOUT_MS: number = 10000;
const HEADER_IF_NONE_MATCH: string = 'If-None-Match';

/** One answer from the configuration endpoint. */
export interface RemoteConfigResponse {
  code: number;
  body: string;
  /** The validator to store beside the values and echo back next time. */
  etag: string | null;
}

/**
 * How the controller asks. A seam, not an abstraction for its own sake: it is
 * what lets the retry / staleness / parsing rules be tested without a network,
 * which is the half of this feature that must not be got wrong.
 */
export interface RemoteConfigFetcher {
  fetch(url: string, ifNoneMatch: string | null): Promise<RemoteConfigResponse>;
}

/** Real fetcher, on the same NetworkKit stack the intake uploads run on. */
export class HttpRemoteConfigFetcher implements RemoteConfigFetcher {
  private readonly userAgent: string;

  constructor(userAgent: string) {
    this.userAgent = userAgent;
  }

  async fetch(url: string, ifNoneMatch: string | null): Promise<RemoteConfigResponse> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = { 'User-Agent': this.userAgent };
      if (ifNoneMatch !== null) {
        header[HEADER_IF_NONE_MATCH] = ifNoneMatch;
      }
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS
      });
      const body: string = typeof response.result === 'string' ? response.result as string : '';
      FlashcatLog.d(`rum.remoteconfig: GET ${CONFIG_PATH} -> ${response.responseCode}`);
      return { code: response.responseCode as number, body: body, etag: HttpRemoteConfigFetcher.etagOf(response) };
    } finally {
      request.destroy();
    }
  }

  /** Header names are case-insensitive on the wire and the stack does not
   * normalise them, so both spellings are read before giving up. */
  private static etagOf(response: http.HttpResponse): string | null {
    const headers: Record<string, Object> = response.header as Record<string, Object>;
    if (headers === undefined || headers === null) {
      return null;
    }
    const value: Object | undefined = headers['etag'] ?? headers['ETag'];
    return typeof value === 'string' && (value as string).length > 0 ? value as string : null;
  }
}

/**
 * Where to ask. A custom endpoint means the app was pointed at the customer's
 * own host for the RUM intake, and the configuration lives beside it there —
 * exactly the layout the private-deployment nginx template serves.
 *
 * The SDK version rides along purely as information: it keys nothing on this
 * side (see the store key), and the server may one day target a configuration
 * at a range of them.
 */
export function buildConfigUrl(host: string, clientToken: string, context: FlashcatContext): string {
  const base: string = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
  let query: string = `?client_token=${encodeURIComponent(clientToken)}&sdk=harmony`;
  query += appendParam('env', context.env);
  query += appendParam('app_version', context.version);
  query += appendParam('sdk_version', context.sdkVersion);
  return `${base}${CONFIG_PATH}${query}`;
}

function appendParam(key: string, value: string): string {
  return value.length === 0 ? '' : `&${key}=${encodeURIComponent(value)}`;
}
