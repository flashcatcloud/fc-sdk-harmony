import * as fs from 'node:fs';
import * as path from 'node:path';
import type { ArktsSourcemap, NativeSymbol } from './collect.ts';

/** The DD-EVP-ORIGIN value fc-rum routes HarmonyOS symbol uploads on. */
export const ORIGIN = 'flashcat-hvigor-plugin';
/** event.type for an ArkTS sourcemap + nameCache upload. */
export const TYPE_SOURCEMAP = 'harmony_sourcemap';
/** event.type for a native (.so DWARF) symbol-file upload. */
export const TYPE_SYMBOL_FILE = 'harmony_symbol_file';

/** SaaS sourcemap/symbol upload host. Distinct from RUM ingest (`browser.flashcat.cloud`). */
const DEFAULT_UPLOAD_ENDPOINT = 'https://ci.flashcat.cloud';

/** Known RUM-ingest-only hosts that 404 on `/sourcemap/upload`. */
const RUM_INGEST_ONLY_HOSTS = new Set(['browser.flashcat.cloud', 'jira.flashcat.cloud']);

export type EndpointResolution =
  | { ok: true; endpoint: string; warnings: string[] }
  | { ok: false; reason: string; warnings: string[] };

/**
 * Resolve the symbol-upload base URL.
 *
 * Priority when `explicit` is **omitted** (`undefined`):
 * `FLASHCAT_SOURCEMAP_INTAKE_URL` → legacy `FLASHCAT_ENDPOINT` → SaaS default.
 *
 * When `explicit` is provided (`''` included; `null` counts as omitted — plain-JS
 * hvigorfiles pass it from config lookups), it is the only source — an empty
 * or invalid value skips the upload instead of falling back to SaaS.
 */
export function resolveUploadEndpoint(
  explicit?: string | null,
  env: NodeJS.ProcessEnv = process.env
): EndpointResolution {
  const warnings: string[] = [];

  let raw: string;
  let source: 'option' | 'FLASHCAT_SOURCEMAP_INTAKE_URL' | 'FLASHCAT_ENDPOINT' | 'default';

  if (explicit != null) {
    raw = explicit.trim();
    source = 'option';
    if (!raw) {
      return { ok: false, reason: 'endpoint is empty — skipping symbol upload (will not fall back to SaaS)', warnings };
    }
  } else if (env.FLASHCAT_SOURCEMAP_INTAKE_URL !== undefined) {
    raw = env.FLASHCAT_SOURCEMAP_INTAKE_URL.trim();
    source = 'FLASHCAT_SOURCEMAP_INTAKE_URL';
    if (!raw) {
      return {
        ok: false,
        reason: 'FLASHCAT_SOURCEMAP_INTAKE_URL is empty — skipping symbol upload (will not fall back to SaaS)',
        warnings
      };
    }
  } else if (env.FLASHCAT_ENDPOINT !== undefined) {
    raw = env.FLASHCAT_ENDPOINT.trim();
    source = 'FLASHCAT_ENDPOINT';
    if (!raw) {
      return {
        ok: false,
        reason: 'FLASHCAT_ENDPOINT is empty — skipping symbol upload (will not fall back to SaaS)',
        warnings
      };
    }
    warnings.push(
      'FLASHCAT_ENDPOINT is deprecated for symbol upload; prefer FLASHCAT_SOURCEMAP_INTAKE_URL (or omit for SaaS)'
    );
  } else {
    raw = DEFAULT_UPLOAD_ENDPOINT;
    source = 'default';
  }

  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { ok: false, reason: `invalid symbol-upload endpoint from ${source}: ${JSON.stringify(raw)}`, warnings };
  }

  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return {
      ok: false,
      reason: `symbol-upload endpoint from ${source} must be http(s), got ${url.protocol}`,
      warnings
    };
  }
  if (url.search || url.hash) {
    return {
      ok: false,
      reason: `symbol-upload endpoint from ${source} must not include query or hash`,
      warnings
    };
  }

  if (RUM_INGEST_ONLY_HOSTS.has(url.hostname)) {
    warnings.push(
      `${url.hostname} is a RUM ingest host and returns 404 on /sourcemap/upload — use https://ci.flashcat.cloud (SaaS) or your private symbol-upload base URL`
    );
  }

  const endpoint = raw.replace(/\/+$/, '');
  return { ok: true, endpoint, warnings };
}

/**
 * Build the upload URL. Accepts either a base host or a full
 * `.../sourcemap/upload` path so private-deploy pastes don't double the suffix.
 */
export function resolveSourcemapUploadUrl(endpoint: string): string {
  const normalized = endpoint.trim().replace(/\/+$/, '');
  if (normalized.endsWith('/sourcemap/upload')) {
    return normalized;
  }
  return `${normalized}/sourcemap/upload`;
}

export interface UploadConfig {
  /** Symbol-upload base URL, e.g. https://ci.flashcat.cloud (SaaS) or a private ingest host. */
  endpoint: string;
  apiKey: string;
  service: string;
  version: string;
  pluginVersion: string;
}

/** event metadata for an ArkTS sourcemap upload. */
export function sourcemapEvent(cfg: UploadConfig): Record<string, string> {
  return {
    type: TYPE_SOURCEMAP,
    service: cfg.service,
    version: cfg.version,
    cli_version: cfg.pluginVersion
  };
}

/** event metadata for one native symbol-file upload. */
export function symbolFileEvent(cfg: UploadConfig, sym: NativeSymbol): Record<string, string> {
  const event: Record<string, string> = {
    type: TYPE_SYMBOL_FILE,
    service: cfg.service,
    version: cfg.version,
    cli_version: cfg.pluginVersion,
    arch: sym.arch,
    lib_name: sym.libName
  };
  if (sym.buildId) {
    event.build_id = sym.buildId;
  }
  return event;
}

function headers(cfg: UploadConfig): Record<string, string> {
  return {
    'DD-API-KEY': cfg.apiKey,
    'DD-EVP-ORIGIN': ORIGIN,
    'DD-EVP-ORIGIN-VERSION': cfg.pluginVersion
  };
}

function uploadUrl(cfg: UploadConfig): string {
  return resolveSourcemapUploadUrl(cfg.endpoint);
}

function fileBlob(filePath: string): Blob {
  const data = fs.readFileSync(filePath);
  return new Blob([data]);
}

/** POST one multipart form; returns {ok, status, body}. Never throws on HTTP status. */
async function post(cfg: UploadConfig, form: FormData): Promise<{ ok: boolean; status: number; body: string }> {
  const res = await fetch(uploadUrl(cfg), { method: 'POST', headers: headers(cfg), body: form });
  const body = await res.text();
  return { ok: res.ok, status: res.status, body };
}

export async function uploadSourcemap(
  cfg: UploadConfig,
  sm: ArktsSourcemap
): Promise<{ ok: boolean; status: number; body: string }> {
  const form = new FormData();
  form.set('event', JSON.stringify(sourcemapEvent(cfg)));
  form.set('source_map', fileBlob(sm.sourceMapPath), 'sourceMaps.map');
  if (sm.nameCachePath) {
    form.set('name_cache', fileBlob(sm.nameCachePath), 'nameCache.json');
  }
  return post(cfg, form);
}

export async function uploadSymbol(
  cfg: UploadConfig,
  sym: NativeSymbol
): Promise<{ ok: boolean; status: number; body: string }> {
  const form = new FormData();
  form.set('event', JSON.stringify(symbolFileEvent(cfg, sym)));
  form.set('symbol_file', fileBlob(sym.soPath), path.basename(sym.soPath));
  return post(cfg, form);
}
