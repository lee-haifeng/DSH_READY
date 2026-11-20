/**
 * Agent loop.
 *
 * One `run` call owns everything from "user pressed send" to "the assistant stopped":
 * it streams a reply, commits it, executes any tool calls, feeds the results back and
 * repeats. When a goal is active it also keeps nudging the model across rounds, which
 * is what the desktop goal driver does.
 *
 * The loop never renders anything itself. It reports progress through `AgentEvents`,
 * so the chat screen can keep the streaming text in a single reactive field instead of
 * rebuilding the whole message list on every token.
 */

import {
  AppSettings, BLOCK_IMAGE, BLOCK_REASONING, BLOCK_TEXT, BLOCK_TOOL_CALL, ChatMessage, ChatSession,
  ContentBlock, EVT_BLOCK_END, EVT_BLOCK_START, EVT_ERROR, EVT_FINISH, EVT_REASONING, EVT_TEXT,
  EVT_TOOL_DELTA, EVT_USAGE, Goal, GOAL_ACTIVE, GOAL_COMPLETE, ROLE_ASSISTANT,
  ROLE_SYSTEM, ROLE_TOOL, ROLE_USER, StreamEvent, TokenUsage, ToolResult
} from '../model/Types';
import { MAX_AGENT_ROUNDS, MAX_TOOL_RESULT_CHARS, MODEL_FLASH } from '../common/Constants';
import { CancelToken } from '../common/Cancel';
import { Log, newId } from '../common/Utils';
import { LlmClient } from './LlmClient';
import { buildGoalContinuation, buildSystemPrompt, toolDefs, ToolDef } from './Prompt';
import { ToolContext, ToolRunner } from './Tools';
import { ImageService } from './ImageService';
import { translate } from '../i18n/Strings';
import { WireBlock, WireMessage, WireRequest, WireThinking, WireTool, WireOutputConfig } from './Wire';

const log = new Log('Agent');

/** Phases reported to the UI. */
export const PHASE_IDLE: string = 'idle';
export const PHASE_THINKING: string = 'thinking';
export const PHASE_STREAMING: string = 'streaming';
export const PHASE_TOOL: string = 'tool';

/** Callbacks the chat screen implements. */
export interface AgentEvents {
  onPhase: (phase: string) => void;
  onText: (delta: string) => void;
  onReasoning: (delta: string) => void;
  onToolDelta: (toolCallId: string, toolName: string, argumentsDelta: string) => void;
  onAssistant: (message: ChatMessage) => void;
  onToolResult: (message: ChatMessage) => void;
  onUsage: (usage: TokenUsage) => void;
  onError: (code: string, message: string) => void;
  onPersist: () => void;
  askUser: (question: string, options: Array<string>) => Promise<string>;
}

/** Convert a durable message into wire blocks, following the desktop serialiser rules. */
function wireBlocksOf(message: ChatMessage): Array<WireBlock> {
  const out: Array<WireBlock> = [];
  for (let i = 0; i < message.blocks.length; i++) {
    const block: ContentBlock = message.blocks[i];
    if (block.kind === BLOCK_TEXT) {
      const text: string = block.text === undefined ? '' : block.text;
      if (text.length > 0) {
        out.push({ type: 'text', text: text });
      }
    } else if (block.kind === BLOCK_REASONING) {
      const thinking: WireBlock = { type: 'thinking', thinking: block.text === undefined ? '' : block.text };
      if (block.signature !== undefined && block.signature.length > 0) {
        thinking.signature = block.signature;
      }
      out.push(thinking);
    } else if (block.kind === BLOCK_TOOL_CALL) {
      let input: Record<string, Object> = {};
      const raw: string = block.toolArguments === undefined ? '' : block.toolArguments;
      try {
        const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        if (parsed !== null && parsed !== undefined) {
          input = parsed;
        }
      } catch (e) {
        // Malformed historical arguments become an empty object, as upstream does.
        input = {};
      }
      out.push({
        type: 'tool_use',
        id: block.toolCallId === undefined ? '' : block.toolCallId,
        name: block.toolName === undefined ? '' : block.toolName,
        input: input
      });
    } else if (block.kind === BLOCK_IMAGE) {
      const mediaType: string = block.mediaType === undefined ? 'image/jpeg' : block.mediaType;
      // Attachments are stored as files; encode only when a request is actually built.
      let data: string = block.base64 === undefined ? '' : block.base64;
      if (data.length === 0 && block.uri !== undefined && block.uri.length > 0) {
        data = ImageService.base64Of(block.uri);
      }
      if (data.length > 0) {
        out.push({ type: 'image', source: { type: 'base64', media_type: mediaType, data: data } });
      }
    }
  }
  return out;
}

