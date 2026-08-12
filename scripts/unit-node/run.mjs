#!/usr/bin/env node
/**
 * Headless unit-test runner for the FlashCat HarmonyOS SDK.
 *
 * DevEco's Local Test executor is IDE-only; this runner makes the SAME hypium
 * test files executable under plain Node (CI-able on any machine):
 *   1. transpiles every src/main/ets + src/test .ets file with the TypeScript
 *      compiler (type-check is done separately by `hvigorw UnitTestBuild`);
 *   2. redirects @kit.* / @ohos* / @flashcatcloud/core imports to runtime
 *      shims (node:fs-backed fileIo, node:zlib-backed compression, in-memory
 *      preferences) so persistence/compression logic runs for real;
 *   3. executes each test file's default export with a hypium-compatible
 *      harness and exits non-zero on any failure.
 *
 * Usage: node scripts/unit-node/run.mjs [testFileFilter]
 */
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

const require = createRequire(import.meta.url);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..', '..');
const outRoot = path.join(repoRoot, '.node-tests');
const filter = process.argv[2] ?? '';

// TypeScript compiler shipped with DevEco (no npm install needed).
const TSC_CANDIDATES = [
  '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript',
  path.join(repoRoot, 'node_modules', 'typescript')
];
let ts = null;
for (const candidate of TSC_CANDIDATES) {
  try {
    ts = require(candidate);
    break;
  } catch (_e) { /* try next */ }
}
if (ts === null) {
  console.error('typescript compiler not found (DevEco ohpm bundle or node_modules)');
  process.exit(2);
}

const MODULES = ['flashcat-core', 'flashcat-rum', 'flashcat-crash', 'flashcat-trace', 'flashcat-axios'];

// ---- transpile ----
fs.rmSync(outRoot, { recursive: true, force: true });
fs.mkdirSync(outRoot, { recursive: true });

function transpileTree(srcDir, destDir) {
  if (!fs.existsSync(srcDir)) return;
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const from = path.join(srcDir, entry.name);
    if (entry.isDirectory()) {
      transpileTree(from, path.join(destDir, entry.name));
      continue;
    }
    if (!entry.name.endsWith('.ets') && !entry.name.endsWith('.ts')) continue;
    const source = fs.readFileSync(from, 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
        esModuleInterop: true
      },
      fileName: entry.name
    });
    const to = path.join(destDir, entry.name.replace(/\.ets$/, '.ts').replace(/\.ts$/, '.js'));
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.writeFileSync(to, output.outputText);
  }
}

for (const mod of MODULES) {
  transpileTree(path.join(repoRoot, mod, 'src', 'main', 'ets'), path.join(outRoot, mod, 'src', 'main', 'ets'));
  transpileTree(path.join(repoRoot, mod, 'src', 'test'), path.join(outRoot, mod, 'src', 'test'));
  const index = path.join(repoRoot, mod, 'Index.ets');
  if (fs.existsSync(index)) {
    const output = ts.transpileModule(fs.readFileSync(index, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
      fileName: 'Index.ets'
    });
    fs.writeFileSync(path.join(outRoot, mod, 'Index.js'), output.outputText);
  }
}

// ---- runtime module redirection ----
const shimDir = path.join(scriptDir, 'shims');
const Module = require('node:module');
const originalResolve = Module._resolveFilename;
const SHIM_MAP = {
  '@ohos/hypium': path.join(shimDir, 'hypium.js'),
  '@kit.AbilityKit': path.join(shimDir, 'kit-ability.js'),
  '@kit.ArkData': path.join(shimDir, 'kit-arkdata.js'),
  '@kit.ArkTS': path.join(shimDir, 'kit-arkts.js'),
  '@kit.ArkUI': path.join(shimDir, 'kit-arkui.js'),
  '@kit.BackgroundTasksKit': path.join(shimDir, 'kit-backgroundtasks.js'),
  '@kit.BasicServicesKit': path.join(shimDir, 'kit-basicservices.js'),
  '@kit.CoreFileKit': path.join(shimDir, 'kit-corefile.js'),
  '@kit.CryptoArchitectureKit': path.join(shimDir, 'kit-crypto.js'),
  '@kit.NetworkKit': path.join(shimDir, 'kit-network.js'),
  '@kit.PerformanceAnalysisKit': path.join(shimDir, 'kit-performance.js'),
  '@kit.RemoteCommunicationKit': path.join(shimDir, 'kit-rcp.js'),
  '@ohos.app.ability.appRecovery': path.join(shimDir, 'app-recovery.js'),
  '@flashcatcloud/core': path.join(outRoot, 'flashcat-core', 'Index.js'),
  '@flashcatcloud/trace': path.join(outRoot, 'flashcat-trace', 'Index.js')
};
Module._resolveFilename = function patched(request, ...rest) {
  if (SHIM_MAP[request] !== undefined) {
    return SHIM_MAP[request];
  }
  return originalResolve.call(this, request, ...rest);
};

// Isolated working dir for the node:fs-backed fileIo shim.
process.env.FLASHCAT_TEST_FS_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'flashcat-unit-'));

// ---- discover and run ----
const harness = require(path.join(shimDir, 'hypium.js'));
const testFiles = [];
for (const mod of MODULES) {
  const testDir = path.join(outRoot, mod, 'src', 'test');
  if (!fs.existsSync(testDir)) continue;
  for (const name of fs.readdirSync(testDir)) {
    if (!name.endsWith('.test.js')) continue;
    if (filter && !name.includes(filter)) continue;
    // Aggregator List.test files re-invoke sibling suites (IDE entry point);
    // running them alongside the individual files would double-count.
    if (name === 'List.test.js') {
      const source = fs.readFileSync(path.join(testDir, name), 'utf8');
      if (/require\("\.\/[^"]+\.test"\)/.test(source)) continue;
    }
    testFiles.push({ mod, file: path.join(testDir, name), name });
  }
}

let hadError = false;
for (const t of testFiles) {
  try {
    const suite = require(t.file);
    const entry = suite.default ?? suite;
    if (typeof entry === 'function') {
      entry();
    }
  } catch (e) {
    hadError = true;
    console.error(`LOAD FAIL ${t.mod}/${t.name}: ${e && e.stack ? e.stack.split('\n').slice(0, 4).join('\n') : e}`);
  }
}

harness.__run().then((summary) => {
  console.log(`\n${summary.passed} passed, ${summary.failed} failed, ${testFiles.length} files`);
  fs.rmSync(process.env.FLASHCAT_TEST_FS_ROOT, { recursive: true, force: true });
  process.exit(summary.failed > 0 || hadError ? 1 : 0);
});
