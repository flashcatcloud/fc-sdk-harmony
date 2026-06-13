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
  endpoint: string;
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
 *     endpoint: 'https://browser.flashcat.cloud',
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
        postDependencies: ['assembleHap', 'assembleHar'],
        run: async (): Promise<void> => {
          if (options.enabled === false) {
            return;
          }
          if (!options.apiKey) {
            // eslint-disable-next-line no-console
            console.warn('flashcat: FLASHCAT_API_KEY not set — skipping symbol upload.');
            return;
          }
          const cfg: UploadConfig = {
            endpoint: options.endpoint,
            apiKey: options.apiKey,
            service: options.service,
            version: options.version,
            pluginVersion: options.pluginVersion ?? '0.1.0'
          };
          const buildDir = `${node.getNodePath()}/${options.buildDir ?? 'build/default'}`;
          // eslint-disable-next-line no-console
          await uploadAll(buildDir, cfg, (m) => console.log(m));
        }
      });
    }
  };
}
