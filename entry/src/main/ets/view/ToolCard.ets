/**
 * Tool call card.
 *
 * Collapsed by default: the user sees which tool ran and what it produced in one line.
 * Expanding reveals the exact arguments and the raw result, which is what you need when
 * a tool misbehaves.
 */

import { DARK, FONT_SM, FONT_XS, FONT_MD, MONO_FAMILY, Palette, RADIUS_SM, SPACE_SM, SPACE_XS } from '../common/Theme';
import { KEY_LANG, KEY_PALETTE } from '../common/StateKeys';
import { translate } from '../i18n/Strings';
import { toolGlyph, toolLabel } from '../common/ToolLabels';

@Component
export struct ToolCard {
  /** Wire tool name. */
  name: string = '';
  /** Raw JSON arguments accumulated from the stream. */
  argsJson: string = '';
  /** `running` / `done` / `error`. */
  state: string = 'running';
  /** One line result summary. */
  summary: string = '';
  /** Full result text. */
  resultText: string = '';
  isError: boolean = false;

  @StorageLink(KEY_LANG) lang: string = 'zh';
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;
  @State expanded: boolean = false;

  /** Pretty print arguments when they are valid JSON, otherwise show them raw. */
  private prettyArgs(): string {
    const raw: string = this.argsJson.trim();
    if (raw.length === 0) {
      return '';
    }
    try {
      return JSON.stringify(JSON.parse(raw), null, 2);
    } catch (e) {
      return raw;
    }
  }

  private stateLabel(): string {
    if (this.state === 'running') {
      return translate(this.lang, 'chat.tool.running');
    }
    if (this.isError || this.state === 'error') {
      return translate(this.lang, 'chat.tool.error');
    }
    return translate(this.lang, 'chat.tool.done');
  }

  private stateColor(): string {
    if (this.state === 'running') {
      return this.palette.warning;
    }
    if (this.isError || this.state === 'error') {
      return this.palette.danger;
    }
    return this.palette.success;
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: SPACE_SM }) {
        Text(toolGlyph(this.name))
          .fontSize(FONT_MD)
          .fontColor(this.palette.accent)
          .width(22)
          .textAlign(TextAlign.Center)
        Text(toolLabel(this.lang, this.name))
          .fontSize(FONT_SM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.stateLabel())
          .fontSize(FONT_XS)
          .fontColor(this.stateColor())
        Text(this.expanded ? '⌃' : '⌄')
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
          .margin({ left: SPACE_XS })
      }
      .width('100%')
      .padding({ left: SPACE_SM, right: SPACE_SM, top: SPACE_SM, bottom: SPACE_SM })

      if (this.summary.length > 0 && !this.expanded) {
        Text(this.summary)
          .fontSize(FONT_XS)
          .fontColor(this.palette.textSecondary)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: SPACE_SM + 22, right: SPACE_SM, bottom: SPACE_SM })
      }

      if (this.expanded) {
        Column({ space: SPACE_XS }) {
          if (this.prettyArgs().length > 0) {
            Text(translate(this.lang, 'chat.tool.arguments'))
              .fontSize(FONT_XS)
              .fontColor(this.palette.textTertiary)
              .width('100%')
            Text(this.prettyArgs())
              .fontSize(FONT_XS)
              .fontFamily(MONO_FAMILY)
              .fontColor(this.palette.textSecondary)
              .width('100%')
              .padding(SPACE_SM)
              .backgroundColor(this.palette.codeBackground)
              .borderRadius(RADIUS_SM)
          }
          if (this.resultText.length > 0) {
            Text(translate(this.lang, 'chat.tool.result'))
              .fontSize(FONT_XS)
              .fontColor(this.palette.textTertiary)
              .width('100%')
              .margin({ top: SPACE_XS })
            Scroll() {
              Text(this.resultText)
                .fontSize(FONT_XS)
                .fontFamily(MONO_FAMILY)
                .fontColor(this.isError ? this.palette.danger : this.palette.textSecondary)
                .width('100%')
            }
            .constraintSize({ maxHeight: 260 })
            .width('100%')
            .padding(SPACE_SM)
            .backgroundColor(this.palette.codeBackground)
            .borderRadius(RADIUS_SM)
            .scrollBar(BarState.Auto)
            .align(Alignment.TopStart)
          }
        }
        .width('100%')
        .padding({ left: SPACE_SM, right: SPACE_SM, bottom: SPACE_SM })
      }
    }
    .width('100%')
    .backgroundColor(this.palette.toolBg)
    .borderRadius(RADIUS_SM)
    .border({ width: 1, color: this.palette.toolBorder })
    .onClick(() => {
      this.expanded = !this.expanded;
    })
  }
}
