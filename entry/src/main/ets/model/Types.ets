/**
 * Durable data model.
 *
 * The shapes mirror the desktop harness session model closely enough that a session
 * exported from the desktop can be read here, while staying flat so ArkTS state
 * observation can track every field without nested proxies.
 */

/** Content block kinds, matching the desktop protocol vocabulary. */
export const BLOCK_TEXT: string = 'text';
export const BLOCK_REASONING: string = 'reasoning';
export const BLOCK_TOOL_CALL: string = 'tool-call';
export const BLOCK_IMAGE: string = 'image';

/** Message roles. `tool` carries tool results back to the model. */
export const ROLE_USER: string = 'user';
export const ROLE_ASSISTANT: string = 'assistant';
export const ROLE_TOOL: string = 'tool';
export const ROLE_SYSTEM: string = 'system';

/** Per-message lifecycle, used by the UI only and never persisted. */
export const STATUS_STREAMING: string = 'streaming';
export const STATUS_DONE: string = 'done';
export const STATUS_ERROR: string = 'error';
export const STATUS_ABORTED: string = 'aborted';

/** One piece of message content. Exactly one group of fields is populated per kind. */
export interface ContentBlock {
  kind: string;
  /** `text` and `reasoning` payload. */
  text?: string;
  /** Thinking signature returned by the provider, replayed on later turns. */
  signature?: string;
  /** `tool-call` identity. */
  toolCallId?: string;
  toolName?: string;
  /** Raw JSON string as streamed, so a partially received call is still displayable. */
  toolArguments?: string;
  /** `image` payload. */
  imageId?: string;
  name?: string;
  mediaType?: string;
  base64?: string;
  width?: number;
  height?: number;
  /** Attached images keep their origin so a retry can re-read the file. */
  uri?: string;
}

/** A single tool invocation recorded in the conversation. */
export interface ToolInvocation {
  id: string;
  name: string;
  arguments: string;
  /** Running / done / error. */
  state: string;
  summary: string;
  startedAt: number;
  finishedAt: number;
}

/** Token accounting reported by the provider. */
export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  totalTokens: number;
}

/** One conversation turn. */
export interface ChatMessage {
  id: string;
  role: string;
  blocks: ContentBlock[];
  createdAt: number;
  /** UI-only lifecycle. */
  status?: string;
  /** Only on `tool` messages. */
  toolCallId?: string;
  toolName?: string;
  /** One line describing what the tool did, shown in the card header. */
  toolSummary?: string;
  isError?: boolean;
  /** Only on assistant messages. */
  usage?: TokenUsage;
  modelId?: string;
  durationMs?: number;
  /** Set when the turn failed, so the bubble can show the reason inline. */
  errorText?: string;
}

/** Goal phases, matching the desktop goal plugin. */
export const GOAL_ACTIVE: string = 'active';
export const GOAL_PAUSED: string = 'paused';
export const GOAL_COMPLETE: string = 'complete';
export const GOAL_BLOCKED: string = 'blocked';

/** A persisted long running objective that keeps the agent working across rounds. */
export interface Goal {
  id: string;
  objective: string;
  phase: string;
  rounds: number;
  maxRounds: number;
  createdAt: number;
  updatedAt: number;
  blockedReason?: string;
}

/** Todo entry produced by the `todo_write` tool. */
export const TODO_PENDING: string = 'pending';
export const TODO_IN_PROGRESS: string = 'in_progress';
export const TODO_COMPLETED: string = 'completed';

export interface TodoItem {
  content: string;
  status: string;
}

/** One chat session: a conversation plus its metadata. */
export interface ChatSession {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: ChatMessage[];
  modelId: string;
  effort: string;
  goal?: Goal;
  todos: TodoItem[];
  /** Cached first user message, used by search without loading every file. */
  preview: string;
}

/** Lightweight row used by the session list so listing does not parse every message. */
export interface SessionSummary {
  id: string;
  title: string;
  updatedAt: number;
  createdAt: number;
  messageCount: number;
  preview: string;
  goalPhase: string;
}

/** Persisted user preferences. */
export interface AppSettings {
  baseUrl: string;
  modelId: string;
  effort: string;
  maxTokens: number;
  temperature: number;
  systemPrompt: string;
  language: string;
  themeMode: string;
  autoTitle: boolean;
  searchProvider: string;
  hasApiKey: boolean;
  apiKeyHint: string;
}

/** Tool schema advertised to the model, using the Messages `tools` shape. */
export interface ToolSchema {
  name: string;
  description: string;
  inputSchema: string;
}

/** Result of executing one tool call. */
export interface ToolResult {
  content: string;
  isError: boolean;
  /** Short human readable label rendered in the tool card header. */
  summary: string;
}

/** Streaming event surfaced by the LLM client to the agent loop and the UI. */
export const EVT_BLOCK_START: string = 'block-start';
export const EVT_TEXT: string = 'text';
export const EVT_REASONING: string = 'reasoning';
export const EVT_TOOL_DELTA: string = 'tool-delta';
export const EVT_BLOCK_END: string = 'block-end';
export const EVT_USAGE: string = 'usage';
export const EVT_FINISH: string = 'finish';
export const EVT_ERROR: string = 'error';

/** A parsed stream chunk. */
export interface StreamEvent {
  kind: string;
  index: number;
  text?: string;
  /** Tool call identity for `tool-delta`. */
  toolCallId?: string;
  toolName?: string;
  argumentsDelta?: string;
  /** Final assembled block for `block-end`. */
  block?: ContentBlock;
  usage?: TokenUsage;
  /** `stop`, `tool-calls`, `max-tokens`. */
  finishKind?: string;
  errorText?: string;
  errorCode?: string;
}
