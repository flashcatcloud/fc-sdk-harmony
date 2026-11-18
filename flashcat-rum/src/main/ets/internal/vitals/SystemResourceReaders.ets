import { FlashcatLog } from '@flashcatcloud/core';
import { fileIo } from '@kit.CoreFileKit';
import { process } from '@kit.ArkTS';
import { systemDateTime } from '@kit.BasicServicesKit';
import { ResourceReaders } from './ResourceSampler';
import { CpuReading } from './ViewVitals';

// Android parity: kB from the kernel × 1000.
const BYTES_PER_KB: number = 1000;
const STAT_PATH: string = '/proc/self/stat';
const STATUS_PATH: string = '/proc/self/status';
// stat is a few hundred bytes and status about 1.5 KB: the first read takes
// either whole, as a rule. Reads after it, when a kernel returns less, go
// through one chunk.
const PROC_CHUNK_BYTES: number = 4096;
const PROC_MAX_BYTES: number = 65536;
// Fields 14 and 15 of /proc/<pid>/stat; fields 3.. follow the ")" that closes field 2.
export const UTIME_FIELD: number = 14;
export const STIME_FIELD: number = 15;
const FIRST_FIELD_AFTER_COMM: number = 3;

const VMRSS_KEY: string = 'VmRSS:';
const CPUS_ALLOWED_KEY: string = 'Cpus_allowed_list:';
const COMMA: number = 0x2c;
const DASH: number = 0x2d;
const DIGIT_0: number = 0x30;
const DIGIT_9: number = 0x39;
const SPACE: number = 0x20;
const TAB: number = 0x09;
const NEWLINE: number = 0x0a;
const CARRIAGE_RETURN: number = 0x0d;
const CLOSE_PAREN: number = 0x29;
const LETTER_K: number = 0x6b;
const LETTER_B: number = 0x42;

// One chunk and one file image for the life of the process, so a sample
// allocates no buffer and builds no string. What a sample allocates is
// garbage that only an ArkTS GC gives back, and an idle app rarely prompts
// one: with a buffer and a string per read (two reads a sample, two samples
// a second) an idle app's resident memory grew by about 3 MB a minute, most
// of it native memory behind the buffers, which does not hurry the GC.
// Reads run on one thread, one at a time.
let chunk: Uint8Array | null = null;
let image: Uint8Array | null = null;

function isBlank(b: number): boolean {
  return b === SPACE || b === TAB;
}

function isSpace(b: number): boolean {
  return b === SPACE || b === TAB || b === NEWLINE || b === CARRIAGE_RETURN;
}

function isDigit(b: number): boolean {
  return b >= DIGIT_0 && b <= DIGIT_9;
}

/** The decimal number of the digits in [from, to), or null when one is not a digit. */
function decimal(bytes: Uint8Array, from: number, to: number): number | null {
  if (from >= to) {
    return null;
  }
  let value: number = 0;
  for (let i: number = from; i < to; i++) {
    if (!isDigit(bytes[i])) {
      return null;
    }
    value = value * 10 + (bytes[i] - DIGIT_0);
  }
  return value;
}

/** The kB of the line starting at `at` when it is "VmRSS:<blanks><digits><blanks>kB<blanks>", else null. */
function vmRssAt(bytes: Uint8Array, length: number, at: number): number | null {
  for (let k: number = 0; k < VMRSS_KEY.length; k++) {
    if (at + k >= length || bytes[at + k] !== VMRSS_KEY.charCodeAt(k)) {
      return null;
    }
  }
  let i: number = at + VMRSS_KEY.length;
  while (i < length && isBlank(bytes[i])) {
    i++;
  }
  const digits: number = i;
  while (i < length && isDigit(bytes[i])) {
    i++;
  }
  const kb: number | null = decimal(bytes, digits, i);
  while (i < length && isBlank(bytes[i])) {
    i++;
  }
  if (kb === null || i + 1 >= length || bytes[i] !== LETTER_K || bytes[i + 1] !== LETTER_B) {
    return null;
  }
  i += 2;
  while (i < length && isBlank(bytes[i])) {
    i++;
  }
  return i >= length || bytes[i] === NEWLINE ? kb : null;
}

