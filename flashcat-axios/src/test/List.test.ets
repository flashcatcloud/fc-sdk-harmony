import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { InternalAxiosRequestConfig } from '@ohos/axios';
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

    it('measuresTheDecodedResponseBody', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(sizeOf('hello')).assertEqual(5);
      expect(sizeOf(new ArrayBuffer(64))).assertEqual(64);
      expect(sizeOf(undefined)).assertEqual(0);
      // Objects are measured by their serialized length — axios hands back the
      // parsed body, so the bytes off the wire are no longer available.
      const body: Record<string, Object> = { 'a': 1 };
      expect(sizeOf(body)).assertEqual('{"a":1}'.length);
    });
  });
}
