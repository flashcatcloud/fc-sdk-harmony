import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http } from '@kit.NetworkKit';
import { SdkCore, TrackingConsent } from '@flashcatcloud/core';
import { FlashcatTrace } from '../main/ets/FlashcatTrace';
import { FlashcatHttp } from '../main/ets/FlashcatHttp';
import { TraceConfiguration } from '../main/ets/TraceConfiguration';
import { TraceInterceptor } from '../main/ets/internal/TraceInterceptor';
import { TransferTiming, transferTimingOfHttp, transferTimingOfRcp } from '../main/ets/internal/TransferTiming';

/** A core whose RUM feature records what the trace module sends it. */
function recordingCore(sent: Array<Record<string, Object>>): SdkCore {
  const rum: Record<string, Object> = {
    sendEvent: (event: Record<string, Object>): void => {
      sent.push(event);
    }
  };
  return {
    isActive: (): boolean => true,
    getTrackingConsent: (): TrackingConsent => TrackingConsent.PENDING,
    getFeature: (name: string): Object | null => name === 'rum' ? rum : null,
    updateFeatureContext: (): void => {}
  } as Object as SdkCore;
}

function ofType(sent: Array<Record<string, Object>>, type: string): Record<string, Object> {
  return sent.filter((e: Record<string, Object>): boolean => e['type'] === type)[0];
}

/** As reported for a fresh https request on the emulator. */
function performanceTiming(): http.PerformanceTiming {
  return {
    dnsTiming: 1.476, tcpTiming: 1.939, tlsTiming: 520.172, firstSendTiming: 520.62,
    firstReceiveTiming: 1118.865, totalFinishTiming: 1120.23, redirectTiming: 0,
    responseHeaderTiming: 1120.432, responseBodyTiming: 1120.911, totalTiming: 1123.033
  } as http.PerformanceTiming;
}

function rcpContext(url: string): rcp.RequestContext {
  const request: Record<string, Object> = {
    'url': { toString: (): string => url } as Object,
    'method': 'GET',
    'headers': {} as Record<string, Object>
  };
  return { 'request': request } as Object as rcp.RequestContext;
}

async function throughInterceptor(sent: Array<Record<string, Object>>, url: string,
  response: rcp.Response): Promise<void> {
  const interceptor: TraceInterceptor =
    new TraceInterceptor(recordingCore(sent), new TraceConfiguration(100, ['example.com']));
  await interceptor.intercept(rcpContext(url), {
    handle: (_context: rcp.RequestContext): Promise<rcp.Response> => Promise.resolve(response)
  } as rcp.RequestHandler);
}

async function throughFlashcatHttp(sent: Array<Record<string, Object>>, url: string,
  response: Record<string, Object>): Promise<void> {
  const kit: Record<string, Object> = http as Object as Record<string, Object>;
  const realCreate: Object = kit['createHttp'];
  kit['createHttp'] = (): Object => {
    return { request: (): Promise<Object> => Promise.resolve(response), destroy: (): void => {} } as Object;
  };
  try {
    FlashcatTrace.enable(new TraceConfiguration(100, ['example.com']), recordingCore(sent));
    await FlashcatHttp.request(url, { method: http.RequestMethod.GET });
  } finally {
    kit['createHttp'] = realCreate;
    FlashcatTrace.enable(new TraceConfiguration(100), recordingCore([]));
  }
}

