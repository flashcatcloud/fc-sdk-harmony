import { common } from '@kit.AbilityKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { RumErrorSource } from '@flashcatcloud/rum';
import { FlashcatTrace } from '@flashcatcloud/trace';
import testNapi from 'libentry.so';
import { DemoSdk } from '../common/DemoSdk';

/**
 * FlashCat SDK manual-verification harness. Every button maps to one telemetry
 * path so you can confirm it on a device + a proxy (Charles) + the FlashCat
 * console: views, resources, errors, and crashes (native + ArkTS + freeze).
 */
@Entry
@Component
struct Index {
  @State useProd: boolean = false;
  @State initialized: boolean = false;
  @State statusText: string = 'SDK not initialized';
  @State log: string = '';

  private context: common.Context = getContext(this) as common.Context;

  private append(line: string): void {
    this.log = `• ${line}\n${this.log}`;
  }

  private initSdk(): void {
    DemoSdk.init(this.context, this.useProd);
    this.initialized = DemoSdk.isInitialized();
    this.statusText = `Initialized → ${DemoSdk.currentEnv()}`;
    // Open an initial view so resources/errors have a parent.
    DemoSdk.monitor().startView('demo-home', 'DemoHome');
    this.append(`SDK initialized (${DemoSdk.currentEnv()}); started view "DemoHome"`);
  }

  private async fireTracedRequest(): Promise<void> {
    try {
      const session: rcp.Session = rcp.createSession({
        interceptors: [FlashcatTrace.interceptor()]
      });
      const response: rcp.Response = await session.get('https://browser.flashcat.cloud/');
      this.append(`network: GET / → ${response.statusCode} (traceparent injected)`);
      session.close();
    } catch (e) {
      this.append(`network failed: ${e instanceof Error ? e.message : 'error'}`);
    }
  }

  private throwArkTsError(): void {
    // Unhandled async throw → errorManager.on('error') + hiAppEvent APP_CRASH (JsError).
    this.append('throwing unhandled ArkTS error in 100ms…');
    setTimeout(() => {
      throw new Error('Demo unhandled ArkTS error');
    }, 100);
  }

  private triggerNativeCrash(): void {
    this.append('triggering native SIGSEGV (libentry.so)…');
    testNapi.triggerNativeCrash();
  }

  private triggerFreeze(): void {
    // Block the main thread > 6s → hiAppEvent APP_FREEZE (watchdog).
    this.append('blocking main thread ~8s to trigger APP_FREEZE…');
    const end: number = Date.now() + 8000;
    while (Date.now() < end) {
      // busy-wait
    }
    this.append('main thread unblocked');
  }

  @Builder
  actionButton(label: string, action: () => void) {
    Button(label)
      .width('92%')
      .margin({ top: 6 })
      .enabled(this.initialized)
      .onClick(action)
  }

  build() {
    Column() {
      Text('FlashCat SDK Demo')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 12, bottom: 4 })

      Text(this.statusText)
        .fontSize(13)
        .fontColor(this.initialized ? '#166FF6' : '#999999')
        .margin({ bottom: 8 })

      // ---- environment + init ----
      Row() {
        Text('Production env').fontSize(14)
        Toggle({ type: ToggleType.Switch, isOn: this.useProd })
          .enabled(!this.initialized)
          .onChange((isOn: boolean) => { this.useProd = isOn; })
          .margin({ left: 8 })
      }
      .margin({ bottom: 6 })

      Button(this.initialized ? 'SDK Initialized' : 'Initialize SDK')
        .width('92%')
        .enabled(!this.initialized)
        .onClick(() => { this.initSdk(); })

      Divider().margin({ top: 10, bottom: 4 })

      // ---- RUM views ----
      this.actionButton('Start View', () => {
        DemoSdk.monitor().startView('demo-second', 'SecondView');
        this.append('startView "SecondView"');
      })
      this.actionButton('Stop View', () => {
        DemoSdk.monitor().stopView('demo-second');
        this.append('stopView "SecondView"');
      })

      // ---- resources / network ----
      this.actionButton('Fire Traced Network Request', () => { this.fireTracedRequest(); })

      // ---- errors ----
      this.actionButton('Add Manual Error', () => {
        DemoSdk.monitor().addError('Demo manual error', RumErrorSource.CUSTOM, 'at Index.addManualError');
        this.append('addError (manual, custom source)');
      })
      this.actionButton('Throw Unhandled ArkTS Error', () => { this.throwArkTsError(); })

      // ---- crashes ----
      this.actionButton('Trigger Native Crash (SIGSEGV)', () => { this.triggerNativeCrash(); })
      this.actionButton('Trigger App Freeze (8s)', () => { this.triggerFreeze(); })

      Divider().margin({ top: 10, bottom: 4 })

      Text('Event log').fontSize(13).fontWeight(FontWeight.Medium)
      Scroll() {
        Text(this.log.length > 0 ? this.log : '(no events yet)')
          .fontSize(12)
          .fontColor('#666666')
          .width('92%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12 })
  }
}
