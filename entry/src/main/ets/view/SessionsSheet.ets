/**
 * SessionsSheet —— 会话列表 sheet（从聊天页弹出）。
 *
 * 设计约束（与 DSH Mobile 的其他 sheet 对齐）：
 *  - 数据全部来自 SessionStore：空搜索时 list()，有搜索词时 search()；
 *  - 列表在 load() 里压平成 SessionRow 数组（kind = header / row），
 *    渲染层只用一个 ForEach，避免嵌套分组结构带来的刷新歧义；
 *  - 刷新：aboutToAppear 拉一次；父组件 bumpRevision 后通过 @Watch 再拉一次；
 *  - 重命名是页内的输入卡片（promptAction 无法输入文本），确认后
 *    load -> 改 title -> save，不新增 SessionStore API；
 *  - 删除前用 promptAction.showDialog 二次确认，确认后 remove()；
 *  - 长按行或点右侧「⋯」打开展示在页内的操作菜单，不依赖系统菜单 API；
 *  - 本组件只负责展示和操作索引，不改父组件的当前会话状态。
 */

import {
  DARK, FONT_BODY, FONT_MD, FONT_SM, FONT_TITLE, FONT_XS, Palette, RADIUS_MD, RADIUS_SM, RADIUS_XL,
  SPACE_LG, SPACE_MD, SPACE_SM, SPACE_XS, SPACE_XL
} from '../common/Theme';
import { KEY_ACTIVE_SESSION, KEY_LANG, KEY_PALETTE, KEY_SESSION_REVISION } from '../common/StateKeys';
import { ChatSession, SessionSummary } from '../model/Types';
import { SearchHit, SessionStore } from '../service/SessionStore';
import { translate } from '../i18n/Strings';
import { formatSessionTime } from '../common/Utils';

/** 压平后的列表行类型：分组标题。 */
const KIND_HEADER: string = 'header';
/** 压平后的列表行类型：会话行。 */
const KIND_ROW: string = 'row';

/** 时间分组标识，只在本文件内部使用。 */
const GROUP_TODAY: string = 'today';
const GROUP_YESTERDAY: string = 'yesterday';
const GROUP_EARLIER: string = 'earlier';

/** 目标完成态：完成的目标不再显示“目标进行中”圆点。 */
const GOAL_PHASE_COMPLETE: string = 'complete';

/** 一天的毫秒数，用于计算“昨天”的边界。 */
const ONE_DAY_MS: number = 86400000;

/** 标题右侧目标进行中圆点的直径（vp）。 */
const GOAL_DOT_SIZE: number = 6;

/** 会话行标题字号（fp），契约要求 15fp。 */
const FONT_ROW_TITLE: number = 15;

/** 会话行上下内边距（vp），保证行高舒适。 */
const ROW_PADDING_V: number = 10;

/** 「⋯」点击热区的边长（vp）。 */
const MORE_HIT_SIZE: number = 30;

/** 操作菜单里每个按钮的高度（vp）。 */
const MENU_ITEM_HEIGHT: number = 46;

/** 全透明的颜色字符串，用于未选中行，避免叠加额外底色。 */
const TRANSPARENT_COLOR: string = '#00000000';

/**
 * 列表里的一行：分组标题或会话行。
 * load() 时一次性算好所有展示字段，build 里不再做数据加工。
 */
interface SessionRow {
  /** 'header' | 'row' */
  kind: string;
  /** 分组标题文本（kind = header 时有效）。 */
  label: string;
  /** 会话 id（kind = row 时有效）。 */
  id: string;
  /** 会话标题，可能为空串。 */
  title: string;
  /** 会话预览文字。 */
  preview: string;
  /** 更新时间戳，用于 formatSessionTime。 */
  time: number;
  /** 搜索命中片段，空搜索时为空串。 */
  snippet: string;
  /** 是否有进行中的目标（goalPhase 非空且不是 complete）。 */
  goalActive: boolean;
}

@Component
export struct SessionsSheet {
  // 父组件回调：选中会话 / 新建会话 / 关闭本 sheet。
  onPick: (id: string) => void = () => {};
  onNew: () => void = () => {};
  onClose: () => void = () => {};

