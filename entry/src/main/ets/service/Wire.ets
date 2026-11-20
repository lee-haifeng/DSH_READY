/**
 * Wire types for the DeepSeek Messages protocol.
 *
 * These mirror `packages/llm/llm-deepseek/src/wire-types.ts` from the desktop client.
 * Every interface is flat with optional fields so a single serialiser can emit
 * exactly the keys the provider expects: `JSON.stringify` drops `undefined`.
 */

/** Image payload: either inline base64 or a Files API reference. */
export interface WireSource {
  type: string;
  media_type?: string;
  data?: string;
  file_id?: string;
}

/** One content block in a request or a translation result. */
export interface WireBlock {
  type: string;
  /** `text` blocks. */
  text?: string;
  /** `thinking` blocks. */
  thinking?: string;
  signature?: string;
  /** `tool_use` blocks. */
  id?: string;
  name?: string;
  input?: Record<string, Object>;
  /** `tool_result` blocks. */
  tool_use_id?: string;
  content?: Array<WireBlock>;
  is_error?: boolean;
  /** `image` blocks. */
  source?: WireSource;
}

/** One conversation turn. */
export interface WireMessage {
  role: string;
  content: Array<WireBlock>;
}

/** Tool declaration accepted by the endpoint. */
export interface WireTool {
  name: string;
  description: string;
  input_schema: Record<string, Object>;
}

/** Thinking policy object. */
export interface WireThinking {
  type: string;
}

/** Reasoning effort selector. */
export interface WireOutputConfig {
  effort: string;
}

/** Request body for `POST /v1/messages`. */
export interface WireRequest {
  model: string;
  stream: boolean;
  max_tokens: number;
  messages: Array<WireMessage>;
  system?: string;
  thinking: WireThinking;
  output_config?: WireOutputConfig;
  temperature?: number;
  tools?: Array<WireTool>;
}

/* ------------------------------------------------------------------ */
/* Streamed response events                                            */
/* ------------------------------------------------------------------ */

/** Usage counters as reported by the provider. */
export interface SseUsage {
  input_tokens?: number;
  output_tokens?: number;
  cache_read_input_tokens?: number;
  cache_creation_input_tokens?: number;
}

/** `message_start` payload. */
export interface SseMessage {
  id?: string;
  model?: string;
  usage?: SseUsage;
}

/** One block in `content_block_start`. */
export interface SseContentBlock {
  type?: string;
  text?: string;
  thinking?: string;
  signature?: string;
  id?: string;
  name?: string;
  input?: Record<string, Object>;
}

/** `content_block_delta` payload. */
export interface SseDelta {
  type?: string;
  text?: string;
  thinking?: string;
  signature?: string;
  partial_json?: string;
  stop_reason?: string;
  stop_details?: SseStopDetails;
}

/** Refusal explanation. */
export interface SseStopDetails {
  explanation?: string;
}

/** One decoded SSE event. */
export interface SseEvent {
  type?: string;
  index?: number;
  message?: SseMessage;
  content_block?: SseContentBlock;
  delta?: SseDelta;
  usage?: SseUsage;
}
