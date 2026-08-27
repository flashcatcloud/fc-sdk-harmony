# @flashcatcloud/hvigor-plugin

Uploads HarmonyOS debug symbols to FlashCat (fc-rum) so crash stacks are
symbolicated in the FlashCat console:

- **ArkTS** — `sourceMaps.map` (+ `nameCache.json` for obfuscated release builds)
  to de-obfuscate ArkTS/TS frames.
- **Native** — unstripped `.so` files (DWARF, keyed by GNU build-id) to resolve
  C/C++ frames from `hiAppEvent` native crashes.

Zero runtime dependencies (uses Node ≥18 built-in `fetch`/`FormData`).

## Install

The plugin is published on **npm**, not ohpm. Declare it in
`hvigor/hvigor-config.json5` — hvigor fetches it from npm itself:

```json5
{
  "modelVersion": "5.0.0",
  "dependencies": {
    "@flashcatcloud/hvigor-plugin": "0.1.4"
  }
}
```

You can install it with npm instead, but a HarmonyOS project has no root
`package.json`, and `npm install` walks *up* the directory tree looking for one —
so run `npm init -y` in the project root first, or npm will install into whatever
unrelated project it finds in a parent directory (often your home directory):

```sh
npm init -y                                  # only if there is no root package.json
npm install -D @flashcatcloud/hvigor-plugin
```

Pin the exact version and commit the lock file: the plugin has zero runtime
dependencies, so the lock stays a few lines.

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
      version: '1.0.0'
    })
  ]
};
```

Then, after a release build, run the task as its own hvigor invocation:

```sh
FLASHCAT_API_KEY=*** \
  hvigorw uploadFlashcatSymbols --no-daemon \
  --mode module -p module=entry@beta -p product=beta
```

`--no-daemon` is not optional if you configure the plugin from environment
variables. hvigor builds through a long-lived daemon process, which copies the
environment once when it is *created* and afterwards refreshes only a fixed
allowlist (`DEVECO_SDK_HOME`, `OHOS_BASE_SDK_HOME`, and two incremental-build
flags). A reused daemon therefore sees the environment of whoever started it — an
IDE build, or an earlier command — not the one you just typed. The failure is easy
to miss: `FLASHCAT_API_KEY` reads as unset and the task skips with only a warning,
or a stale version uploads the symbols under the wrong version number. Values
written directly into `hvigorfile.ts` are not affected.

Endpoint resolution (first match wins):

1. `endpoint` option — if provided (even as `''`), it is the only source; empty/invalid **skips** upload (no SaaS fallback)
2. `FLASHCAT_SOURCEMAP_INTAKE_URL` (preferred for private deploys; same name as Android / flashcat-cli)
3. Legacy `FLASHCAT_ENDPOINT` (deprecated; emits a warning — historically often set to the RUM host `browser.flashcat.cloud`, which 404s on symbol upload)
4. SaaS default `https://ci.flashcat.cloud`

Do **not** use `browser.flashcat.cloud` / `jira.flashcat.cloud` for symbol upload — those are RUM ingest hosts only.

The task declares no build dependencies, so it works on HAP, HAR and HSP modules
alike — a module has at most one of `assembleHap`/`assembleHar`, and naming both
breaks task-graph resolution for every module. Build first, then run the upload
task. A missing artifact or an upload failure is logged but never fails the build,
so read the log: `flashcat: sourcemap upload OK (200)` is the success line.

The directory scanned follows the product being built (`-p product=beta` →
`<module>/build/beta`), read from the project's OHOS app context. Pass `buildDir`
only if your artifacts live somewhere else. Either way the resolved directory is
logged (`flashcat: scanning <dir> (...)`) so a wrong guess is visible immediately.

## Programmatic / CI use

```ts
import { uploadAll } from '@flashcatcloud/hvigor-plugin';
const result = await uploadAll('entry/build/default', {
  endpoint: process.env.FLASHCAT_SOURCEMAP_INTAKE_URL || 'https://ci.flashcat.cloud',
  apiKey, service, version, pluginVersion: '0.1.4'
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
