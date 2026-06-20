import { router } from '@kit.ArkUI';
import { FlashcatRum } from '@flashcatcloud/rum';

/**
 * Phase-2 A1 demo page (second level). Push/pop here exercises a 3-deep view
 * stack so the auto start/stopView ordering (stop-before-start) is observable.
 */
@Entry
@Component
struct PageSettings {
  build() {
    Column({ space: 12 }) {
      Text('Settings Page')
        .fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 20 })
      Text('Auto-tracked as its own View. Back pops to Detail (auto re-show).')
        .fontSize(13).fontColor('#666666').margin({ top: 4 })

      Button('Toggle setting (tap)')
        .width('100%').margin({ top: 12 })
        .onClick(() => { FlashcatRum.trackTap('settings-toggle'); })

      Button('Back to Detail')
        .width('100%')
        .onClick(() => {
          FlashcatRum.trackTap('settings-back');
          router.back();
        })

      Button('Back to Home (pop to root)')
        .width('100%')
        .onClick(() => {
          FlashcatRum.trackTap('settings-to-home');
          router.back({ url: 'pages/Index' });
        })
    }
    .width('100%').height('100%').padding({ left: 14, right: 14 })
  }
}
