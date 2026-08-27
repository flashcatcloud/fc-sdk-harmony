# Changelog

## 0.2.0

Carries the changes first published as 0.1.4, which was withdrawn: removing an
option in a patch release meant everyone on the `^0.1.3` range picked it up on
their next install. Same changes, correct version — `^0.1.3` stays on 0.1.x, and
moving to 0.2.0 is a deliberate step.

- Fix `uploadFlashcatSymbols` breaking task-graph resolution: the task declared
  `dependencies: ['assembleHap','assembleHar']`, but a module has at most one of
  those, so the missing one failed the build. The task now declares no build
  dependencies — run it as its own hvigor invocation after a release build.
- **Breaking:** remove the `enabled` option. With no build dependencies the task
  runs only when it is named on the command line, so naming it *is* the switch; a
  second gate could only ever silently skip an upload that was explicitly asked
  for. Drop `enabled` (and the `FLASHCAT_UPLOAD` variable that fed it) from
  `hvigorfile.ts`. Every remaining skip path logs its reason.
- The build directory now follows the product being built (`-p product=beta` →
  `build/beta`), read from the project's OHOS app context. `buildDir` stays as an
  override for layouts that do not follow that convention; previously it defaulted
  to `build/default` and silently scanned the wrong directory for every other
  product.
- Log the directory being scanned and how it was chosen, and name that directory
  in the "no sourceMaps.map found" message, so a wrong build dir is visible in the
  build output instead of looking like missing sourcemap output.
- Run the upload task with `--no-daemon`. hvigor's daemon snapshots the
  environment when it is first started and refreshes only a fixed allowlist of
  variables, so a reused daemon can hand the plugin a stale or empty `process.env`
  — silently skipping the upload, or uploading under the previous version number.
- An empty `buildDir` now counts as unset instead of resolving to the module root.
  An unassigned `FLASHCAT_BUILD_DIR=` in CI reaches the option as `''`, and scanning
  the module root collects every product's sourcemap — uploading an arbitrary one
  under the current version, the same class of bug the product-aware default fixes.
- The "skipping symbol upload" warning now names the `apiKey` option rather than only
  the environment variable, and points at `--no-daemon` — the likeliest reason the
  value arrived empty.
- First tests for task registration and build-dir resolution (`plugin.ts` had none).

## 0.1.3

- Default symbol-upload host is now `https://ci.flashcat.cloud` (was
  `https://browser.flashcat.cloud`, which 404s — that host is RUM ingest only).
- Honour `FLASHCAT_SOURCEMAP_INTAKE_URL` first (same variable as Android /
  flashcat-cli); `FLASHCAT_ENDPOINT` remains a legacy alias and emits a warning.
- Explicit empty `endpoint` / empty env vars **skip** upload instead of falling
  back to SaaS. Values are validated with `new URL()` (http(s), no query/hash).
- Warn when the resolved host is a known RUM-ingest-only host
  (`browser.flashcat.cloud` / `jira.flashcat.cloud`).
- If the configured endpoint already ends with `/sourcemap/upload`, do not
  append the path again.
- `pluginVersion` fallback reads `package.json` (no hand-copied literal).

## 0.1.2

- Fix the `uploadFlashcatSymbols` task ordering: the task declared
  `postDependencies: ['assembleHap','assembleHar']`, which schedules it BEFORE
  the assemble tasks — so it uploaded the previous build's sourcemap and `.so`
  symbols under the new version number, and crashes on the new version could not
  be symbolicated. It now uses `dependencies`, so the assemble tasks run first.
- `pluginVersion` fallback reported to fc-rum tracks the package version (0.1.2).

## 0.1.1

- Publish as CommonJS (`"type": "commonjs"`) so hvigor can `require()` the plugin
  from `hvigorfile.ts`. 0.1.0 shipped as ESM and failed to load with
  `ERR_REQUIRE_ESM` — the documented integration was broken for every consumer.

## 0.1.0

- Initial release: upload HarmonyOS ArkTS `sourceMaps.map` (+ `nameCache.json`) and
  native `.so` debug symbols to fc-rum for crash symbolication, via the
  `uploadFlashcatSymbols` hvigor task.
