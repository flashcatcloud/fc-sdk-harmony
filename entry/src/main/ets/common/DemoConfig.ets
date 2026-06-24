import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';

const CONFIG_FILE: string = 'demo_config.json';
// Committed template with empty credentials. `demo_config.json` itself is
// gitignored (it holds live clientToken/applicationId), so a fresh checkout
// only ships the example — the loader falls back to it and init then surfaces
// a clear "Missing demo config fields" message until you fill it in.
const EXAMPLE_FILE: string = 'demo_config.example.json';
const DEFAULT_SERVICE: string = 'flashcat-harmony-demo';

export interface DemoConfig {
  readonly clientToken: string;
  readonly applicationId: string;
  readonly service: string;
}

/**
 * Loads demo-only SDK credentials from `resources/rawfile/demo_config.json`.
 * The production SDK modules do not depend on this; it only keeps the sample app
 * free of checked-in client tokens and application ids.
 */
export class DemoConfigLoader {
  static load(context: common.Context): DemoConfig {
    const primary: DemoConfig | undefined = DemoConfigLoader.tryLoad(context, CONFIG_FILE);
    if (primary !== undefined) {
      return primary;
    }
    const example: DemoConfig | undefined = DemoConfigLoader.tryLoad(context, EXAMPLE_FILE);
    if (example !== undefined) {
      return example;
    }
    throw new Error(`Failed to load resources/rawfile/${CONFIG_FILE} (and ${EXAMPLE_FILE}). ` +
      `Copy ${EXAMPLE_FILE} to ${CONFIG_FILE} and fill in clientToken/applicationId.`);
  }

  private static tryLoad(context: common.Context, file: string): DemoConfig | undefined {
    try {
      const content: Uint8Array = context.resourceManager.getRawFileContentSync(file);
      return DemoConfigLoader.parse(buffer.from(content.buffer).toString());
    } catch (e) {
      return undefined;
    }
  }

  static parse(jsonText: string): DemoConfig {
    const raw: Object = JSON.parse(jsonText) as Object;
    const data: Record<string, Object> = DemoConfigLoader.asRecord(raw);
    const service: string = DemoConfigLoader.stringField(data, 'service');
    return {
      clientToken: DemoConfigLoader.stringField(data, 'clientToken'),
      applicationId: DemoConfigLoader.stringField(data, 'applicationId'),
      service: service.length > 0 ? service : DEFAULT_SERVICE
    };
  }

  static missingRequiredFields(config: DemoConfig): string[] {
    const missing: string[] = [];
    if (config.clientToken.length === 0) {
      missing.push('clientToken');
    }
    if (config.applicationId.length === 0) {
      missing.push('applicationId');
    }
    return missing;
  }

  static configFileName(): string {
    return CONFIG_FILE;
  }

  private static asRecord(value: Object): Record<string, Object> {
    if (typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return {};
  }

  private static stringField(data: Record<string, Object>, key: string): string {
    const value: Object | undefined = data[key];
    return typeof value === 'string' ? value.trim() : '';
  }
}
