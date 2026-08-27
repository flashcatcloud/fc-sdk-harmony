import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { flashcatSymbolUploadPlugin } from '../hvigor-plugin/dist/index.js';

export default {
  system: hapTasks,
  plugins: [
    flashcatSymbolUploadPlugin({
      apiKey: process.env.FLASHCAT_API_KEY ?? '',
      service: 'fc-sdk-harmony-demo',
      version: '0.1.0',
      enabled: process.env.FLASHCAT_UPLOAD === '1'
    })
  ]
};
