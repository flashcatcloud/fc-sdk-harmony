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
 *   binary_images: Array<Record<string, Object>>, // native symbol metadata
 *   arch: string,            // normalized: arm64 / arm / x64 / x86, or ''
 *   build_id: string,        // first app native image build id, or ''
 *   source_type: 'harmony'
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
const SOURCE_TYPE: string = 'harmony';

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
    const crashType: string = CrashEventMapper.asString(params['crash_type']);

    // Stack: prefer an inline string (ArkTS/JS `Error.stack`); native (cppcrash)
    // faults carry no inline stack — the frames live in `exception.frames` as an
    // array of objects, which we serialize into the text form fc-rum's
    // stack.ParseHarmony understands.
    let stack: string = CrashEventMapper.asString(exception['stack']);
    if (stack.length === 0) {
      stack = CrashEventMapper.framesToStack(exception['frames']);
    }

    // Message: "Name: reason" when present (JS); native faults have neither, so fall
    // back to the crash type ("NativeCrash"/...) before the generic placeholder.
    let message: string = name.length > 0 ? `${name}: ${reason}` : reason;
    if (message.length === 0) {
      message = crashType.length > 0 ? crashType : 'Unknown crash';
    }

    const arch: string = CrashEventMapper.arch(params);
    const binaryImages: Array<Record<string, Object>> = CrashEventMapper.binaryImages(params, exception, arch);

    const event: Record<string, Object> = {
      'type': 'crash_report',
      'target': 'rum',
      'message': CrashEventMapper.truncate(message, MAX_MESSAGE_CHARS),
      'stack': CrashEventMapper.truncate(stack, MAX_STACK_CHARS),
      'source': RumErrorSource.SOURCE as string,
      'is_crash': true,
      'crash_kind': kind,
      'binary_images': binaryImages,
      'arch': arch,
      'build_id': CrashEventMapper.buildId(params, binaryImages),
      'source_type': SOURCE_TYPE
    };
    return event;
  }

  /**
   * Serializes a hiAppEvent `exception.frames` array into the text stack parsed by
   * fc-rum's stack.ParseHarmony: native frames as bionic
   * `#NN pc <hexaddr> <lib> (symbol+offset)` and ArkTS/JS frames as V8
   * `at func (file:line:col)`. A frame carrying a `pc` is native; one carrying a
   * `line` is an ArkTS source frame.
   */
  private static framesToStack(value: Object | undefined): string {
    if (!Array.isArray(value)) {
      return '';
    }
    const frames: Array<Object> = value as Array<Object>;
    const lines: string[] = [];
    for (let i = 0; i < frames.length; i++) {
      const line: string = CrashEventMapper.frameToLine(CrashEventMapper.asRecord(frames[i]), lines.length);
      if (line.length > 0) {
        lines.push(line);
      }
    }
    return lines.join('\n');
  }

  private static frameToLine(frame: Record<string, Object>, index: number): string {
    const pc: string = CrashEventMapper.asString(frame['pc']);
    const file: string = CrashEventMapper.asString(frame['file']);
    const symbol: string = CrashEventMapper.asString(frame['symbol']);
    if (pc.length > 0) {
      // Native frame: "#NN pc <hexaddr> <lib> (symbol+offset)".
      let out: string = `#${index} pc ${pc} ${file}`;
      if (symbol.length > 0) {
        const offset: string = CrashEventMapper.asString(frame['offset']);
        out += offset.length > 0 ? ` (${symbol}+${offset})` : ` (${symbol})`;
      }
      return out;
    }
    if (frame['line'] !== undefined && file.length > 0) {
      // ArkTS/JS source frame: "at func (file:line:col)".
      const lineNo: string = CrashEventMapper.asString(frame['line']);
      const column: string = CrashEventMapper.asString(frame['column']);
      const col: string = column.length > 0 ? column : '0';
      if (symbol.length > 0) {
        return `at ${symbol} (${file}:${lineNo}:${col})`;
      }
      return `at ${file}:${lineNo}:${col}`;
    }
    return '';
  }

  /** Truncates over-long text to keep the assembled crash event under intake limits. */
  private static truncate(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max) + TRUNCATION_SUFFIX;
  }

  private static binaryImages(
    params: Record<string, Object>,
    exception: Record<string, Object>,
    arch: string
  ): Array<Record<string, Object>> {
    // Prefer an explicit top-level binary_images array when present.
    const top: Object | undefined = params['binary_images'];
    if (Array.isArray(top)) {
      const images: Array<Record<string, Object>> = CrashEventMapper.normalizeImages(top as Array<Object>, arch);
      const json: string = JSON.stringify(images);
      // Drop rather than truncate: a truncated JSON array is unparseable downstream.
      return json.length <= MAX_BINARY_IMAGES_CHARS ? images : [];
    }
    // Otherwise synthesize from the native frames' build ids — one image per .so so
    // the symbolicator can match (build_id, arch, lib).
    const derived: Array<Record<string, Object>> =
      CrashEventMapper.imagesFromFrames(exception['frames'], arch);
    if (derived.length === 0) {
      return [];
    }
    const derivedJson: string = JSON.stringify(derived);
    return derivedJson.length <= MAX_BINARY_IMAGES_CHARS ? derived : [];
  }

  /** Builds one binary-image descriptor per distinct native (.so) library found in
   * the frame list, carrying its build id (as uuid), basename, system flag and arch. */
  private static imagesFromFrames(value: Object | undefined, arch: string): Array<Record<string, Object>> {
    const out: Array<Record<string, Object>> = [];
    if (!Array.isArray(value)) {
      return out;
    }
    const frames: Array<Object> = value as Array<Object>;
    const seen: string[] = [];
    for (let i = 0; i < frames.length; i++) {
      const frame: Record<string, Object> = CrashEventMapper.asRecord(frames[i]);
      const pc: string = CrashEventMapper.asString(frame['pc']);
      const file: string = CrashEventMapper.asString(frame['file']);
      const buildId: string = CrashEventMapper.asString(frame['buildId']);
      if (pc.length === 0 || file.length === 0 || buildId.length === 0) {
        continue; // not a native frame
      }
      const name: string = CrashEventMapper.libName(file);
      if (seen.indexOf(name) >= 0) {
        continue;
      }
      seen.push(name);
      const image: Record<string, Object> = {
        'uuid': buildId,
        'name': name,
        'is_system': CrashEventMapper.isSystemLibrary(file),
        'arch': arch
      };
      out.push(image);
    }
    return out;
  }

  private static normalizeImages(value: Array<Object>, fallbackArch: string): Array<Record<string, Object>> {
    const out: Array<Record<string, Object>> = [];
    for (let i = 0; i < value.length; i++) {
      const image: Record<string, Object> = CrashEventMapper.asRecord(value[i]);
      const uuid: string = CrashEventMapper.asString(image['uuid']);
      if (uuid.length === 0) {
        continue;
      }
      const normalized: Record<string, Object> = {};
      for (const key of Object.keys(image)) {
        normalized[key] = image[key];
      }
      const imageArch: string = CrashEventMapper.normalizeArch(CrashEventMapper.asString(image['arch']));
      normalized['arch'] = imageArch.length > 0 ? imageArch : fallbackArch;
      out.push(normalized);
    }
    return out;
  }

  private static buildId(params: Record<string, Object>, images: Array<Record<string, Object>>): string {
    const explicit: string = CrashEventMapper.asString(params['build_id']);
    if (explicit.length > 0) {
      return explicit;
    }
    for (let i = 0; i < images.length; i++) {
      const uuid: string = CrashEventMapper.asString(images[i]['uuid']);
      const isSystem: boolean = images[i]['is_system'] === true;
      if (uuid.length > 0 && !isSystem) {
        return uuid;
      }
    }
    return '';
  }

  private static arch(params: Record<string, Object>): string {
    let arch: string = CrashEventMapper.normalizeArch(CrashEventMapper.asString(params['cpu_abi']));
    if (arch.length === 0) {
      arch = CrashEventMapper.normalizeArch(CrashEventMapper.asString(params['arch']));
    }
    return arch;
  }

  private static normalizeArch(value: string): string {
    switch (value) {
      case 'arm64-v8a':
      case 'aarch64':
      case 'arm64':
        return 'arm64';
      case 'armeabi-v7a':
      case 'armeabi':
      case 'arm':
        return 'arm';
      case 'x86_64':
      case 'x64':
        return 'x64';
      case 'x86':
        return 'x86';
      default:
        return '';
    }
  }

  private static isSystemLibrary(file: string): boolean {
    return file.startsWith('/system/') || file.startsWith('/apex/') ||
      file.startsWith('/vendor/') || file.startsWith('/product/');
  }

  /** Basename of a library path ("/data/.../libentry.so" → "libentry.so"). */
  private static libName(file: string): string {
    const slash: number = file.lastIndexOf('/');
    return slash >= 0 ? file.substring(slash + 1) : file;
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
