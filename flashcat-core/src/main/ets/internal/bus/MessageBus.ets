import { FeatureEventReceiver } from '../../api/feature/Feature';

/**
 * Inter-feature message bus. Features publish loosely-typed messages and others
 * subscribe by target feature name — the same decoupling pattern as Android's
 * FeatureEventReceiver bus (e.g. Crash -> RUM error event, RUM view -> Logs/Trace).
 */
export class MessageBus {
  private readonly receivers: Map<string, FeatureEventReceiver> = new Map<string, FeatureEventReceiver>();

  setReceiver(featureName: string, receiver: FeatureEventReceiver): void {
    this.receivers.set(featureName, receiver);
  }

  removeReceiver(featureName: string): void {
    this.receivers.delete(featureName);
  }

  /** Deliver an event to the receiver registered for `targetFeatureName`. */
  send(targetFeatureName: string, event: Record<string, Object>): void {
    const receiver: FeatureEventReceiver | undefined = this.receivers.get(targetFeatureName);
    if (receiver !== undefined) {
      receiver.onReceive(event);
    }
    // TODO: optional broadcast channel for events not addressed to a single feature.
  }
}