  @StorageLink(KEY_LANG) lang: string = 'zh';
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;
  @StorageLink(KEY_SESSION_REVISION) @Watch('onRevision') revision: number = 0;

  /** 压平后的展示行（分组标题 + 会话行混排）。 */
  @State rows: SessionRow[] = [];
  /** 搜索框内容。 */
  @State query: string = '';
  /** 正在重命名的会话 id，空串表示不显示重命名卡片。 */
  @State renamingId: string = '';
  /** 重命名输入框的草稿文本。 */
  @State renameText: string = '';
  /** 操作菜单对应的会话 id，空串表示菜单关闭。 */
  @State menuId: string = '';
  /** 操作菜单顶部展示的会话标题。 */
  @State menuTitle: string = '';

  aboutToAppear(): void {
    this.load();
  }

  /** revision 变化说明索引被改过（新建 / 保存 / 删除），重新拉一次列表。 */
  onRevision(): void {
    this.load();
  }

  // -------------------------------------------------------------------------
  // 数据加载与展示辅助
  // -------------------------------------------------------------------------

  /** 按当前搜索词重建扁平行数组。任何异常都降级为空列表，保证页面不崩。 */
  private load(): void {
    const rows: SessionRow[] = [];
    try {
      const trimmed: string = this.query.trim();
      if (trimmed.length > 0) {
        const hits: SearchHit[] = SessionStore.search(trimmed);
        for (let i = 0; i < hits.length; i++) {
          const hit: SearchHit = hits[i];
          rows.push(this.makeRow(hit.summary, hit.snippet));
        }
      } else {
        this.appendGrouped(rows, SessionStore.list());
      }
    } catch (error) {
      // 磁盘读取失败时保持空列表，不把异常抛到 UI 线程。
    }
    this.rows = rows;
  }

  /** 把按 updatedAt 倒序的会话按 今天 / 昨天 / 更早 分组压平。 */
  private appendGrouped(rows: SessionRow[], sessions: SessionSummary[]): void {
    const now: Date = new Date();
    const startOfToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const startOfYesterday: number = startOfToday - ONE_DAY_MS;
    let currentGroup: string = '';
    for (let i = 0; i < sessions.length; i++) {
      const summary: SessionSummary = sessions[i];
      let group: string = GROUP_EARLIER;
      if (summary.updatedAt >= startOfToday) {
        group = GROUP_TODAY;
      } else if (summary.updatedAt >= startOfYesterday) {
        group = GROUP_YESTERDAY;
      }
      if (group !== currentGroup) {
        currentGroup = group;
        rows.push(this.makeHeader(group));
      }
      rows.push(this.makeRow(summary, ''));
    }
  }

  /** 构造一条分组标题行。 */
  private makeHeader(group: string): SessionRow {
    const row: SessionRow = {
      kind: KIND_HEADER,
      label: this.groupTitle(group),
      id: '',
      title: '',
      preview: '',
      time: 0,
      snippet: '',
      goalActive: false
    };
    return row;
  }

  /** 构造一条会话行；索引文件可能由旧版本写出，字段缺失时做兜底。 */
  private makeRow(summary: SessionSummary, snippet: string): SessionRow {
    const title: string = summary.title === undefined ? '' : summary.title;
    const preview: string = summary.preview === undefined ? '' : summary.preview;
    const phase: string = summary.goalPhase === undefined ? '' : summary.goalPhase;
    const row: SessionRow = {
      kind: KIND_ROW,
      label: '',
      id: summary.id,
      title: title,
      preview: preview,
      time: summary.updatedAt,
      snippet: snippet,
      goalActive: phase.length > 0 && phase !== GOAL_PHASE_COMPLETE
    };
    return row;
  }

  /** 分组标识 -> 本地化标题。 */
  private groupTitle(group: string): string {
    if (group === GROUP_TODAY) {
      return translate(this.lang, 'session.today');
    }
    if (group === GROUP_YESTERDAY) {
      return translate(this.lang, 'session.yesterday');
    }
    return translate(this.lang, 'session.earlier');
  }