/**
 * VmRSS in kB out of the first `length` bytes of a /proc/<pid>/status, or
 * null when it has none.
 * Read from the file rather than through `hidebug`: on a phone an isolated
 * `hidebug.getRssInfo()` (one sample after the thread was idle, as the sampler
 * takes them) cost about 7 ms of CPU, the file read under 1 ms; the native
 * memory info calls cost more still.
 */
export function parseVmRssKb(status: Uint8Array, length: number): number | null {
  for (let line: number = 0; line < length; line++) {
    if (line === 0 || status[line - 1] === NEWLINE) {
      const kb: number | null = vmRssAt(status, length, line);
      if (kb !== null) {
        return kb;
      }
    }
  }
  return null;
}

/**
 * Field `field` (a number of clock ticks: 14 is utime, 15 stime) out of the first
 * `length` bytes of a /proc/<pid>/stat, or null when they are not one. Fields are
 * counted after the last ")": the process name in field 2 may itself contain
 * spaces and parentheses.
 */
export function parseStatField(stat: Uint8Array, length: number, field: number): number | null {
  let i: number = length - 1;
  while (i >= 0 && stat[i] !== CLOSE_PAREN) {
    i--;
  }
  if (i < 0) {
    return null;
  }
  i++;
  let from: number = i;
  for (let f: number = FIRST_FIELD_AFTER_COMM; f <= field; f++) {
    while (i < length && isSpace(stat[i])) {
      i++;
    }
    if (i >= length) {
      return null;
    }
    from = i;
    while (i < length && !isSpace(stat[i])) {
      i++;
    }
  }
  return decimal(stat, from, i);
}

/**
 * The number of CPUs in the `Cpus_allowed_list:` line ("0-3,6,8-9" is 7) out of
 * the first `length` bytes of a /proc/<pid>/status, or null when it has none.
 * The CPUs the process may run on: the cores its CPU time is shared out over.
 */
export function parseAllowedCpus(status: Uint8Array, length: number): number | null {
  for (let line: number = 0; line < length; line++) {
    if (line !== 0 && status[line - 1] !== NEWLINE) {
      continue;
    }
    let i: number = line;
    let k: number = 0;
    while (k < CPUS_ALLOWED_KEY.length && i < length && status[i] === CPUS_ALLOWED_KEY.charCodeAt(k)) {
      i++;
      k++;
    }
    if (k < CPUS_ALLOWED_KEY.length) {
      continue;
    }
    while (i < length && isBlank(status[i])) {
      i++;
    }
    let count: number = 0;
    while (i < length && isDigit(status[i])) {
      let end: number = i;
      while (end < length && isDigit(status[end])) {
        end++;
      }
      const first: number | null = decimal(status, i, end);
      i = end;
      let last: number | null = first;
      if (i < length && status[i] === DASH) {
        end = ++i;
        while (end < length && isDigit(status[end])) {
          end++;
        }
        last = decimal(status, i, end);
        i = end;
      }
      if (first === null || last === null || last < first) {
        return null;
      }
      count += last - first + 1;
      if (i < length && status[i] === COMMA) {
        i++;
      }
    }
    return count > 0 && (i >= length || isSpace(status[i])) ? count : null;
  }
  return null;
}

function kilobytesToBytes(kb: number | null): number | null {
  return kb !== null && Number.isFinite(kb) && kb >= 0 ? kb * BYTES_PER_KB : null;
}

/**
 * A /proc file of this process, opened on the first read and kept open: each
 * read starts at offset 0, where procfs builds the file's text afresh, so it
 * sees current values. On a phone, opening and closing the file was about a
 * third of a sample's CPU.
 *
 * Read in chunks rather than with readTextSync: a /proc file's size is 0, and
 * readTextSync reads only as many bytes as the size says — none.
 */
class ProcFile {
  private readonly path: string;
  private fd: number = -1;

  constructor(path: string) {
    this.path = path;
  }

