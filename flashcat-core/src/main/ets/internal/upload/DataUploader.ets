import { http } from '@kit.NetworkKit';
import { Configuration } from '../../config/Configuration';
import { intakeEndpoint } from '../../FlashcatSite';
import { Batch } from '../persistence/FilePersistenceStrategy';
import { FlashcatLog } from '../FlashcatLog';

export enum UploadStatus {
  SUCCESS,
  RETRY,   // transient (timeout / 408 / 429 / 5xx / network) — keep the batch, back off
  DROP     // permanent (other 4xx) — discard the batch
}

const SDK_VERSION: string = '0.1.0';

/**
 * Sends a single NDJSON batch to the FlashCat intake.
 *
 * Contract (mirrors the fc-sdk-electron FlashCat intake):
 *   POST https://{site}/api/v2/rum
 *   Content-Type: text/plain;charset=UTF-8   (NDJSON body — NOT a JSON array)
 *   DD-API-KEY: <clientToken>
 * Sending application/json or a JSON-array body is rejected with HTTP 400.
 */
export class DataUploader {
  private readonly configuration: Configuration;
  private readonly trackPath: string;

  constructor(configuration: Configuration, trackPath: string) {
    this.configuration = configuration;
    this.trackPath = trackPath; // e.g. "/api/v2/rum"
  }

  private endpoint(): string {
    const host: string = this.configuration.customEndpoint.length > 0
      ? this.configuration.customEndpoint
      : intakeEndpoint(this.configuration.site);
    return `${host}${this.trackPath}`;
  }

  async upload(batch: Batch): Promise<UploadStatus> {
    const request = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'text/plain;charset=UTF-8',
        'DD-API-KEY': this.configuration.clientToken,
        'User-Agent': `flashcat-sdk-harmony/${SDK_VERSION}`
      };
      const response = await request.request(this.endpoint(), {
        method: http.RequestMethod.POST,
        header,
        extraData: batch.data,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30000,
        readTimeout: 30000
      });
      FlashcatLog.d(`upload: POST ${this.trackPath} -> ${response.responseCode} (${batch.data.length} bytes)`);
      return DataUploader.statusFor(response.responseCode);
    } catch (e) {
      FlashcatLog.e(`upload: POST ${this.trackPath} failed: ${e instanceof Error ? e.message : 'network error'}`);
      return UploadStatus.RETRY; // network error
    } finally {
      request.destroy();
    }
  }

  private static statusFor(code: number): UploadStatus {
    if (code >= 200 && code < 300) {
      return UploadStatus.SUCCESS;
    }
    // Auth (401/403) is treated as transient: a misconfigured token must NOT cause
    // silent permanent data loss. The disk quota bounds retention if it never recovers.
    if (code === 401 || code === 403 || code === 408 || code === 429 || code >= 500) {
      return UploadStatus.RETRY;
    }
    // Other 4xx (400/413/…) mean the payload will never be accepted — drop it.
    return UploadStatus.DROP;
  }
}
