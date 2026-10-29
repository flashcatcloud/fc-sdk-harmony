import { hidebug } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { ResourceReaders } from './ResourceSampler';

// Android parity: kB from the kernel × 1000.
const BYTES_PER_KB: number = 1000;
const STAT_PATH: string = '/proc/self/stat';
// Field 14 of /proc/<pid>/stat; fields 3.. follow the ")" that closes field 2.
const UTIME_FIELD: number = 14;
const FIRST_FIELD_AFTER_COMM: number = 3;

/**
 * How resident memory is read on a given API level. Each path is the cheapest
 * one that level offers, and each is used as the system documents it.
 */
export enum MemoryPath {
  /** API 24+: VmRSS from /proc/self/status, documented as lightweight. Synchronous. */
  RSS_INFO = 'rss_info',
  /** API 20–23: Rss from smaps_rollup, read off the main thread by the system. */
  NATIVE_ASYNC = 'native_async',
  /** API 12–19: Rss from smaps_rollup, synchronous and slow — run on the task pool. */
  NATIVE_TASKPOOL = 'native_taskpool',
  NONE = 'none'
}

export function memoryPathFor(apiVersion: number): MemoryPath {
  if (apiVersion >= 24) {
    return MemoryPath.RSS_INFO;
  }
  if (apiVersion >= 20) {
    return MemoryPath.NATIVE_ASYNC;
  }
  if (apiVersion >= 12) {
    return MemoryPath.NATIVE_TASKPOOL;
  }
  return MemoryPath.NONE;
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

function kilobytesToBytes(kb: number): number | null {
  return Number.isFinite(kb) && kb >= 0 ? kb * BYTES_PER_KB : null;
}

@Concurrent
function readNativeRssKb(): number {
  // A plain number crosses the thread boundary; a bigint is not guaranteed to.
  return Number(hidebug.getAppNativeMemInfo().rss);
}

function memoryReaderFor(path: MemoryPath): (() => Promise<number | null>) | null {
  switch (path) {
    case MemoryPath.RSS_INFO:
      return (): Promise<number | null> =>
        Promise.resolve(kilobytesToBytes(Number(hidebug.getRssInfo().rss)));
    case MemoryPath.NATIVE_ASYNC:
      return (): Promise<number | null> => hidebug.getAppNativeMemInfoAsync()
        .then((info: hidebug.NativeMemInfo) => kilobytesToBytes(Number(info.rss)));
    case MemoryPath.NATIVE_TASKPOOL:
      return (): Promise<number | null> => (taskpool.execute(readNativeRssKb) as Promise<Object>)
        .then((kb: Object) => typeof kb === 'number' ? kilobytesToBytes(kb as number) : null);
    default:
      return null;
  }
}

function readCpuTicks(): number | null {
  return parseUtimeTicks(fileIo.readTextSync(STAT_PATH));
}

/** The readers for a device on `apiVersion`. Each one's failures reach the
 * sampler as a throw or rejection, which it contains. */
export function systemResourceReaders(apiVersion: number): ResourceReaders {
  return {
    memoryBytes: memoryReaderFor(memoryPathFor(apiVersion)),
    cpuTicks: readCpuTicks
  };
}
