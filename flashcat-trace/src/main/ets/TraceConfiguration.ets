/**
 * Trace-propagation configuration. Built via {@link TraceConfigurationBuilder}.
 */
export class TraceConfiguration {
  /** 0..100 — fraction of requests marked sampled in the traceparent flags. */
  readonly sampleRate: number;
  /**
   * Hosts to inject `traceparent` into via the FlashcatHttp auto-capture wrapper.
   * Empty → inject for ALL hosts (back-compat with the rcp interceptor). Non-empty
   * → only matching hosts get the header, so trace ids never leak to third parties.
   * A host matches if it equals an entry or is a subdomain of one.
   */
  readonly firstPartyHosts: string[];

  constructor(sampleRate: number, firstPartyHosts: string[] = []) {
    this.sampleRate = sampleRate;
    this.firstPartyHosts = firstPartyHosts;
  }

  /** Whether `host` is a configured first-party host (empty config = all hosts). */
  isFirstParty(host: string): boolean {
    if (this.firstPartyHosts.length === 0) {
      return true;
    }
    const h: string = host.toLowerCase();
    for (const entry of this.firstPartyHosts) {
      const e: string = entry.toLowerCase();
      if (h === e || h.endsWith(`.${e}`)) {
        return true;
      }
    }
    return false;
  }
}

export class TraceConfigurationBuilder {
  private sampleRate: number = 100;
  private firstPartyHosts: string[] = [];

  setSampleRate(rate: number): TraceConfigurationBuilder {
    this.sampleRate = rate;
    return this;
  }

  /** Restrict `traceparent` injection (FlashcatHttp) to these hosts + their subdomains. */
  setFirstPartyHosts(hosts: string[]): TraceConfigurationBuilder {
    this.firstPartyHosts = hosts;
    return this;
  }

  build(): TraceConfiguration {
    return new TraceConfiguration(this.sampleRate, this.firstPartyHosts);
  }
}