  /** 空标题统一显示“新对话”。 */
  private rowTitle(row: SessionRow): string {
    const title: string = row.title.trim();
    if (title.length === 0) {
      return translate(this.lang, 'session.untitled');
    }
    return title;
  }

  /** 第二行：搜索时优先展示命中片段，否则展示会话预览。 */
  private rowSubtitle(row: SessionRow): string {
    if (row.snippet.length > 0) {
      return row.snippet;
    }
    return row.preview;
  }

  /** 右侧时间：今天 / 昨天 + 时刻，更早显示日期。 */
  private rowTimeLabel(row: SessionRow): string {
    return formatSessionTime(row.time, translate(this.lang, 'session.today'),
      translate(this.lang, 'session.yesterday'));
  }

  /** 当前是否有搜索词。 */
  private hasQuery(): boolean {
    return this.query.trim().length > 0;
  }

  /** 空列表文案：搜索无结果与完全没有会话区分开。 */
  private emptyText(): string {
    if (this.hasQuery()) {
      return translate(this.lang, 'session.search.empty');
    }
    return translate(this.lang, 'session.empty');
  }

  /** 当前打开的会话 id，用于给对应行加一点底色。 */
  private activeId(): string {
    const value: string | undefined = AppStorage.get<string>(KEY_ACTIVE_SESSION);
    return value === undefined ? '' : value;
  }

  /** 选中行用 surfaceAlt，其余透明。 */
  private rowBackground(row: SessionRow): string {
    if (row.id.length > 0 && row.id === this.activeId()) {
      return this.palette.surfaceAlt;
    }
    return TRANSPARENT_COLOR;
  }

  // -------------------------------------------------------------------------
  // 重命名 / 删除 / 操作菜单
  // -------------------------------------------------------------------------

  /** 打开页内操作菜单（长按行或点「⋯」触发）。 */
  private openMenu(row: SessionRow): void {
    this.menuId = row.id;
    this.menuTitle = this.rowTitle(row);
  }

  private closeMenu(): void {
    this.menuId = '';
    this.menuTitle = '';
  }

  /** 进入重命名：把当前标题读进输入框。 */
  private startRename(id: string): void {
    const session: ChatSession | undefined = SessionStore.load(id);
    this.renamingId = id;
    this.renameText = session === undefined ? '' : session.title;
    this.closeMenu();
  }

  private cancelRename(): void {
    this.renamingId = '';
    this.renameText = '';
  }

  /** 确认重命名：load -> 改 title -> save（SessionStore 没有 rename API）。 */
  private confirmRename(): void {
    const id: string = this.renamingId;
    const title: string = this.renameText.trim();
    if (id.length > 0) {
      const session: ChatSession | undefined = SessionStore.load(id);
      if (session !== undefined) {
        session.title = title;
        SessionStore.save(session);
      }
    }
    this.cancelRename();
    this.load();
  }

