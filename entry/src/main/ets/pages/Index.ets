import { common } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { router } from '@kit.ArkUI';
import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { FlashcatRum, RumActionType, RumErrorSource, RumResourceKind, RumResourceMethod } from '@flashcatcloud/rum';
import { FlashcatTrace, FlashcatHttp } from '@flashcatcloud/trace';
import { http } from '@kit.NetworkKit';
import { TrackingConsent } from '@flashcatcloud/core';
import testNapi from 'libentry.so';
import { DemoSdk } from '../common/DemoSdk';
import { SpikeMode, SpikeModeStore } from '../common/SpikeMode';
import {
  BenchSample, BenchStats, NetworkContentionBench
} from '../common/NetworkContentionBench';
import axios, { AxiosInstance, AxiosResponse } from '@ohos/axios';
import { trackAxios } from '@flashcatcloud/axios';

/** ArkTS requires every object literal to have a declared type. */
interface AxiosDemoPayload {
  demo: boolean;
}

const SPIKE_DOMAIN: number = 0x0000;
const SPIKE_TAG: string = 'FCSpike';
const SPIKE_FAULT_WATCHER_NAME: string = 'fc_spike_fault_probe';

@Concurrent
function spikeTaskPoolThrow(): void {
  throw new Error('FCSpike: taskpool worker');
}

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
  @State spikeMode: SpikeMode = SpikeMode.OFF;
  @State spikeLaunchCounter: number = 0;
  @State spikeLastCrashTimestamp: number = 0;
  @State interactivityProbeCount: number = 0;
  @StorageProp('fcSpikeRecoveredPayload') recoveredPayload: string = '';

  private context: common.Context = getContext(this) as common.Context;
  private resourceSeq: number = 0;
  private faultPackageHolder: hiAppEvent.AppEventPackageHolder | null = null;
  private faultWatcherRegistered: boolean = false;
  private trackedAxios: AxiosInstance | null = null;

  aboutToAppear(): void {
    try {
      this.spikeMode = SpikeModeStore.readMode(this.context);
      this.spikeLaunchCounter = SpikeModeStore.readLaunchCounter(this.context);
      this.spikeLastCrashTimestamp = SpikeModeStore.readLastCrashTimestamp(this.context);
      this.appendSpike(`page ready; persisted mode=${this.spikeMode}; launch=${this.spikeLaunchCounter}`);
    } catch (error) {
      this.appendSpikeError(`failed to read spike state: ${errorText(error)}`);
    }
    this.registerFaultWatcher();
    this.maybeRunE2e();
  }

  /** E2E smoke hook: auto-init against the mock intake and run a scenario. */
  private maybeRunE2e(): void {
    const endpoint: string = AppStorage.get<string>('e2eEndpoint') ?? '';
    hilog.info(0x0000, 'FlashcatDemo', 'e2e hook: endpoint=%{public}s initialized=%{public}s',
      endpoint, `${DemoSdk.isInitialized()}`);
    if (endpoint.length === 0) {
      return;
    }
    const scenario: string = AppStorage.get<string>('e2eScenario') ?? '';
    if (!DemoSdk.isInitialized()) {
      // Sentinels: 'prod' / 'staging' mean "use the real site ingest for that
      // environment" (no custom endpoint) — for verification in the live
      // RUM console rather than the local mock.
      if (endpoint === 'prod') {
        this.customEndpoint = '';
        this.useProd = true;
      } else if (endpoint === 'staging') {
        this.customEndpoint = '';
        this.useProd = false;
      } else {
        this.customEndpoint = endpoint;
        this.useProd = false;
      }
      // crash-only: auto error capture disabled, crash pipeline kept.
      this.initSdkE2e(scenario !== 'crash-only');
    }
    this.append(`e2e: scenario "${scenario}" endpoint ${endpoint}`);
    hilog.info(0x0000, 'FlashcatDemo', 'e2e scenario "%{public}s" scheduled', scenario);
    setTimeout(() => {
      this.runE2eScenario(scenario);
    }, 1000);
  }

  private initSdkE2e(trackErrors: boolean): void {
    try {
      const pacing: string = AppStorage.get<string>('netbenchPacing') ?? 'demo';
      DemoSdk.init(this.context, this.useProd, this.customEndpoint, false, trackErrors, pacing);
    } catch (e) {
      this.append(e instanceof Error ? e.message : 'SDK initialization failed');
      return;
    }
    this.initialized = DemoSdk.isInitialized();
    this.statusText = `Initialized → ${DemoSdk.currentEnv()}`;
    DemoSdk.monitor().startView('demo-home', 'DemoHome');
    FlashcatRum.startViewTracking(this.getUIContext());
    this.append(`init OK (${DemoSdk.currentEnv()}); trackErrors=${trackErrors}`);
  }

  /**
   * Network-contention measurement, one group per app run. `netbench_pacing`
   * selects the group: 'off' is the baseline (SDK present but silent), while
   * 'default' and 'low' generate load under their respective pacing settings.
   *
   * Results go to HiLog under NETBENCH so a run is driven and collected over
   * hdc alone — no tapping, reproducible from a script on any SDK version.
   */
  private async runNetBench(url: string): Promise<void> {
    const rounds: number = Number.parseInt(AppStorage.get<string>('netbenchRounds') ?? '20', 10);
    const bodyBytes: number = Number.parseInt(AppStorage.get<string>('netbenchBodyBytes') ?? '16384', 10);
    const perTick: number = Number.parseInt(AppStorage.get<string>('netbenchEvents') ?? '10', 10);
    const pacing: string = AppStorage.get<string>('netbenchPacing') ?? 'off';
    const uploading: boolean = pacing !== 'off';
    hilog.info(0x0000, 'NETBENCH', 'group=%{public}s rounds=%{public}d body=%{public}d perTick=%{public}d',
      pacing, rounds, bodyBytes, perTick);
    try {
      const samples: Array<BenchSample> = await NetworkContentionBench.runGroup(
        url, rounds, bodyBytes, perTick, uploading,
        (done: number, total: number): void => {
          hilog.info(0x0000, 'NETBENCH', 'progress %{public}d/%{public}d', done, total);
        });
      const stats: BenchStats = NetworkContentionBench.summarize(samples);
      hilog.info(0x0000, 'NETBENCH', 'result group=%{public}s n=%{public}d mean=%{public}d p50=%{public}d p95=%{public}d failures=%{public}d',
        pacing, stats.count, stats.meanMs, stats.p50Ms, stats.p95Ms, stats.failures);
      for (const sample of samples) {
        hilog.info(0x0000, 'NETBENCH', 'sample %{public}d %{public}d %{public}s',
          sample.round, sample.durationMs, `${sample.ok}`);
      }
      hilog.info(0x0000, 'NETBENCH', 'done');
      this.append(`netbench ${pacing}: mean ${stats.meanMs}ms p95 ${stats.p95Ms}ms`);
    } catch (e) {
      hilog.error(0x0000, 'NETBENCH', 'failed: %{public}s',
        e instanceof Error ? e.message : `${e}`);
    }
  }

  private runE2eScenario(name: string): void {
    if (name === 'crash-only') {
      // Auto-captured signals that MUST be suppressed with trackErrors=false:
      const bizReason: Record<string, Object> = { 'code': 424242, 'message': 'suppressed rejection' };
      Promise.reject(bizReason as Object);
      this.append('e2e: crash-only — rejection emitted (should be suppressed), crashing in 1200ms');
      setTimeout(() => {
        throw new Error('E2E crash-only marker');
      }, 1200);
    } else if (name === 'events') {
      DemoSdk.monitor().addAction(RumActionType.TAP, 'e2e-tap');
      DemoSdk.monitor().addError('e2e manual error', RumErrorSource.CUSTOM, 'at Index.e2e');
      // BusinessError-shaped rejection: must surface as "message (code N)",
      // never "[object Object]".
      const bizReason: Record<string, Object> = { 'code': 1234567, 'message': 'e2e biz error' };
      Promise.reject(bizReason as Object);
      this.append('e2e: events scenario emitted');
    } else if (name === 'axios') {
      // Hits the mock intake's echo endpoint so the assertions can compare the
      // traceparent that actually left the device against the resource event.
      const endpoint: string = AppStorage.get<string>('e2eEndpoint') ?? '';
      this.axiosRequest('GET', `${endpoint}/e2e/echo`);
      this.axiosRequest('GET', `${endpoint}/e2e/status/404`);
      this.append('e2e: axios scenario emitted');
    } else if (name === 'netbench') {
      const endpoint: string = AppStorage.get<string>('e2eEndpoint') ?? '';
      this.append('e2e: netbench started');
      this.runNetBench(`${endpoint}/e2e/echo`);
    } else if (name === 'crash') {
      this.append('e2e: crashing in 800ms');
      setTimeout(() => {
        throw new Error('E2E crash marker');
      }, 800);
    }
  }

  aboutToDisappear(): void {
    if (!this.faultWatcherRegistered) {
      return;
    }
    try {
      const watcher: hiAppEvent.Watcher = { name: SPIKE_FAULT_WATCHER_NAME };
      hiAppEvent.removeWatcher(watcher);
      this.appendSpike('fault watcher removed');
    } catch (error) {
      this.appendSpikeError(`fault watcher removal failed: ${errorText(error)}`);
    }
    this.faultWatcherRegistered = false;
    this.faultPackageHolder = null;
  }

  private append(line: string): void {
    this.log = `• ${line}\n${this.log}`;
  }

  private appendSpike(line: string): void {
    hilog.info(SPIKE_DOMAIN, SPIKE_TAG, '%{public}s', line);
    this.append(`[FCSpike] ${line}`);
  }

  private appendSpikeError(line: string): void {
    hilog.error(SPIKE_DOMAIN, SPIKE_TAG, '%{public}s', line);
    this.append(`[FCSpike] ${line}`);
  }

  private selectSpikeMode(mode: SpikeMode): void {
    SpikeModeStore.writeMode(this.context, mode).then((): void => {
      this.spikeMode = mode;
      this.appendSpike(`persisted mode → ${mode}; cold-relaunch before testing`);
    }).catch((error: Object): void => {
      this.appendSpikeError(`failed to persist mode ${mode}: ${errorText(error)}`);
    });
  }

  private registerFaultWatcher(): void {
    if (this.faultWatcherRegistered) {
      return;
    }
    const watcher: hiAppEvent.Watcher = {
      name: SPIKE_FAULT_WATCHER_NAME,
      appEventFilters: [{
        domain: hiAppEvent.domain.OS,
        names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE]
      }]
    };
    try {
      this.faultPackageHolder = hiAppEvent.addWatcher(watcher);
      this.faultWatcherRegistered = true;
      this.appendSpike('fault watcher ready; use Query recent faults after launch');
    } catch (error) {
      this.appendSpikeError(`fault watcher registration failed: ${errorText(error)}`);
    }
  }

  private queryRecentFaults(): void {
    const holder: hiAppEvent.AppEventPackageHolder | null = this.faultPackageHolder;
    if (holder === null) {
      this.appendSpikeError('fault query unavailable: watcher holder is missing');
      return;
    }
    let count: number = 0;
    let eventPackage: hiAppEvent.AppEventPackage | null = holder.takeNext();
    while (eventPackage !== null) {
      this.appendSpike(
        `fault package id=${eventPackage.packageId} row=${eventPackage.row} size=${eventPackage.size}`);
      for (const eventInfo of eventPackage.data) {
        count++;
        this.appendSpike(`fault #${count}: ${JSON.stringify(eventInfo)}`);
      }
      eventPackage = holder.takeNext();
    }
    if (count === 0) {
      this.appendSpike('no queued APP_CRASH / APP_FREEZE faults; wait for collection and retry');
    } else {
      this.appendSpike(`fault query complete; events=${count}`);
    }
  }

  private initSdk(recover: boolean = false): void {
    try {
      DemoSdk.init(this.context, this.useProd, this.customEndpoint, recover);
    } catch (e) {
      const message: string = e instanceof Error ? e.message : 'SDK initialization failed';
      this.statusText = message;
      this.append(message);
      return;
    }
    this.initialized = DemoSdk.isInitialized();
    this.statusText = `Initialized → ${DemoSdk.currentEnv()}`;
    DemoSdk.monitor().startView('demo-home', 'DemoHome');
    // Phase 2 A1: turn on automatic View tracking for router navigation, scoped to
    // this component's UIContext. From here, pushing/popping pages auto-emits views.
    FlashcatRum.startViewTracking(this.getUIContext());
    this.append(`init OK (${DemoSdk.currentEnv()}); view "DemoHome" started; nav auto-tracking on`);
  }

  private async request(method: string, url: string): Promise<void> {
    // rcp caps live sessions per process — close in finally so failed requests
    // (this demo has a button that always fails) don't leak the session.
    const session: rcp.Session = rcp.createSession({ interceptors: [FlashcatTrace.interceptor()] });
    try {
      let resp: rcp.Response;
      if (method === 'POST') {
        resp = await session.post(url, '{"demo":true}');
      } else if (method === 'DELETE') {
        resp = await session.delete(url);
      } else {
        resp = await session.get(url);
      }
      this.append(`net ${method} ${shortUrl(url)} → ${resp.statusCode}`);
    } catch (e) {
      this.append(`net ${method} ${shortUrl(url)} FAILED: ${e instanceof Error ? e.message : 'error'}`);
    } finally {
      session.close();
    }
  }

  // Phase 2 A2: FlashcatHttp wrapper — auto resource + traceparent, NO interceptor.
  private async autoHttp(method: http.RequestMethod, url: string): Promise<void> {
    try {
      const resp: http.HttpResponse = await FlashcatHttp.request(url, { method });
      this.append(`auto-http ${method} ${shortUrl(url)} → ${resp.responseCode}`);
    } catch (e) {
      this.append(`auto-http ${method} ${shortUrl(url)} FAILED: ${e instanceof Error ? e.message : 'error'}`);
    }
  }

  // Manual axios instrumentation (common/AxiosTracking.ets) — axios ships its
  // own @ohos.net.http adapter, so neither the rcp interceptor nor FlashcatHttp
  // sees these requests; the resource comes from the manual API instead.
  private async axiosRequest(method: string, url: string): Promise<void> {
    try {
      const client: AxiosInstance = this.axiosClient();
      const body: AxiosDemoPayload = { demo: true };
      const resp: AxiosResponse = method === 'POST'
        ? await client.post(url, body)
        : await client.get(url);
      this.append(`axios ${method} ${shortUrl(url)} → ${resp.status}`);
    } catch (e) {
      this.append(`axios ${method} ${shortUrl(url)} FAILED: ${e instanceof Error ? e.message : 'error'}`);
    }
  }

  /** One tracked instance per process — attaching twice would double-report. */
  private axiosClient(): AxiosInstance {
    if (this.trackedAxios === null) {
      const client: AxiosInstance = axios.create();
      trackAxios(client);
      this.trackedAxios = client;
    }
    return this.trackedAxios;
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
    this.appendSpikeError('triggering native SIGSEGV (libentry.so)…');
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
      .onClick(() => {
        // Phase 2 A3: route every button tap through auto-instrumentation. One
        // wrapper here auto-emits a TAP action (target = the button label) for
        // every button — no per-button addAction. Inert unless RUM is enabled
        // with trackUserInteractions(true).
        FlashcatRum.trackTap(label);
        action();
      })
  }

  @Builder
  spikeModeButton(label: string, mode: SpikeMode) {
    Button(label)
      .width('32%')
      .fontSize(11)
      .fontColor(this.spikeMode === mode ? '#FFFFFF' : '#333333')
      .backgroundColor(this.spikeMode === mode ? '#166FF6' : '#E8E8E8')
      .onClick(() => { this.selectSpikeMode(mode); })
  }

  @Builder
  spikeBtn(label: string, action: () => void) {
    Button(label)
      .width('100%')
      .fontSize(14)
      .margin({ top: 5 })
      .onClick(() => { action(); })
  }

  build() {
    Column() {
      Text('FlashCat SDK Demo')
        .fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 10 })
      Text(this.statusText)
        .fontSize(12).fontColor(this.initialized ? '#166FF6' : '#999999').margin({ top: 2 })

      Scroll() {
        Column() {
          // ---- Phase 0 crash semantics spike (does not require SDK init) ----
          this.sectionTitle('Spike: crash soft-landing (Phase 0)')
          if (this.recoveredPayload.length > 0) {
            Text(`RECOVERED FROM CRASH\nRestored: ${this.recoveredPayload}`)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#8A2A00')
              .backgroundColor('#FFF0E5')
              .border({ width: 1, color: '#FF8A3D' })
              .borderRadius(6)
              .padding(10)
              .width('100%')
              .margin({ top: 5, bottom: 5 })
          }
          Text(`Persisted mode: ${this.spikeMode}`)
            .fontSize(13).fontWeight(FontWeight.Bold).width('100%').margin({ top: 4 })
          Text('Mode changes take effect on the next cold launch because the observer is registered in onCreate.')
            .fontSize(11).fontColor('#8A5A00').width('100%').margin({ top: 2, bottom: 4 })
          Row() {
            this.spikeModeButton('OFF', SpikeMode.OFF)
            this.spikeModeButton('OBSERVE', SpikeMode.OBSERVE_ONLY)
            this.spikeModeButton('RECOVER', SpikeMode.RECOVER)
          }.width('100%').justifyContent(FlexAlign.SpaceBetween)
          Text(`Launch counter: ${this.spikeLaunchCounter} · Last crash: ${formatTimestamp(this.spikeLastCrashTimestamp)}`)
            .fontSize(11).fontColor('#666666').width('100%').margin({ top: 5 })
          this.spikeBtn('a · Main-thread synchronous throw', () => {
            this.appendSpikeError('throwing main-thread synchronous error now');
            throw new Error('FCSpike: sync main-thread');
          })
          this.spikeBtn('b · Async callback throw (setTimeout 0)', () => {
            this.appendSpike('scheduled async callback throw');
            setTimeout((): void => {
              this.appendSpikeError('throwing from async callback now');
              throw new Error('FCSpike: async callback');
            }, 0);
          })
          this.spikeBtn('c · Unhandled Promise rejection', () => {
            this.appendSpikeError('creating unhandled rejected Promise now');
            Promise.reject(new Error('FCSpike: unhandled promise rejection'));
          })
          this.spikeBtn('d · TaskPool worker throw (uncaught execute result)', () => {
            this.appendSpikeError('executing TaskPool function that throws');
            taskpool.execute(spikeTaskPoolThrow);
          })
          this.spikeBtn('e · Native crash (SIGSEGV)', () => { this.triggerNativeCrash(); })
          this.spikeBtn('Post-crash interactivity probe', () => {
            this.interactivityProbeCount++;
            this.appendSpike(`interactivity probe count=${this.interactivityProbeCount}`);
          })
          this.spikeBtn('Query recent APP_CRASH / APP_FREEZE faults', () => {
            this.queryRecentFaults();
          })

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
            .onClick(() => { this.initSdk(false); })
          Button(this.initialized ? 'SDK Initialized' : 'Initialize SDK (recover policy)')
            .width('100%').margin({ top: 6 }).enabled(!this.initialized)
            .onClick(() => { this.initSdk(true); })
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

          // ---- Navigation (auto View tracking, A1) ----
          this.sectionTitle('5b · Navigation (auto Views)')
          this.btn('Go to Detail page →', () => { router.pushUrl({ url: 'pages/PageDetail' }); this.append('pushUrl PageDetail (auto view expected)'); })
          this.btn('Go to Settings page →', () => { router.pushUrl({ url: 'pages/PageSettings' }); this.append('pushUrl PageSettings (auto view expected)'); })

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
          this.btn('Auto HTTP GET (FlashcatHttp, no interceptor)', () => { this.autoHttp(http.RequestMethod.GET, 'https://httpbingo.org/get'); })
          this.btn('Auto HTTP POST (FlashcatHttp, no interceptor)', () => { this.autoHttp(http.RequestMethod.POST, 'https://httpbingo.org/post'); })
          this.btn('axios GET (manual instrumentation)', () => { this.axiosRequest('GET', 'https://httpbingo.org/get'); })
          this.btn('axios POST (manual instrumentation)', () => { this.axiosRequest('POST', 'https://httpbingo.org/post'); })
          this.btn('axios 404 (manual, error path)', () => { this.axiosRequest('GET', 'https://httpbingo.org/status/404'); })
          this.btn('Auto HTTP image (→ resource_type=image)', () => { this.autoHttp(http.RequestMethod.GET, 'https://httpbingo.org/image/png'); })
          this.btn('Auto HTTP image 404 (static error)', () => { this.autoHttp(http.RequestMethod.GET, 'https://httpbingo.org/image/missing.png'); })

          // ---- Event mapper (R3) ----
          this.sectionTitle('7b · Event mapper (PII redaction)')
          this.btn('Tap "secret" target (dropped by mapper)', () => { FlashcatRum.trackTap('secret-button'); this.append('tapped secret (mapper should DROP the action)'); })
          this.btn('Auto HTTP with ?token (url scrubbed)', () => { this.autoHttp(http.RequestMethod.GET, 'https://httpbingo.org/get?token=SECRET123&u=1'); })

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

function formatTimestamp(timestamp: number): string {
  return timestamp > 0 ? new Date(timestamp).toISOString() : 'none';
}

function errorText(value: Object): string {
  return value instanceof Error ? value.message : `${value}`;
}
