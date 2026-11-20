/**
 * SettingsSheet —— 全屏设置面板。
 *
 * 从聊天页以全屏 sheet 形式弹出，集中管理：API Key、服务地址、模型、推理强度、
 * 最大输出长度、随机性、自定义人设、外观（主题）、语言、自动标题、搜索服务与关于信息。
 *
 * 状态约定：
 *  - 组件自己持有一份 @State settings 快照；任何修改都先构造一个“完整的”新
 *    AppSettings（ArkTS 不允许对象展开），交给 SettingsService.save 持久化并重新
 *    发布 lang / palette，然后整体替换本地快照，触发重绘；
 *  - 主题与语言由 SettingsService 重新发布到 AppStorage，本组件的 @StorageLink
 *    随之更新，因此切换后整个面板立即换色 / 换语言；
 *  - 长文本（自定义人设）使用本地草稿，失焦、点“完成/返回”或组件销毁时落盘，
 *    避免每敲一个字符都触发一次同步磁盘写入；
 *  - 滑块拖动期间只更新本地草稿用于实时回显，松手（End / Click）后才保存。
 *
 * 本文件只依赖既有公共模块，不修改任何其它文件。
 */

import {
  DARK,
  FONT_BODY,
  FONT_MD,
  FONT_SM,
  FONT_TITLE,
  FONT_XS,
  Palette,
  RADIUS_MD,
  RADIUS_SM,
  SPACE_LG,
  SPACE_MD,
  SPACE_SM,
  SPACE_XL,
  SPACE_XS,
  THEME_DARK,
  THEME_LIGHT,
  THEME_SYSTEM
} from '../common/Theme';
import { KEY_LANG, KEY_PALETTE } from '../common/StateKeys';
import {
  APP_NAME,
  APP_VERSION,
  BUILTIN_MODELS,
  DEFAULT_BASE_URL,
  EFFORT_HIGH,
  EFFORTS,
  MODEL_FLASH,
  ModelEntry,
  UPSTREAM_REPO
} from '../common/Constants';
import { AppSettings } from '../model/Types';
import { SEARCH_BING, SEARCH_DUCKDUCKGO, SettingsService } from '../service/SettingsService';
import { SecretService } from '../service/SecretService';
import { MemoryEntry, MemoryStore } from '../service/MemoryStore';
import { translate } from '../i18n/Strings';

/** 语言代码。i18n 模块未在契约中列出 LANG_* 常量，这里用本地常量兜底。 */
const LANG_ZH: string = 'zh';
const LANG_EN: string = 'en';

/** 最大输出长度滑块的取值范围（tokens）。 */
const MAX_TOKENS_MIN: number = 1024;
/** Matches the upstream adapter default cap of 256,000 tokens. */
const MAX_TOKENS_MAX: number = 262144;
const MAX_TOKENS_STEP: number = 1024;
const MAX_TOKENS_FALLBACK: number = 16384;
/**
 * Presets instead of a slider: 1K–256K on a phone-width track would make one pixel worth
 * thousands of tokens, so precise dragging is impossible and the control lies about itself.
 */
const MAX_TOKENS_PRESETS: Array<number> = [4096, 16384, 65536, 262144];

/** 设置页正文 / 行标签字号（视觉稿要求 15fp，现有令牌里没有 15，故本地定义）。 */
const CONTENT_FONT: number = 15;

/** 主题与语言的固定选项顺序。 */
const THEME_MODES: string[] = [THEME_SYSTEM, THEME_LIGHT, THEME_DARK];
const LANGUAGE_CODES: string[] = [LANG_ZH, LANG_EN];

/** 设置页最多直接列出多少条记忆，其余只显示总数。 */
const MEMORY_DISPLAY_LIMIT: number = 30;

/**
 * @State 字段的占位初始值。
 * ArkTS 要求 @State 变量本地初始化，aboutToAppear 里会立刻换成 SettingsService 的快照。
 */