/** Append blocks to the previous turn when the role matches, mirroring the wire format. */
function pushMerged(target: Array<WireMessage>, role: string, blocks: Array<WireBlock>): void {
  if (blocks.length === 0) {
    return;
  }
  const last: WireMessage | undefined = target.length === 0 ? undefined : target[target.length - 1];
  if (last !== undefined && last.role === role) {
    for (let i = 0; i < blocks.length; i++) {
      last.content.push(blocks[i]);
    }
    return;
  }
  target.push({ role: role, content: blocks });
}

/**
 * Build the request history.
 *
 * System-role chat messages are UI-only notices (goal rounds, errors) and never reach
 * the provider; goal state travels in the system prompt instead.
 */
function buildWireMessages(session: ChatSession): Array<WireMessage> {
  const out: Array<WireMessage> = [];
  const answered: Set<string> = new Set();
  for (let i = 0; i < session.messages.length; i++) {
    const message: ChatMessage = session.messages[i];
    if (message.role === ROLE_USER) {
      pushMerged(out, 'user', wireBlocksOf(message));
    } else if (message.role === ROLE_ASSISTANT) {
      const blocks: Array<WireBlock> = wireBlocksOf(message);
      pushMerged(out, 'assistant', blocks);
      for (let j = 0; j < blocks.length; j++) {
        const block: WireBlock = blocks[j];
        if (block.type === 'tool_use' && block.id !== undefined) {
          answered.add(block.id);
        }
      }
    } else if (message.role === ROLE_TOOL) {
      const id: string = message.toolCallId === undefined ? '' : message.toolCallId;
      const text: string = message.blocks.length > 0 && message.blocks[0].text !== undefined
        ? message.blocks[0].text as string : '';
      const result: WireBlock = { type: 'tool_result', tool_use_id: id, content: [{ type: 'text', text: text }] };
      if (message.isError === true) {
        result.is_error = true;
      }
      answered.delete(id);
      pushMerged(out, 'user', [result]);
    }
  }
  // Any tool call left unanswered would make the request invalid; answer it locally.
  if (answered.size > 0) {
    const pending: Array<WireBlock> = [];
    answered.forEach((id: string) => {
      pending.push({ type: 'tool_result', tool_use_id: id, content: [{ type: 'text', text: 'Cancelled before completion.' }], is_error: true });
    });
    pushMerged(out, 'user', pending);
  }
  return out;
}

/** Build the tool declarations for the wire request. */
function buildTools(): Array<WireTool> {
  const defs: Array<ToolDef> = toolDefs();
  const tools: Array<WireTool> = [];
  for (let i = 0; i < defs.length; i++) {
    const def: ToolDef = defs[i];
    let schema: Record<string, Object> = {};
    try {
      schema = JSON.parse(def.schemaJson) as Record<string, Object>;
    } catch (e) {
      schema = {};
    }
    tools.push({ name: def.name, description: def.description, input_schema: schema });
  }
  return tools;
}

export class AgentRuntime {
  private settings: AppSettings;
  private events: AgentEvents;
  private apiKey: string;
  private lang: string;

  constructor(settings: AppSettings, apiKey: string, lang: string, events: AgentEvents) {
    this.settings = settings;
    this.apiKey = apiKey;
    this.lang = lang;
    this.events = events;
  }

  /** Localised UI notice stored as a system message. */
  private notice(key: string): string {
    return translate(this.lang, key);
  }

