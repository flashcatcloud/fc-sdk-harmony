import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(dirname(fileURLToPath(import.meta.url)));

function read(path) {
  return readFileSync(join(root, path), 'utf8');
}

const checks = [
  {
    name: 'PHASE-1 status reflects implemented-but-uncompiled state',
    file: 'docs/PHASE-1.md',
    assert: (text) =>
      text.includes('已实现') &&
      text.includes('尚未编译') &&
      !text.includes('尚未实现')
  },
  {
    name: 'PHASE-1 does not promise phase-1 trace_id stamping on View/Error',
    file: 'docs/PHASE-1.md',
    assert: (text) =>
      !text.includes('trace_id 回写到当前 View/Error') &&
      !text.includes('trace_id 写到当前 View / Error') &&
      text.includes('ResourceEvent')
  },
  {
    name: 'Trace public docs describe propagation, not client span upload or View/Error stamping',
    file: 'flashcat-trace/src/main/ets/FlashcatTrace.ets',
    assert: (text) =>
      text.includes('span data') &&
      text.includes('only the header') &&
      !text.includes('writes the trace_id onto RUM View/Error')
  },
  {
    name: 'Trace interceptor docs do not claim View/Error correlation',
    file: 'flashcat-trace/src/main/ets/internal/TraceInterceptor.ets',
    assert: (text) =>
      text.includes("Publishes the latest trace_id into core context under the 'trace' feature key") &&
      !text.includes('RUM can correlate View/Error events')
  },
  {
    name: 'RUM assembler documents ResourceEvent as the phase-2 correlation point',
    file: 'flashcat-rum/src/main/ets/internal/assembly/RumEventAssembler.ets',
    assert: (text) =>
      text.includes('Proper correlation belongs on ResourceEvents') &&
      text.includes('_dd.trace_id / _dd.span_id')
  }
];

const failures = [];

for (const check of checks) {
  const text = read(check.file);
  if (!check.assert(text)) {
    failures.push(`${check.name} (${check.file})`);
  }
}

if (failures.length > 0) {
  console.error('Phase-1 consistency checks failed:');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Phase-1 consistency checks passed (${checks.length} checks).`);