  /** 删除前弹系统确认框，确认后才删。 */
  private async requestDelete(id: string): Promise<void> {
    let confirmed: boolean = false;
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: translate(this.lang, 'common.delete'),
        message: translate(this.lang, 'session.delete.confirm'),
        buttons: [
          { text: translate(this.lang, 'common.cancel'), color: this.palette.textSecondary },
          { text: translate(this.lang, 'common.delete'), color: this.palette.danger }
        ]
      });
      confirmed = result.index === 1;
    } catch (error) {
      confirmed = false;
    }
    if (confirmed) {
      SessionStore.remove(id);
      this.load();
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @Builder
  TopBar() {
    Row() {
      Column() {
        Text('‹')
          .fontSize(30)
          .fontColor(this.palette.textPrimary)
      }
      .width(36)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.onClose();
      })

      Text(translate(this.lang, 'session.title'))
        .fontSize(FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette.textPrimary)
        .layoutWeight(1)
        .margin({ left: SPACE_XS })

      Text(`＋ ${translate(this.lang, 'session.new')}`)
        .fontSize(FONT_MD)
        .fontColor(this.palette.accent)
        .padding({ left: SPACE_SM, right: 0, top: SPACE_XS, bottom: SPACE_XS })
        .onClick(() => {
          this.onNew();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: SPACE_SM, right: SPACE_LG, top: SPACE_LG, bottom: SPACE_MD })
  }

  @Builder
  SearchBar() {
    Row() {
      Text('⌕')
        .fontSize(FONT_BODY)
        .fontColor(this.palette.textTertiary)
        .margin({ right: SPACE_XS })
      TextInput({ text: this.query, placeholder: translate(this.lang, 'session.search.placeholder') })
        .layoutWeight(1)
        .height(36)
        .fontSize(FONT_MD)
        .fontColor(this.palette.textPrimary)
        .placeholderColor(this.palette.textTertiary)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0, top: 0, bottom: 0 })
        .onChange((value: string) => {
          this.query = value;
          this.load();
        })
      if (this.query.length > 0) {
        Text('✕')
          .fontSize(FONT_SM)
          .fontColor(this.palette.textTertiary)
          .padding({ left: SPACE_SM })
          .onClick(() => {
            this.query = '';
            this.load();
          })
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: SPACE_MD, right: SPACE_MD })
    .backgroundColor(this.palette.surfaceAlt)
    .borderRadius(RADIUS_MD)
    .margin({ left: SPACE_LG, right: SPACE_LG, bottom: SPACE_MD })
  }

  /** 列表上方的重命名输入卡片。 */
  @Builder
  RenameCard() {
    Column() {
      Text(translate(this.lang, 'session.rename.title'))
        .fontSize(FONT_SM)
        .fontColor(this.palette.textSecondary)
        .width('100%')
      Row() {
        TextInput({ text: this.renameText, placeholder: translate(this.lang, 'session.rename.placeholder') })
          .layoutWeight(1)
          .height(36)
          .fontSize(FONT_MD)
          .fontColor(this.palette.textPrimary)
          .placeholderColor(this.palette.textTertiary)
          .backgroundColor(this.palette.surfaceHigh)
          .borderRadius(RADIUS_SM)
          .padding({ left: SPACE_SM, right: SPACE_SM })
          .onChange((value: string) => {
            this.renameText = value;
          })
        Text(translate(this.lang, 'common.cancel'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.textSecondary)
          .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
          .margin({ left: SPACE_XS })
          .onClick(() => {
            this.cancelRename();
          })
        Text(translate(this.lang, 'common.ok'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.onAccent)
          .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
          .backgroundColor(this.palette.accent)
          .borderRadius(RADIUS_SM)
          .onClick(() => {
            this.confirmRename();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: SPACE_SM })
    }
    .width('100%')
    .padding(SPACE_MD)
    .backgroundColor(this.palette.surfaceAlt)
    .borderRadius(RADIUS_MD)
    .margin({ left: SPACE_LG, right: SPACE_LG, bottom: SPACE_SM })
  }

  @Builder
  SessionList() {
    List() {
      ForEach(this.rows, (row: SessionRow, index: number) => {
        ListItem() {
          if (row.kind === KIND_HEADER) {
            this.GroupHeader(row)
          } else {
            this.SessionRowView(row)
          }
        }
      }, (row: SessionRow, index: number): string => `${row.kind}-${row.label}-${row.id}`)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 分组标题：12fp 灰色，上方留白。 */
  @Builder
  GroupHeader(row: SessionRow) {
    Row() {
      Text(row.label)
        .fontSize(FONT_SM)
        .fontColor(this.palette.textTertiary)
    }
    .width('100%')
    .padding({ left: SPACE_LG, right: SPACE_LG, top: SPACE_LG, bottom: SPACE_XS })
  }

  /** 单个会话行：左标题/预览，右时间 + 「⋯」；长按弹操作菜单。 */
  @Builder
  SessionRowView(row: SessionRow) {
    Row() {
      Row() {
        Column() {
          Row() {
            Text(this.rowTitle(row))
              .fontSize(FONT_ROW_TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (row.goalActive) {
              // 用圆角容器画圆点：Circle.fill 的 ColorMetrics 重载要求 API 26，
              // 而本应用的 compatibleSdkVersion 是 6.1.1(24)，这里避开该 API。
              Row()
                .width(GOAL_DOT_SIZE)
                .height(GOAL_DOT_SIZE)
                .backgroundColor(this.palette.accent)
                .borderRadius(GOAL_DOT_SIZE / 2)
                .margin({ left: SPACE_XS })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.rowSubtitle(row).length > 0) {
            Text(this.rowSubtitle(row))
              .fontSize(FONT_SM)
              .fontColor(this.palette.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 3 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.rowTimeLabel(row))
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
          .margin({ left: SPACE_SM })
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          LongPressGesture()
            .onAction(() => {
              this.openMenu(row);
            }),
          TapGesture()
            .onAction(() => {
              this.onPick(row.id);
            })
        )
      )

      Text('⋯')
        .fontSize(FONT_BODY)
        .fontColor(this.palette.textTertiary)
        .width(MORE_HIT_SIZE)
        .height(MORE_HIT_SIZE)
        .textAlign(TextAlign.Center)
        .margin({ left: SPACE_XS })
        .onClick(() => {
          this.openMenu(row);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: SPACE_LG, right: SPACE_MD, top: ROW_PADDING_V, bottom: ROW_PADDING_V })
    .backgroundColor(this.rowBackground(row))
    .borderWidth({ bottom: 1 })
    .borderColor(this.palette.border)
  }

  @Builder
  EmptyState() {
    Column() {
      Text(this.emptyText())
        .fontSize(FONT_MD)
        .fontColor(this.palette.textTertiary)
        .textAlign(TextAlign.Center)
        .padding({ left: SPACE_XL, right: SPACE_XL })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 覆盖在页面上的操作菜单：重命名 / 删除 / 取消。 */
  @Builder
  ActionMenu() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.palette.scrim)
        .onClick(() => {
          this.closeMenu();
        })

      Column() {
        Text(this.menuTitle)
          .fontSize(FONT_SM)
          .fontColor(this.palette.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: SPACE_LG, right: SPACE_LG, top: SPACE_MD, bottom: SPACE_SM })
        Divider()
          .strokeWidth(1)
          .color(this.palette.border)
        Text(translate(this.lang, 'common.rename'))
          .fontSize(FONT_BODY)
          .fontColor(this.palette.textPrimary)
          .width('100%')
          .height(MENU_ITEM_HEIGHT)
          .textAlign(TextAlign.Start)
          .padding({ left: SPACE_LG, right: SPACE_LG })
          .onClick(() => {
            this.startRename(this.menuId);
          })
        Divider()
          .strokeWidth(1)
          .color(this.palette.border)
          .margin({ left: SPACE_LG, right: SPACE_LG })
        Text(translate(this.lang, 'common.delete'))
          .fontSize(FONT_BODY)
          .fontColor(this.palette.danger)
          .width('100%')
          .height(MENU_ITEM_HEIGHT)
          .textAlign(TextAlign.Start)
          .padding({ left: SPACE_LG, right: SPACE_LG })
          .onClick(() => {
            const id: string = this.menuId;
            this.closeMenu();
            this.requestDelete(id);
          })
        Divider()
          .strokeWidth(1)
          .color(this.palette.border)
        Text(translate(this.lang, 'common.cancel'))
          .fontSize(FONT_BODY)
          .fontColor(this.palette.textSecondary)
          .width('100%')
          .height(MENU_ITEM_HEIGHT)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.closeMenu();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.palette.surfaceHigh)
      .borderRadius({ topLeft: RADIUS_XL, topRight: RADIUS_XL })
      .padding({ top: SPACE_SM, bottom: SPACE_XL })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.TopBar()
        this.SearchBar()
        if (this.renamingId.length > 0) {
          this.RenameCard()
        }
        if (this.rows.length === 0) {
          this.EmptyState()
        } else {
          this.SessionList()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.palette.surface)
      .borderRadius({ topLeft: RADIUS_XL, topRight: RADIUS_XL })
      .clip(true)

      if (this.menuId.length > 0) {
        this.ActionMenu()
      }
    }
    .width('100%')
    .height('100%')
  }
}
