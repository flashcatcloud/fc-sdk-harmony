import { test } from 'node:test';
import assert from 'node:assert/strict';
import { flashcatSymbolUploadPlugin, resolveBuildDir, type HvigorNode } from '../dist/plugin.js';

interface RegisteredTask {
  name: string;
  run: () => void | Promise<void>;
}

/** Minimal hvigor node stub. `product` null models a node with no OHOS app context. */
function fakeNode(modulePath: string, product: string | null): HvigorNode & { tasks: RegisteredTask[] } {
  const tasks: RegisteredTask[] = [];
  const projectNode: HvigorNode = {
    getNodePath: () => '/project',
    registerTask: () => {},
    getContext: (pluginId: string) =>
      pluginId === 'com.ohos.app' && product !== null
        ? { getCurrentProduct: () => ({ getProductName: () => product }) }
        : undefined
  };
  return {
    tasks,
    getNodePath: () => modulePath,
    getParentNode: () => projectNode,
    getContext: () => undefined,
    registerTask: (t) => {
      tasks.push(t as RegisteredTask);
    }
  };
}

const options = { apiKey: 'k', service: 'demo', version: '1.2.3' };

test('registers uploadFlashcatSymbols with no build-task dependencies', () => {
  // 0.1.3 declared dependencies: ['assembleHap','assembleHar']. Every module has at
  // most one of those, so the missing one broke task-graph resolution.
  const node = fakeNode('/project/entry', 'default');
  flashcatSymbolUploadPlugin(options).apply(node);

  assert.equal(node.tasks.length, 1);
  assert.equal(node.tasks[0].name, 'uploadFlashcatSymbols');
  assert.ok(!('dependencies' in node.tasks[0]), 'must not declare build-task dependencies');
  assert.ok(!('postDependencies' in node.tasks[0]), 'must not declare postDependencies');
});

test('plugin id is stable', () => {
  assert.equal(flashcatSymbolUploadPlugin(options).pluginId, 'flashcat-symbol-upload');
});

test('build dir follows the product being built', () => {
  const r = resolveBuildDir(fakeNode('/project/entry', 'beta'));
  assert.equal(r.dir, '/project/entry/build/beta');
  assert.match(r.how, /beta/);
});

test('build dir falls back to the default product, and says so', () => {
  const r = resolveBuildDir(fakeNode('/project/entry', null));
  assert.equal(r.dir, '/project/entry/build/default');
  assert.match(r.how, /buildDir/, 'the fallback must tell the user how to override it');
});

test('explicit buildDir wins over the product', () => {
  const r = resolveBuildDir(fakeNode('/project/entry', 'beta'), 'build/custom');
  assert.equal(r.dir, '/project/entry/build/custom');
  assert.equal(r.how, 'buildDir option');
});

test('an empty buildDir counts as unset, not as the module root', () => {
  // An unassigned FLASHCAT_BUILD_DIR= reaches the option as ''. Scanning the module
  // root would collect every product's sourcemap and upload an arbitrary one.
  const r = resolveBuildDir(fakeNode('/project/entry', 'beta'), '');
  assert.equal(r.dir, '/project/entry/build/beta');
  assert.match(r.how, /beta/);
});

test('missing api key is a no-op, never throws', async () => {
  const noKey = fakeNode('/project/entry', 'default');
  flashcatSymbolUploadPlugin({ ...options, apiKey: '' }).apply(noKey);
  await noKey.tasks[0].run();
});
