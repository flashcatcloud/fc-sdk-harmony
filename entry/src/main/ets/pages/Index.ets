import { common } from '@kit.AbilityKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from '@flashcatcloud/rum';
import { FlashcatTrace } from '@flashcatcloud/trace';
import { TrackingConsent } from '@flashcatcloud/core';
import testNapi from 'libentry.so';
import { DemoSdk } from '../common/DemoSdk';

/**
 * FlashCat SDK manual-verification harness. Grouped by telemetry type so each
 * SDK capability has at least one button. Watch HiLog (tag "Flashcat") + a proxy
 * / the FlashCat console while exercising these.
 */
@Entry
@Component
struct Index {
  @State useProd: boolean = false;
  @State customEndpoint: string = '';
  @State initialized: boolean = false;
  @State statusText: string = 'SDK not initialized';
  @State sessionId: string = '—';
  @State log: string = '';

  private context: common.Context = getContext(this) as common.Context;
  private resourceSeq: number = 0;

  private append(line: string): void {
    this.log = `• ${line}\n${this.log}`;
  }

  private initSdk(): void {
    DemoSdk.init(this.context, this.useProd, this.customEndpoint);
    this.initialized = DemoSdk.isInitialized();
    this.statusText = `Initialized → ${DemoSdk.currentEnv()}`;
    DemoSdk.monitor().startView('demo-home', 'DemoHome');
    this.append(`init OK (${DemoSdk.currentEnv()}); view "DemoHome" started`);
  }

  private async request(method: string, url: string): Promise<void> {
    try {
      const session: rcp.Session = rcp.createSession({ interceptors: [FlashcatTrace.interceptor()] });
      let resp: rcp.Response;
      if (method === 'POST') {
        resp = await session.post(url, '{"demo":true}');
      } else if (method === 'DELETE') {
        resp = await session.delete(url);
      } else {
        resp = await session.get(url);
      }
      this.append(`net ${method} ${shortUrl(url)} → ${resp.statusCode}`);
      session.close();
    } catch (e) {
      this.append(`net ${method} ${shortUrl(url)} FAILED: ${e instanceof Error ? e.message : 'error'}`);
    }
  }

  private manualResource(): void {
    this.resourceSeq++;
    const key: string = `manual-res-${this.resourceSeq}`;
    DemoSdk.monitor().startResource(key, RumResourceMethod.GET, `https://demo.local/api/item/${this.resourceSeq}`);
    DemoSdk.monitor().stopResource(key, 200, 1234, RumResourceKind.NATIVE);
    this.append(`manual resource ${key} (200, 1234B)`);
  }

  private throwArkTsError(): void {
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
    this.append('blocking main thread ~8s → APP_FREEZE…');
    const end: number = Date.now() + 8000;
    while (Date.now() < end) {
      // busy-wait
    }
    this.append('main thread unblocked');
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor('#166FF6')
      .width('100%')
      .margin({ top: 12, bottom: 2 })
  }

  @Builder
  btn(label: string, action: () => void) {
    Button(label)
      .width('100%')
      .fontSize(14)
      .margin({ top: 5 })
      .enabled(this.initialized)
      .onClick(action)
  }

  build() {
    Column() {
      Text('FlashCat SDK Demo')
        .fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 10 })
      Text(this.statusText)
        .fontSize(12).fontColor(this.initialized ? '#166FF6' : '#999999').margin({ top: 2 })

      Scroll() {
        Column() {
          // ---- Setup ----
          this.sectionTitle('1 · Setup')
          Row() {
            Text('Production env').fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.useProd })
              .enabled(!this.initialized)
              .onChange((v: boolean) => { this.useProd = v; })
              .margin({ left: 8 })
          }.width('100%').margin({ top: 4 })
          TextInput({ placeholder: 'custom endpoint e.g. http://10.0.2.2:8080 (optional)', text: this.customEndpoint })
            .fontSize(12).enabled(!this.initialized).margin({ top: 4 })
            .onChange((v: string) => { this.customEndpoint = v; })
          Button(this.initialized ? 'SDK Initialized' : 'Initialize SDK')
            .width('100%').margin({ top: 6 }).enabled(!this.initialized)
            .onClick(() => { this.initSdk(); })
          this.btn('Show Session ID', () => {
            DemoSdk.monitor().getCurrentSessionId((id: string | undefined) => {
              this.sessionId = id ?? 'none';
              this.append(`sessionId = ${this.sessionId}`);
            });
          })

          // ---- Consent ----
          this.sectionTitle('2 · Consent')
          this.btn('Consent GRANTED', () => { DemoSdk.setConsent(TrackingConsent.GRANTED); this.append('consent → GRANTED'); })
          this.btn('Consent PENDING', () => { DemoSdk.setConsent(TrackingConsent.PENDING); this.append('consent → PENDING (buffered)'); })
          this.btn('Consent NOT_GRANTED', () => { DemoSdk.setConsent(TrackingConsent.NOT_GRANTED); this.append('consent → NOT_GRANTED (dropped)'); })

