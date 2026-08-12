# @flashcatcloud/hvigor-plugin

Uploads HarmonyOS debug symbols to FlashCat (fc-rum) so crash stacks are
symbolicated in the FlashCat console:

- **ArkTS** — `sourceMaps.map` (+ `nameCache.json` for obfuscated release builds)
  to de-obfuscate ArkTS/TS frames.
- **Native** — unstripped `.so` files (DWARF, keyed by GNU build-id) to resolve
  C/C++ frames from `hiAppEvent` native crashes.

Zero runtime dependencies (uses Node ≥18 built-in `fetch`/`FormData`).

## Install

The plugin is published on **npm**, not ohpm. Install it as a devDependency in
the project root `package.json` (not `oh-package.json5`):

```sh
npm install -D @flashcatcloud/hvigor-plugin
```

Alternatively, declare it in `hvigor/hvigor-config.json5` `dependencies` —
hvigor still fetches it from npm:

```json5
{
  "modelVersion": "5.0.0",
  "dependencies": {
    "@flashcatcloud/hvigor-plugin": "^0.1.3"
  }
}
```

## Usage (hvigor task)

In the module's `hvigorfile.ts`:

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { flashcatSymbolUploadPlugin } from '@flashcatcloud/hvigor-plugin';

export default {
  system: hapTasks,
  plugins: [
    flashcatSymbolUploadPlugin({
      // Omit endpoint for SaaS (defaults to https://ci.flashcat.cloud).
      // Private deploy: set FLASHCAT_SOURCEMAP_INTAKE_URL=https://rum.example.com
      // (scheme + host, no path), or pass endpoint: 'https://rum.example.com'.
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

Endpoint resolution (first match wins):

1. `endpoint` option — if provided (even as `''`), it is the only source; empty/invalid **skips** upload (no SaaS fallback)
2. `FLASHCAT_SOURCEMAP_INTAKE_URL` (preferred for private deploys; same name as Android / flashcat-cli)
3. Legacy `FLASHCAT_ENDPOINT` (deprecated; emits a warning — historically often set to the RUM host `browser.flashcat.cloud`, which 404s on symbol upload)
4. SaaS default `https://ci.flashcat.cloud`

Do **not** use `browser.flashcat.cloud` / `jira.flashcat.cloud` for symbol upload — those are RUM ingest hosts only.

The task is registered with `dependencies: ['assembleHap','assembleHar']` (it runs
after the assemble tasks), so the sourcemap + native libs exist when it runs. A missing artifact or upload
failure is logged but never fails the build.

## Programmatic / CI use

```ts
import { uploadAll } from '@flashcatcloud/hvigor-plugin';
const result = await uploadAll('entry/build/default', {
  endpoint: process.env.FLASHCAT_SOURCEMAP_INTAKE_URL || 'https://ci.flashcat.cloud',
  apiKey, service, version, pluginVersion: '0.1.3'
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
