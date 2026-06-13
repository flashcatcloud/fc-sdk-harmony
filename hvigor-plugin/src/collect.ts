import * as fs from 'node:fs';
import * as path from 'node:path';
import { extractElfBuildId } from './elf.ts';

/** Maps an Android-style ABI dir name to the arch token fc-rum expects. */
export function archFromAbi(abi: string): string {
  switch (abi) {
    case 'arm64-v8a':
      return 'arm64';
    case 'armeabi-v7a':
      return 'arm';
    case 'x86_64':
      return 'x64';
    case 'x86':
      return 'x86';
    default:
      return abi;
  }
}

export interface ArktsSourcemap {
  sourceMapPath: string;
  nameCachePath: string | null; // present only for obfuscated (release) builds
}

export interface NativeSymbol {
  soPath: string;
  libName: string; // basename, e.g. libentry.so
  arch: string; // arm64 / arm / x64 / x86
  buildId: string | null; // GNU build-id hex, null if the .so has none
}

/** Recursively collect files matching a predicate (bounded, ignores symlinks). */
function walk(dir: string, match: (full: string, name: string) => boolean, out: string[]): void {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isSymbolicLink()) {
      continue;
    }
    if (e.isDirectory()) {
      walk(full, match, out);
    } else if (e.isFile() && match(full, e.name)) {
      out.push(full);
    }
  }
}

/**
 * Find the ArkTS `sourceMaps.map` (and obfuscation `nameCache.json` if present)
 * under a module build directory. Prefers the packaged `outputs/.../mapping`
 * copy, falling back to any `sourceMaps.map` found.
 */
export function collectArktsSourcemap(buildDir: string): ArktsSourcemap | null {
  const maps: string[] = [];
  walk(buildDir, (_full, name) => name === 'sourceMaps.map', maps);
  if (maps.length === 0) {
    return null;
  }
  maps.sort((a, b) => {
    const score = (p: string): number => (p.includes(`${path.sep}outputs${path.sep}`) ? 0 : 1);
    return score(a) - score(b);
  });
  const caches: string[] = [];
  walk(buildDir, (_full, name) => name === 'nameCache.json', caches);
  return { sourceMapPath: maps[0], nameCachePath: caches.length > 0 ? caches[0] : null };
}

/**
 * Find UNSTRIPPED native `.so` debug files under a module build directory. Prefers
 * the CMake object output (`intermediates/cmake/.../obj/<abi>/*.so`) which retains
 * DWARF + the GNU build-id; the `stripped_native_libs` copies are useless for
 * symbolication. System libs (libc++_shared.so) are skipped.
 */
export function collectNativeSymbols(buildDir: string): NativeSymbol[] {
  const sos: string[] = [];
  const objRoot = (p: string): boolean => p.includes(`${path.sep}cmake${path.sep}`) && p.includes(`${path.sep}obj${path.sep}`);
  walk(buildDir, (full, name) => name.endsWith('.so') && objRoot(full), sos);
  const out: NativeSymbol[] = [];
  const seen = new Set<string>();
  for (const so of sos) {
    const libName = path.basename(so);
    if (libName === 'libc++_shared.so' || libName.startsWith('libclang_rt')) {
      continue;
    }
    const abi = path.basename(path.dirname(so));
    const arch = archFromAbi(abi);
    const key = `${arch}/${libName}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    let buildId: string | null = null;
    try {
      buildId = extractElfBuildId(fs.readFileSync(so));
    } catch {
      buildId = null;
    }
    out.push({ soPath: so, libName, arch, buildId });
  }
  return out;
}
