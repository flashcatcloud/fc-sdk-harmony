# @flashcatcloud/hvigor-plugin

Uploads HarmonyOS debug symbols to FlashCat (fc-rum) so crash stacks are
symbolicated in the FlashCat console:

- **ArkTS** — `sourceMaps.map` (+ `nameCache.json` for obfuscated release builds)
  to de-obfuscate ArkTS/TS frames.
- **Native** — unstripped `.so` files (DWARF, keyed by GNU build-id) to resolve
  C/C++ frames from `hiAppEvent` native crashes.

Zero runtime dependencies (uses Node ≥18 built-in `fetch`/`FormData`).

## Usage (hvigor task)

In the module's `hvigorfile.ts`:

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { flashcatSymbolUploadPlugin } from '@flashcatcloud/hvigor-plugin';

export default {
  system: hapTasks,
  plugins: [
    flashcatSymbolUploadPlugin({
      endpoint: 'https://browser.flashcat.cloud', // staging: https://jira.flashcat.cloud
      apiKey: process.env.FLASHCAT_API_KEY ?? '',
      service: 'my-app',
      version: '1.0.0',
      enabled: process.env.FLASHCAT_UPLOAD === '1'   // upload only when explicitly asked
    })
  ]
};
```

Then, after a release build:

```sh
FLASHCAT_UPLOAD=1 FLASHCAT_API_KEY=*** \
  hvigorw uploadFlashcatSymbols --mode module -p module=entry@default -p product=default
```

The task is registered with `postDependencies: ['assembleHap','assembleHar']`, so
the sourcemap + native libs exist when it runs. A missing artifact or upload
failure is logged but never fails the build.

## Programmatic / CI use

```ts
import { uploadAll } from '@flashcatcloud/hvigor-plugin';
const result = await uploadAll('entry/build/default', {
  endpoint, apiKey, service, version, pluginVersion: '0.1.0'
}, console.log);
```

## Upload contract (must match fc-rum)

`POST {endpoint}/sourcemap/upload`, `multipart/form-data`, headers:

| Header | Value |
|---|---|
| `DD-API-KEY` | FlashCat API key (resolves the account) |
| `DD-EVP-ORIGIN` | `flashcat-hvigor-plugin` (routes to the HarmonyOS handler) |
| `DD-EVP-ORIGIN-VERSION` | plugin version |

ArkTS sourcemap upload — form fields:
- `event`: `{"type":"harmony_sourcemap","service","version","cli_version"}`
- `source_map`: the `sourceMaps.map` file
- `name_cache`: the `nameCache.json` file (optional; obfuscated builds only)

Native symbol upload — one request per `.so`, form fields:
- `event`: `{"type":"harmony_symbol_file","service","version","arch","lib_name","build_id"}`
- `symbol_file`: the unstripped `.so`

`arch` ∈ {`arm64`,`arm`,`x64`,`x86`}. `build_id` is the GNU build-id hex (the
same value fc-rum re-derives from the `.so` — verified identical across the
TypeScript and Go extractors). Build `.so` with `-Wl,--build-id` (the default for
HarmonyOS NDK) so this is present.

## Test

```sh
npm test   # node --experimental-strip-types --test test/*.test.ts  (no install needed for tests)
```
