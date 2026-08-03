import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * A W3C trace context. trace_id is 128-bit (32 hex), span_id 64-bit (16 hex).
 * Emits the `traceparent` header: `00-{trace_id}-{span_id}-{flags}`,
 * flags `01` = sampled, `00` = not sampled, plus the companion `tracestate`
 * header carrying the Datadog vendor entry `dd=s:{0|1};o:rum` (sampling
 * priority + RUM origin), matching the browser/native SDK convention so the
 * backend APM continues the same sampling decision and tags the trace's origin.
 */
export class TraceContext {
  readonly traceId: string;
  readonly spanId: string;
  readonly sampled: boolean;

  private constructor(traceId: string, spanId: string, sampled: boolean) {
    this.traceId = traceId;
    this.spanId = spanId;
    this.sampled = sampled;
  }

  static generate(sampleRate: number): TraceContext {
    const traceId: string = TraceContext.randomHex(16); // 16 bytes → 32 hex
    const spanId: string = TraceContext.randomHex(8);   // 8 bytes  → 16 hex
    const sampled: boolean = TraceContext.decideSampling(sampleRate);
    return new TraceContext(traceId, spanId, sampled);
  }

  traceparent(): string {
    const flags: string = this.sampled ? '01' : '00';
    return `00-${this.traceId}-${this.spanId}-${flags}`;
  }

  /**
   * The span id as an unsigned decimal string — the Datadog `_dd.span_id`
   * convention. The intake parses span ids base-10 (`strconv.ParseUint(…, 10, 64)`),
   * so sending the raw 16-hex form made the parse fail and left span_id empty on
   * essentially every resource, breaking RUM↔APM correlation. The hex form stays
   * in `traceparent` (W3C requires it).
   */
  spanIdDecimal(): string {
    return TraceContext.hexToUnsignedDecimalString(this.spanId);
  }

  /**
   * Converts a hex string to its unsigned decimal representation without BigInt
   * (64-bit values exceed Number's 53-bit integer precision). Returns '' for
   * non-hex input.
   */
  static hexToUnsignedDecimalString(hex: string): string {
    if (hex.length === 0) {
      return '';
    }
    // Little-endian array of decimal digits; repeatedly ×16 + nibble.
    const digits: number[] = [0];
    for (let i: number = 0; i < hex.length; i++) {
      const nibble: number = parseInt(hex.charAt(i), 16);
      if (Number.isNaN(nibble)) {
        return '';
      }
      let carry: number = nibble;
      for (let j: number = 0; j < digits.length; j++) {
        const value: number = digits[j] * 16 + carry;
        digits[j] = value % 10;
        carry = Math.floor(value / 10);
      }
      while (carry > 0) {
        digits.push(carry % 10);
        carry = Math.floor(carry / 10);
      }
    }
    let out: string = '';
    for (let i: number = digits.length - 1; i >= 0; i--) {
      out += `${digits[i]}`;
    }
    // Strip leading zeros but keep a single zero.
    let start: number = 0;
    while (start < out.length - 1 && out.charAt(start) === '0') {
      start += 1;
    }
    return out.substring(start);
  }

  /**
   * W3C `tracestate` value with the Datadog vendor entry: `dd=s:{0|1};o:rum`.
   * `s` = sampling priority (1 = keep, 0 = drop), `o` = origin (rum). When an
   * existing tracestate is present, preserve other vendors and replace only the
   * Datadog member, moving it to the front — W3C requires the most recently
   * mutated member to lead the list.
   */
  tracestate(existing: string = ''): string {
    const sampling: string = this.sampled ? '1' : '0';
    return TraceContext.mergeDatadogTracestate(existing, `dd=s:${sampling};o:rum`);
  }

  private static mergeDatadogTracestate(existing: string, datadogMember: string): string {
    const trimmed: string = existing.trim();
    if (trimmed.length === 0) {
      return datadogMember;
    }
    const members: string[] = trimmed.split(',').map((member: string): string => member.trim())
      .filter((member: string): boolean => member.length > 0);
    // Keep every non-`dd` vendor in its original order, drop any existing `dd`
    // member(s), then put our updated `dd` first.
    const others: string[] = members.filter((member: string): boolean => {
      const separator: number = member.indexOf('=');
      const key: string = separator >= 0 ? member.substring(0, separator).trim().toLowerCase() : '';
      return key !== 'dd';
    });
    others.unshift(datadogMember);
    return others.join(',');
  }

  private static randomHex(byteLength: number): string {
    try {
      const rand = cryptoFramework.createRandom();
      const blob = rand.generateRandomSync(byteLength); // { data: Uint8Array }
      return TraceContext.bytesToHex(blob.data);
    } catch (_e) {
      return TraceContext.fallbackRandomHex(byteLength);
    }
  }

  private static bytesToHex(bytes: Uint8Array): string {
    let hex: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      const b: number = bytes[i];
      hex += (b < 16 ? '0' : '') + b.toString(16);
    }
    return hex;
  }

  private static fallbackRandomHex(byteLength: number): string {
    let hex: string = '';
    for (let i: number = 0; i < byteLength; i++) {
      const b: number = Math.floor(Math.random() * 256);
      hex += (b < 16 ? '0' : '') + b.toString(16);
    }
    return hex;
  }

  private static decideSampling(sampleRate: number): boolean {
    if (sampleRate >= 100) {
      return true;
    }
    if (sampleRate <= 0) {
      return false;
    }
    return (Math.random() * 100) < sampleRate;
  }
}
