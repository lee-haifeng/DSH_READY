/**
 * Ask-the-user overlay.
 *
 * The `ask_user_question` tool blocks the agent loop until this sheet resolves, so the
 * component must always call back exactly once: on submit, on skip, or on dismiss.
 */

import {
  DARK, FONT_BODY, FONT_MD, FONT_SM, FONT_TITLE, FONT_XS, Palette, RADIUS_MD, SPACE_LG, SPACE_MD, SPACE_SM, SPACE_XS
} from '../common/Theme';
import { KEY_LANG, KEY_PALETTE } from '../common/StateKeys';
import { translate } from '../i18n/Strings';

@Component
export struct AskUserSheet {
  @Prop question: string = '';
  @Prop options: Array<string> = [];
  onAnswer: (answer: string) => void = (answer: string) => {};
  onSkip: () => void = () => {};

  @StorageLink(KEY_LANG) lang: string = 'zh';
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;
  @State draft: string = '';

  private submit(text: string): void {
    const answer: string = text.trim();
    this.draft = '';
    this.onAnswer(answer);
  }

  build() {
    Column({ space: SPACE_MD }) {
      Row() {
        Text(translate(this.lang, 'ask.title'))
          .fontSize(FONT_MD)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
        Text('✕')
          .fontSize(FONT_MD)
          .fontColor(this.palette.textSecondary)
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.draft = '';
            this.onSkip();
          })
      }
      .width('100%')

      Text(this.question)
        .fontSize(FONT_BODY)
        .lineHeight(24)
        .fontColor(this.palette.textPrimary)
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)

      if (this.options.length > 0) {
        Column({ space: SPACE_SM }) {
          ForEach(this.options, (option: string, index: number) => {
            Text(option)
              .fontSize(FONT_SM)
              .fontColor(this.palette.textPrimary)
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_MD, bottom: SPACE_MD })
              .backgroundColor(this.palette.surfaceAlt)
              .borderRadius(RADIUS_MD)
              .onClick(() => {
                this.submit(option);
              })
          }, (option: string, index: number) => `opt-${index}`)
        }
        .width('100%')
      }

      TextInput({ text: this.draft, placeholder: translate(this.lang, 'ask.submit') })
        .placeholderColor(this.palette.textTertiary)
        .fontSize(FONT_SM)
        .fontColor(this.palette.textPrimary)
        .backgroundColor(this.palette.surfaceAlt)
        .borderRadius(RADIUS_MD)
        .width('100%')
        .onChange((value: string) => {
          this.draft = value;
        })

      Row({ space: SPACE_SM }) {
        Text(translate(this.lang, 'ask.skip'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.textSecondary)
          .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
          .backgroundColor(this.palette.surfaceAlt)
          .borderRadius(RADIUS_MD)
          .onClick(() => {
            this.draft = '';
            this.onSkip();
          })
        Text(translate(this.lang, 'ask.submit'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.onAccent)
          .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
          .backgroundColor(this.draft.trim().length > 0 ? this.palette.accent : this.palette.borderStrong)
          .borderRadius(RADIUS_MD)
          .onClick(() => {
            if (this.draft.trim().length === 0) {
              return;
            }
            this.submit(this.draft);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(SPACE_LG)
    .backgroundColor(this.palette.surfaceHigh)
    .borderRadius({ topLeft: 20, topRight: 20 })
    .border({ width: 1, color: this.palette.border })
  }
}
