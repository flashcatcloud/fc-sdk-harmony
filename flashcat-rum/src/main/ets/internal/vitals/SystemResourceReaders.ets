import { fileIo } from '@kit.CoreFileKit';
import { ResourceReaders } from './ResourceSampler';

// Android parity: kB from the kernel × 1000.
const BYTES_PER_KB: number = 1000;
const STAT_PATH: string = '/proc/self/stat';
const STATUS_PATH: string = '/proc/self/status';
// stat is a few hundred bytes and status about 1.5 KB: one chunk and an empty
// read at the end, as a rule.
const PROC_CHUNK_BYTES: number = 4096;
const PROC_MAX_BYTES: number = 65536;
// Field 14 of /proc/<pid>/stat; fields 3.. follow the ")" that closes field 2.
const UTIME_FIELD: number = 14;
const FIRST_FIELD_AFTER_COMM: number = 3;

const VMRSS_KEY: string = 'VmRSS:';
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
 * utime (field 14, clock ticks) out of the first `length` bytes of a
 * /proc/<pid>/stat, or null when they are not one. Fields are counted after
 * the last ")": the process name in field 2 may itself contain spaces and
 * parentheses.
 */
export function parseUtimeTicks(stat: Uint8Array, length: number): number | null {
  let i: number = length - 1;
  while (i >= 0 && stat[i] !== CLOSE_PAREN) {
    i--;
  }
  if (i < 0) {
    return null;
  }
  i++;
  let from: number = i;
  for (let field: number = FIRST_FIELD_AFTER_COMM; field <= UTIME_FIELD; field++) {
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

function kilobytesToBytes(kb: number | null): number | null {
  return kb !== null && Number.isFinite(kb) && kb >= 0 ? kb * BYTES_PER_KB : null;
}

/** The bytes of a /proc file, up to PROC_MAX_BYTES, into `image`; returns how
 * many. Read in chunks until the end, not with readTextSync: a /proc file's
 * size is 0, and readTextSync reads only as many bytes as the size says —
 * none. A read may also return less than the file holds (a long Groups line
 * puts VmRSS past the first chunk). */
function readProcFile(path: string): number {
  if (chunk === null || image === null) {
    chunk = new Uint8Array(PROC_CHUNK_BYTES);
    image = new Uint8Array(PROC_MAX_BYTES);
  }
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    let total: number = 0;
    while (total < PROC_MAX_BYTES) {
      const read: number = fileIo.readSync(file.fd, chunk.buffer as ArrayBuffer,
        { length: Math.min(PROC_CHUNK_BYTES, PROC_MAX_BYTES - total) });
      if (read <= 0) {
        break;
      }
      for (let i: number = 0; i < read; i++) {
        image[total + i] = chunk[i];
      }
      total += read;
    }
    return total;
  } finally {
    fileIo.closeSync(file);
  }
}

function readCpuTicks(): number | null {
  const length: number = readProcFile(STAT_PATH);
  return parseUtimeTicks(image as Uint8Array, length);
}

function readMemoryBytes(): Promise<number | null> {
  const length: number = readProcFile(STATUS_PATH);
  return Promise.resolve(kilobytesToBytes(parseVmRssKb(image as Uint8Array, length)));
}

/** The readers of this process. Each one's failures reach the sampler as a
 * throw or rejection, which it contains. */
export function systemResourceReaders(): ResourceReaders {
  return {
    memoryBytes: readMemoryBytes,
    cpuTicks: readCpuTicks
  };
}
