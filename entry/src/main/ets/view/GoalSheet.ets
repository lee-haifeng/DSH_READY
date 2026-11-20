/**
 * Goal mode sheet.
 *
 * Creating a goal turns one conversation into sustained work: after every settled reply
 * the agent continues on its own until the objective is met or the round cap is hit.
 */

import {
  DARK, FONT_BODY, FONT_MD, FONT_SM, FONT_TITLE, FONT_XS, Palette, RADIUS_MD, SPACE_LG, SPACE_MD, SPACE_SM, SPACE_XS
} from '../common/Theme';
import { KEY_LANG, KEY_PALETTE } from '../common/StateKeys';
import { translate } from '../i18n/Strings';
import { MAX_GOAL_ROUNDS } from '../common/Constants';

@Component
export struct GoalSheet {
  @Prop hasGoal: boolean = false;
  @Prop objective: string = '';
  @Prop phase: string = '';
  @Prop rounds: number = 0;
  @Prop maxRounds: number = MAX_GOAL_ROUNDS;
  @Prop blockedReason: string = '';
  onCreate: (objective: string) => void = (objective: string) => {};
  onPause: () => void = () => {};
  onResume: () => void = () => {};
  onComplete: () => void = () => {};
  onEnd: () => void = () => {};
  onClose: () => void = () => {};

  @StorageLink(KEY_LANG) lang: string = 'zh';
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;
  @State draft: string = '';

  private phaseLabel(): string {
    if (this.phase === 'active') {
      return translate(this.lang, 'goal.phase.active');
    }
    if (this.phase === 'paused') {
      return translate(this.lang, 'goal.phase.paused');
    }
    if (this.phase === 'complete') {
      return translate(this.lang, 'goal.phase.complete');
    }
    if (this.phase === 'blocked') {
      return translate(this.lang, 'goal.phase.blocked');
    }
    return this.phase;
  }

  private phaseColor(): string {
    if (this.phase === 'active') {
      return this.palette.accent;
    }
    if (this.phase === 'complete') {
      return this.palette.success;
    }
    if (this.phase === 'blocked') {
      return this.palette.danger;
    }
    return this.palette.warning;
  }

  @Builder
  Header() {
    Row() {
      Text(translate(this.lang, 'goal.title'))
        .fontSize(FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette.textPrimary)
        .layoutWeight(1)
      Text('✕')
        .fontSize(FONT_MD)
        .fontColor(this.palette.textSecondary)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    .padding({ left: SPACE_LG, right: SPACE_LG, top: SPACE_LG, bottom: SPACE_SM })
  }

  @Builder
  ActiveGoal() {
    Column({ space: SPACE_MD }) {
      Row({ space: SPACE_SM }) {
        Text(this.phaseLabel())
          .fontSize(FONT_XS)
          .fontColor(this.palette.onAccent)
          .padding({ left: SPACE_SM, right: SPACE_SM, top: 3, bottom: 3 })
          .backgroundColor(this.phaseColor())
          .borderRadius(10)
        Text(`${translate(this.lang, 'goal.rounds')} ${this.rounds}/${this.maxRounds}`)
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
      }
      .width('100%')

      Text(this.objective)
        .fontSize(FONT_BODY)
        .lineHeight(24)
        .fontColor(this.palette.textPrimary)
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)

      if (this.blockedReason.length > 0) {
        Column({ space: SPACE_XS }) {
          Text(translate(this.lang, 'goal.blockedReason'))
            .fontSize(FONT_XS)
            .fontColor(this.palette.textTertiary)
          Text(this.blockedReason)
            .fontSize(FONT_SM)
            .fontColor(this.palette.danger)
        }
        .width('100%')
        .padding(SPACE_MD)
        .backgroundColor(this.palette.dangerSoft)
        .borderRadius(RADIUS_MD)
      }

      Row({ space: SPACE_SM }) {
        if (this.phase === 'active') {
          Text(translate(this.lang, 'goal.pause'))
            .fontSize(FONT_SM)
            .fontColor(this.palette.textPrimary)
            .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
            .backgroundColor(this.palette.surfaceAlt)
            .borderRadius(RADIUS_MD)
            .onClick(() => {
              this.onPause();
            })
        } else if (this.phase === 'paused' || this.phase === 'blocked') {
          Text(translate(this.lang, 'goal.resume'))
            .fontSize(FONT_SM)
            .fontColor(this.palette.onAccent)
            .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
            .backgroundColor(this.palette.accent)
            .borderRadius(RADIUS_MD)
            .onClick(() => {
              this.onResume();
            })
        }
        if (this.phase !== 'complete') {
          Text(translate(this.lang, 'goal.complete'))
            .fontSize(FONT_SM)
            .fontColor(this.palette.success)
            .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
            .backgroundColor(this.palette.surfaceAlt)
            .borderRadius(RADIUS_MD)
            .onClick(() => {
              this.onComplete();
            })
        }
        Text(translate(this.lang, 'goal.delete'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.danger)
          .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
          .backgroundColor(this.palette.surfaceAlt)
          .borderRadius(RADIUS_MD)
          .onClick(() => {
            this.onEnd();
          })
      }
      .width('100%')

      Text(translate(this.lang, 'goal.note'))
        .fontSize(FONT_XS)
        .fontColor(this.palette.textTertiary)
        .width('100%')
    }
    .width('100%')
    .padding(SPACE_LG)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
  }

  @Builder
  CreateGoal() {
    Column({ space: SPACE_MD }) {
      Text(translate(this.lang, 'goal.subtitle'))
        .fontSize(FONT_SM)
        .lineHeight(20)
        .fontColor(this.palette.textSecondary)
        .width('100%')

      TextArea({ text: this.draft, placeholder: translate(this.lang, 'goal.objective.placeholder') })
        .placeholderColor(this.palette.textTertiary)
        .fontSize(FONT_BODY)
        .fontColor(this.palette.textPrimary)
        .backgroundColor(this.palette.surfaceAlt)
        .borderRadius(RADIUS_MD)
        .constraintSize({ minHeight: 110 })
        .width('100%')
        .onChange((value: string) => {
          this.draft = value;
        })

      Row() {
        Text(translate(this.lang, 'goal.create'))
          .fontSize(FONT_MD)
          .fontColor(this.palette.onAccent)
          .padding({ left: SPACE_LG, right: SPACE_LG, top: SPACE_SM, bottom: SPACE_SM })
          .backgroundColor(this.draft.trim().length > 0 ? this.palette.accent : this.palette.borderStrong)
          .borderRadius(RADIUS_MD)
          .onClick(() => {
            if (this.draft.trim().length === 0) {
              return;
            }
            this.onCreate(this.draft.trim());
            this.draft = '';
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(SPACE_LG)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
  }

  build() {
    Column({ space: SPACE_MD }) {
      this.Header()
      Scroll() {
        Column({ space: SPACE_MD }) {
          if (this.hasGoal) {
            this.ActiveGoal()
          } else {
            this.CreateGoal()
          }
        }
        .width('100%')
        .padding({ left: SPACE_LG, right: SPACE_LG, bottom: SPACE_LG })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.bg)
  }
}
