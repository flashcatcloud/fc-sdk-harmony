import { RumErrorSource } from './RumErrorSourceLite';

/**
 * Pure translation of a hiAppEvent system-event payload (the `params` object of an
 * `AppEventInfo`) into a loosely-typed bus message addressed to the RUM feature.
 *
 * This class touches no device APIs, so it is fully unit-testable. The thin
 * watcher that produces these `params` lives in {@link CrashFeature} and is
 * verified on device.
 *
 * Output bus-message contract (consumed by RumFeature.onReceive):
 * ```
 * {
 *   type: 'crash_report', target: 'rum',
 *   message: string, stack: string, source: 'source',
 *   is_crash: true, crash_kind: 'crash' | 'freeze',
 *   binary_images: string,   // JSON array string for native symbolication, or ''
 *   arch: string             // '' when unknown
 * }
 * ```
 */
// Payload caps. The RUM intake rejects bodies over nginx's default 1 MiB (see the
// Replay 413 incident), and an oversized crash event would also bloat on-disk
// batches, so the stack/message/binary-images are bounded defensively.
const MAX_MESSAGE_CHARS: number = 2000;
const MAX_STACK_CHARS: number = 50000;
const MAX_BINARY_IMAGES_CHARS: number = 100000;
const TRUNCATION_SUFFIX: string = '…[truncated]';

export class CrashEventMapper {
  static fromAppCrash(params: Record<string, Object>): Record<string, Object> {
    return CrashEventMapper.build(params, 'crash');
  }

  static fromAppFreeze(params: Record<string, Object>): Record<string, Object> {
    return CrashEventMapper.build(params, 'freeze');
  }

  private static build(params: Record<string, Object>, kind: string): Record<string, Object> {
    const exception: Record<string, Object> = CrashEventMapper.asRecord(params['exception']);
    const name: string = CrashEventMapper.asString(exception['name']);
    const reason: string = CrashEventMapper.asString(exception['message']);
    const stack: string = CrashEventMapper.asString(exception['stack']);
    let message: string = name.length > 0 ? `${name}: ${reason}` : reason;
    if (message.length === 0) {
      message = 'Unknown crash';
    }
    const event: Record<string, Object> = {
      'type': 'crash_report',
      'target': 'rum',
      'message': CrashEventMapper.truncate(message, MAX_MESSAGE_CHARS),
      'stack': CrashEventMapper.truncate(stack, MAX_STACK_CHARS),
      'source': RumErrorSource.SOURCE as string,
      'is_crash': true,
      'crash_kind': kind,
      'binary_images': CrashEventMapper.binaryImages(params),
      'arch': CrashEventMapper.asString(params['arch'])
    };
    return event;
  }

  /** Truncates over-long text to keep the assembled crash event under intake limits. */
  private static truncate(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max) + TRUNCATION_SUFFIX;
  }

  private static binaryImages(params: Record<string, Object>): string {
    const images: Object | undefined = params['binary_images'];
    if (Array.isArray(images)) {
      const json: string = JSON.stringify(images);
      // Drop rather than truncate: a truncated JSON array is unparseable downstream.
      return json.length <= MAX_BINARY_IMAGES_CHARS ? json : '';
    }
    return '';
  }

  private static asRecord(value: Object | undefined): Record<string, Object> {
    if (value !== undefined && typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return {};
  }

  private static asString(value: Object | undefined): string {
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return `${value}`;
    }
    return '';
  }
}
