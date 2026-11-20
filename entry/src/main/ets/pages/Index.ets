/**
 * Chat screen — the application shell.
 *
 * Owns the active session, runs the agent loop, and hosts the three sheets (sessions,
 * settings, goal) plus the blocking ask-user overlay. Streaming text is kept in
 * dedicated fields so a long answer never re-renders the committed message list.
 */

import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  DARK, FONT_BODY, FONT_HERO, FONT_MD, FONT_SM, FONT_TITLE, FONT_XS, Palette, RADIUS_LG, RADIUS_MD,
  SPACE_LG, SPACE_MD, SPACE_SM, SPACE_XS
} from '../common/Theme';
import {
  KEY_IS_DARK, KEY_LANG, KEY_PALETTE, KEY_SESSION_REVISION
} from '../common/StateKeys';
import { translate } from '../i18n/Strings';
import {
  AppSettings, BLOCK_TEXT, ChatMessage, ChatSession, ContentBlock, Goal, GOAL_ACTIVE,
  GOAL_COMPLETE, GOAL_PAUSED, ROLE_SYSTEM, ROLE_USER, TodoItem, TODO_COMPLETED,
  TODO_IN_PROGRESS, TokenUsage
} from '../model/Types';
import { buildRenderItems, RenderItem, ToolPair } from '../model/Render';
import { MAX_IMAGES_PER_MESSAGE } from '../common/Constants';
import { clip, formatSessionTime, newId } from '../common/Utils';
import { errorMessage } from '../common/Errors';
import { SettingsService } from '../service/SettingsService';
import { SecretService } from '../service/SecretService';
import { SessionStore } from '../service/SessionStore';
import { AgentEvents, AgentRuntime, PHASE_IDLE, PHASE_STREAMING, PHASE_THINKING, PHASE_TOOL } from '../service/AgentLoop';
import { CancelToken } from '../common/Cancel';
import { ImageService } from '../service/ImageService';
import { SpeechService, SpeechEvents } from '../service/SpeechService';
import { TitleService } from '../service/TitleService';
import { MessageItem } from '../view/MessageItem';
import { Composer } from '../view/Composer';
import { MarkdownView } from '../view/MarkdownView';
import { ToolCard } from '../view/ToolCard';
import { SessionsSheet } from '../view/SessionsSheet';
import { SettingsSheet } from '../view/SettingsSheet';
import { GoalSheet } from '../view/GoalSheet';
import { AskUserSheet } from '../view/AskUserSheet';

/** Sheet identifiers. */
const SHEET_NONE: string = '';
const SHEET_SESSIONS: string = 'sessions';
const SHEET_SETTINGS: string = 'settings';
const SHEET_GOAL: string = 'goal';

/** A blank session used as the initial state value. */
function blankSession(): ChatSession {
  const now: number = Date.now();
  const session: ChatSession = {
    id: '',
    title: '',
    createdAt: now,
    updatedAt: now,
    messages: [],
    modelId: '',
    effort: '',
    todos: [],
    preview: ''
  };
  return session;
}

@Entry
@Component
struct Index {
  @StorageLink(KEY_LANG) lang: string = 'zh';
  @StorageLink(KEY_PALETTE) palette: Palette = DARK;
  @StorageLink(KEY_IS_DARK) isDark: boolean = true;
  @StorageLink(KEY_SESSION_REVISION) revision: number = 0;

  @State session: ChatSession = blankSession();
  @State items: Array<RenderItem> = [];
  @State liveText: string = '';
  @State liveReasoning: string = '';
  @State liveTools: Array<ToolPair> = [];
  @State phase: string = PHASE_IDLE;
  @State streaming: boolean = false;
  @State attachments: Array<ContentBlock> = [];
  @State listening: boolean = false;
  @State listeningText: string = '';
  @State sheetVisible: boolean = false;
  @State activeSheet: string = SHEET_NONE;
  @State askVisible: boolean = false;
  @State askQuestion: string = '';
  @State askOptions: Array<string> = [];
  @State planOpen: boolean = false;
  @State errorText: string = '';
  /** Status bar height in vp; the window is full screen, so content must inset itself. */
  @State topInset: number = 0;
  /** Navigation indicator height in vp, keeping the composer clear of the gesture bar. */
  @State bottomInset: number = 0;