  /**
   * `parse` of the file's bytes. A read returns the whole file as a rule, and
   * reading stops at the first one that ends a line `parse` can read: every
   * read makes the kernel build the text again, so the empty read that marks
   * the end would double its cost. A kernel that returns less (a long Groups
   * line puts VmRSS past 4 KB) is read on to the end.
   */
  read(parse: (bytes: Uint8Array, length: number) => number | null): number | null {
    if (chunk === null || image === null) {
      chunk = new Uint8Array(PROC_CHUNK_BYTES);
      image = new Uint8Array(PROC_MAX_BYTES);
    }
    if (this.fd < 0) {
      this.fd = fileIo.openSync(this.path, fileIo.OpenMode.READ_ONLY).fd;
    }
    let total: number = fileIo.readSync(this.fd, image.buffer as ArrayBuffer, { offset: 0, length: PROC_MAX_BYTES });
    while (total > 0 && total < PROC_MAX_BYTES) {
      if (image[total - 1] === NEWLINE) {
        const value: number | null = parse(image, total);
        if (value !== null) {
          return value;
        }
      }
      const read: number = fileIo.readSync(this.fd, chunk.buffer as ArrayBuffer,
        { offset: total, length: Math.min(PROC_CHUNK_BYTES, PROC_MAX_BYTES - total) });
      if (read <= 0) {
        break;
      }
      for (let i: number = 0; i < read; i++) {
        image[total + i] = chunk[i];
      }
      total += read;
    }
    return parse(image, Math.max(0, total));
  }
}

const stat: ProcFile = new ProcFile(STAT_PATH);
const status: ProcFile = new ProcFile(STATUS_PATH);
// The main thread's id is the process id.
const mainThreadStat: ProcFile = new ProcFile(`/proc/self/task/${process.pid}/stat`);

// One reading for the life of the process, filled in place: a sample allocates nothing.
const reading: CpuReading = { userTicks: 0, processTicks: 0, mainThreadTicks: -1, cores: 0, atNs: 0 };
let utimeTicks: number = 0;
// Read once: the CPUs a process may use do not change while it runs in the foreground.
let coresRead: boolean = false;
let mainThreadReadable: boolean = true;

function parseProcessTimes(bytes: Uint8Array, length: number): number | null {
  const utime: number | null = parseStatField(bytes, length, UTIME_FIELD);
  const stime: number | null = parseStatField(bytes, length, STIME_FIELD);
  if (utime === null || stime === null) {
    return null;
  }
  utimeTicks = utime;
  return utime + stime;
}

function parseThreadTimes(bytes: Uint8Array, length: number): number | null {
  const utime: number | null = parseStatField(bytes, length, UTIME_FIELD);
  const stime: number | null = parseStatField(bytes, length, STIME_FIELD);
  return utime === null || stime === null ? null : utime + stime;
}

/**
 * The process's CPU time (user + system, and user alone), the main thread's, and when
 * they were read; null when the process's own is unreadable. A main thread or a CPU
 * count that cannot be read leaves only its own fields out (-1, 0).
 */
function readCpu(): CpuReading | null {
  const processTicks: number | null = stat.read(parseProcessTimes);
  if (processTicks === null) {
    return null;
  }
  reading.atNs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true);
  reading.processTicks = processTicks;
  reading.userTicks = utimeTicks;
  reading.mainThreadTicks = -1;
  if (mainThreadReadable) {
    try {
      reading.mainThreadTicks = mainThreadStat.read(parseThreadTimes) ?? -1;
    } catch (_e) {
      mainThreadReadable = false;
    }
  }
  if (!coresRead) {
    coresRead = true;
    try {
      reading.cores = status.read(parseAllowedCpus) ?? 0;
    } catch (_e) {
      reading.cores = 0;
    }
    if (reading.cores === 0) {
      FlashcatLog.d('rum.vitals: the CPU count is not readable; views carry no process CPU usage');
    }
  }
  return reading;
}

function readMemoryBytes(): Promise<number | null> {
  return Promise.resolve(kilobytesToBytes(status.read(parseVmRssKb)));
}

/** The readers of this process. Each one's failures reach the sampler as a
 * throw or rejection, which it contains. */
export function systemResourceReaders(): ResourceReaders {
  return {
    memoryBytes: readMemoryBytes,
    cpu: readCpu
  };
}
