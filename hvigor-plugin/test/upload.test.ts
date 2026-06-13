import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ORIGIN, TYPE_SOURCEMAP, TYPE_SYMBOL_FILE, sourcemapEvent, symbolFileEvent, type UploadConfig
} from '../src/upload.ts';
import type { NativeSymbol } from '../src/collect.ts';

const cfg: UploadConfig = {
  endpoint: 'https://browser.flashcat.cloud',
  apiKey: 'k',
  service: 'demo',
  version: '1.2.3',
  pluginVersion: '0.1.0'
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
  assert.equal(e.cli_version, '0.1.0');
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
