/**
 * Trace-propagation configuration. Built via {@link TraceConfigurationBuilder}.
 */
export class TraceConfiguration {
  /** 0..100 — fraction of requests marked sampled in the traceparent flags. */
  readonly sampleRate: number;

  constructor(sampleRate: number) {
    this.sampleRate = sampleRate;
  }
}

export class TraceConfigurationBuilder {
  private sampleRate: number = 100;

  setSampleRate(rate: number): TraceConfigurationBuilder {
    this.sampleRate = rate;
    return this;
  }

  build(): TraceConfiguration {
    return new TraceConfiguration(this.sampleRate);
  }
}