  private scroller: Scroller = new Scroller();
  private token: CancelToken | undefined = undefined;
  private askResolver: ((answer: string) => void) | undefined = undefined;
  private speech: SpeechService | undefined = undefined;
  private deltaCount: number = 0;
  private mainWindow: window.Window | undefined = undefined;

  aboutToAppear(): void {
    SettingsService.ensurePublished();
    this.speech = new SpeechService(this.speechEvents());
    this.restoreSession();
    this.measureSafeArea();
  }

  aboutToDisappear(): void {
    const token: CancelToken | undefined = this.token;
    if (token !== undefined) {
      token.cancel();
    }
    const speech: SpeechService | undefined = this.speech;
    if (speech !== undefined) {
      speech.release();
    }
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow !== undefined) {
      try {
        mainWindow.off('avoidAreaChange');
      } catch (e) {
        // The window may already be gone during teardown.
      }
      this.mainWindow = undefined;
    }
  }

  /* -------------------------------- safe area --------------------------------- */

  /**
   * Read the system bar insets.
   *
   * `EntryAbility` asks for `setWindowLayoutFullScreen(true)` so the background can run
   * under the status bar; the flip side is that the system no longer insets the page for
   * us, so the chat shell pads itself by exactly the status bar and navigation indicator
   * heights reported here.
   */
  private async measureSafeArea(): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mainWindow: window.Window = await window.getLastWindow(context);
      this.mainWindow = mainWindow;
      this.refreshInsets();
      mainWindow.on('avoidAreaChange', (options: window.AvoidAreaOptions) => {
        this.refreshInsets();
      });
    } catch (e) {
      // Without a window handle the shell simply renders edge to edge as before.
    }
  }

  /** Convert the current avoid areas into vp paddings. */
  private refreshInsets(): void {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    try {
      const systemArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicatorArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const uiContext = this.getUIContext();
      this.topInset = uiContext.px2vp(systemArea.topRect.height);
      this.bottomInset = uiContext.px2vp(indicatorArea.bottomRect.height);
    } catch (e) {
      // Keep the previous values rather than collapsing the layout.
    }
  }

  /* ----------------------------- session lifecycle ----------------------------- */

  /** Restore the last conversation, or the newest one, or start a fresh session. */
  private restoreSession(): void {
    const settings: AppSettings = SettingsService.get();
    const lastId: string = SettingsService.lastSession();
    let session: ChatSession | undefined = lastId.length > 0 ? SessionStore.load(lastId) : undefined;
    if (session === undefined) {
      const rows = SessionStore.list();
      if (rows.length > 0) {
        session = SessionStore.load(rows[0].id);
      }
    }
    if (session === undefined) {
      session = SessionStore.create(settings.modelId, settings.effort);
    }
    this.applySession(session);
  }

  /** Switch the screen onto a session. */
  private applySession(session: ChatSession): void {
    this.session = session;
    this.buildItems();
    this.liveText = '';
    this.liveReasoning = '';
    this.liveTools = [];
    this.phase = PHASE_IDLE;
    this.errorText = '';
    if (session.id.length > 0) {
      SettingsService.setActiveSession(session.id);
      SettingsService.saveLastSession(session.id);
    }
    this.scrollToBottom();
  }

  /** Start a fresh, unsaved conversation. */
  private newSession(): void {
    const settings: AppSettings = SettingsService.get();
    this.applySession(SessionStore.create(settings.modelId, settings.effort));
  }

  private buildItems(): void {
    this.items = buildRenderItems(this.session.messages);
  }

  /** Persist the active session once it has content. */
  private persist(): void {
    const session: ChatSession = this.session;
    if (session.id.length === 0 || session.messages.length === 0) {
      return;
    }
    SessionStore.save(session);
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // The list may not be laid out yet; the next call will succeed.
      }
    }, 50);
  }

  /* --------------------------------- sending ---------------------------------- */

  private async send(text: string): Promise<void> {
    if (this.streaming) {
      return;
    }
    const settings: AppSettings = SettingsService.get();
    const apiKey: string = await SecretService.getApiKey();
    if (apiKey.length === 0) {
      this.showToast(translate(this.lang, 'error.noApiKey'));
      this.openSheet(SHEET_SETTINGS);
      return;
    }
    const session: ChatSession = this.session;
    const blocks: Array<ContentBlock> = [];
    if (text.length > 0) {
      blocks.push({ kind: BLOCK_TEXT, text: text });
    }
    for (let i = 0; i < this.attachments.length; i++) {
      blocks.push(this.attachments[i]);
    }
    const userMessage: ChatMessage = {
      id: newId('m'),
      role: ROLE_USER,
      blocks: blocks,
      createdAt: Date.now()
    };
    session.messages.push(userMessage);
    if (session.preview.length === 0) {
      session.preview = clip(text, 80);
    }
    this.attachments = [];
    this.errorText = '';
    this.buildItems();
    this.streaming = true;
    this.persist();
    this.scrollToBottom();

    const token: CancelToken = new CancelToken();
    this.token = token;
    const runtime: AgentRuntime = new AgentRuntime(settings, apiKey, this.lang, this.agentEvents());
    try {
      await runtime.run(session, token, '');
    } catch (e) {
      this.errorText = errorMessage(this.lang, 'UNKNOWN');
    }
    this.token = undefined;
    this.streaming = false;
    this.phase = PHASE_IDLE;
    this.liveText = '';
    this.liveReasoning = '';
    this.liveTools = [];
    this.buildItems();
    this.persist();
    this.scrollToBottom();
    this.maybeGenerateTitle(settings, apiKey);
  }

  /** Stop the current turn. */
  private stop(): void {
    const token: CancelToken | undefined = this.token;
    if (token !== undefined) {
      token.cancel();
    }
    this.streaming = false;
    this.phase = PHASE_IDLE;
    this.showToast(translate(this.lang, 'chat.stopped'));
  }

  /** Name the conversation after its first exchange. */
  private async maybeGenerateTitle(settings: AppSettings, apiKey: string): Promise<void> {
    const session: ChatSession = this.session;
    if (!settings.autoTitle || session.title.length > 0) {
      return;
    }
    let firstUser: string = '';
    let firstAssistant: string = '';
    for (let i = 0; i < session.messages.length; i++) {
      const message: ChatMessage = session.messages[i];
      if (message.role === ROLE_USER && firstUser.length === 0) {
        for (let j = 0; j < message.blocks.length; j++) {
          const block: ContentBlock = message.blocks[j];
          if (block.kind === BLOCK_TEXT && block.text !== undefined) {
            firstUser += block.text;
          }
        }
      }
      if (message.role === 'assistant' && firstAssistant.length === 0) {
        firstAssistant = TitleService.textOf(message.blocks);
      }
    }
    if (firstUser.trim().length === 0) {
      return;
    }
    let title: string = await TitleService.generate(settings, apiKey, firstUser, firstAssistant);
    if (title.length === 0) {
      title = TitleService.fallback(firstUser);
    }
    if (title.length === 0) {
      return;
    }
    session.title = title;
    this.persist();
    SessionStore.bumpRevision();
  }

  /** Agent loop callbacks. */
  private agentEvents(): AgentEvents {
    const events: AgentEvents = {
      onPhase: (next: string): void => {
        this.phase = next;
        if (next !== PHASE_STREAMING) {
          this.scrollToBottom();
        }
      },
      onText: (delta: string): void => {
        this.liveText = `${this.liveText}${delta}`;
        this.deltaCount = this.deltaCount + 1;
        if (this.deltaCount % 12 === 0) {
          this.scrollToBottom();
        }
      },
      onReasoning: (delta: string): void => {
        this.liveReasoning = `${this.liveReasoning}${delta}`;
      },
      onToolDelta: (toolCallId: string, toolName: string, argumentsDelta: string): void => {
        const tools: Array<ToolPair> = this.liveTools;
        let found: ToolPair | undefined = undefined;
        for (let i = 0; i < tools.length; i++) {
          if (tools[i].toolCallId === toolCallId) {
            found = tools[i];
            break;
          }
        }
        if (found === undefined) {
          const pair: ToolPair = {
            toolCallId: toolCallId,
            name: toolName,
            argsJson: argumentsDelta,
            state: 'running',
            summary: '',
            resultText: '',
            isError: false
          };
          tools.push(pair);
          this.liveTools = tools.slice();
        } else {
          found.argsJson = `${found.argsJson}${argumentsDelta}`;
          if (toolName.length > 0) {
            found.name = toolName;
          }
          this.liveTools = tools.slice();
        }
        this.scrollToBottom();
      },
      onAssistant: (message: ChatMessage): void => {
        this.liveText = '';
        this.liveReasoning = '';
        this.liveTools = [];
        this.deltaCount = 0;
        this.buildItems();
        this.scrollToBottom();
      },
      onToolResult: (message: ChatMessage): void => {
        this.buildItems();
        this.scrollToBottom();
      },
      onUsage: (usage: TokenUsage): void => {
        // Usage is displayed from the committed assistant message.
      },
      onError: (code: string, message: string): void => {
        // The agent passes an i18n key for local conditions and a provider sentence for
        // remote failures; only the former is translated.
        const isKey: boolean = message.indexOf(' ') < 0 && message.indexOf('.') > 0
          && translate(this.lang, message) !== message;
        const text: string = isKey ? translate(this.lang, message) : errorMessage(this.lang, code);
        this.errorText = text;
        this.showToast(text);
      },
      onPersist: (): void => {
        this.persist();
      },
      askUser: (question: string, options: Array<string>): Promise<string> => {
        return this.promptUser(question, options);
      }
    };
    return events;
  }

  /* --------------------------------- ask user --------------------------------- */

  /** Show the overlay and resolve with the user's answer. */
  private promptUser(question: string, options: Array<string>): Promise<string> {
    this.askQuestion = question;
    this.askOptions = options;
    this.askVisible = true;
    return new Promise<string>((resolve: (value: string) => void) => {
      this.askResolver = resolve;
    });
  }

  private resolveAsk(answer: string): void {
    this.askVisible = false;
    this.askQuestion = '';
    this.askOptions = [];
    const resolver: ((answer: string) => void) | undefined = this.askResolver;
    this.askResolver = undefined;
    if (resolver !== undefined) {
      resolver(answer);
    }
  }

  /* ---------------------------------- voice ----------------------------------- */

  private speechEvents(): SpeechEvents {
    const events: SpeechEvents = {
      onPartial: (text: string): void => {
        this.listeningText = text;
      },
      onFinal: (text: string): void => {
        this.listeningText = text;
      },
      onError: (message: string): void => {
        this.listening = false;
        const text: string = message.startsWith('chat.') ? translate(this.lang, message) : message;
        this.showToast(text);
      },
      onStateChange: (listening: boolean): void => {
        this.listening = listening;
        if (!listening) {
          this.listeningText = '';
        }
      }
    };
    return events;
  }

  private voiceToggle(): void {
    const speech: SpeechService | undefined = this.speech;
    if (speech === undefined) {
      return;
    }
    if (speech.isListening()) {
      speech.stop();
      return;
    }
    speech.setLanguage(this.lang);
    speech.start().then((started: boolean) => {
      if (!started) {
        this.showToast(translate(this.lang, 'chat.voice.unsupported'));
      }
    });
  }

  /* -------------------------------- attachments -------------------------------- */

  private async attach(): Promise<void> {
    const remaining: number = MAX_IMAGES_PER_MESSAGE - this.attachments.length;
    if (remaining <= 0) {
      this.showToast(translate(this.lang, 'error.imageLimit'));
      return;
    }
    const picked: Array<ContentBlock> = await ImageService.pick(remaining);
    if (picked.length === 0) {
      return;
    }
    const next: Array<ContentBlock> = this.attachments;
    for (let i = 0; i < picked.length; i++) {
      next.push(picked[i]);
    }
    this.attachments = next.slice();
  }

  private removeAttachment(index: number): void {
    const next: Array<ContentBlock> = this.attachments;
    if (index < 0 || index >= next.length) {
      return;
    }
    const removed: ContentBlock = next[index];
    if (removed.uri !== undefined) {
      ImageService.discard(removed.uri);
    }
    next.splice(index, 1);
    this.attachments = next.slice();
  }

  /* ----------------------------------- goal ----------------------------------- */

  private goalOf(): Goal | undefined {
    return this.session.goal;
  }

  private setGoalPhase(phase: string, reason: string): void {
    const goal: Goal | undefined = this.session.goal;
    if (goal === undefined) {
      return;
    }
    goal.phase = phase;
    goal.blockedReason = reason;
    goal.updatedAt = Date.now();
    this.persist();
    SessionStore.bumpRevision();
  }

  private createGoal(objective: string): void {
    const now: number = Date.now();
    const goal: Goal = {
      id: newId('g'),
      objective: objective,
      phase: GOAL_ACTIVE,
      rounds: 0,
      maxRounds: 60,
      createdAt: now,
      updatedAt: now
    };
    this.session.goal = goal;
    this.persist();
    SessionStore.bumpRevision();
    this.closeSheet();
    this.showToast(translate(this.lang, 'goal.phase.active'));
  }

  private endGoal(): void {
    this.session.goal = undefined;
    this.persist();
    SessionStore.bumpRevision();
    this.closeSheet();
  }

  /* --------------------------------- chrome ----------------------------------- */

  private openSheet(name: string): void {
    this.activeSheet = name;
    this.sheetVisible = true;
  }

  private closeSheet(): void {
    this.sheetVisible = false;
  }

  private showToast(text: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text, duration: 1800 });
    } catch (e) {
      // Toasts are cosmetic; a missing UI context is not worth surfacing.
    }
  }

  private title(): string {
    const title: string = this.session.title;
    return title.length > 0 ? title : translate(this.lang, 'session.untitled');
  }

  private planDone(): number {
    const todos: Array<TodoItem> = this.session.todos;
    let done: number = 0;
    for (let i = 0; i < todos.length; i++) {
      if (todos[i].status === TODO_COMPLETED) {
        done++;
      }
    }
    return done;
  }

  /* --------------------------------- builders --------------------------------- */

  @Builder
  TopBar() {
    Column({ space: 0 }) {
      Row({ space: SPACE_SM }) {
        Text('☰')
          .fontSize(FONT_TITLE)
          .fontColor(this.palette.textSecondary)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.openSheet(SHEET_SESSIONS);
          })
        Column({ space: 2 }) {
          Text(this.title())
            .fontSize(FONT_MD)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.session.goal !== undefined) {
            Text(`${translate(this.lang, 'goal.phase.' + (this.session.goal === undefined ? 'active' : this.session.goal.phase))}`)
              .fontSize(FONT_XS)
              .fontColor(this.palette.accent)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Text('◎')
          .fontSize(FONT_TITLE)
          .fontColor(this.session.goal !== undefined ? this.palette.accent : this.palette.textSecondary)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.openSheet(SHEET_GOAL);
          })
        Text('⚙')
          .fontSize(FONT_TITLE)
          .fontColor(this.palette.textSecondary)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.openSheet(SHEET_SETTINGS);
          })
      }
      .width('100%')
      .padding({ left: SPACE_SM, right: SPACE_SM, top: SPACE_XS, bottom: SPACE_XS })
      .height(52)
    }
    .width('100%')
    .backgroundColor(this.palette.bg)
  }

  @Builder
  EmptyState() {
    Column({ space: SPACE_MD }) {
      Text('◈')
        .fontSize(44)
        .fontColor(this.palette.accent)
      Text(translate(this.lang, 'chat.empty.title'))
        .fontSize(FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette.textPrimary)
      Text(translate(this.lang, 'chat.empty.body'))
        .fontSize(FONT_SM)
        .lineHeight(20)
        .fontColor(this.palette.textSecondary)
        .textAlign(TextAlign.Center)
        .padding({ left: SPACE_LG, right: SPACE_LG })

      Column({ space: SPACE_SM }) {
        Text(translate(this.lang, 'chat.empty.suggest1'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.textPrimary)
          .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
          .backgroundColor(this.palette.surfaceAlt)
          .borderRadius(RADIUS_MD)
          .onClick(() => {
            this.send(translate(this.lang, 'chat.empty.suggest1'));
          })
        Text(translate(this.lang, 'chat.empty.suggest2'))
          .fontSize(FONT_SM)
          .fontColor(this.palette.textPrimary)
          .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
          .backgroundColor(this.palette.surfaceAlt)
          .borderRadius(RADIUS_MD)
          .onClick(() => {
            this.send(translate(this.lang, 'chat.empty.suggest2'));
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  PlanStrip() {
    Column({ space: 0 }) {
      Row({ space: SPACE_SM }) {
        Text(translate(this.lang, 'todo.title'))
          .fontSize(FONT_XS)
          .fontColor(this.palette.textSecondary)
        Text(`${this.planDone()}/${this.session.todos.length}`)
          .fontSize(FONT_XS)
          .fontColor(this.palette.accent)
        Blank()
        Text(this.planOpen ? '⌃' : '⌄')
          .fontSize(FONT_XS)
          .fontColor(this.palette.textTertiary)
      }
      .width('100%')
      .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_XS, bottom: SPACE_XS })
      .onClick(() => {
        this.planOpen = !this.planOpen;
      })

      if (this.planOpen) {
        Column({ space: SPACE_XS }) {
          ForEach(this.session.todos, (todo: TodoItem, index: number) => {
            Row({ space: SPACE_SM }) {
              Text(todo.status === TODO_COMPLETED ? '☑' : todo.status === TODO_IN_PROGRESS ? '◐' : '☐')
                .fontSize(FONT_XS)
                .fontColor(todo.status === TODO_COMPLETED ? this.palette.success : this.palette.textTertiary)
              Text(todo.content)
                .fontSize(FONT_XS)
                .fontColor(todo.status === TODO_COMPLETED ? this.palette.textTertiary : this.palette.textSecondary)
                .decoration({ type: todo.status === TODO_COMPLETED ? TextDecorationType.LineThrough : TextDecorationType.None })
                .layoutWeight(1)
            }
            .width('100%')
          }, (todo: TodoItem, index: number) => `todo-${index}-${todo.status}`)
        }
        .width('100%')
        .padding({ left: SPACE_MD, right: SPACE_MD, bottom: SPACE_SM })
      }
    }
    .width('100%')
    .backgroundColor(this.palette.surfaceAlt)
    .borderRadius(RADIUS_MD)
    .margin({ left: SPACE_MD, right: SPACE_MD, bottom: SPACE_XS })
  }

  @Builder
  LiveTurn() {
    Column({ space: 0 }) {
      if (this.liveReasoning.length > 0) {
        Column({ space: SPACE_XS }) {
          Text(translate(this.lang, 'chat.reasoning'))
            .fontSize(FONT_XS)
            .fontColor(this.palette.textTertiary)
          Text(this.liveReasoning)
            .fontSize(FONT_SM)
            .lineHeight(20)
            .fontColor(this.palette.textSecondary)
            .width('100%')
            .maxLines(12)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(SPACE_SM)
        .backgroundColor(this.palette.reasoningBg)
        .borderRadius(RADIUS_MD)
        .margin({ bottom: SPACE_SM })
      }
      if (this.liveText.length > 0) {
        MarkdownView({ text: this.liveText, palette: this.palette, fontSize: 16 })
      }
      ForEach(this.liveTools, (pair: ToolPair, index: number) => {
        Column() {
          ToolCard({
            name: pair.name,
            argsJson: pair.argsJson,
            state: pair.state,
            summary: pair.summary,
            resultText: pair.resultText,
            isError: pair.isError
          })
        }
        .width('100%')
        .margin({ top: SPACE_XS })
      }, (pair: ToolPair, index: number) => `live-tool-${index}-${pair.toolCallId}`)

      if (this.liveText.length === 0 && this.liveReasoning.length === 0 && this.liveTools.length === 0) {
        Row({ space: SPACE_SM }) {
          Text('◈')
            .fontSize(FONT_SM)
            .fontColor(this.palette.accent)
          Text(this.phase === PHASE_TOOL
            ? translate(this.lang, 'chat.tool.running')
            : translate(this.lang, 'chat.thinking'))
            .fontSize(FONT_SM)
            .fontColor(this.palette.textTertiary)
        }
        .padding({ top: SPACE_SM, bottom: SPACE_SM })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: SPACE_XS, right: SPACE_XS })
  }

  @Builder
  Conversation() {
    List({ space: 0, scroller: this.scroller }) {
      ForEach(this.items, (item: RenderItem, index: number) => {
        ListItem() {
          MessageItem({ item: item })
        }
        .padding({ left: SPACE_MD, right: SPACE_MD })
      }, (item: RenderItem, index: number) => item.messageId)

      if (this.streaming) {
        ListItem() {
          this.LiveTurn()
        }
        .padding({ left: SPACE_MD, right: SPACE_MD })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  ErrorBanner() {
    Row({ space: SPACE_SM }) {
      Text('!')
        .fontSize(FONT_XS)
        .fontColor(this.palette.danger)
      Text(this.errorText)
        .fontSize(FONT_XS)
        .fontColor(this.palette.danger)
        .layoutWeight(1)
      Text('✕')
        .fontSize(FONT_XS)
        .fontColor(this.palette.danger)
        .onClick(() => {
          this.errorText = '';
        })
    }
    .width('100%')
    .padding({ left: SPACE_MD, right: SPACE_MD, top: SPACE_SM, bottom: SPACE_SM })
    .backgroundColor(this.palette.dangerSoft)
    .margin({ left: SPACE_MD, right: SPACE_MD, bottom: SPACE_XS })
    .borderRadius(RADIUS_MD)
  }

  @Builder
  SheetContent() {
    if (this.activeSheet === SHEET_SESSIONS) {
      SessionsSheet({
        onPick: (id: string): void => {
          const next: ChatSession | undefined = SessionStore.load(id);
          if (next !== undefined) {
            this.applySession(next);
          }
          this.closeSheet();
        },
        onNew: (): void => {
          this.newSession();
          this.closeSheet();
        },
        onClose: (): void => {
          this.closeSheet();
        }
      })
    } else if (this.activeSheet === SHEET_SETTINGS) {
      SettingsSheet({
        onClose: (): void => {
          this.closeSheet();
          SettingsService.publish();
        }
      })
    } else if (this.activeSheet === SHEET_GOAL) {
      GoalSheet({
        hasGoal: this.session.goal !== undefined,
        objective: this.session.goal === undefined ? '' : this.session.goal.objective,
        phase: this.session.goal === undefined ? '' : this.session.goal.phase,
        rounds: this.session.goal === undefined ? 0 : this.session.goal.rounds,
        maxRounds: this.session.goal === undefined ? 60 : this.session.goal.maxRounds,
        blockedReason: this.session.goal === undefined ? '' : (this.session.goal.blockedReason === undefined ? '' : this.session.goal.blockedReason),
        onCreate: (objective: string): void => {
          this.createGoal(objective);
        },
        onPause: (): void => {
          this.setGoalPhase(GOAL_PAUSED, '');
        },
        onResume: (): void => {
          this.setGoalPhase(GOAL_ACTIVE, '');
        },
        onComplete: (): void => {
          this.setGoalPhase(GOAL_COMPLETE, '');
        },
        onEnd: (): void => {
          this.endGoal();
        },
        onClose: (): void => {
          this.closeSheet();
        }
      })
    } else {
      Column()
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 0 }) {
        this.TopBar()
        if (this.session.messages.length === 0 && !this.streaming) {
          this.EmptyState()
        } else {
          this.Conversation()
        }
        if (this.errorText.length > 0) {
          this.ErrorBanner()
        }
        if (this.session.todos.length > 0) {
          this.PlanStrip()
        }
        Composer({
          streaming: this.streaming,
          listening: this.listening,
          listeningText: this.listeningText,
          attachments: this.attachments,
          onSend: (text: string): void => {
            this.send(text);
          },
          onStop: (): void => {
            this.stop();
          },
          onAttachImage: (): void => {
            this.attach();
          },
          onVoiceToggle: (): void => {
            this.voiceToggle();
          },
          onRemoveAttachment: (index: number): void => {
            this.removeAttachment(index);
          }
        })
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.palette.bg)

      if (this.askVisible) {
        Column() {
          Blank()
            .onClick(() => {
              this.resolveAsk('');
            })
          AskUserSheet({
            question: this.askQuestion,
            options: this.askOptions,
            onAnswer: (answer: string): void => {
              this.resolveAsk(answer);
            },
            onSkip: (): void => {
              this.resolveAsk('');
            }
          })
        }
        .width('100%')
        .height('100%')
        .padding({ bottom: this.bottomInset })
        .backgroundColor(this.palette.scrim)
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.sheetVisible, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: false,
      backgroundColor: this.palette.bg,
      onDisappear: () => {
        this.activeSheet = SHEET_NONE;
      }
    })
  }
}
