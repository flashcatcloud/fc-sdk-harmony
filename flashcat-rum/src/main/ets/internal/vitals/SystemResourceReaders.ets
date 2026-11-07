import { buffer } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { ResourceReaders } from './ResourceSampler';

// Android parity: kB from the kernel × 1000.
const BYTES_PER_KB: number = 1000;
const STAT_PATH: string = '/proc/self/stat';
const STATUS_PATH: string = '/proc/self/status';
// VmRSS sits in the first thirty lines of a status file of about 1.5 KB.
const STATUS_READ_BYTES: number = 4096;
// Field 14 of /proc/<pid>/stat; fields 3.. follow the ")" that closes field 2.
const UTIME_FIELD: number = 14;
const FIRST_FIELD_AFTER_COMM: number = 3;
// A stat line is a few hundred bytes; utime comes well before the end of it.
const STAT_READ_BYTES: number = 1024;

/**
 * VmRSS in kB out of a /proc/<pid>/status text, or null when it has none.
 * Read from the file rather than through `hidebug`: on a phone an isolated
 * `hidebug.getRssInfo()` (one sample after the thread was idle, as the sampler
 * takes them) cost about 7 ms of CPU, the file read under 1 ms; the native
 * memory info calls cost more still.
 */
export function parseVmRssKb(status: string): number | null {
  const found: RegExpMatchArray | null = status.match(/^VmRSS:\s*(\d+)\s*kB\s*$/m);
  return found === null ? null : Number(found[1]);
}

/**
 * utime (field 14, clock ticks) out of a /proc/<pid>/stat line, or null when
 * the text is not one. Fields are counted after the last ")": the process
 * name in field 2 may itself contain spaces and parentheses.
 */
export function parseUtimeTicks(stat: string): number | null {
  const commEnd: number = stat.lastIndexOf(')');
  if (commEnd < 0) {
    return null;
  }
  const fields: string[] = stat.substring(commEnd + 1).trim().split(/\s+/);
  const raw: string | undefined = fields[UTIME_FIELD - FIRST_FIELD_AFTER_COMM];
  if (raw === undefined || !/^\d+$/.test(raw)) {
    return null;
  }
  return Number(raw);
}

function kilobytesToBytes(kb: number | null): number | null {
  return kb !== null && Number.isFinite(kb) && kb >= 0 ? kb * BYTES_PER_KB : null;
}

/** Read with a buffer of its own, not readTextSync: a /proc file's size is 0,
 * and readTextSync reads only as many bytes as the size says — none. */
function readProcFile(path: string, maxBytes: number): string {
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const bytes: ArrayBuffer = new ArrayBuffer(maxBytes);
    const read: number = fileIo.readSync(file.fd, bytes);
    return buffer.from(bytes, 0, read).toString('utf-8');
  } finally {
    fileIo.closeSync(file);
  }
}

function readCpuTicks(): number | null {
  return parseUtimeTicks(readProcFile(STAT_PATH, STAT_READ_BYTES));
}

function readMemoryBytes(): Promise<number | null> {
  return Promise.resolve(kilobytesToBytes(parseVmRssKb(readProcFile(STATUS_PATH, STATUS_READ_BYTES))));
}

/** The readers of this process. Each one's failures reach the sampler as a
 * throw or rejection, which it contains. */
export function systemResourceReaders(): ResourceReaders {
  return {
    memoryBytes: readMemoryBytes,
    cpuTicks: readCpuTicks
  };
}
