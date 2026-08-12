import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ORIGIN, TYPE_SOURCEMAP, TYPE_SYMBOL_FILE, sourcemapEvent, symbolFileEvent,
  resolveUploadEndpoint, resolveSourcemapUploadUrl, DEFAULT_UPLOAD_ENDPOINT,
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

test('resolveUploadEndpoint prefers explicit option, then FLASHCAT_SOURCEMAP_INTAKE_URL, then FLASHCAT_ENDPOINT, then SaaS', () => {
  const prevIntake = process.env.FLASHCAT_SOURCEMAP_INTAKE_URL;
  const prevLegacy = process.env.FLASHCAT_ENDPOINT;
  try {
    delete process.env.FLASHCAT_SOURCEMAP_INTAKE_URL;
    delete process.env.FLASHCAT_ENDPOINT;
    assert.equal(resolveUploadEndpoint(), DEFAULT_UPLOAD_ENDPOINT);
    assert.equal(DEFAULT_UPLOAD_ENDPOINT, 'https://ci.flashcat.cloud');

    process.env.FLASHCAT_ENDPOINT = 'https://legacy.example.com/';
    assert.equal(resolveUploadEndpoint(), 'https://legacy.example.com');

    process.env.FLASHCAT_SOURCEMAP_INTAKE_URL = 'https://private.example.com';
    assert.equal(resolveUploadEndpoint(), 'https://private.example.com');

    assert.equal(resolveUploadEndpoint('https://explicit.example.com/'), 'https://explicit.example.com');
  } finally {
    if (prevIntake === undefined) delete process.env.FLASHCAT_SOURCEMAP_INTAKE_URL;
    else process.env.FLASHCAT_SOURCEMAP_INTAKE_URL = prevIntake;
    if (prevLegacy === undefined) delete process.env.FLASHCAT_ENDPOINT;
    else process.env.FLASHCAT_ENDPOINT = prevLegacy;
  }
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
