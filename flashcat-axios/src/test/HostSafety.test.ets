import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { AxiosInstance, InternalAxiosRequestConfig, AxiosResponse, AxiosError } from '@ohos/axios';
import { trackAxios } from '../main/ets/AxiosTracking';

type RequestHook = (config: InternalAxiosRequestConfig) => InternalAxiosRequestConfig;
type ResponseHook = (response: AxiosResponse) => AxiosResponse;
type ErrorHook = (error: AxiosError) => Promise<AxiosResponse>;

/** Captures the interceptors trackAxios registers, so the test can drive them. */
class FakeInstance {
  requestHook: RequestHook | null = null;
  responseHook: ResponseHook | null = null;
  errorHook: ErrorHook | null = null;

  asInstance(): AxiosInstance {
    const self: FakeInstance = this;
    const interceptors: Record<string, Object> = {
      'request': { use: (hook: RequestHook): number => {
        self.requestHook = hook;
        return 0;
      } } as Object,
      'response': { use: (ok: ResponseHook, fail: ErrorHook): number => {
        self.responseHook = ok;
        self.errorHook = fail;
        return 0;
      } } as Object
    };
    return { 'interceptors': interceptors } as Object as AxiosInstance;
  }
}

/** A config whose headers object misbehaves: any telemetry step touching it throws. */
function hostileConfig(): InternalAxiosRequestConfig {
  const headers: Record<string, Object> = {
    'has': (): boolean => {
      throw new Error('headers broken');
    },
    'set': (): void => {
      throw new Error('headers broken');
    }
  };
  return { 'url': 'https://api.example.com/a', 'headers': headers } as Object as InternalAxiosRequestConfig;
}

export default function axiosHostSafetyTests(): void {
  describe('AxiosHostSafety', (): void => {
    it('trackingSomethingThatIsNotAnInstanceIsANoOp',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        let threw: boolean = false;
        try {
          trackAxios(null as Object as AxiosInstance);
          trackAxios({} as AxiosInstance);
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
      });

    it('aFailedRegistrationLeavesNoRequestInterceptorBehind',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        // A request interceptor without its response side opens resources
        // that nothing closes.
        let requestRegistered: boolean = false;
        const interceptors: Record<string, Object> = {
          'request': { use: (): number => {
            requestRegistered = true;
            return 0;
          } } as Object,
          'response': { use: (): number => {
            throw new Error('response side unavailable');
          } } as Object
        };
        trackAxios({ 'interceptors': interceptors } as Object as AxiosInstance);
        expect(requestRegistered).assertFalse();
      });

    it('theRequestConfigPassesThroughWhenTelemetryFails',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const fake: FakeInstance = new FakeInstance();
        trackAxios(fake.asInstance());
        const config: InternalAxiosRequestConfig = hostileConfig();
        let threw: boolean = false;
        let returned: InternalAxiosRequestConfig | null = null;
        try {
          returned = (fake.requestHook as RequestHook)(config);
        } catch (_e) {
          threw = true;
        }
        expect(threw).assertFalse();
        expect(returned === config).assertTrue();
      });

    it('theResponseAndTheRejectionPassThroughUnchanged',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, async (): Promise<void> => {
        const fake: FakeInstance = new FakeInstance();
        trackAxios(fake.asInstance());
        // An error whose config getter throws: telemetry fails, the rejection must not change.
        const error: Record<string, Object> = { 'message': 'boom' };
        Object.defineProperty(error, 'config', { get: (): Object => {
          throw new Error('config broken');
        } });
        let rejected: Object | undefined = undefined;
        try {
          await (fake.errorHook as ErrorHook)(error as Object as AxiosError);
        } catch (e) {
          rejected = e as Object;
        }
        expect(rejected === error).assertTrue();

        const response: Record<string, Object> = { 'status': 200, 'data': 'ok' };
        Object.defineProperty(response, 'config', { get: (): Object => {
          throw new Error('config broken');
        } });
        expect((fake.responseHook as ResponseHook)(response as Object as AxiosResponse) ===
          (response as Object as AxiosResponse)).assertTrue();
      });
  });
}
