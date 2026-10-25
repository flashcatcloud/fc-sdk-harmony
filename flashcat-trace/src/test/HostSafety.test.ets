import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http } from '@kit.NetworkKit';
import { SdkCore } from '@flashcatcloud/core';
import { FlashcatTrace } from '../main/ets/FlashcatTrace';
import { FlashcatHttp } from '../main/ets/FlashcatHttp';
import { TraceConfiguration } from '../main/ets/TraceConfiguration';
import { TraceInterceptor } from '../main/ets/internal/TraceInterceptor';

function requestContext(): rcp.RequestContext {
  const request: Record<string, Object> = {
    'url': { toString: (): string => 'https://api.example.com/items' } as Object,
    'method': 'GET',
    'headers': {} as Record<string, Object>
  };
  return { 'request': request } as Object as rcp.RequestContext;
}

function handler(run: () => Promise<rcp.Response>): rcp.RequestHandler {
  return { handle: (_context: rcp.RequestContext): Promise<rcp.Response> => run() } as rcp.RequestHandler;
}

/** A core whose every call throws: telemetry fails at its first step. */
function brokenCore(): SdkCore {
  const fail = (): never => {
    throw new Error('sdk failure');
  };
  return { isActive: fail, getTrackingConsent: fail, getFeature: fail, updateFeatureContext: fail } as Object as SdkCore;
}

export default function traceHostSafetyTests(): void {
  describe('TraceHostSafety', (): void => {
    it('theHostsOwnRejectionPassesThroughUnchanged',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // rcp rejects with a BusinessError-like value carrying a code the host checks.
        const original: Record<string, Object> = { 'code': 1007900028, 'message': 'timeout' };
        const interceptor: TraceInterceptor = new TraceInterceptor(null, new TraceConfiguration(100));
        let caught: Object | undefined = undefined;
        try {
          await interceptor.intercept(requestContext(), handler(() => Promise.reject(original)));
        } catch (e) {
          caught = e as Object;
        }
        expect(caught === original).assertTrue();
      });

    it('aResponseTheSdkCannotMeasureStillReachesTheHost',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const response: rcp.Response = { 'statusCode': 200, 'body': null, 'headers': {} } as Object as rcp.Response;
        const interceptor: TraceInterceptor = new TraceInterceptor(null, new TraceConfiguration(100));
        const result: rcp.Response =
          await interceptor.intercept(requestContext(), handler(() => Promise.resolve(response)));
        expect(result === response).assertTrue();
      });

    it('aTelemetryFailureNeverStopsTheRequest',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const response: rcp.Response = { 'statusCode': 200, 'headers': {} } as Object as rcp.Response;
        const interceptor: TraceInterceptor = new TraceInterceptor(brokenCore(), new TraceConfiguration(100));
        let sent: boolean = false;
        const result: rcp.Response = await interceptor.intercept(requestContext(), handler(() => {
          sent = true;
          return Promise.resolve(response);
        }));
        expect(sent).assertTrue();
        expect(result === response).assertTrue();
      });

    it('flashcatHttpPassesTheRequestErrorThroughUnchanged',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        // @kit.NetworkKit rejects with a BusinessError-like value whose code the host checks.
        const original: Record<string, Object> = { 'code': 2300028, 'message': 'timeout' };
        const kit: Record<string, Object> = http as Object as Record<string, Object>;
        const realCreate: Object = kit['createHttp'];
        kit['createHttp'] = (): Object => {
          return {
            request: (): Promise<Object> => Promise.reject(original),
            destroy: (): void => {}
          } as Object;
        };
        const options: http.HttpRequestOptions = { method: http.RequestMethod.GET };
        let caught: Object | undefined = undefined;
        try {
          await FlashcatHttp.request('https://api.example.com/items', options);
        } catch (e) {
          caught = e as Object;
        } finally {
          kit['createHttp'] = realCreate;
        }
        expect(caught === original).assertTrue();
        expect(options.header === undefined).assertTrue();
      });

    it('enableBeforeInitializeIsANoOp',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let threw: boolean = false;
        try {
          FlashcatTrace.enable(new TraceConfiguration(100));
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
      });
  });
}
