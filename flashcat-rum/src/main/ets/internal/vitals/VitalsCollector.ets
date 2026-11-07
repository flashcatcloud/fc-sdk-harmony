import { ViewVitals } from './ViewVitals';

/**
 * Something that feeds the open views' vitals while the app is in the
 * foreground: the memory/CPU sampler and the frame observer. Views register
 * while they are open; the RUM feature drives the foreground and the stop.
 */
export interface VitalsCollector {
  register(view: ViewVitals): void;
  unregister(view: ViewVitals): void;
  setForeground(foreground: boolean): void;
  /** The configured frequency may have changed. */
  refreshPeriod(): void;
  /** SDK stop: for good. */
  stop(): void;
}

/** Every collector at once, so the scopes and the feature hold one. */
export class VitalsCollectors implements VitalsCollector {
  private readonly collectors: VitalsCollector[];

  constructor(collectors: VitalsCollector[]) {
    this.collectors = collectors;
  }

  register(view: ViewVitals): void {
    this.collectors.forEach((c: VitalsCollector) => c.register(view));
  }

  unregister(view: ViewVitals): void {
    this.collectors.forEach((c: VitalsCollector) => c.unregister(view));
  }

  setForeground(foreground: boolean): void {
    this.collectors.forEach((c: VitalsCollector) => c.setForeground(foreground));
  }

  refreshPeriod(): void {
    this.collectors.forEach((c: VitalsCollector) => c.refreshPeriod());
  }

  stop(): void {
    this.collectors.forEach((c: VitalsCollector) => c.stop());
  }
}
