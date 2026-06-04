import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * A W3C trace context. trace_id is 128-bit (32 hex), span_id 64-bit (16 hex).
 * Emits the `traceparent` header: `00-{trace_id}-{span_id}-{flags}`,
 * flags `01` = sampled, `00` = not sampled.
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

  private static randomHex(byteLength: number): string {
    const rand = cryptoFramework.createRandom();
    const blob = rand.generateRandomSync(byteLength); // { data: Uint8Array }
    const bytes: Uint8Array = blob.data;
    let hex: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      const b: number = bytes[i];
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
