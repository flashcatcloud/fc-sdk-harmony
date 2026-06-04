import { SdkCore } from '../api/SdkCore';

/** Holds named SdkCore instances. Supports the multi-instance pattern from Android. */
export class SdkCoreRegistry {
  static readonly DEFAULT_INSTANCE_NAME: string = 'flashcat-default';

  private readonly instances: Map<string, SdkCore> = new Map<string, SdkCore>();

  register(name: string, core: SdkCore): void {
    this.instances.set(name, core);
  }

  unregister(name: string): void {
    this.instances.delete(name);
  }

  get(name: string): SdkCore | null {
    return this.instances.get(name) ?? null;
  }

  has(name: string): boolean {
    return this.instances.has(name);
  }
}
