import { RumErrorSource } from './RumErrorSourceLite';
import { CrashFingerprint, CrashIncidentRecord } from './CrashIncident';
import { JsCrashPolicy } from '../CrashConfiguration';

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
 *   error_type: string,       // exception name, signal name or freeze name
 *   is_crash: boolean,       // false only for a jank: the process lives on
 *   crash_kind: 'crash' | 'freeze' | 'jank',
 *   'freeze.dump_started_at'?: string, // freeze only: watchdog dump wall-clock time
 *   'jank.duration_ms'?: number, 'jank.sampled_at'?: number, // jank only
 *   'freeze.reason'?: string, // freeze only: the system's own text for the freeze
 *   binary_images: Array<Record<string, Object>>, // native symbol metadata
 *   arch: string,            // normalized: arm64 / arm / x64 / x86, or ''
 *   build_id: string,        // first app native image build id, or ''
 *   source_type: 'harmony',
 *   threads?: Array<{ name, crashed, state?, stack }>, // every thread of the dump
 *   memory?: { rss_kb?, sys_free_kb?, sys_avail_kb?, sys_total_kb? } // at the fault
 * }
 * ```
 */
// Payload caps. The RUM intake rejects bodies over nginx's default 1 MiB (see the
// Replay 413 incident), and an oversized crash event would also bloat on-disk
// batches, so the stack/message/binary-images are bounded defensively.
const MAX_MESSAGE_CHARS: number = 2000;
const MAX_STACK_CHARS: number = 50000;
const MAX_BINARY_IMAGES_CHARS: number = 100000;
// Threads are budgeted in UTF-8 bytes: the event store drops any event line over
// 512 KiB outright, so non-ASCII names or symbols must not push the crash past it.
const MAX_THREADS_BYTES: number = 200000;
const TRUNCATION_SUFFIX: string = '…[truncated]';
const SOURCE_TYPE: string = 'harmony';
// hiAppEvent `params.memory` keys (KB) → the names reported to RUM.
const MEMORY_FIELDS: string[][] = [
  ['rss', 'rss_kb'],
  ['sys_free_mem', 'sys_free_kb'],
  ['sys_avail_mem', 'sys_avail_kb'],
  ['sys_total_mem', 'sys_total_kb']
];
// Separates an APP_FREEZE message from the watchdog dump's wall-clock time.
const FREEZE_DUMP_TIME_MARKER: string = 'Main handler dump start time:';
// A jank's message is a constant: where it happened is in the stack, and how long
// it lasted in `jank.duration_ms`, so every occurrence shares one message.
const JANK_MESSAGE: string = 'Main thread jank';
// One sampled frame: "#NN pc <hexaddr> <rest>", and an ArkTS frame "#NN at <fn> (<file>:<line>:<col>)".
const SAMPLED_NATIVE_FRAME: RegExp = /^#\d+\s+pc\s+([0-9a-fA-F]+)\s+(.+)$/;
// Matched in two steps, each linear: a single pattern with an optional "<fn> (" ahead
// of the location backtracks quadratically over a long line that is no frame.
const SAMPLED_ARKTS_FRAME: RegExp = /^#\d+\s+at\s+(.*)$/;
const ARKTS_LOCATION: RegExp = /^([^()\s]+):(\d+):(\d+)$/;
// A native frame's trailing "(<build id>)".
const SAMPLED_BUILD_ID: RegExp = /\(([0-9a-fA-F]{16,})\)$/;
const SYMBOL_OFFSET: RegExp = /^(.*)\+(\d+)$/;
// One node of the sampled call tree in a jank's external log: indentation, sample count, frame.
const SAMPLE_TREE_LINE: RegExp = /^( *)(\d+)\s+(#\d+\s+.*)$/;

export class CrashEventMapper {
  static fromAppCrash(params: Record<string, Object>): Record<string, Object> {
    return CrashEventMapper.build(params, 'crash');
  }

  /**
   * APP_FREEZE carries no inline stack: the watchdog's dump lists every thread
   * under `params.threads` (`{ tid, thread_name, frames }`, frames in the same
   * shape as a native APP_CRASH's `exception.frames`), and the blocked main
   * thread is the one whose tid equals `params.pid`. Its frames become the
   * error stack.
   *
   * The system's text for one kind of freeze varies ("User input does not
   * respond!" or "App main thread is not response!" for APP_INPUT_BLOCK, with
   * log status such as "FREEZE_HALF_HIVIEW_LOG write success" or the dump's
   * wall-clock time appended), so the message is a fixed description of the
   * kind and every occurrence of one freeze shares it. The system's text is
   * kept in `freeze.reason`, the dump time in `freeze.dump_started_at`.
   */
  static fromAppFreeze(params: Record<string, Object>): Record<string, Object> {
    const exception: Record<string, Object> = CrashEventMapper.asRecord(params['exception']);
    const message: string = CrashEventMapper.asString(exception['message']);
    const marker: number = message.indexOf(FREEZE_DUMP_TIME_MARKER);
    const freezeException: Record<string, Object> = CrashEventMapper.copy(exception);
    freezeException['message'] = CrashEventMapper.freezeDescription(CrashEventMapper.asString(exception['name']));
    const mainFrames: Array<Object> = CrashEventMapper.mainThreadFrames(params);
    if (mainFrames.length > 0) {
      freezeException['frames'] = mainFrames;
    }
    const freezeParams: Record<string, Object> = CrashEventMapper.copy(params);
    freezeParams['exception'] = freezeException;
    const event: Record<string, Object> = CrashEventMapper.build(freezeParams, 'freeze');
    const reason: string = (marker >= 0 ? message.substring(0, marker) : message).trim();
    if (reason.length > 0) {
      event['freeze.reason'] = CrashEventMapper.truncate(reason, MAX_MESSAGE_CHARS);
    }
    if (marker >= 0) {
      const dumpStartedAt: string = message.substring(marker + FREEZE_DUMP_TIME_MARKER.length).trim();
      if (dumpStartedAt.length > 0) {
        event['freeze.dump_started_at'] = dumpStartedAt;
      }
    }
    return event;
  }

  /**
   * MAIN_THREAD_JANK: the main thread ran one task long enough for the system to
   * sample it, and the process lives on. The samples come two ways: the text of
   * the external log (`params.external_log`, read by the caller), a call tree
   * rooted at the thread entry where each line is "<samples> #NN pc ..." indented
   * by depth; and `params.heaviest_stack`, the single stack sampled most often.
   * The tree is preferred: its heaviest path follows the branch most samples went
   * through, while the most frequent single stack can be the idle event loop when
   * the blocking task's samples, though the majority, are spread over several leaves. Returns null when
   * neither yields a frame — a trace-only jank carries no stack at all.
   */
  static fromMainThreadJank(params: Record<string, Object>, externalLog: string): Record<string, Object> | null {
    let frames: Array<Record<string, Object>> = CrashEventMapper.heaviestTreePath(externalLog);
    if (frames.length === 0) {
      frames = CrashEventMapper.sampledFrames(CrashEventMapper.asString(params['heaviest_stack']));
    }
    const stack: string = CrashEventMapper.framesToStack(frames);
    if (stack.length === 0) {
      return null;
    }
    const binaryImages: Array<Record<string, Object>> = CrashEventMapper.imagesFromFrames(frames, '');
    const event: Record<string, Object> = {
      'type': 'crash_report',
      'target': 'rum',
      'message': JANK_MESSAGE,
      'stack': CrashEventMapper.truncate(stack, MAX_STACK_CHARS),
      'source': RumErrorSource.SOURCE as string,
      'is_crash': false,
      'crash_kind': 'jank',
      'binary_images': JSON.stringify(binaryImages).length <= MAX_BINARY_IMAGES_CHARS ? binaryImages : [],
      'arch': '',
      'build_id': CrashEventMapper.buildId(params, binaryImages),
      'source_type': SOURCE_TYPE
    };
    const begin: Object | undefined = params['begin_time'];
    const end: Object | undefined = params['end_time'];
    if (typeof begin === 'number' && typeof end === 'number' && Number.isFinite(begin) && Number.isFinite(end)
      && end >= begin) {
      event['jank.duration_ms'] = end - begin;
    }
    const time: Object | undefined = params['time'];
    if (typeof time === 'number' && Number.isFinite(time) && time > 0) {
      event['jank.sampled_at'] = time;
    }
    return event;
  }

  /** The heaviest root-to-leaf path of a sampled call tree, leaf first; [] for no tree. */
  private static heaviestTreePath(text: string): Array<Record<string, Object>> {
    const roots: Array<SampleNode> = [];
    const open: Array<SampleNode> = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const m: RegExpMatchArray | null = lines[i].trimEnd().match(SAMPLE_TREE_LINE);
      if (m === null) {
        continue;
      }
      const node: SampleNode = new SampleNode(m[1].length, Number(m[2]), m[3]);
      while (open.length > 0 && open[open.length - 1].depth >= node.depth) {
        open.pop();
      }
      (open.length > 0 ? open[open.length - 1].children : roots).push(node);
      open.push(node);
    }
    const path: string[] = [];
    let level: Array<SampleNode> = roots;
    while (level.length > 0) {
      let heaviest: SampleNode = level[0];
      for (let i = 1; i < level.length; i++) {
        if (level[i].count > heaviest.count) {
          heaviest = level[i];
        }
      }
      path.push(heaviest.frame);
      level = heaviest.children;
    }
    path.reverse();
    return CrashEventMapper.sampledFrames(path.join('\n'));
  }

  /**
   * Frames of a sampled stack, one "#NN ..." line each, leaf first. `heaviest_stack`
   * separates its lines with a literal backslash-n, not a newline; both are accepted.
   */
  private static sampledFrames(text: string): Array<Record<string, Object>> {
    const frames: Array<Record<string, Object>> = [];
    const lines: string[] = text.split('\\n').join('\n').split('\n');
    for (let i = 0; i < lines.length; i++) {
      const frame: Record<string, Object> | null = CrashEventMapper.sampledFrame(lines[i].trim());
      if (frame !== null) {
        frames.push(frame);
      }
    }
    return frames;
  }

  /**
   * One sampled frame in the shape of an `exception.frames` entry. A native line is
   * "#NN pc <addr> <file>(<symbol>+<offset>)(<build id>)", where the symbol and the
   * build id may each be absent, and the file is "[Unknown]" for a frame the
   * sampler could not resolve.
   */
  private static sampledFrame(line: string): Record<string, Object> | null {
    const arkts: RegExpMatchArray | null = line.match(SAMPLED_ARKTS_FRAME);
    if (arkts !== null) {
      return CrashEventMapper.sampledArkTsFrame(arkts[1]);
    }
    const native: RegExpMatchArray | null = line.match(SAMPLED_NATIVE_FRAME);
    if (native === null) {
      return null;
    }
    let rest: string = native[2];
    let buildId: string = '';
    const id: RegExpMatchArray | null = rest.match(SAMPLED_BUILD_ID);
    if (id !== null) {
      buildId = id[1];
      rest = rest.substring(0, rest.length - id[0].length);
    }
    let file: string = rest;
    let symbol: string = '';
    const open: number = rest.indexOf('(');
    if (open > 0 && rest.endsWith(')')) {
      file = rest.substring(0, open);
      symbol = rest.substring(open + 1, rest.length - 1);
    }
    const frame: Record<string, Object> = { 'pc': native[1], 'file': file, 'buildId': buildId };
    const offset: RegExpMatchArray | null = symbol.match(SYMBOL_OFFSET);
    if (offset !== null) {
      frame['symbol'] = offset[1];
      frame['offset'] = offset[2];
    } else {
      frame['symbol'] = symbol;
    }
    return frame;
  }

  /**
   * An ArkTS frame after its "#NN at ": "<fn> (<file>:<line>:<col>)" or "<file>:<line>:<col>".
   * The location holds no parenthesis, so a symbol ends at the last "(", which a blank precedes.
   */
  private static sampledArkTsFrame(text: string): Record<string, Object> | null {
    let location: string = text.endsWith(')') ? text.substring(0, text.length - 1) : text;
    let symbol: string = '';
    const open: number = location.lastIndexOf('(');
    if (open >= 0) {
      const head: string = location.substring(0, open);
      symbol = head.trim();
      if (symbol.length === 0 || head.length === head.trimEnd().length) {
        return null; // no "<fn> " ahead of the "("
      }
      location = location.substring(open + 1);
    }
    const parts: RegExpMatchArray | null = location.match(ARKTS_LOCATION);
    if (parts === null) {
      return null;
    }
    const line: number = Number(parts[2]);
    const column: number = Number(parts[3]);
    if (!Number.isFinite(line) || !Number.isFinite(column)) {
      return null; // digits beyond a double are no position
    }
    return { 'symbol': symbol, 'file': parts[1], 'line': line, 'column': column };
  }

  /** The message of a freeze of this kind (`exception.name`). */
  private static freezeDescription(name: string): string {
    switch (name) {
      case 'THREAD_BLOCK_6S':
        return 'App main thread is not responding';
      case 'APP_INPUT_BLOCK':
        return 'User input is not responding';
      case 'LIFECYCLE_TIMEOUT':
        return 'Ability lifecycle timed out';
      default:
        return 'App is not responding';
    }
  }

  /** Frames of the thread whose tid is the process id (the main thread), or []. */
  private static mainThreadFrames(params: Record<string, Object>): Array<Object> {
    const threads: Object | undefined = params['threads'];
    const pid: Object | undefined = params['pid'];
    if (!Array.isArray(threads) || typeof pid !== 'number') {
      return [];
    }
    const list: Array<Object> = threads as Array<Object>;
    for (let i = 0; i < list.length; i++) {
      const thread: Record<string, Object> = CrashEventMapper.asRecord(list[i]);
      const frames: Object | undefined = thread['frames'];
      if (thread['tid'] === pid && Array.isArray(frames)) {
        return frames as Array<Object>;
      }
    }
    return [];
  }

  private static copy(record: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    for (const key of Object.keys(record)) {
      out[key] = record[key];
    }
    return out;
  }

  static fromPendingIncident(incident: CrashIncidentRecord): Record<string, Object> {
    const exception: Record<string, Object> = {
      'name': incident.exceptionName,
      'message': incident.message,
      'stack': incident.stack
    };
    const event: Record<string, Object> = CrashEventMapper.fromAppCrash({
      'crash_type': 'JsError',
      'exception': exception
    });
    event['incident_id'] = incident.incidentId;
    event['fingerprint'] = incident.fingerprint;
    event['timestamp_ms'] = incident.timestampMs;
    event['original_session_id'] = incident.sessionId;
    event['original_view_id'] = incident.viewId;
    event['original_view_name'] = incident.viewName;
    event['original_view_url'] = incident.viewUrl;
    if (incident.policy === JsCrashPolicy.REPORT_AND_RECOVER) {
      event['crash.recovered'] = true;
    }
    return event;
  }

  private static build(params: Record<string, Object>, kind: string): Record<string, Object> {
    const exception: Record<string, Object> = CrashEventMapper.asRecord(params['exception']);
    const name: string = CrashEventMapper.asString(exception['name']);
    const reason: string = CrashEventMapper.asString(exception['message']);
    const crashType: string = CrashEventMapper.asString(params['crash_type']);

    // Stack: prefer an inline string (ArkTS/JS `Error.stack`), minus the
    // runtime's sourcemap banners (a fault during launch starts its stack with
    // "SourceMap is not initialized yet"); native (cppcrash)
    // faults carry no inline stack — the frames live in `exception.frames` as an
    // array of objects, which we serialize into the text form fc-rum's
    // stack.ParseHarmony understands.
    let stack: string = CrashFingerprint.framesOnly(CrashEventMapper.asString(exception['stack']));
    if (stack.length === 0) {
      stack = CrashEventMapper.framesToStack(exception['frames']);
    }

    // A native crash names its signal (`exception.signal`): the signal is its
    // type, and "SIGSEGV(SEGV_MAPERR)" its message, followed by the system's
    // reason when it gives one. Neither carries an address, so every
    // occurrence of one fault shares the message.
    const signal: Record<string, Object> = CrashEventMapper.asRecord(exception['signal']);
    const signo: Object | undefined = signal['signo'];
    const signalName: string = typeof signo === 'number' ? CrashEventMapper.signalName(signo) : '';
    // Message: "Name: reason" when present (JS); a name with no reason (e.g. a
    // banner-only stack parsed to CrashExceptionParts('Error', '')) stays just
    // the name — never a dangling "Error: ". A fault with neither falls back to
    // the crash type ("NativeCrash"/...) before the generic placeholder.
    let message: string = name.length > 0
      ? (reason.length > 0 ? `${name}: ${reason}` : name)
      : reason;
    if (signalName.length > 0) {
      const code: string = CrashEventMapper.signalCode(signo as number, signal['code']);
      const signalText: string = code.length > 0 ? `${signalName}(${code})` : signalName;
      message = message.length > 0 ? `${signalText}: ${message}` : signalText;
    }
    if (message.length === 0) {
      message = crashType.length > 0 ? crashType : 'Unknown crash';
    }
    // error.type: the signal of a native crash, the exception name of an ArkTS
    // crash, the fault name of a freeze (THREAD_BLOCK_6S, APP_INPUT_BLOCK, …).
    // Without one: the system event (APP_FREEZE) or crash type, and 'Error' for
    // an ArkTS crash, as an unnamed exception is typed everywhere else.
    let errorType: string = signalName.length > 0 ? signalName : name;
    if (errorType.length === 0) {
      errorType = kind === 'freeze' ? 'APP_FREEZE'
        : (crashType.length > 0 && crashType !== 'JsError' ? crashType : 'Error');
    }

    const arch: string = CrashEventMapper.arch(params);
    const binaryImages: Array<Record<string, Object>> = CrashEventMapper.binaryImages(params, exception, arch);

    const event: Record<string, Object> = {
      'type': 'crash_report',
      'target': 'rum',
      'message': CrashEventMapper.truncate(message, MAX_MESSAGE_CHARS),
      'error_type': errorType,
      'stack': CrashEventMapper.truncate(stack, MAX_STACK_CHARS),
      'source': RumErrorSource.SOURCE as string,
      'is_crash': true,
      'crash_kind': kind,
      'binary_images': binaryImages,
      'arch': arch,
      'build_id': CrashEventMapper.buildId(params, binaryImages),
      'source_type': SOURCE_TYPE
    };
    // The process that faulted: the next launch matches it against the process that wrote the
    // last view it would attribute the fault to.
    const pid: Object | undefined = params['pid'];
    if (typeof pid === 'number' && pid > 0) {
      event['process_id'] = pid;
    }
    const threads: Array<Record<string, Object>> = CrashEventMapper.threads(params, exception, kind);
    if (threads.length > 0) {
      event['threads'] = threads;
    }
    const memory: Record<string, Object> = CrashEventMapper.memory(params);
    if (Object.keys(memory).length > 0) {
      event['memory'] = memory;
    }
    return event;
  }

  /**
   * Every thread of the fault's dump (`params.threads`, present for NativeCrash
   * and APP_FREEZE, never for JsError) as RUM error threads. The faulting thread is
   * the signalled one for a native crash (`exception.tid`) and the blocked main
   * thread for a freeze (tid == pid); it is listed first, and taken from
   * `exception.frames` when the dump does not include it. Each stack is bounded
   * like `error.stack`, and the list is cut at a byte budget that always fits the
   * faulting thread.
   */
  private static threads(
    params: Record<string, Object>,
    exception: Record<string, Object>,
    kind: string
  ): Array<Record<string, Object>> {
    const value: Object | undefined = params['threads'];
    if (!Array.isArray(value)) {
      return [];
    }
    // Compared as text: a tid read as a number on one side and a string on the
    // other must still identify the same thread.
    const faultTid: string = CrashEventMapper.asString(kind === 'freeze' ? params['pid'] : exception['tid']);
    const crashed: Array<Record<string, Object>> = [];
    const others: Array<Record<string, Object>> = [];
    const list: Array<Object> = value as Array<Object>;
    for (let i = 0; i < list.length; i++) {
      const thread: Record<string, Object> = CrashEventMapper.asRecord(list[i]);
      const isCrashed: boolean = faultTid.length > 0 && CrashEventMapper.asString(thread['tid']) === faultTid;
      const out: Record<string, Object> | null = CrashEventMapper.thread(thread, isCrashed);
      if (out === null) {
        continue;
      }
      if (isCrashed) {
        crashed.push(out);
      } else {
        others.push(out);
      }
    }
    if (crashed.length === 0 && kind === 'crash') {
      const out: Record<string, Object> | null = CrashEventMapper.thread(exception, true);
      if (out !== null) {
        crashed.push(out);
      }
    }
    const ordered: Array<Record<string, Object>> = crashed.concat(others);
    const kept: Array<Record<string, Object>> = [];
    let size: number = 2; // the enclosing brackets
    for (let i = 0; i < ordered.length; i++) {
      size += CrashEventMapper.utf8Length(JSON.stringify(ordered[i])) + 1;
      if (size > MAX_THREADS_BYTES) {
        break;
      }
      kept.push(ordered[i]);
    }
    return kept;
  }

  /** One dump thread (`{ thread_name, tid, state?, frames }`) as a RUM thread, or null without frames. */
  private static thread(thread: Record<string, Object>, crashed: boolean): Record<string, Object> | null {
    const stack: string = CrashEventMapper.truncate(CrashEventMapper.framesToStack(thread['frames']), MAX_STACK_CHARS);
    if (stack.length === 0) {
      return null;
    }
    const tid: string = CrashEventMapper.asString(thread['tid']);
    const threadName: string = CrashEventMapper.asString(thread['thread_name']);
    const out: Record<string, Object> = {
      'name': threadName.length > 0 ? threadName : `Thread ${tid}`,
      'crashed': crashed,
      'stack': stack
    };
    const state: string = CrashEventMapper.asString(thread['state']);
    if (state.length > 0) {
      out['state'] = state;
    }
    return out;
  }

  /** UTF-8 byte length; a surrogate pair counts 3 + 3, slightly over its real 4. */
  private static utf8Length(text: string): number {
    let bytes: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      bytes += code < 0x80 ? 1 : (code < 0x800 ? 2 : 3);
    }
    return bytes;
  }

  /** Process and device memory at the fault (`params.memory`, API 22+), in KB. */
  private static memory(params: Record<string, Object>): Record<string, Object> {
    const memory: Record<string, Object> = CrashEventMapper.asRecord(params['memory']);
    const out: Record<string, Object> = {};
    for (let i = 0; i < MEMORY_FIELDS.length; i++) {
      const value: Object | undefined = memory[MEMORY_FIELDS[i][0]];
      if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
        out[MEMORY_FIELDS[i][1]] = value;
      }
    }
    return out;
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

  /** Name of a fault signal (Linux numbering, shared by every HarmonyOS ABI). */
  private static signalName(signo: number): string {
    switch (signo) {
      case 4: return 'SIGILL';
      case 5: return 'SIGTRAP';
      case 6: return 'SIGABRT';
      case 7: return 'SIGBUS';
      case 8: return 'SIGFPE';
      case 9: return 'SIGKILL';
      case 11: return 'SIGSEGV';
      case 13: return 'SIGPIPE';
      case 16: return 'SIGSTKFLT';
      case 31: return 'SIGSYS';
      default: return `SIG${signo}`;
    }
  }

  /** Name of a signal's `si_code` ("SEGV_MAPERR"), the number when it has none, '' without a code. */
  private static signalCode(signo: number, value: Object | undefined): string {
    if (typeof value !== 'number') {
      return '';
    }
    const code: number = value;
    switch (code) {
      case 0: return 'SI_USER';
      case 0x80: return 'SI_KERNEL';
      case -1: return 'SI_QUEUE';
      case -2: return 'SI_TIMER';
      case -6: return 'SI_TKILL';
      default: break;
    }
    const names: string[] = CrashEventMapper.signalCodeNames(signo);
    return code >= 1 && code <= names.length ? names[code - 1] : `${code}`;
  }

  /** The signal-specific `si_code` names, in order from 1. */
  private static signalCodeNames(signo: number): string[] {
    switch (signo) {
      case 4:
        return ['ILL_ILLOPC', 'ILL_ILLOPN', 'ILL_ILLADR', 'ILL_ILLTRP', 'ILL_PRVOPC', 'ILL_PRVREG', 'ILL_COPROC',
          'ILL_BADSTK'];
      case 5:
        return ['TRAP_BRKPT', 'TRAP_TRACE', 'TRAP_BRANCH', 'TRAP_HWBKPT'];
      case 7:
        return ['BUS_ADRALN', 'BUS_ADRERR', 'BUS_OBJERR', 'BUS_MCEERR_AR', 'BUS_MCEERR_AO'];
      case 8:
        return ['FPE_INTDIV', 'FPE_INTOVF', 'FPE_FLTDIV', 'FPE_FLTOVF', 'FPE_FLTUND', 'FPE_FLTRES', 'FPE_FLTINV',
          'FPE_FLTSUB'];
      case 11:
        return ['SEGV_MAPERR', 'SEGV_ACCERR', 'SEGV_BNDERR', 'SEGV_PKUERR', 'SEGV_ACCADI', 'SEGV_ADIDERR',
          'SEGV_ADIPERR', 'SEGV_MTEAERR', 'SEGV_MTESERR'];
      default:
        return [];
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

/** One node of a jank's sampled call tree: its indentation, sample count and frame line. */
class SampleNode {
  readonly depth: number;
  readonly count: number;
  readonly frame: string;
  readonly children: Array<SampleNode> = [];

  constructor(depth: number, count: number, frame: string) {
    this.depth = depth;
    this.count = count;
    this.frame = frame;
  }
}
