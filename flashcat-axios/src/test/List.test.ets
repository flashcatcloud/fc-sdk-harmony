import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { InternalAxiosRequestConfig, AxiosResponse } from '@ohos/axios';
import { fullUrlOf, sizeOf } from '../main/ets/AxiosTracking';

/** Minimal stand-in: only the two fields fullUrlOf reads. */
function configOf(url?: string, baseURL?: string): InternalAxiosRequestConfig {
  const config: Record<string, Object> = {};
  if (url !== undefined) {
    config['url'] = url;
  }
  if (baseURL !== undefined) {
    config['baseURL'] = baseURL;
  }
  return config as Object as InternalAxiosRequestConfig;
}

function responseOf(data: Object | undefined, headers?: Record<string, Object>): AxiosResponse {
  const response: Record<string, Object> = { 'status': 200, 'headers': headers ?? {} };
  if (data !== undefined) {
    response['data'] = data;
  }
  return response as Object as AxiosResponse;
}

export default function axiosIntegrationTests(): void {
  describe('flashcat-axios', (): void => {
    // A request interceptor sees the relative path; axios joins it with
    // baseURL inside the adapter. Forwarding the bare path leaves the
    // first-party check with no host to match, so nothing gets injected and
    // the resource is reported without a host.
    it('joinsBaseUrlWithTheRequestPath', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(fullUrlOf(configOf('/orders', 'https://api.example.com')))
        .assertEqual('https://api.example.com/orders');
      expect(fullUrlOf(configOf('orders', 'https://api.example.com')))
        .assertEqual('https://api.example.com/orders');
    });

    it('collapsesDuplicateSlashesAtTheJoin', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(fullUrlOf(configOf('/orders', 'https://api.example.com/')))
        .assertEqual('https://api.example.com/orders');
    });

    it('keepsAnAbsoluteRequestUrlAsIs', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(fullUrlOf(configOf('https://other.example.com/p', 'https://api.example.com')))
        .assertEqual('https://other.example.com/p');
      expect(fullUrlOf(configOf('http://other.example.com/p', 'https://api.example.com')))
        .assertEqual('http://other.example.com/p');
    });

    it('handlesEitherHalfBeingAbsent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(fullUrlOf(configOf('https://api.example.com/p'))).assertEqual('https://api.example.com/p');
      expect(fullUrlOf(configOf(undefined, 'https://api.example.com'))).assertEqual('https://api.example.com');
      expect(fullUrlOf(configOf())).assertEqual('');
    });

    it('measuresTheResponseWithoutReencodingIt', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // Content-Length wins: the bytes that came off the wire.
      expect(sizeOf(responseOf({ 'a': 1 }, { 'content-length': '1234' }))).assertEqual(1234);
      expect(sizeOf(responseOf('hello', { 'Content-Length': 7 }))).assertEqual(7);
      // Without it, cheap lengths only.
      expect(sizeOf(responseOf('hello'))).assertEqual(5);
      expect(sizeOf(responseOf(new ArrayBuffer(64)))).assertEqual(64);
      expect(sizeOf(responseOf(undefined))).assertEqual(0);
      // A parsed object is never serialized again just to measure it.
      let stringified: boolean = false;
      const body: Record<string, Object> = { 'toJSON': (): string => {
        stringified = true;
        return 'x';
      } };
      expect(sizeOf(responseOf(body))).assertEqual(0);
      expect(stringified).assertFalse();
    });
  });
}
