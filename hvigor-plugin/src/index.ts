import { collectArktsSourcemap, collectNativeSymbols } from './collect.ts';
import { uploadSourcemap, uploadSymbol, type UploadConfig } from './upload.ts';

export { extractElfBuildId } from './elf.ts';
export {
  collectArktsSourcemap, collectNativeSymbols, archFromAbi,
  type ArktsSourcemap, type NativeSymbol
} from './collect.ts';
export {
  uploadSourcemap, uploadSymbol, sourcemapEvent, symbolFileEvent,
  ORIGIN, TYPE_SOURCEMAP, TYPE_SYMBOL_FILE, type UploadConfig
} from './upload.ts';
export { flashcatSymbolUploadPlugin } from './plugin.ts';

export interface UploadResult {
  sourcemap: { uploaded: boolean; status?: number; reason?: string };
  symbols: Array<{ libName: string; arch: string; uploaded: boolean; status?: number; reason?: string }>;
}

export type Logger = (msg: string) => void;

/**
 * Collect ArkTS sourcemap + native symbols under `buildDir` and upload them.
 * Pure orchestration over collect + upload; safe to call from a hvigor task or a
 * standalone script. Missing artifacts are skipped with a logged reason, never
 * throwing — a symbol-upload failure must not fail the app build.
 */
export async function uploadAll(buildDir: string, cfg: UploadConfig, log: Logger = () => {}): Promise<UploadResult> {
  const result: UploadResult = { sourcemap: { uploaded: false }, symbols: [] };

  const sm = collectArktsSourcemap(buildDir);
  if (!sm) {
    result.sourcemap.reason = `no sourceMaps.map found under ${buildDir} (wrong build dir, or sourcemap output disabled?)`;
    log(`flashcat: ${result.sourcemap.reason}`);
  } else {
    try {
      const r = await uploadSourcemap(cfg, sm);
      result.sourcemap = { uploaded: r.ok, status: r.status, reason: r.ok ? undefined : r.body };
      log(`flashcat: sourcemap upload ${r.ok ? 'OK' : 'FAILED'} (${r.status})${sm.nameCachePath ? ' + nameCache' : ''}`);
    } catch (e) {
      result.sourcemap = { uploaded: false, reason: e instanceof Error ? e.message : 'upload error' };
      log(`flashcat: sourcemap upload error: ${result.sourcemap.reason}`);
    }
  }

  for (const sym of collectNativeSymbols(buildDir)) {
    if (!sym.buildId) {
      result.symbols.push({ libName: sym.libName, arch: sym.arch, uploaded: false, reason: 'no GNU build-id (build .so with -Wl,--build-id)' });
      log(`flashcat: skip ${sym.libName} (${sym.arch}) — no build-id`);
      continue;
    }
    try {
      const r = await uploadSymbol(cfg, sym);
      result.symbols.push({ libName: sym.libName, arch: sym.arch, uploaded: r.ok, status: r.status, reason: r.ok ? undefined : r.body });
      log(`flashcat: symbol ${sym.libName} (${sym.arch}) ${r.ok ? 'OK' : 'FAILED'} (${r.status})`);
    } catch (e) {
      result.symbols.push({ libName: sym.libName, arch: sym.arch, uploaded: false, reason: e instanceof Error ? e.message : 'upload error' });
      log(`flashcat: symbol ${sym.libName} upload error`);
    }
  }
  return result;
}
