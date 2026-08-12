# Changelog

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
