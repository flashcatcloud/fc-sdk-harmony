import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { archFromAbi, collectArktsSourcemap, collectNativeSymbols } from '../dist/collect.js';

test('archFromAbi maps Android ABI dir names to fc-rum arch tokens', () => {
  assert.equal(archFromAbi('arm64-v8a'), 'arm64');
  assert.equal(archFromAbi('armeabi-v7a'), 'arm');
  assert.equal(archFromAbi('x86_64'), 'x64');
  assert.equal(archFromAbi('x86'), 'x86');
  assert.equal(archFromAbi('weird'), 'weird');
});

function mkBuildDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fc-collect-'));
  // sourcemap in outputs (preferred) + an intermediates copy
  fs.mkdirSync(path.join(dir, 'outputs', 'default', 'mapping'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'outputs', 'default', 'mapping', 'sourceMaps.map'), '{"version":3}');
  fs.mkdirSync(path.join(dir, 'intermediates', 'loader_out'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'intermediates', 'loader_out', 'sourceMaps.map'), '{"version":3,"stale":true}');
  fs.writeFileSync(path.join(dir, 'outputs', 'default', 'mapping', 'nameCache.json'), '{}');
  // an unstripped .so under cmake/obj, plus a stripped copy (should be ignored) + a system lib
  const obj = path.join(dir, 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a');
  fs.mkdirSync(obj, { recursive: true });
  // copy the real fixture so build-id extraction works
  const fixture = path.join(path.dirname(new URL(import.meta.url).pathname), 'testdata', 'libfixture-arm64.so');
  fs.copyFileSync(fixture, path.join(obj, 'libentry.so'));
  fs.writeFileSync(path.join(obj, 'libc++_shared.so'), 'system');
  const stripped = path.join(dir, 'intermediates', 'stripped_native_libs', 'default', 'arm64-v8a');
  fs.mkdirSync(stripped, { recursive: true });
  fs.writeFileSync(path.join(stripped, 'libentry.so'), 'stripped');
  return dir;
}

test('collectArktsSourcemap prefers the outputs copy and finds nameCache', () => {
  const dir = mkBuildDir();
  const sm = collectArktsSourcemap(dir);
  assert.ok(sm);
  assert.ok(sm!.sourceMapPath.includes(`${path.sep}outputs${path.sep}`), 'prefers outputs copy');
  assert.ok(sm!.nameCachePath, 'finds nameCache.json');
});

test('collectArktsSourcemap returns null when absent', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fc-empty-'));
  assert.equal(collectArktsSourcemap(dir), null);
});

test('collectNativeSymbols picks unstripped .so, skips system libs and stripped copies', () => {
  const dir = mkBuildDir();
  const syms = collectNativeSymbols(dir);
  assert.equal(syms.length, 1, 'only libentry.so from cmake/obj');
  const s = syms[0];
  assert.equal(s.libName, 'libentry.so');
  assert.equal(s.arch, 'arm64');
  assert.ok(s.soPath.includes(`${path.sep}cmake${path.sep}`), 'uses the cmake/obj copy, not stripped');
  assert.ok(s.buildId, 'extracts a build-id from the unstripped .so');
});
