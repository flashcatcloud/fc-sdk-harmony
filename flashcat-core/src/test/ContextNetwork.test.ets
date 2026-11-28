import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { ContextProvider } from '../main/ets/internal/context/ContextProvider';
import { NetworkInfo } from '../main/ets/api/context/FlashcatContext';

type Handler = (arg?: Object) => void;

/** Stands in for connection.createNetConnection: records the handlers, fires them on demand. */
class FakeNetConnection {
  handlers: Map<string, Handler> = new Map();
  unregistered: number = 0;

  fire(type: string, arg?: Object): void {
    const handler: Handler | undefined = this.handlers.get(type);
    if (handler !== undefined) {
      handler(arg);
    }
  }

  asConnection(): Object {
    return {
      'on': (type: string, handler: Handler): void => {
        this.handlers.set(type, handler);
      },
      'register': (): void => {},
      'unregister': (): void => {
        this.unregistered += 1;
      }
    } as Record<string, Object>;
  }
}

const kit: Record<string, Object> = connection as Object as Record<string, Object>;

/** Runs `body` with a ContextProvider whose network subscription goes to `fake`. */
function withProvider(fake: FakeNetConnection, capsOf: (net: Object) => Object,
  body: (provider: ContextProvider) => void): void {
  const realCreate: Object = kit['createNetConnection'];
  const realCaps: Object = kit['getNetCapabilitiesSync'];
  kit['createNetConnection'] = (): Object => fake.asConnection();
  kit['getNetCapabilitiesSync'] = capsOf;
  try {
    const context: common.Context = { 'filesDir': '/tmp/flashcat-context-network' } as Object as common.Context;
    body(new ContextProvider(context, new ConfigurationBuilder('token', 'prod').build(), false));
  } finally {
    kit['createNetConnection'] = realCreate;
    kit['getNetCapabilitiesSync'] = realCaps;
  }
}

function wifi(): Object {
  return { 'bearerTypes': [connection.NetBearType.BEARER_WIFI] } as Record<string, Object>;
}

export default function contextNetworkTests(): void {
  describe('ContextNetwork', (): void => {
    it('aNetworkComingBackIsConnectedWithoutWaitingForACapabilityChange',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const fake: FakeNetConnection = new FakeNetConnection();
        withProvider(fake, (_net: Object): Object => wifi(), (provider: ContextProvider): void => {
          fake.fire('netLost', { 'netId': 100 } as Record<string, Object>);
          // Negative control: after the loss, and before anything comes back, events say not_connected.
          expect(provider.snapshot().network.status).assertEqual('not_connected');

          fake.fire('netAvailable', { 'netId': 101 } as Record<string, Object>);
          const network: NetworkInfo = provider.snapshot().network;
          expect(network.status).assertEqual('connected');
          expect(network.interfaces.join(',')).assertEqual('wifi');
        });
      });

    it('aNetworkWhoseCapabilitiesCannotBeReadIsStillConnected',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const fake: FakeNetConnection = new FakeNetConnection();
        withProvider(fake, (_net: Object): Object => {
          throw new Error('permission denied');
        }, (provider: ContextProvider): void => {
          fake.fire('netLost', { 'netId': 100 } as Record<string, Object>);
          let threw: boolean = false;
          try {
            fake.fire('netAvailable', { 'netId': 101 } as Record<string, Object>);
          } catch (_e) {
            threw = true;
          }
          expect(threw).assertFalse();
          const network: NetworkInfo = provider.snapshot().network;
          expect(network.status).assertEqual('connected');
          expect(network.interfaces.length).assertEqual(0);
        });
      });

    it('stoppingUnregistersTheNetworkSubscription',
      TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
        const fake: FakeNetConnection = new FakeNetConnection();
        withProvider(fake, (_net: Object): Object => wifi(), (provider: ContextProvider): void => {
          expect(fake.handlers.has('netAvailable')).assertTrue();
          provider.stop();
          provider.stop();
          expect(fake.unregistered).assertEqual(1);
        });
      });
  });
}
