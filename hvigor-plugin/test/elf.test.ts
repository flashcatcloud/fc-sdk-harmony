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

test('extractElfBuildId never throws on malformed/fuzzed ELF-ish input', () => {
  const real = fs.readFileSync(fixture);
  // A valid header followed by corrupted section tables, and random byte soups.
  const cases: Buffer[] = [
    Buffer.alloc(0),
    Buffer.alloc(64, 0xff),
    Buffer.concat([real.subarray(0, 40), Buffer.alloc(8, 0xff)]), // bogus section offsets
  ];
  for (let seed = 0; seed < 200; seed++) {
    const n = (seed * 7) % 256;
    const b = Buffer.alloc(n);
    for (let i = 0; i < n; i++) {
      b[i] = (i * 31 + seed * 17) & 0xff;
    }
    b[0] = 0x7f; b[1] = 0x45; b[2] = 0x4c; b[3] = 0x46; // ELF magic so it enters the parser
    cases.push(b);
  }
  for (const c of cases) {
    // Must return string|null, never throw.
    const r = extractElfBuildId(c);
    assert.ok(r === null || typeof r === 'string');
  }
});