  /** Accumulates one streamed reply into durable blocks. */
  private static applyEvent(
    evt: StreamEvent,
    blocks: Map<number, ContentBlock>,
    events: AgentEvents
  ): void {
    if (evt.kind === EVT_BLOCK_START) {
      const kind: string = evt.text === undefined ? BLOCK_TEXT : evt.text;
      const block: ContentBlock = { kind: kind };
      if (kind === BLOCK_TEXT || kind === BLOCK_REASONING) {
        block.text = '';
      } else if (kind === BLOCK_TOOL_CALL) {
        block.toolCallId = '';
        block.toolName = '';
        block.toolArguments = '';
      }
      blocks.set(evt.index, block);
      return;
    }
    const block: ContentBlock | undefined = blocks.get(evt.index);
    if (block === undefined) {
      return;
    }
    if (evt.kind === EVT_TEXT) {
      block.text = `${block.text === undefined ? '' : block.text}${evt.text === undefined ? '' : evt.text}`;
      events.onText(evt.text === undefined ? '' : evt.text);
      return;
    }
    if (evt.kind === EVT_REASONING) {
      block.text = `${block.text === undefined ? '' : block.text}${evt.text === undefined ? '' : evt.text}`;
      events.onReasoning(evt.text === undefined ? '' : evt.text);
      return;
    }
    if (evt.kind === EVT_TOOL_DELTA) {
      if (evt.toolCallId !== undefined && evt.toolCallId.length > 0) {
        block.toolCallId = evt.toolCallId;
      }
      if (evt.toolName !== undefined && evt.toolName.length > 0) {
        block.toolName = evt.toolName;
      }
      const delta: string = evt.argumentsDelta === undefined ? '' : evt.argumentsDelta;
      block.toolArguments = `${block.toolArguments === undefined ? '' : block.toolArguments}${delta}`;
      events.onToolDelta(
        block.toolCallId === undefined ? '' : block.toolCallId,
        block.toolName === undefined ? '' : block.toolName,
        delta
      );
      return;
    }
    if (evt.kind === EVT_BLOCK_END && evt.block !== undefined) {
      const finalBlock: ContentBlock = evt.block;
      blocks.set(evt.index, finalBlock);
    }
  }

  /** Collect the ordered blocks of the reply just streamed. */
  private static collect(blocks: Map<number, ContentBlock>): Array<ContentBlock> {
    const indices: Array<number> = [];
    blocks.forEach((value: ContentBlock, key: number) => {
      indices.push(key);
    });
    indices.sort((a: number, b: number) => a - b);
    const out: Array<ContentBlock> = [];
    for (let i = 0; i < indices.length; i++) {
      const block: ContentBlock | undefined = blocks.get(indices[i]);
      if (block === undefined) {
        continue;
      }
      if (block.kind === BLOCK_TEXT && (block.text === undefined || block.text.length === 0)) {
        continue;
      }
      if (block.kind === BLOCK_TOOL_CALL && (block.toolName === undefined || block.toolName.length === 0)) {
        continue;
      }
      out.push(block);
    }
    return out;
  }

  private buildRequest(session: ChatSession, nudge: string): WireRequest {
    let system: string = buildSystemPrompt(this.settings, session, new Date());
    if (nudge.length > 0) {
      system = `${system}\n\n# Round directive\n${nudge}`;
    }
    const effort: string = this.settings.effort;
    const thinking: WireThinking = { type: effort === 'off' ? 'disabled' : 'enabled' };
    const request: WireRequest = {
      model: this.settings.modelId,
      stream: true,
      max_tokens: this.settings.maxTokens,
      messages: buildWireMessages(session),
      system: system,
      thinking: thinking,
      tools: buildTools()
    };
    if (effort !== 'off') {
      const outputConfig: WireOutputConfig = { effort: effort };
      request.output_config = outputConfig;
    }
    return request;
  }