const FALLBACK_SETTINGS: AppSettings = {
  baseUrl: DEFAULT_BASE_URL,
  modelId: MODEL_FLASH,
  effort: EFFORT_HIGH,
  maxTokens: MAX_TOKENS_FALLBACK,
  systemPrompt: '',
  language: LANG_ZH,
  themeMode: THEME_SYSTEM,
  autoTitle: true,
  searchProvider: SEARCH_DUCKDUCKGO,
  hasApiKey: false,
  apiKeyHint: ''
};

@Component
export struct SettingsSheet {
  /** 关闭回调，由聊天页传入（允许 @Prop 传函数）。 */
  onClose: () => void = () => {};

  @StorageLink(KEY_LANG) lang: string = LANG_ZH;
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;

  /** 持久化设置的本地快照。 */
  @State settings: AppSettings = FALLBACK_SETTINGS;
  /** API Key 输入草稿（仅在未配置 / 更换密钥时使用）。 */
  @State apiKeyDraft: string = '';
  /** 已有密钥时是否展开“更换密钥”输入框。 */
  @State editingKey: boolean = false;
  /** 密钥读写进行中，禁用按钮避免重复点击。 */
  @State keyBusy: boolean = false;
  /** 最大输出长度滑块拖动期间的本地回显值。 */
  @State maxTokensDraft: number = MAX_TOKENS_FALLBACK;
  /** 自定义人设草稿，失焦 / 关闭时落盘。 */
  @State systemPromptDraft: string = '';
  /** 长期记忆快照，最近的在前面。 */
  @State memories: Array<MemoryEntry> = [];

  aboutToAppear(): void {
    this.settings = SettingsService.get();
    this.maxTokensDraft = this.clampMaxTokens(this.settings.maxTokens);
    this.systemPromptDraft = this.settings.systemPrompt;
    this.apiKeyDraft = '';
    this.editingKey = false;
    this.refreshMemories();
    this.reconcileApiKey();
  }

  /* ------------------------------ long-term memory ---------------------------- */

  /** Reload the memory snapshot, newest first. */
  private refreshMemories(): void {
    const all: Array<MemoryEntry> = MemoryStore.all();
    const rows: Array<MemoryEntry> = [];
    for (let i = all.length - 1; i >= 0; i--) {
      rows.push(all[i]);
    }
    this.memories = rows;
  }

  /** Pin or unpin one entry. */
  private togglePin(id: string, pinned: boolean): void {
    MemoryStore.setPinned(id, !pinned);
    this.refreshMemories();
  }

