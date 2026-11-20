/**
 * Message composer.
 *
 * Owns the draft text so typing never re-renders the conversation. Attachments live on
 * the page because they survive across drafts, and the send button doubles as a stop
 * button while a reply is streaming.
 */

import {
  DARK, FONT_MD, FONT_SM, FONT_XS, Palette, RADIUS_LG, RADIUS_MD, SPACE_LG, SPACE_MD, SPACE_SM, SPACE_XS
} from '../common/Theme';
import { KEY_LANG, KEY_PALETTE } from '../common/StateKeys';
import { translate } from '../i18n/Strings';
import { ContentBlock } from '../model/Types';

@Component
export struct Composer {
  @Prop streaming: boolean = false;
  @Prop listening: boolean = false;
  @Prop listeningText: string = '';
  @Prop attachments: Array<ContentBlock> = [];
  onSend: (text: string) => void = (text: string) => {};
  onStop: () => void = () => {};
  onAttachImage: () => void = () => {};
  onVoiceToggle: () => void = () => {};
  onRemoveAttachment: (index: number) => void = (index: number) => {};

  @StorageLink(KEY_LANG) lang: string = 'zh';
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;
  @State text: string = '';
  @State focused: boolean = false;

  private canSend(): boolean {
    if (this.streaming) {
      return false;
    }
    return this.text.trim().length > 0 || this.attachments.length > 0;
  }

  private submit(): void {
    if (this.streaming) {
      return;
    }
    const body: string = this.text.trim();
    if (body.length === 0 && this.attachments.length === 0) {
      return;
    }
    this.onSend(body);
    this.text = '';
  }

  @Builder
  AttachmentStrip() {
    Scroll() {
      Row({ space: SPACE_SM }) {
        ForEach(this.attachments, (block: ContentBlock, index: number) => {
          Stack({ alignContent: Alignment.TopEnd }) {
            Image(block.uri === undefined ? '' : block.uri)
              .width(56)
              .height(56)
              .objectFit(ImageFit.Cover)
              .borderRadius(RADIUS_MD)
            Text('×')
              .fontSize(FONT_SM)
              .fontColor('#FFFFFF')
              .width(18)
              .height(18)
              .textAlign(TextAlign.Center)
              .backgroundColor('#99000000')
              .borderRadius(9)
              .margin({ top: 2, right: 2 })
              .onClick(() => {
                this.onRemoveAttachment(index);
              })
          }
        }, (block: ContentBlock, index: number) => `${block.uri}-${index}`)
      }
      .padding({ left: SPACE_LG, right: SPACE_LG, bottom: SPACE_SM })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  IconButton(glyph: string, active: boolean, action: () => void) {
    Text(glyph)
      .fontSize(18)
      .fontColor(active ? this.palette.accent : this.palette.textSecondary)
      .width(36)
      .height(36)
      .textAlign(TextAlign.Center)
      .borderRadius(18)
      .backgroundColor(active ? this.palette.accentSoft : '#00000000')
      .onClick(action)
  }

  build() {
    Column({ space: 0 }) {
      if (this.listening) {
        Row({ space: SPACE_SM }) {
          Text('●')
            .fontSize(FONT_XS)
            .fontColor(this.palette.danger)
          Text(this.listeningText.length > 0 ? this.listeningText : translate(this.lang, 'chat.voice.listening'))
            .fontSize(FONT_SM)
            .fontColor(this.palette.textSecondary)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: SPACE_LG, right: SPACE_LG, bottom: SPACE_SM })
        .alignItems(VerticalAlign.Top)
      }

      if (this.attachments.length > 0) {
        this.AttachmentStrip()
      }

      Row({ space: SPACE_SM }) {
        this.IconButton('＋', false, () => {
          this.onAttachImage();
        })
        TextArea({ text: this.text, placeholder: translate(this.lang, 'chat.placeholder') })
          .placeholderColor(this.palette.textTertiary)
          .fontSize(16)
          .fontColor(this.palette.textPrimary)
          .backgroundColor('#00000000')
          .padding({ left: SPACE_SM, right: SPACE_SM, top: SPACE_SM, bottom: SPACE_SM })
          .constraintSize({ minHeight: 40, maxHeight: 132 })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.text = value;
          })
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })

        if (this.streaming) {
          Text('■')
            .fontSize(14)
            .fontColor(this.palette.onAccent)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .backgroundColor(this.palette.textSecondary)
            .onClick(() => {
              this.onStop();
            })
        } else if (this.canSend()) {
          Text('↑')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette.onAccent)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .backgroundColor(this.palette.accent)
            .onClick(() => {
              this.submit();
            })
        } else {
          this.IconButton('◉', this.listening, () => {
            this.onVoiceToggle();
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
      .backgroundColor(this.palette.surfaceAlt)
      .borderRadius(RADIUS_LG)
      .border({ width: 1, color: this.focused ? this.palette.accent : this.palette.border })
      .margin({ left: SPACE_MD, right: SPACE_MD })
    }
    .width('100%')
    .padding({ top: SPACE_SM, bottom: SPACE_SM })
    .backgroundColor(this.palette.bg)
  }
}