  /** Run the loop for one user turn, or continue an active goal. */
  async run(session: ChatSession, token: CancelToken, startWithNudge: string): Promise<void> {
    let rounds: number = 0;
    let nudge: string = startWithNudge;
    while (rounds <= MAX_AGENT_ROUNDS) {
      if (token.cancelled) {
        this.events.onPhase(PHASE_IDLE);
        return;
      }
      const request: WireRequest = this.buildRequest(session, nudge);
      nudge = '';
      this.events.onPhase(PHASE_THINKING);
      const client: LlmClient = new LlmClient();
      const blocks: Map<number, ContentBlock> = new Map();
      let finishKind: string = '';
      const handler = (evt: StreamEvent): void => {
        if (evt.kind === EVT_FINISH && evt.finishKind !== undefined) {
          finishKind = evt.finishKind;
        } else if (evt.kind === EVT_USAGE && evt.usage !== undefined) {
          this.events.onUsage(evt.usage);
        } else if (evt.kind === EVT_ERROR) {
          this.events.onError(evt.errorCode === undefined ? 'ERROR' : evt.errorCode,
            evt.errorText === undefined ? 'request failed' : evt.errorText);
        } else {
          if (evt.kind === EVT_TEXT || evt.kind === EVT_REASONING) {
            this.events.onPhase(PHASE_STREAMING);
          }
          AgentRuntime.applyEvent(evt, blocks, this.events);
        }
      };
      const startedAt: number = Date.now();
      const error = await client.stream(request, this.apiKey, this.settings.baseUrl, handler, token);
      if (token.cancelled) {
        // Keep whatever already streamed so the user's stop does not erase the reply.
        const partial: Array<ContentBlock> = AgentRuntime.collect(blocks);
        if (partial.length > 0) {
          const stopped: ChatMessage = {
            id: newId('m'),
            role: ROLE_ASSISTANT,
            blocks: partial,
            createdAt: Date.now(),
            durationMs: Date.now() - startedAt,
            modelId: this.settings.modelId,
            errorText: translate(this.lang, 'chat.stopped')
          };
          session.messages.push(stopped);
          this.events.onAssistant(stopped);
          this.events.onPersist();
        }
        this.events.onPhase(PHASE_IDLE);
        return;
      }
      if (error !== undefined) {
        if (error.code !== 'ABORTED') {
          this.events.onError(error.code, error.message);
        }
        this.events.onPhase(PHASE_IDLE);
        return;
      }
      const content: Array<ContentBlock> = AgentRuntime.collect(blocks);
      const assistant: ChatMessage = {
        id: newId('m'),
        role: ROLE_ASSISTANT,
        blocks: content,
        createdAt: Date.now(),
        durationMs: Date.now() - startedAt,
        modelId: this.settings.modelId
      };
      session.messages.push(assistant);
      this.events.onAssistant(assistant);
      this.events.onPersist();

      const calls: Array<ContentBlock> = [];
      for (let i = 0; i < content.length; i++) {
        if (content[i].kind === BLOCK_TOOL_CALL) {
          calls.push(content[i]);
        }
      }
      if (calls.length === 0) {
        const continued: boolean = await this.maybeContinueGoal(session, token, finishKind);
        if (continued) {
          rounds++;
          const goal: Goal | undefined = session.goal;
          nudge = goal === undefined ? '' : buildGoalContinuation(goal);
          continue;
        }
        this.events.onPhase(PHASE_IDLE);
        return;
      }
      this.events.onPhase(PHASE_TOOL);
      const context: ToolContext = {
        session: session,
        settings: this.settings,
        askUser: this.events.askUser
      };
      for (let i = 0; i < calls.length; i++) {
        if (token.cancelled) {
          break;
        }
        const call: ContentBlock = calls[i];
        const name: string = call.toolName === undefined ? '' : call.toolName;
        const args: string = call.toolArguments === undefined ? '' : call.toolArguments;
        const result: ToolResult = await ToolRunner.execute(name, args, context);
        const toolMessage: ChatMessage = {
          id: newId('m'),
          role: ROLE_TOOL,
          blocks: [{ kind: BLOCK_TEXT, text: result.content }],
          createdAt: Date.now(),
          toolCallId: call.toolCallId === undefined ? '' : call.toolCallId,
          toolName: name,
          toolSummary: result.summary,
          isError: result.isError
        };
        session.messages.push(toolMessage);
        this.events.onToolResult(toolMessage);
        this.events.onPersist();
      }
      rounds++;
    }
    // Round cap reached.
    this.events.onError('ROUND_LIMIT', 'chat.roundLimit');
    this.events.onPhase(PHASE_IDLE);
  }

  /**
   * Advance an active goal by one round when the last reply settled cleanly.
   * @returns whether a continuation round started
   */
  private async maybeContinueGoal(session: ChatSession, token: CancelToken, finishKind: string): Promise<boolean> {
    const goal: Goal | undefined = session.goal;
    if (goal === undefined || goal.phase !== GOAL_ACTIVE) {
      return false;
    }
    if (finishKind === 'max-tokens') {
      // Truncated output: ask the user before burning more rounds.
      return false;
    }
    if (goal.rounds >= goal.maxRounds) {
      session.messages.push({
        id: newId('n'),
        role: ROLE_SYSTEM,
        blocks: [{ kind: BLOCK_TEXT, text: this.notice('goal.reachedCap') }],
        createdAt: Date.now()
      });
      goal.phase = 'paused';
      goal.updatedAt = Date.now();
      this.events.onPersist();
      return false;
    }
    goal.rounds = goal.rounds + 1;
    goal.updatedAt = Date.now();
    session.messages.push({
      id: newId('n'),
      role: ROLE_SYSTEM,
      blocks: [{
        kind: BLOCK_TEXT,
        text: `${this.notice('goal.rounds')} ${goal.rounds}/${goal.maxRounds}`
      }],
      createdAt: Date.now()
    });
    this.events.onPersist();
    return !token.cancelled;
  }

  /** Whether the model can accept images. */
  static acceptsImages(modelId: string): boolean {
    return modelId === MODEL_FLASH;
  }
}
