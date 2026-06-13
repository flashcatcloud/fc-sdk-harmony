import { FeatureEventReceiver } from '../../api/feature/Feature';
import { FlashcatLog } from '../FlashcatLog';

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
      FlashcatLog.d(`bus: send target=${targetFeatureName} type=${MessageBus.eventType(event)}`);
      receiver.onReceive(event);
    } else {
      FlashcatLog.d(`bus: drop target=${targetFeatureName} type=${MessageBus.eventType(event)} no receiver`);
    }
    // TODO: optional broadcast channel for events not addressed to a single feature.
  }

  private static eventType(event: Record<string, Object>): string {
    const type: Object | undefined = event['type'];
    return typeof type === 'string' ? type : '?';
  }
}
