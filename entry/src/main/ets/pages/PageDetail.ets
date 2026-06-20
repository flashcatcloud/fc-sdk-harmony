import { router } from '@kit.ArkUI';
import { FlashcatRum } from '@flashcatcloud/rum';

/**
 * Phase-2 A1 demo page. Reaching this page (router.pushUrl) and leaving it
 * (router.back) fire `routerPageUpdate` → the SDK auto-emits start/stopView with
 * NO manual startView here. Buttons route through FlashcatRum.trackTap (A3).
 */
@Entry
@Component
struct PageDetail {
  build() {
    Column({ space: 12 }) {
      Text('Detail Page')
        .fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 20 })
      Text('No manual startView on this page — the SDK auto-tracks it via routerPageUpdate.')
        .fontSize(13).fontColor('#666666').margin({ top: 4 })

      Button('Auto-tracked button (tap)')
        .width('100%').margin({ top: 12 })
        .onClick(() => { FlashcatRum.trackTap('detail-cta'); })

      Button('Go deeper → Settings')
        .width('100%')
        .onClick(() => {
          FlashcatRum.trackTap('detail-to-settings');
          router.pushUrl({ url: 'pages/PageSettings' });
        })

      Button('Back')
        .width('100%')
        .onClick(() => {
          FlashcatRum.trackTap('detail-back');
          router.back();
        })
    }
    .width('100%').height('100%').padding({ left: 14, right: 14 })
  }
}
