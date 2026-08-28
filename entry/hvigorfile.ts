import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { flashcatSymbolUploadPlugin } from '../hvigor-plugin/dist/index.js';

export default {
  system: hapTasks,
  plugins: [
    flashcatSymbolUploadPlugin({
      apiKey: process.env.FLASHCAT_API_KEY ?? '',
      // Must match what the demo reports at runtime, or symbolication cannot find
      // these files: service is DemoConfig's default, version is AppScope versionName.
      service: 'flashcat-harmony-demo',
      version: '0.1.1',
      enabled: process.env.FLASHCAT_UPLOAD === '1'
    })
  ]
};
