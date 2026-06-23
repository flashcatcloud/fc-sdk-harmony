import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { ConfigurationBuilder } from '../main/ets/config/Configuration';
import { DataUploader, UploadContext } from '../main/ets/internal/upload/DataUploader';

export default function dataUploaderTests(): void {
  describe('DataUploader', (): void => {
    it('addsSourceAndTagsToRumEndpoint', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const config = new ConfigurationBuilder('token', 'prod')
        .setService('checkout')
        .setCustomEndpoint('https://intake.example')
        .build();
      const context: UploadContext = {
        env: 'prod',
        service: 'checkout',
        version: '1.2.3',
        source: 'harmony'
      };

      const endpoint = DataUploader.endpointFor(config, '/api/v2/rum', () => context);

      expect(endpoint).assertEqual(
        'https://intake.example/api/v2/rum?ddsource=harmony&ddtags=sdk_version%3A0.1.0%2Cenv%3Aprod%2Cservice%3Acheckout%2Cversion%3A1.2.3'
      );
    });

    it('omitsEmptyTags', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const config = new ConfigurationBuilder('token', 'prod')
        .setCustomEndpoint('https://intake.example')
        .build();
      const context: UploadContext = {
        env: 'prod',
        service: '',
        version: '',
        source: 'harmony'
      };

      const endpoint = DataUploader.endpointFor(config, '/api/v2/rum', () => context);

      expect(endpoint).assertEqual(
        'https://intake.example/api/v2/rum?ddsource=harmony&ddtags=sdk_version%3A0.1.0%2Cenv%3Aprod'
      );
    });
  });
}