  /** Delete one entry after confirmation. */
  private async confirmDeleteMemory(id: string): Promise<void> {
    let confirmed: boolean = false;
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: translate(this.lang, 'common.delete'),
        message: translate(this.lang, 'settings.memory.deleteConfirm'),
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
      MemoryStore.remove(id);
      this.refreshMemories();
    }
  }

  /** Wipe every remembered fact after confirmation. */
  private async confirmClearMemories(): Promise<void> {
    let confirmed: boolean = false;
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: translate(this.lang, 'settings.memory.clear'),
        message: translate(this.lang, 'settings.memory.clearConfirm'),
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
      MemoryStore.clear();
      this.refreshMemories();
    }
  }

  /**
   * 凭据库是密钥的唯一真相来源，preferences 里只缓存提示。两者不一致时以凭据库为准：
   * 例如用户手动清空了凭据，或上一次写入在 flush 前被杀。
   */
  private async reconcileApiKey(): Promise<void> {
    const hasKey: boolean = await SecretService.hasApiKey();
    const hint: string = hasKey ? await SecretService.keyHint() : '';
    if (hasKey === this.settings.hasApiKey && hint === this.settings.apiKeyHint) {
      return;
    }
    const next: AppSettings = SettingsService.withApiKeyState(hasKey, hint);
    SettingsService.save(next);
    this.settings = next;
  }

  aboutToDisappear(): void {
    // 用户可能用系统手势直接关掉全屏 sheet，没有走 handleClose，这里补一次人设落盘。
    this.flushSystemPrompt();
  }

  // ---------------------------------------------------------------------------
  // 持久化与完整对象构造（ArkTS 禁止对象展开 / Partial，只能逐字段复制）
  // ---------------------------------------------------------------------------

  /** 保存完整快照并整体替换本地状态，驱动重绘。 */
  private applySettings(next: AppSettings): void {
    SettingsService.save(next);
    this.settings = next;
  }

  private withBaseUrl(baseUrl: string): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: baseUrl,
      modelId: s.modelId,
      effort: s.effort,
      maxTokens: s.maxTokens,
      systemPrompt: s.systemPrompt,
      language: s.language,
      themeMode: s.themeMode,
      autoTitle: s.autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withModel(modelId: string): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: modelId,
      effort: s.effort,
      maxTokens: s.maxTokens,
      systemPrompt: s.systemPrompt,
      language: s.language,
      themeMode: s.themeMode,
      autoTitle: s.autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withEffort(effort: string): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: s.modelId,
      effort: effort,
      maxTokens: s.maxTokens,
      systemPrompt: s.systemPrompt,
      language: s.language,
      themeMode: s.themeMode,
      autoTitle: s.autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withMaxTokens(maxTokens: number): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: s.modelId,
      effort: s.effort,
      maxTokens: maxTokens,
      systemPrompt: s.systemPrompt,
      language: s.language,
      themeMode: s.themeMode,
      autoTitle: s.autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withSystemPrompt(systemPrompt: string): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: s.modelId,
      effort: s.effort,
      maxTokens: s.maxTokens,
      systemPrompt: systemPrompt,
      language: s.language,
      themeMode: s.themeMode,
      autoTitle: s.autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withTheme(themeMode: string): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: s.modelId,
      effort: s.effort,
      maxTokens: s.maxTokens,
      systemPrompt: s.systemPrompt,
      language: s.language,
      themeMode: themeMode,
      autoTitle: s.autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withLang(language: string): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: s.modelId,
      effort: s.effort,
      maxTokens: s.maxTokens,
      systemPrompt: s.systemPrompt,
      language: language,
      themeMode: s.themeMode,
      autoTitle: s.autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withAutoTitle(autoTitle: boolean): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: s.modelId,
      effort: s.effort,
      maxTokens: s.maxTokens,
      systemPrompt: s.systemPrompt,
      language: s.language,
      themeMode: s.themeMode,
      autoTitle: autoTitle,
      searchProvider: s.searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  private withSearch(searchProvider: string): AppSettings {
    const s: AppSettings = this.settings;
    const next: AppSettings = {
      baseUrl: s.baseUrl,
      modelId: s.modelId,
      effort: s.effort,
      maxTokens: s.maxTokens,
      systemPrompt: s.systemPrompt,
      language: s.language,
      themeMode: s.themeMode,
      autoTitle: s.autoTitle,
      searchProvider: searchProvider,
      hasApiKey: s.hasApiKey,
      apiKeyHint: s.apiKeyHint
    };
    return next;
  }

  // ---------------------------------------------------------------------------
  // 各设置项的提交入口
  // ---------------------------------------------------------------------------

  /** 服务地址按契约“改动即保存”。 */
  private setBaseUrl(value: string): void {
    if (value === this.settings.baseUrl) {
      return;
    }
    this.applySettings(this.withBaseUrl(value));
  }

  private setModel(modelId: string): void {
    if (this.settings.modelId === modelId) {
      return;
    }
    this.applySettings(this.withModel(modelId));
  }

  private setEffort(effort: string): void {
    if (this.settings.effort === effort) {
      return;
    }
    this.applySettings(this.withEffort(effort));
  }

  /** 主题保存后 SettingsService 会重新发布 palette，本组件的 @StorageLink 立即换色。 */
  private setTheme(themeMode: string): void {
    if (this.settings.themeMode === themeMode) {
      return;
    }
    this.applySettings(this.withTheme(themeMode));
  }

  /** 语言保存后 SettingsService 会重新发布 KEY_LANG，本组件立即换文案。 */
  private setLanguage(language: string): void {
    if (this.settings.language === language) {
      return;
    }
    this.applySettings(this.withLang(language));
  }

  private setAutoTitle(autoTitle: boolean): void {
    if (this.settings.autoTitle === autoTitle) {
      return;
    }
    this.applySettings(this.withAutoTitle(autoTitle));
  }

  private setSearchProvider(searchProvider: string): void {
    if (this.settings.searchProvider === searchProvider) {
      return;
    }
    this.applySettings(this.withSearch(searchProvider));
  }

  /** 滑块值对齐到 step 并限制在范围内。 */
  private clampMaxTokens(value: number): number {
    const stepped: number = Math.round(value / MAX_TOKENS_STEP) * MAX_TOKENS_STEP;
    if (stepped < MAX_TOKENS_MIN) {
      return MAX_TOKENS_MIN;
    }
    if (stepped > MAX_TOKENS_MAX) {
      return MAX_TOKENS_MAX;
    }
    return stepped;
  }

  /** `4096` → `4K`，让预设按钮在两种语言下都保持短标签。 */
  private presetLabel(value: number): string {
    if (value >= 1024 && value % 1024 === 0) {
      return `${Math.round(value / 1024)}K`;
    }
    return `${value}`;
  }

  /** 保存最大输出长度；滑块松手时才落盘。 */
  private commitMaxTokens(value: number): void {
    const next: number = this.clampMaxTokens(value);
    this.maxTokensDraft = next;
    if (next === this.settings.maxTokens) {
      return;
    }
    this.applySettings(this.withMaxTokens(next));
  }

  /** 人设只在失焦 / 关闭面板 / 组件销毁时写入，避免逐字符同步落盘。 */
  private flushSystemPrompt(): void {
    if (this.systemPromptDraft === this.settings.systemPrompt) {
      return;
    }
    this.applySettings(this.withSystemPrompt(this.systemPromptDraft));
  }

  // ---------------------------------------------------------------------------
  // API Key
  // ---------------------------------------------------------------------------

  private startEditingKey(): void {
    this.apiKeyDraft = '';
    this.editingKey = true;
  }

  private cancelEditingKey(): void {
    this.apiKeyDraft = '';
    this.editingKey = false;
  }

  private async saveApiKey(): Promise<void> {
    if (this.keyBusy) {
      return;
    }
    const value: string = this.apiKeyDraft.trim();
    if (value.length === 0) {
      return;
    }
    this.keyBusy = true;
    try {
      await SecretService.setApiKey(value);
      const hint: string = await SecretService.keyHint();
      const next: AppSettings = SettingsService.withApiKeyState(true, hint);
      this.applySettings(next);
      this.apiKeyDraft = '';
      this.editingKey = false;
      this.toast(translate(this.lang, 'common.saved'));
    } catch (e) {
      this.toast(translate(this.lang, 'error.unknown'));
    } finally {
      this.keyBusy = false;
    }
  }

  private async clearApiKey(): Promise<void> {
    if (this.keyBusy) {
      return;
    }
    this.keyBusy = true;
    try {
      await SecretService.clearApiKey();
      const next: AppSettings = SettingsService.withApiKeyState(false, '');
      this.applySettings(next);
      this.apiKeyDraft = '';
      this.editingKey = false;
      this.toast(translate(this.lang, 'common.saved'));
    } catch (e) {
      this.toast(translate(this.lang, 'error.unknown'));
    } finally {
      this.keyBusy = false;
    }
  }

  /** 统一的轻提示；走 UIContext 的新接口，避免使用已废弃的全局 promptAction。 */
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  /** 返回 / 完成：先把未落盘的人设写入，再交给父组件关闭。 */
  private handleClose(): void {
    this.flushSystemPrompt();
    this.onClose();
  }

  // ---------------------------------------------------------------------------
  // 通用小部件
  // ---------------------------------------------------------------------------

  @Builder
  cardTitle(title: string) {
    Text(title)
      .fontSize(FONT_SM)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.palette.textTertiary)
      .width('100%')
  }

  @Builder
  noteText(text: string) {
    Text(text)
      .fontSize(FONT_SM)
      .fontColor(this.palette.textSecondary)
      .lineHeight(18)
      .width('100%')
  }

  /** 单选标记：实心 accent 圆点 / 空心描边圆。 */
  @Builder
  radioMark(selected: boolean) {
    Text(selected ? '●' : '○')
      .fontSize(FONT_MD)
      .fontColor(selected ? this.palette.accent : this.palette.borderStrong)
      .width(20)
      .textAlign(TextAlign.Center)
  }

  @Builder
  modelRow(entry: ModelEntry) {
    Row({ space: SPACE_MD }) {
      this.radioMark(this.settings.modelId === entry.id)
      Text(entry.label)
        .fontSize(CONTENT_FONT)
        .fontColor(this.palette.textPrimary)
        .layoutWeight(1)
      Text(entry.supportsImages ? translate(this.lang, 'settings.model.images') :
        translate(this.lang, 'settings.model.textOnly'))
        .fontSize(FONT_XS)
        .fontColor(this.palette.textSecondary)
        .padding({ left: SPACE_SM, right: SPACE_SM, top: 2, bottom: 2 })
        .borderRadius(RADIUS_SM)
        .backgroundColor(this.palette.surface)
    }
    .width('100%')
    .height(48)
    .padding({ left: SPACE_MD, right: SPACE_MD })
    .alignItems(VerticalAlign.Center)
    .borderWidth(1)
    .borderColor(this.settings.modelId === entry.id ? this.palette.accent : this.palette.border)
    .backgroundColor(this.settings.modelId === entry.id ? this.palette.accentSoft : this.palette.surfaceAlt)
    .borderRadius(RADIUS_SM)
    .onClick(() => { this.setModel(entry.id); })
  }

  @Builder
  effortSegment(effort: string) {
    Column() {
      Text(translate(this.lang, `settings.effort.${effort}`))
        .fontSize(FONT_MD)
        .fontColor(this.settings.effort === effort ? this.palette.onAccent : this.palette.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(38)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(RADIUS_SM)
    .backgroundColor(this.settings.effort === effort ? this.palette.accent : this.palette.surfaceAlt)
    .onClick(() => { this.setEffort(effort); })
  }

  @Builder
  themeSegment(themeMode: string) {
    Column() {
      Text(translate(this.lang, `settings.theme.${themeMode}`))
        .fontSize(FONT_MD)
        .fontColor(this.settings.themeMode === themeMode ? this.palette.onAccent : this.palette.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(38)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(RADIUS_SM)
    .backgroundColor(this.settings.themeMode === themeMode ? this.palette.accent : this.palette.surfaceAlt)
    .onClick(() => { this.setTheme(themeMode); })
  }

  @Builder
  languageSegment(language: string) {
    Column() {
      Text(translate(this.lang, `settings.language.${language}`))
        .fontSize(FONT_MD)
        .fontColor(this.settings.language === language ? this.palette.onAccent : this.palette.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(38)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(RADIUS_SM)
    .backgroundColor(this.settings.language === language ? this.palette.accent : this.palette.surfaceAlt)
    .onClick(() => { this.setLanguage(language); })
  }

  @Builder
  searchRow(provider: string, label: string) {
    Row({ space: SPACE_MD }) {
      this.radioMark(this.settings.searchProvider === provider)
      Text(label)
        .fontSize(CONTENT_FONT)
        .fontColor(this.palette.textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .padding({ left: SPACE_MD, right: SPACE_MD })
    .alignItems(VerticalAlign.Center)
    .borderWidth(1)
    .borderColor(this.settings.searchProvider === provider ? this.palette.accent : this.palette.border)
    .backgroundColor(this.settings.searchProvider === provider ? this.palette.accentSoft : this.palette.surfaceAlt)
    .borderRadius(RADIUS_SM)
    .onClick(() => { this.setSearchProvider(provider); })
  }

  // ---------------------------------------------------------------------------
  // 1. API Key
  // ---------------------------------------------------------------------------

  @Builder
  apiKeyCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.apiKey'))
      if (this.settings.hasApiKey && !this.editingKey) {
        Row({ space: SPACE_MD }) {
          Column({ space: SPACE_XS }) {
            Text(translate(this.lang, 'settings.apiKey.saved'))
              .fontSize(CONTENT_FONT)
              .fontColor(this.palette.textPrimary)
            Text(this.settings.apiKeyHint.length > 0 ? this.settings.apiKeyHint : '••••')
              .fontSize(FONT_SM)
              .fontColor(this.palette.textSecondary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button(translate(this.lang, 'settings.apiKey.change'))
            .height(36)
            .fontSize(FONT_MD)
            .fontColor(this.palette.accent)
            .backgroundColor(this.palette.accentSoft)
            .enabled(!this.keyBusy)
            .onClick(() => { this.startEditingKey(); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Button(translate(this.lang, 'settings.apiKey.clear'))
          .width('100%')
          .height(40)
          .fontSize(FONT_MD)
          .fontColor(this.palette.danger)
          .backgroundColor(this.palette.dangerSoft)
          .enabled(!this.keyBusy)
          .onClick(() => { this.clearApiKey(); })
      } else {
        Column({ space: SPACE_SM }) {
          Row({ space: SPACE_SM }) {
            TextInput({ text: this.apiKeyDraft, placeholder: translate(this.lang, 'settings.apiKey.placeholder') })
              .type(InputType.Password)
              .layoutWeight(1)
              .height(44)
              .fontSize(CONTENT_FONT)
              .fontColor(this.palette.textPrimary)
              .placeholderColor(this.palette.textTertiary)
              .caretColor(this.palette.accent)
              .backgroundColor(this.palette.surfaceAlt)
              .borderRadius(RADIUS_SM)
              .onChange((value: string) => { this.apiKeyDraft = value; })
            Button(translate(this.lang, 'common.save'))
              .height(44)
              .fontSize(FONT_MD)
              .fontColor(this.palette.onAccent)
              .backgroundColor(this.palette.accent)
              .enabled(!this.keyBusy && this.apiKeyDraft.trim().length > 0)
              .onClick(() => { this.saveApiKey(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          if (this.editingKey) {
            Text(translate(this.lang, 'common.cancel'))
              .fontSize(FONT_MD)
              .fontColor(this.palette.textSecondary)
              .onClick(() => { this.cancelEditingKey(); })
          }
        }
        .width('100%')
      }
      this.noteText(translate(this.lang, 'settings.apiKey.note'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 2. 服务地址
  // ---------------------------------------------------------------------------

  @Builder
  endpointCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.baseUrl'))
      TextInput({ text: this.settings.baseUrl, placeholder: DEFAULT_BASE_URL })
        .height(44)
        .fontSize(CONTENT_FONT)
        .fontColor(this.palette.textPrimary)
        .placeholderColor(this.palette.textTertiary)
        .caretColor(this.palette.accent)
        .backgroundColor(this.palette.surfaceAlt)
        .borderRadius(RADIUS_SM)
        .onChange((value: string) => { this.setBaseUrl(value); })
      this.noteText(translate(this.lang, 'settings.baseUrl.note'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 3. 模型
  // ---------------------------------------------------------------------------

  @Builder
  modelCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.model'))
      Column({ space: SPACE_SM }) {
        ForEach(BUILTIN_MODELS, (entry: ModelEntry, index: number) => {
          this.modelRow(entry)
        }, (entry: ModelEntry, index: number): string => entry.id)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 4. 推理强度
  // ---------------------------------------------------------------------------

  @Builder
  effortCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.effort'))
      Row({ space: SPACE_XS }) {
        ForEach(EFFORTS, (effort: string, index: number) => {
          this.effortSegment(effort)
        }, (effort: string, index: number): string => effort)
      }
      .width('100%')
      this.noteText(translate(this.lang, 'settings.effort.note'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 5. 最大输出长度
  // ---------------------------------------------------------------------------

  @Builder
  maxTokensCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.maxTokens'))
      Row({ space: SPACE_SM }) {
        ForEach(MAX_TOKENS_PRESETS, (preset: number) => {
          Text(this.presetLabel(preset))
            .fontSize(FONT_SM)
            .fontColor(this.maxTokensDraft === preset ? this.palette.onAccent : this.palette.textPrimary)
            .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
            .backgroundColor(this.maxTokensDraft === preset ? this.palette.accent : this.palette.surfaceAlt)
            .borderRadius(RADIUS_MD)
            .onClick(() => {
              this.commitMaxTokens(preset);
            })
        }, (preset: number) => `maxtok-${preset}`)
      }
      .width('100%')

      Row({ space: SPACE_SM }) {
        Text(translate(this.lang, 'settings.maxTokens.note'))
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
          .lineHeight(16)
          .layoutWeight(1)
        Text(`${this.maxTokensDraft}`)
          .fontSize(FONT_XS)
          .fontColor(this.palette.accent)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 6. 自定义人设
  // ---------------------------------------------------------------------------

  @Builder
  personaCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.systemPrompt'))
      TextArea({
        text: this.systemPromptDraft,
        placeholder: translate(this.lang, 'settings.systemPrompt.placeholder')
      })
        .width('100%')
        .height(120)
        .fontSize(CONTENT_FONT)
        .fontColor(this.palette.textPrimary)
        .placeholderColor(this.palette.textTertiary)
        .caretColor(this.palette.accent)
        .backgroundColor(this.palette.surfaceAlt)
        .borderRadius(RADIUS_SM)
        .padding(SPACE_MD)
        .onChange((value: string) => { this.systemPromptDraft = value; })
        .onBlur(() => { this.flushSystemPrompt(); })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 8. 外观（主题）
  // ---------------------------------------------------------------------------

  @Builder
  appearanceCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.appearance'))
      Row({ space: SPACE_XS }) {
        ForEach(THEME_MODES, (themeMode: string, index: number) => {
          this.themeSegment(themeMode)
        }, (themeMode: string, index: number): string => themeMode)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 9. 语言
  // ---------------------------------------------------------------------------

  @Builder
  languageCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.language'))
      Row({ space: SPACE_XS }) {
        ForEach(LANGUAGE_CODES, (language: string, index: number) => {
          this.languageSegment(language)
        }, (language: string, index: number): string => language)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 10. 自动生成会话标题
  // ---------------------------------------------------------------------------

  @Builder
  autoTitleCard() {
    Row({ space: SPACE_MD }) {
      Text(translate(this.lang, 'settings.autoTitle'))
        .fontSize(CONTENT_FONT)
        .fontColor(this.palette.textPrimary)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.settings.autoTitle })
        .selectedColor(this.palette.accent)
        .onChange((isOn: boolean) => { this.setAutoTitle(isOn); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 11. 搜索服务
  // ---------------------------------------------------------------------------

  @Builder
  searchCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.searchProvider'))
      Column({ space: SPACE_SM }) {
        this.searchRow(SEARCH_DUCKDUCKGO, translate(this.lang, 'settings.searchProvider.duck'))
        this.searchRow(SEARCH_BING, translate(this.lang, 'settings.searchProvider.bing'))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 12. 长期记忆
  // ---------------------------------------------------------------------------

  @Builder
  memoryRow(entry: MemoryEntry) {
    Row({ space: SPACE_SM }) {
      Text(entry.text)
        .fontSize(FONT_SM)
        .fontColor(this.palette.textPrimary)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(entry.pinned ? '★' : '☆')
        .fontSize(FONT_MD)
        .fontColor(entry.pinned ? this.palette.warning : this.palette.textTertiary)
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.togglePin(entry.id, entry.pinned);
        })
      Text('×')
        .fontSize(FONT_MD)
        .fontColor(this.palette.textTertiary)
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.confirmDeleteMemory(entry.id);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: SPACE_XS, bottom: SPACE_XS })
  }

  @Builder
  memoryCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.memory'))
      Row({ space: SPACE_SM }) {
        Text(translate(this.lang, 'settings.memory.note'))
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
          .lineHeight(16)
          .layoutWeight(1)
        Text(`${this.memories.length}`)
          .fontSize(FONT_XS)
          .fontColor(this.palette.accent)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.memories.length === 0) {
        Text(translate(this.lang, 'settings.memory.empty'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.textSecondary)
          .lineHeight(18)
          .width('100%')
      } else {
        Column({ space: SPACE_XS }) {
          ForEach(this.memories.slice(0, MEMORY_DISPLAY_LIMIT), (entry: MemoryEntry) => {
            this.memoryRow(entry)
          }, (entry: MemoryEntry) => `mem-${entry.id}-${entry.pinned}`)
        }
        .width('100%')

        if (this.memories.length > MEMORY_DISPLAY_LIMIT) {
          Text(translate(this.lang, 'settings.memory.overflow'))
            .fontSize(FONT_XS)
            .fontColor(this.palette.textTertiary)
            .width('100%')
        }

        Row() {
          Blank()
          Text(translate(this.lang, 'settings.memory.clear'))
            .fontSize(FONT_SM)
            .fontColor(this.palette.danger)
            .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
            .backgroundColor(this.palette.surfaceAlt)
            .borderRadius(RADIUS_SM)
            .onClick(() => {
              this.confirmClearMemories();
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 13. 关于
  // ---------------------------------------------------------------------------

  @Builder
  aboutCard() {
    Column({ space: SPACE_MD }) {
      this.cardTitle(translate(this.lang, 'settings.about'))
      Text(APP_NAME)
        .fontSize(CONTENT_FONT)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette.textPrimary)
        .width('100%')
      Row() {
        Text(translate(this.lang, 'settings.about.version'))
          .fontSize(FONT_MD)
          .fontColor(this.palette.textSecondary)
        Blank()
        Text(APP_VERSION)
          .fontSize(FONT_MD)
          .fontColor(this.palette.textPrimary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Row() {
        Text(translate(this.lang, 'settings.about.upstream'))
          .fontSize(FONT_MD)
          .fontColor(this.palette.textSecondary)
        Text(UPSTREAM_REPO)
          .fontSize(FONT_SM)
          .fontColor(this.palette.textSecondary)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .wordBreak(WordBreak.BREAK_ALL)
          .margin({ left: SPACE_MD })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Row() {
        Text(translate(this.lang, 'settings.about.license'))
          .fontSize(FONT_MD)
          .fontColor(this.palette.textSecondary)
        Blank()
        Text(translate(this.lang, 'settings.about.licenseValue'))
          .fontSize(FONT_MD)
          .fontColor(this.palette.textPrimary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      this.noteText(translate(this.lang, 'about.body'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.surface)
    .borderRadius(RADIUS_MD)
    .padding(SPACE_LG)
  }

  // ---------------------------------------------------------------------------
  // 顶部标题栏
  // ---------------------------------------------------------------------------

  @Builder
  headerBar() {
    Stack() {
      Row() {
        Column() {
          Text('‹')
            .fontSize(30)
            .fontColor(this.palette.textPrimary)
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => { this.handleClose(); })

        Blank()

        Column() {
          Text(translate(this.lang, 'common.done'))
            .fontSize(FONT_BODY)
            .fontColor(this.palette.accent)
        }
        .height(44)
        .padding({ left: SPACE_MD, right: SPACE_MD })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => { this.handleClose(); })
      }
      .width('100%')
      .height(56)
      .padding({ left: SPACE_SM, right: SPACE_SM })
      .alignItems(VerticalAlign.Center)

      Text(translate(this.lang, 'settings.title'))
        .fontSize(FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette.textPrimary)
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.palette.bg)
    .borderWidth({ bottom: 1 })
    .borderColor(this.palette.border)
  }

  // ---------------------------------------------------------------------------
  // 页面骨架
  // ---------------------------------------------------------------------------

  build() {
    Column() {
      this.headerBar()
      Scroll() {
        Column({ space: SPACE_LG }) {
          this.apiKeyCard()
          this.endpointCard()
          this.modelCard()
          this.effortCard()
          this.maxTokensCard()
          this.personaCard()
          this.appearanceCard()
          this.languageCard()
          this.autoTitleCard()
          this.searchCard()
          this.memoryCard()
          this.aboutCard()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: SPACE_LG, right: SPACE_LG, top: SPACE_MD, bottom: SPACE_XL })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.bg)
  }
}
