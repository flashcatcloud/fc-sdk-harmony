import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ORIGIN, TYPE_SOURCEMAP, TYPE_SYMBOL_FILE, sourcemapEvent, symbolFileEvent,
  resolveUploadEndpoint, resolveSourcemapUploadUrl,
  type UploadConfig
} from '../dist/upload.js';
import type { NativeSymbol } from '../dist/collect.js';

const cfg: UploadConfig = {
  endpoint: 'https://ci.flashcat.cloud',
  apiKey: 'k',
  service: 'demo',
  version: '1.2.3',
  pluginVersion: '0.1.3'
};

test('ORIGIN + event types are the agreed contract', () => {
  assert.equal(ORIGIN, 'flashcat-hvigor-plugin');
  assert.equal(TYPE_SOURCEMAP, 'harmony_sourcemap');
  assert.equal(TYPE_SYMBOL_FILE, 'harmony_symbol_file');
});

test('sourcemapEvent carries service/version/type', () => {
  const e = sourcemapEvent(cfg);
  assert.equal(e.type, 'harmony_sourcemap');
  assert.equal(e.service, 'demo');
  assert.equal(e.version, '1.2.3');
  assert.equal(e.cli_version, '0.1.3');
});

test('symbolFileEvent includes arch, lib_name and build_id when present', () => {
  const sym: NativeSymbol = { soPath: '/x/libentry.so', libName: 'libentry.so', arch: 'arm64', buildId: 'deadbeef' };
  const e = symbolFileEvent(cfg, sym);
  assert.equal(e.type, 'harmony_symbol_file');
  assert.equal(e.arch, 'arm64');
  assert.equal(e.lib_name, 'libentry.so');
  assert.equal(e.build_id, 'deadbeef');
});

test('symbolFileEvent omits build_id when the .so has none', () => {
  const sym: NativeSymbol = { soPath: '/x/libentry.so', libName: 'libentry.so', arch: 'arm64', buildId: null };
  const e = symbolFileEvent(cfg, sym);
  assert.equal('build_id' in e, false);
});

test('resolveUploadEndpoint defaults to SaaS when nothing is set', () => {
  const r = resolveUploadEndpoint(undefined, {});
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.equal(r.endpoint, 'https://ci.flashcat.cloud');
    assert.deepEqual(r.warnings, []);
  }
});

test('resolveUploadEndpoint prefers FLASHCAT_SOURCEMAP_INTAKE_URL over FLASHCAT_ENDPOINT', () => {
  const r = resolveUploadEndpoint(undefined, {
    FLASHCAT_ENDPOINT: 'https://legacy.example.com/',
    FLASHCAT_SOURCEMAP_INTAKE_URL: 'https://private.example.com'
  });
  assert.equal(r.ok, true);
  if (r.ok) assert.equal(r.endpoint, 'https://private.example.com');
});

test('resolveUploadEndpoint uses explicit option over env', () => {
  const r = resolveUploadEndpoint('https://explicit.example.com/', {
    FLASHCAT_SOURCEMAP_INTAKE_URL: 'https://private.example.com'
  });
  assert.equal(r.ok, true);
  if (r.ok) assert.equal(r.endpoint, 'https://explicit.example.com');
});

test('resolveUploadEndpoint skips on explicit empty endpoint (no SaaS fallback)', () => {
  const r = resolveUploadEndpoint('', { FLASHCAT_SOURCEMAP_INTAKE_URL: 'https://private.example.com' });
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.reason, /endpoint is empty/);
});

test('resolveUploadEndpoint skips on whitespace-only env (no SaaS fallback)', () => {
  const r = resolveUploadEndpoint(undefined, { FLASHCAT_SOURCEMAP_INTAKE_URL: '   ' });
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.reason, /FLASHCAT_SOURCEMAP_INTAKE_URL is empty/);
});

test('resolveUploadEndpoint warns on legacy FLASHCAT_ENDPOINT', () => {
  const r = resolveUploadEndpoint(undefined, { FLASHCAT_ENDPOINT: 'https://legacy.example.com' });
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.equal(r.endpoint, 'https://legacy.example.com');
    assert.ok(r.warnings.some((w) => w.includes('FLASHCAT_ENDPOINT is deprecated')));
  }
});

test('resolveUploadEndpoint warns on RUM-ingest-only hosts', () => {
  const r = resolveUploadEndpoint('https://browser.flashcat.cloud', {});
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.ok(r.warnings.some((w) => w.includes('RUM ingest host')));
  }
});

test('resolveUploadEndpoint rejects invalid URL / missing scheme / query', () => {
  assert.equal(resolveUploadEndpoint('not a url', {}).ok, false);
  assert.equal(resolveUploadEndpoint('ci.flashcat.cloud', {}).ok, false);
  assert.equal(resolveUploadEndpoint('https://ci.flashcat.cloud?x=1', {}).ok, false);
  assert.equal(resolveUploadEndpoint('ftp://ci.flashcat.cloud', {}).ok, false);
});

test('resolveSourcemapUploadUrl appends path unless already present', () => {
  assert.equal(
    resolveSourcemapUploadUrl('https://ci.flashcat.cloud'),
    'https://ci.flashcat.cloud/sourcemap/upload'
  );
  assert.equal(
    resolveSourcemapUploadUrl('https://rum.example.com/sourcemap/upload'),
    'https://rum.example.com/sourcemap/upload'
  );
  assert.equal(
    resolveSourcemapUploadUrl('https://rum.example.com/sourcemap/upload/'),
    'https://rum.example.com/sourcemap/upload'
  );
});
