/**
 * One conversation row.
 *
 * Renders the ordered parts of a turn: reasoning panel, markdown prose, tool cards and
 * attached images. User turns are bubbles on the right; assistant turns are full width
 * on the page background so long answers stay readable.
 */

import { DARK, FONT_SM, FONT_XS, Palette, RADIUS_LG, RADIUS_MD, SPACE_LG, SPACE_MD, SPACE_SM, SPACE_XS } from '../common/Theme';
import { KEY_LANG, KEY_PALETTE } from '../common/StateKeys';
import { translate } from '../i18n/Strings';
import { ContentBlock, TokenUsage } from '../model/Types';
import { RenderItem, RenderPart, ToolPair } from '../model/Render';
import { formatDuration, formatTokens } from '../common/Utils';
import { MarkdownView } from './MarkdownView';
import { ToolCard } from './ToolCard';

/** Default value required by ArkUI for a non-decorated member. */
function emptyItem(): RenderItem {
  const item: RenderItem = {
    kind: 'assistant',
    messageId: '',
    parts: [],
    images: [],
    tools: [],
    createdAt: 0,
    durationMs: 0,
    errorText: ''
  };
  return item;
}

@Component
export struct MessageItem {
  item: RenderItem = emptyItem();
  @StorageLink(KEY_LANG) lang: string = 'zh';
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;
  @State reasoningOpen: boolean = false;

  private toolAt(index: number): ToolPair {
    if (index < 0 || index >= this.item.tools.length) {
      const fallback: ToolPair = {
        toolCallId: '', name: '', argsJson: '', state: 'done', summary: '', resultText: '', isError: false
      };
      return fallback;
    }
    return this.item.tools[index];
  }

  private usageLine(): string {
    const usage: TokenUsage | undefined = this.item.usage;
    const parts: Array<string> = [];
    if (this.item.durationMs > 0) {
      parts.push(formatDuration(this.item.durationMs));
    }
    if (usage !== undefined && usage.totalTokens > 0) {
      parts.push(`${formatTokens(usage.totalTokens)} ${translate(this.lang, 'chat.tokens')}`);
    }
    return parts.join(' · ');
  }

  @Builder
  ReasoningPart(text: string) {
    Column({ space: 0 }) {
      Row({ space: SPACE_XS }) {
        Text('◈')
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
        Text(translate(this.lang, 'chat.reasoning'))
          .fontSize(FONT_XS)
          .fontColor(this.palette.textSecondary)
        Text(this.reasoningOpen ? '⌃' : '⌄')
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
      }
      .onClick(() => {
        this.reasoningOpen = !this.reasoningOpen;
      })
      .padding({ left: SPACE_SM, right: SPACE_SM, top: SPACE_SM, bottom: SPACE_SM })

      if (this.reasoningOpen) {
        Text(text)
          .fontSize(FONT_SM)
          .fontColor(this.palette.textSecondary)
          .lineHeight(20)
          .width('100%')
          .padding({ left: SPACE_SM, right: SPACE_SM, bottom: SPACE_SM })
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.reasoningBg)
    .borderRadius(RADIUS_MD)
    .border({ width: 1, color: this.palette.reasoningBorder })
    .margin({ bottom: SPACE_SM })
  }

  @Builder
  ImageStrip() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.item.images, (block: ContentBlock, index: number) => {
        Image(block.uri === undefined ? '' : block.uri)
          .width(96)
          .height(96)
          .objectFit(ImageFit.Cover)
          .borderRadius(RADIUS_MD)
          .margin({ right: SPACE_SM, bottom: SPACE_SM })
      }, (block: ContentBlock, index: number) => `${this.item.messageId}-img-${index}`)
    }
    .width('100%')
    .margin({ bottom: SPACE_XS })
  }

  @Builder
  UserRow() {
    Column({ space: 0 }) {
      if (this.item.images.length > 0) {
        Row() {
          this.ImageStrip()
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      ForEach(this.item.parts, (part: RenderPart, index: number) => {
        if (part.kind === 'text' && part.text.length > 0) {
          Text(part.text)
            .fontSize(16)
            .lineHeight(24)
            .fontColor(this.palette.userBubbleText)
            .copyOption(CopyOptions.LocalDevice)
            .padding({ left: SPACE_LG, right: SPACE_LG, top: SPACE_MD, bottom: SPACE_MD })
            .backgroundColor(this.palette.userBubble)
            .borderRadius(RADIUS_LG)
            .constraintSize({ maxWidth: '82%' })
        }
      }, (part: RenderPart, index: number) => `${this.item.messageId}-u-${index}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
    .padding({ left: 48 })
  }

  @Builder
  AssistantRow() {
    Column({ space: 0 }) {
      if (this.item.images.length > 0) {
        this.ImageStrip()
      }
      ForEach(this.item.parts, (part: RenderPart, index: number) => {
        if (part.kind === 'reasoning') {
          this.ReasoningPart(part.text)
        } else if (part.kind === 'text') {
          MarkdownView({ text: part.text, palette: this.palette, fontSize: 16 })
        } else if (part.kind === 'tool') {
          Column() {
            ToolCard({
              name: this.toolAt(part.toolIndex).name,
              argsJson: this.toolAt(part.toolIndex).argsJson,
              state: this.toolAt(part.toolIndex).state,
              summary: this.toolAt(part.toolIndex).summary,
              resultText: this.toolAt(part.toolIndex).resultText,
              isError: this.toolAt(part.toolIndex).isError
            })
          }
          .width('100%')
          .margin({ top: SPACE_XS, bottom: SPACE_SM })
        }
      }, (part: RenderPart, index: number) => `${this.item.messageId}-a-${index}`)

      if (this.item.errorText.length > 0) {
        Text(this.item.errorText)
          .fontSize(FONT_SM)
          .fontColor(this.palette.danger)
          .width('100%')
          .padding(SPACE_MD)
          .backgroundColor(this.palette.dangerSoft)
          .borderRadius(RADIUS_MD)
      }
      if (this.usageLine().length > 0) {
        Text(this.usageLine())
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
          .margin({ top: SPACE_XS })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: SPACE_XS, right: SPACE_XS })
  }

  @Builder
  SystemRow() {
    Row() {
      Text(this.item.parts.length > 0 ? this.item.parts[0].text : '')
        .fontSize(FONT_XS)
        .fontColor(this.palette.textTertiary)
        .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_XS, bottom: SPACE_XS })
        .backgroundColor(this.palette.surfaceAlt)
        .borderRadius(RADIUS_LG)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (this.item.kind === 'user') {
        this.UserRow()
      } else if (this.item.kind === 'system') {
        this.SystemRow()
      } else {
        this.AssistantRow()
      }
    }
    .width('100%')
    .padding({ top: SPACE_SM, bottom: SPACE_SM })
  }
}