          // ---- User ----
          this.sectionTitle('3 · User')
          this.btn('Set User (alice)', () => { DemoSdk.setUser('u-1001', 'Alice', 'alice@example.com'); this.append('setUser alice'); })
          this.btn('Clear User', () => { DemoSdk.clearUser(); this.append('clearUser'); })

          // ---- Global attributes ----
          this.sectionTitle('4 · Global attributes')
          this.btn('Add attribute team=mobile', () => { DemoSdk.monitor().addAttribute('team', 'mobile'); this.append('addAttribute team=mobile'); })
          this.btn('Remove attribute team', () => { DemoSdk.monitor().removeAttribute('team'); this.append('removeAttribute team'); })

          // ---- Views ----
          this.sectionTitle('5 · Views')
          this.btn('Start View "Cart"', () => { DemoSdk.monitor().startView('cart', 'Cart'); this.append('startView Cart'); })
          this.btn('Stop View "Cart"', () => { DemoSdk.monitor().stopView('cart'); this.append('stopView Cart'); })
          this.btn('View with attributes', () => {
            const attrs: Record<string, Object> = { 'tab': 'profile', 'premium': true };
            DemoSdk.monitor().startView('profile', 'Profile', attrs);
            this.append('startView Profile {tab,premium}');
          })

          // ---- Actions ----
          this.sectionTitle('6 · Actions')
          this.btn('Add Action (tap "checkout")', () => { DemoSdk.monitor().addAction(RumActionType.TAP, 'checkout'); this.append('addAction tap checkout'); })
          this.btn('Start/Stop Action (scroll)', () => {
            DemoSdk.monitor().startAction(RumActionType.SCROLL, 'feed-scroll');
            DemoSdk.monitor().stopAction(RumActionType.SCROLL, 'feed-scroll');
            this.append('start+stop action scroll');
          })

          // ---- Network / Trace ----
          this.sectionTitle('7 · Network / Trace')
          this.btn('Traced GET 200', () => { this.request('GET', 'https://httpbingo.org/get'); })
          this.btn('Traced POST 200', () => { this.request('POST', 'https://httpbingo.org/post'); })
          this.btn('Traced GET 404', () => { this.request('GET', 'https://httpbingo.org/status/404'); })
          this.btn('Traced GET 500', () => { this.request('GET', 'https://httpbingo.org/status/500'); })
          this.btn('Traced GET bad host (network error)', () => { this.request('GET', 'https://nonexistent.invalid.flashcat/'); })
          this.btn('Manual resource (no network)', () => { this.manualResource(); })

          // ---- Errors ----
          this.sectionTitle('8 · Errors')
          this.btn('Manual error (custom)', () => { DemoSdk.monitor().addError('Demo manual error', RumErrorSource.CUSTOM, 'at Index.manualError'); this.append('addError custom'); })
          this.btn('Error (console source)', () => { DemoSdk.monitor().addError('console warning sample', RumErrorSource.CONSOLE); this.append('addError console'); })
          this.btn('Error with attributes', () => {
            const attrs: Record<string, Object> = { 'screen': 'checkout', 'code': 42 };
            DemoSdk.monitor().addError('checkout failed', RumErrorSource.SOURCE, 'at checkout', attrs);
            this.append('addError + attributes');
          })
          this.btn('Burst: 5 errors', () => {
            for (let i = 1; i <= 5; i++) {
              DemoSdk.monitor().addError(`burst error #${i}`, RumErrorSource.CUSTOM);
            }
            this.append('added 5 errors');
          })
          this.btn('Throw Unhandled ArkTS Error', () => { this.throwArkTsError(); })

          // ---- Crashes ----
          this.sectionTitle('9 · Crashes (delivered next launch)')
          this.btn('Trigger Native Crash (SIGSEGV)', () => { this.triggerNativeCrash(); })
          this.btn('Trigger App Freeze (8s)', () => { this.triggerFreeze(); })

          // ---- Log ----
          this.sectionTitle('Event log')
          Text(this.log.length > 0 ? this.log : '(no events yet)')
            .fontSize(11).fontColor('#666666').width('100%').textAlign(TextAlign.Start)
            .margin({ bottom: 24 })
        }.width('100%')
      }
      .layoutWeight(1).width('100%').margin({ top: 6 })
      .align(Alignment.Top)
    }
    .width('100%').height('100%').padding({ left: 14, right: 14 })
  }
}

function shortUrl(url: string): string {
  const noScheme: string = url.replace('https://', '').replace('http://', '');
  return noScheme.length > 36 ? noScheme.substring(0, 36) + '…' : noScheme;
}
