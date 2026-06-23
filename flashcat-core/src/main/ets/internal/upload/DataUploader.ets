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

export interface BatchUploader {
  upload(batch: Batch): Promise<UploadStatus>;
}

export interface UploadContext {
  env: string;
  service: string;
  version: string;
  source: string;
}

export type UploadContextProvider = () => UploadContext;

const SDK_VERSION: string = '0.1.0';
const DEFAULT_SOURCE: string = 'harmony';

/**
 * Sends a single NDJSON batch to the FlashCat intake.
 *
 * Contract (mirrors the fc-sdk-electron FlashCat intake):
 *   POST https://{site}/api/v2/rum
 *   Content-Type: text/plain;charset=UTF-8   (NDJSON body — NOT a JSON array)
 *   DD-API-KEY: <clientToken>
 * Sending application/json or a JSON-array body is rejected with HTTP 400.
 */
export class DataUploader implements BatchUploader {
  private readonly configuration: Configuration;
  private readonly trackPath: string;
  private readonly contextProvider: UploadContextProvider;

  constructor(configuration: Configuration, trackPath: string, contextProvider?: UploadContextProvider) {
    this.configuration = configuration;
    this.trackPath = trackPath; // e.g. "/api/v2/rum"
    this.contextProvider = contextProvider ?? (() => DataUploader.defaultContext(configuration));
  }

  private endpoint(): string {
    return DataUploader.endpointFor(this.configuration, this.trackPath, this.contextProvider);
  }

  static endpointFor(configuration: Configuration, trackPath: string, contextProvider?: UploadContextProvider): string {
    const host: string = configuration.customEndpoint.length > 0
      ? configuration.customEndpoint
      : intakeEndpoint(configuration.site);
    const baseEndpoint: string = `${host}${trackPath}`;
    const context: UploadContext = contextProvider !== undefined
      ? contextProvider()
      : DataUploader.defaultContext(configuration);
    const query: string = DataUploader.intakeQuery(context);
    if (query.length === 0) {
      return baseEndpoint;
    }
    const separator: string = baseEndpoint.indexOf('?') >= 0 ? '&' : '?';
    return `${baseEndpoint}${separator}${query}`;
  }

  private static defaultContext(configuration: Configuration): UploadContext {
    return {
      env: configuration.env,
      service: configuration.service ?? '',
      version: '',
      source: DEFAULT_SOURCE
    };
  }

  private static intakeQuery(context: UploadContext): string {
    const source: string = context.source.length > 0 ? context.source : DEFAULT_SOURCE;
    const tags: Array<string> = [`sdk_version:${SDK_VERSION}`];
    DataUploader.appendTag(tags, 'env', context.env);
    DataUploader.appendTag(tags, 'service', context.service);
    DataUploader.appendTag(tags, 'version', context.version);
    return `ddsource=${encodeURIComponent(source)}&ddtags=${encodeURIComponent(tags.join(','))}`;
  }

  private static appendTag(tags: Array<string>, key: string, value: string): void {
    if (value.length === 0) {
      return;
    }
    tags.push(`${key}:${value}`);
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
