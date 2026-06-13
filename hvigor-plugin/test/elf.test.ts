import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractElfBuildId } from '../src/elf.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = path.join(here, 'testdata', 'libfixture-arm64.so');

test('extractElfBuildId reads a GNU build-id from a real arm64 .so', () => {
  const data = fs.readFileSync(fixture);
  const id = extractElfBuildId(data);
  assert.ok(id, 'expected a build-id from the fixture .so');
  assert.match(id as string, /^[0-9a-f]+$/, 'build-id is lowercase hex');
  assert.ok((id as string).length >= 32, 'GNU build-id is normally >= 16 bytes');
});

test('extractElfBuildId returns null for a non-ELF buffer', () => {
  assert.equal(extractElfBuildId(Buffer.from('not an elf file')), null);
});

test('extractElfBuildId returns null for a truncated ELF header', () => {
  const buf = Buffer.from([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01]);
  assert.equal(extractElfBuildId(buf), null);
});