export default function traceResourceTimingTests(): void {
  describe('TraceResourceTiming', (): void => {
    it('performanceTimingMapsToLibcurlMarks', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const timing: TransferTiming = transferTimingOfHttp(performanceTiming()) as TransferTiming;
      expect(timing['namelookup']).assertEqual(1.476);
      expect(timing['connect']).assertEqual(1.939);
      expect(timing['appconnect']).assertEqual(520.172);
      expect(timing['pretransfer']).assertEqual(520.62);
      expect(timing['starttransfer']).assertEqual(1118.865);
      expect(timing['total']).assertEqual(1120.23);
      // No redirect: libcurl's 0 is a stage never reached, not a mark.
      expect(timing['redirect']).assertUndefined();
      expect(Object.keys(timing).length).assertEqual(6);
    });

    it('timeInfoMapsToLibcurlMarks', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // A request that reused its connection: connect and TLS are 0.
      const info: rcp.TimeInfo = {
        nameLookupTimeMs: 0.05, connectTimeMs: 0, tlsHandshakeTimeMs: 0, preTransferTimeMs: 0.261,
        startTransferTimeMs: 339.354, totalTimeMs: 339.458, redirectTimeMs: 0
      } as rcp.TimeInfo;
      const timing: TransferTiming = transferTimingOfRcp(info) as TransferTiming;
      expect(Object.keys(timing).sort().join(',')).assertEqual('namelookup,pretransfer,starttransfer,total');
      expect(timing['starttransfer']).assertEqual(339.354);
    });

    it('noTimingFromTheKitIsNoTiming', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      expect(transferTimingOfRcp(undefined)).assertUndefined();
      expect(transferTimingOfHttp(undefined)).assertUndefined();
      expect(transferTimingOfRcp({} as rcp.TimeInfo)).assertUndefined();
    });

    it('flashcatHttpReportsTheKitsTimingAndTheFirstPartyHost',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const sent: Array<Record<string, Object>> = [];
        await throughFlashcatHttp(sent, 'https://api.example.com/items', {
          'responseCode': 200, 'result': 'ok', 'header': {}, 'performanceTiming': performanceTiming()
        });
        expect(ofType(sent, 'network_request_started')['first_party_host'] as string).assertEqual('api.example.com');
        const timing: TransferTiming = ofType(sent, 'network_request_completed')['timing'] as TransferTiming;
        expect(timing['total']).assertEqual(1120.23);
      });

    it('aThirdPartyRequestCarriesNoFirstPartyHost',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const sent: Array<Record<string, Object>> = [];
        await throughFlashcatHttp(sent, 'https://cdn.other.net/a.png', { 'responseCode': 200, 'header': {} });
        const started: Record<string, Object> = ofType(sent, 'network_request_started');
        expect(Object.keys(started).indexOf('first_party_host')).assertEqual(-1);
        // A response without performanceTiming is still a resource, without timing.
        expect(Object.keys(ofType(sent, 'network_request_completed')).indexOf('timing')).assertEqual(-1);
      });

    it('theRcpInterceptorReportsTimeInfoWhenTheSessionCollectsIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const sent: Array<Record<string, Object>> = [];
        const info: rcp.TimeInfo = {
          nameLookupTimeMs: 0.406, connectTimeMs: 2.965, tlsHandshakeTimeMs: 519.983, preTransferTimeMs: 520.233,
          startTransferTimeMs: 844.949, totalTimeMs: 845.068, redirectTimeMs: 0
        } as rcp.TimeInfo;
        await throughInterceptor(sent, 'https://example.com/a',
          { 'statusCode': 200, 'headers': {}, 'timeInfo': info } as Object as rcp.Response);
        expect(ofType(sent, 'network_request_started')['first_party_host'] as string).assertEqual('example.com');
        const timing: TransferTiming = ofType(sent, 'network_request_completed')['timing'] as TransferTiming;
        expect(timing['appconnect']).assertEqual(519.983);
      });

    it('theRcpInterceptorReportsNoTimingWhenTheSessionDoesNotCollectIt',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const sent: Array<Record<string, Object>> = [];
        await throughInterceptor(sent, 'https://other.net/a',
          { 'statusCode': 200, 'headers': {} } as Object as rcp.Response);
        expect(Object.keys(ofType(sent, 'network_request_started')).indexOf('first_party_host')).assertEqual(-1);
        expect(Object.keys(ofType(sent, 'network_request_completed')).indexOf('timing')).assertEqual(-1);
      });

    it('aManualResourceIsClassifiedButUntimed', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const sent: Array<Record<string, Object>> = [];
      FlashcatTrace.enable(new TraceConfiguration(100, ['example.com']), recordingCore(sent));
      try {
        const key: string = FlashcatTrace.startTracedResource('https://api.example.com/a', 'GET').key;
        FlashcatTrace.stopTracedResource(key, 200, 10);
      } finally {
        FlashcatTrace.enable(new TraceConfiguration(100), recordingCore([]));
      }
      expect(ofType(sent, 'network_request_started')['first_party_host'] as string).assertEqual('api.example.com');
      expect(Object.keys(ofType(sent, 'network_request_completed')).indexOf('timing')).assertEqual(-1);
    });
  });
}
