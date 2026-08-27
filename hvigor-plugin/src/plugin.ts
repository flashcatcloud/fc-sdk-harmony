import { createRequire } from 'node:module';
import { uploadAll } from './index.ts';
import { resolveUploadEndpoint, type UploadConfig } from './upload.ts';

// Keep the reported plugin version in sync with package.json (no hand-copied literal).
const requirePackageJson = createRequire(__filename);
const PACKAGE_VERSION: string = (requirePackageJson('../package.json') as { version: string }).version;

/** Plugin id hvigor registers the OHOS app (project-level) context under. */
const OHOS_APP_PLUGIN_ID = 'com.ohos.app';

/** Product hvigor builds when `-p product=` is omitted. */
const DEFAULT_PRODUCT = 'default';

// The hvigor plugin API (@ohos/hvigor) is provided by DevEco at build time and is
// not a build-time dependency of this package. We model only the surface we use so
// the package type-checks standalone. `getParentNode`/`getContext` are optional
// because a caller may hand us a minimal node (tests, non-OHOS hvigor projects).
export interface HvigorNode {
  getNodePath(): string;
  getParentNode?(): HvigorNode | undefined;
  getContext?(pluginId: string): unknown;
  registerTask(task: { name: string; run: () => void | Promise<void> }): void;
}
export interface HvigorPlugin {
  pluginId: string;
  apply(node: HvigorNode): void;
}

export interface FlashcatPluginOptions {
  /** Symbol-upload base URL. Optional — when omitted, uses $FLASHCAT_SOURCEMAP_INTAKE_URL,
   *  then legacy $FLASHCAT_ENDPOINT, then SaaS `https://ci.flashcat.cloud`.
   *  When set (including empty string), that value is used alone: empty/invalid skips
   *  upload instead of falling back to SaaS. Private deploys: scheme + host, no path. */
  endpoint?: string;
  apiKey: string;
  service: string;
  version: string;
  /** Module build dir, relative to the module root. Optional — by default it follows
   *  the product being built (`-p product=beta` → `build/beta`). Set it only when the
   *  artifacts are somewhere that does not follow that layout. An empty string counts
   *  as unset: an unassigned `FLASHCAT_BUILD_DIR=` in CI must not turn into a scan of
   *  the whole module root, which would collect another product's sourcemap. */
  buildDir?: string;
  pluginVersion?: string;
}

/**
 * The product hvigor is currently building (`-p product=beta`), read from the
 * project node's OHOS app context. Returns null when that context is not
 * reachable, so the caller can fall back to the default product and say so.
 */
function currentProductName(node: HvigorNode): string | null {
  try {
    const context = node.getParentNode?.()?.getContext?.(OHOS_APP_PLUGIN_ID) as
      | { getCurrentProduct?: () => { getProductName?: () => string } | undefined }
      | undefined;
    const name = context?.getCurrentProduct?.()?.getProductName?.();
    return typeof name === 'string' && name.length > 0 ? name : null;
  } catch {
    return null;
  }
}

/**
 * Absolute build-artifact dir to scan, plus how it was decided. The `how` string is
 * logged so a wrong directory is visible in the build output instead of surfacing
 * later as an unexplained "no sourceMaps.map found".
 */
export function resolveBuildDir(node: HvigorNode, explicit?: string): { dir: string; how: string } {
  const moduleRoot = node.getNodePath();
  if (explicit !== undefined && explicit !== '') {
    return { dir: `${moduleRoot}/${explicit}`, how: 'buildDir option' };
  }
  const product = currentProductName(node);
  if (product === null) {
    return {
      dir: `${moduleRoot}/build/${DEFAULT_PRODUCT}`,
      how: `product unavailable, assuming '${DEFAULT_PRODUCT}' — pass buildDir if this is wrong`
    };
  }
  return { dir: `${moduleRoot}/build/${product}`, how: `product '${product}'` };
}

/**
 * Registers an `uploadFlashcatSymbols` task on the module, which uploads ArkTS
 * sourcemaps + native `.so` debug symbols for the product being built.
 *
 * The task declares no build dependencies: run it after a release build, as its
 * own hvigor invocation. (Declaring `assembleHap`/`assembleHar` would break every
 * module that has only one of them.)
 *
 * Wire it into a module's `hvigorfile.ts`:
 * ```ts
 * import { hapTasks } from '@ohos/hvigor-ohos-plugin';
 * import { flashcatSymbolUploadPlugin } from '@flashcatcloud/hvigor-plugin';
 * export default {
 *   system: hapTasks,
 *   plugins: [flashcatSymbolUploadPlugin({
 *     apiKey: process.env.FLASHCAT_API_KEY ?? '',
 *     service: 'my-app', version: '1.0.0'
 *   })]
 * };
 * ```
 * Run with `--no-daemon`: hvigor's daemon snapshots the environment when it is
 * first started and does not refresh it, so without that flag a reused daemon can
 * hand the plugin a stale (or empty) `process.env`.
 * `hvigorw uploadFlashcatSymbols --no-daemon --mode module -p module=entry@default`.
 */
export function flashcatSymbolUploadPlugin(options: FlashcatPluginOptions): HvigorPlugin {
  return {
    pluginId: 'flashcat-symbol-upload',
    apply(node: HvigorNode): void {
      node.registerTask({
        name: 'uploadFlashcatSymbols',
        run: async (): Promise<void> => {
          if (!options.apiKey) {
            // eslint-disable-next-line no-console
            console.warn(
              'flashcat: apiKey is empty — skipping symbol upload. Set FLASHCAT_API_KEY, ' +
                'and pass --no-daemon so hvigor does not hand the plugin a cached environment.'
            );
            return;
          }
          const resolved = resolveUploadEndpoint(options.endpoint);
          for (const w of resolved.warnings) {
            // eslint-disable-next-line no-console
            console.warn(`flashcat: ${w}`);
          }
          if (!resolved.ok) {
            // eslint-disable-next-line no-console
            console.warn(`flashcat: ${resolved.reason}`);
            return;
          }
          const cfg: UploadConfig = {
            endpoint: resolved.endpoint,
            apiKey: options.apiKey,
            service: options.service,
            version: options.version,
            pluginVersion: options.pluginVersion ?? PACKAGE_VERSION
          };
          const { dir, how } = resolveBuildDir(node, options.buildDir);
          // eslint-disable-next-line no-console
          console.log(`flashcat: scanning ${dir} (${how})`);
          // eslint-disable-next-line no-console
          await uploadAll(dir, cfg, (m) => console.log(m));
        }
      });
    }
  };
}
