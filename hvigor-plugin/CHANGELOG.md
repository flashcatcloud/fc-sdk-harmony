# Changelog

## 0.1.1

- Publish as CommonJS (`"type": "commonjs"`) so hvigor can `require()` the plugin
  from `hvigorfile.ts`. 0.1.0 shipped as ESM and failed to load with
  `ERR_REQUIRE_ESM` — the documented integration was broken for every consumer.

## 0.1.0

- Initial release: upload HarmonyOS ArkTS `sourceMaps.map` (+ `nameCache.json`) and
  native `.so` debug symbols to fc-rum for crash symbolication, via the
  `uploadFlashcatSymbols` hvigor task.
