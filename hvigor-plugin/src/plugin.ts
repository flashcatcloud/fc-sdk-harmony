import { uploadAll } from './index.ts';
import type { UploadConfig } from './upload.ts';

// The hvigor plugin API (@ohos/hvigor) is provided by DevEco at build time and is
// not a build-time dependency of this package. We model only the surface we use so
// the package type-checks standalone.
export interface HvigorNode {
  getNodePath(): string;
  registerTask(task: { name: string; run: () => void | Promise<void>; dependencies?: string[]; postDependencies?: string[] }): void;
}
export interface HvigorPlugin {
  pluginId: string;
  apply(node: HvigorNode): void;
}

export interface FlashcatPluginOptions {
  /** RUM ingest base URL. Optional — defaults to $FLASHCAT_ENDPOINT, else the SaaS
   *  ingest (https://browser.flashcat.cloud). Set it (or the env var) for staging /
   *  self-hosted. */
  endpoint?: string;
  apiKey: string;
  service: string;
  version: string;
  /** module build dir relative to the module root; default 'build/default'. */
  buildDir?: string;
  /** when false the task is registered but does nothing (e.g. debug builds). Default true. */
  enabled?: boolean;
  pluginVersion?: string;
}

/**
 * Registers an `uploadFlashcatSymbols` task on the module. Runs AFTER the module
 * is assembled (`default@PackageHap` / `default@PackageHar` produce the sourcemap
 * and native libs) and uploads ArkTS sourcemaps + native `.so` debug symbols.
 *
 * Wire it into a module's `hvigorfile.ts`:
 * ```ts
 * import { hapTasks } from '@ohos/hvigor-ohos-plugin';
 * import { flashcatSymbolUploadPlugin } from '@flashcatcloud/hvigor-plugin';
 * export default {
 *   system: hapTasks,
 *   plugins: [flashcatSymbolUploadPlugin({
 *     apiKey: process.env.FLASHCAT_API_KEY ?? '',
 *     service: 'my-app', version: '1.0.0',
 *     enabled: process.env.FLASHCAT_UPLOAD === '1'
 *   })]
 * };
 * ```
 * Run with: `hvigorw uploadFlashcatSymbols --mode module -p module=entry@default`.
 */
export function flashcatSymbolUploadPlugin(options: FlashcatPluginOptions): HvigorPlugin {
  return {
    pluginId: 'flashcat-symbol-upload',
    apply(node: HvigorNode): void {
      node.registerTask({
        name: 'uploadFlashcatSymbols',
        // hvigor semantics: `dependencies` are tasks that run BEFORE this task
        // (`postDependencies` would schedule this task before them — i.e. before
        // the build, uploading the previous build's symbols under the new version).
        dependencies: ['assembleHap', 'assembleHar'],
        run: async (): Promise<void> => {
          if (options.enabled === false) {
            return;
          }
          if (!options.apiKey) {
            // eslint-disable-next-line no-console
            console.warn('flashcat: FLASHCAT_API_KEY not set — skipping symbol upload.');
            return;
          }
          // endpoint may be omitted in config; fall back to env then the SaaS ingest.
          const endpoint = options.endpoint ?? process.env.FLASHCAT_ENDPOINT ?? 'https://browser.flashcat.cloud';
          const cfg: UploadConfig = {
            endpoint,
            apiKey: options.apiKey,
            service: options.service,
            version: options.version,
            pluginVersion: options.pluginVersion ?? '0.1.2' // keep in sync with package.json version
          };
          const buildDir = `${node.getNodePath()}/${options.buildDir ?? 'build/default'}`;
          // eslint-disable-next-line no-console
          await uploadAll(buildDir, cfg, (m) => console.log(m));
        }
      });
    }
  };
}
