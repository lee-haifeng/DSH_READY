/**
 * Streaming client for the DeepSeek Messages endpoint.
 *
 * Mirrors `packages/llm/llm-deepseek/src/translate.ts` from the desktop client: the
 * same event names, block ordering rules, finish reasons and refusal handling. The
 * transport is HarmonyOS `@ohos.net.http` with `requestInStream`, whose
 * `dataReceive` callback delivers raw chunks that we split into SSE lines.
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BLOCK_REASONING, BLOCK_TEXT, BLOCK_TOOL_CALL, ContentBlock, EVT_BLOCK_END, EVT_BLOCK_START, EVT_ERROR,
  EVT_FINISH, EVT_REASONING, EVT_TEXT, EVT_TOOL_DELTA, EVT_USAGE, StreamEvent, TokenUsage
} from '../model/Types';
import { HEADER_API_KEY, MESSAGES_PATH } from '../common/Constants';
import { CancelToken } from '../common/Cancel';
import { Log } from '../common/Utils';
import { SseContentBlock, SseDelta, SseEvent, SseMessage, SseStopDetails, SseUsage, WireRequest } from './Wire';

const log = new Log('Llm');

const DECODER_OPTIONS: util.TextDecoderOptions = { fatal: false, ignoreBOM: true };
const STREAM_DECODE: util.DecodeToStringOptions = { stream: true };

/** Normalised failure surfaced to the UI. Codes match the desktop adapter vocabulary. */
export interface LlmErrorInfo {
  code: string;
  message: string;
}

/** A block being assembled from the stream. */
class OpenBlock {
  index: number = 0;
  kind: string = '';
  text: string = '';
  toolCallId: string = '';
  toolName: string = '';
  json: string = '';
  signature: string = '';
  closed: boolean = false;
}

/** Join a base URL and a path without doubling or dropping the separator. */
function joinUrl(baseUrl: string, path: string): string {
  let root: string = baseUrl.trim();
  while (root.endsWith('/')) {
    root = root.slice(0, root.length - 1);
  }
  if (root.endsWith('/v1') && path.startsWith('/v1/')) {
    return `${root}${path.slice(3)}`;
  }
  return `${root}${path}`;
}

/** Map an HTTP status onto the adapter's stable error vocabulary. */
function codeForStatus(status: number): string {
  if (status === 401 || status === 403) {
    return 'AUTH';
  }
  if (status === 402) {
    return 'QUOTA';
  }
  if (status === 429) {
    return 'RATE_LIMIT';
  }
  if (status === 400 || status === 422) {
    return 'INVALID_REQUEST';
  }
  if (status >= 500) {
    return 'SERVER';
  }
  return `HTTP_${status}`;
}

/** Map a transport failure onto a user-facing code. */
function codeForTransport(err: BusinessError): string {
  const code: number = err.code;
  if (code === 2300028) {
    return 'TIMEOUT';
  }
  if (code === 2300006 || code === 2300007 || code === 2300005 || code === 2300056) {
    return 'NETWORK';
  }
  if (code === 2300058 || code === 2300059 || code === 2300060 || code === 2300077) {
    return 'TLS';
  }
  if (code === 2300998) {
    return 'DOMAIN_BLOCKED';
  }
  if (code === 2300997) {
    return 'CLEARTEXT_BLOCKED';
  }
  return 'NETWORK';
}

/** Extract a human readable message from a provider error body. */
function messageFromBody(body: string, fallback: string): string {
  const trimmed: string = body.trim();
  if (trimmed.length === 0) {
    return fallback;
  }
  try {
    const parsed: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
    const error: Object | undefined = parsed.error;
    if (error !== undefined && error !== null) {
      const errorRecord: Record<string, Object> = error as Record<string, Object>;
      const message: Object | undefined = errorRecord.message;
      if (typeof message === 'string' && message.length > 0) {
        return message as string;
      }
    }
    const direct: Object | undefined = parsed.message;
    if (typeof direct === 'string' && (direct as string).length > 0) {
      return direct as string;
    }
  } catch (e) {
    // Not JSON; fall through and use the truncated body.
  }
  return trimmed.length > 300 ? `${trimmed.slice(0, 300)}…` : trimmed;
}

export class LlmClient {
  private request: http.HttpRequest | undefined = undefined;
  private lineBuffer: string = '';
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8', DECODER_OPTIONS);
  private rawBody: string = '';
  private blocks: Map<number, OpenBlock> = new Map();
  private nextIndex: number = 0;
  private usage: TokenUsage = {
    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 0
  };
  private started: boolean = false;
  private finishKind: string = '';
  private refused: string = '';
  private settled: boolean = false;
  private onEvent: (evt: StreamEvent) => void = (evt: StreamEvent) => {};

  /** Abort the in-flight request; safe to call repeatedly. */
  abort(): void {
    const request: http.HttpRequest | undefined = this.request;
    if (request === undefined) {
      return;
    }
    this.request = undefined;
    try {
      request.off('dataReceive');
      request.off('dataEnd');
      request.destroy();
    } catch (e) {
      // Destroying an already released client is not an error worth surfacing.
    }
  }

  /** Accumulate usage counters exactly as the desktop adapter does. */
  private updateUsage(usage: SseUsage): void {
    if (usage.input_tokens !== undefined) {
      this.usage.inputTokens = usage.input_tokens;
    }
    if (usage.output_tokens !== undefined) {
      this.usage.outputTokens = usage.output_tokens;
    }
    if (usage.cache_read_input_tokens !== undefined) {
      this.usage.cacheReadTokens = usage.cache_read_input_tokens;
    }
    if (usage.cache_creation_input_tokens !== undefined) {
      this.usage.cacheWriteTokens = usage.cache_creation_input_tokens;
    }
  }

  private emit(evt: StreamEvent): void {
    this.onEvent(evt);
  }

  /** Map provider stop reasons onto the adapter's finish kinds. */
  private static mapStopReason(reason: string): string {
    if (reason === 'end_turn' || reason === 'stop_sequence') {
      return 'stop';
    }
    if (reason === 'tool_use') {
      return 'tool-calls';
    }
    if (reason === 'max_tokens') {
      return 'max-tokens';
    }
    return 'stop';
  }

  /** Turn one decoded SSE data payload into stream events. */
  private handleEvent(raw: string): void {
    const payload: string = raw.trim();
    if (payload.length === 0 || payload === '[DONE]') {
      return;
    }
    let event: SseEvent;
    try {
      event = JSON.parse(payload) as SseEvent;
    } catch (e) {
      log.warn(`unparseable sse payload: ${payload.slice(0, 120)}`);
      return;
    }
    const type: string = event.type === undefined ? '' : event.type;
    if (type === 'message_start') {
      if (!this.started) {
        this.started = true;
        const message: SseMessage | undefined = event.message;
        if (message !== undefined && message.usage !== undefined) {
          const usage: SseUsage | undefined = message.usage;
          if (usage !== undefined) {
            this.updateUsage(usage);
          }
        }
      }
      return;
    }
    if (type !== 'content_block_start' && type !== 'content_block_delta'
      && type !== 'content_block_stop' && type !== 'message_delta' && type !== 'message_stop') {
      // Anthropic emits ping and other bookkeeping events; they carry no content.
      return;
    }
    if (!this.started) {
      return;
    }
    if (type === 'content_block_start') {
      this.startBlock(event);
      return;
    }
    if (type === 'content_block_delta') {
      this.applyDelta(event);
      return;
    }
    if (type === 'content_block_stop') {
      this.stopBlock(event);
      return;
    }
    if (type === 'message_delta') {
      const delta: SseDelta | undefined = event.delta;
      if (delta !== undefined) {
        if (delta.stop_reason === 'refusal') {
          const details: SseStopDetails | undefined = delta.stop_details;
          const explanation: string | undefined = details === undefined ? undefined : details.explanation;
          this.refused = explanation === undefined ? '' : explanation;
          this.finishKind = 'refusal';
        } else if (delta.stop_reason !== undefined) {
          this.finishKind = LlmClient.mapStopReason(delta.stop_reason);
        }
      }
      const usage: SseUsage | undefined = event.usage;
      if (usage !== undefined) {
        this.updateUsage(usage);
      }
      return;
    }
    this.settle();
  }

  private startBlock(event: SseEvent): void {
    const wireIndex: number = event.index === undefined ? 0 : event.index;
    if (this.blocks.has(wireIndex) || this.finishKind.length > 0) {
      return;
    }
    const native: SseContentBlock | undefined = event.content_block;
    if (native === undefined) {
      return;
    }
    const block: OpenBlock = new OpenBlock();
    block.index = this.nextIndex;
    this.nextIndex = this.nextIndex + 1;
    const nativeType: string = native.type === undefined ? '' : native.type;
    if (nativeType === 'text') {
      block.kind = BLOCK_TEXT;
      block.text = native.text === undefined ? '' : native.text;
    } else if (nativeType === 'thinking') {
      block.kind = BLOCK_REASONING;
      block.text = native.thinking === undefined ? '' : native.thinking;
      block.signature = native.signature === undefined ? '' : native.signature;
    } else if (nativeType === 'tool_use') {
      block.kind = BLOCK_TOOL_CALL;
      block.toolCallId = native.id === undefined ? '' : native.id;
      block.toolName = native.name === undefined ? '' : native.name;
    } else {
      log.warn(`unsupported response block ${nativeType}`);
      return;
    }
    this.blocks.set(wireIndex, block);
    const startEvent: StreamEvent = { kind: EVT_BLOCK_START, index: block.index, text: block.kind };
    this.emit(startEvent);
    if (block.kind === BLOCK_TOOL_CALL) {
      const toolEvent: StreamEvent = {
        kind: EVT_TOOL_DELTA, index: block.index,
        toolCallId: block.toolCallId, toolName: block.toolName, argumentsDelta: ''
      };
      this.emit(toolEvent);
    } else if (block.text.length > 0) {
      const textEvent: StreamEvent = {
        kind: block.kind === BLOCK_TEXT ? EVT_TEXT : EVT_REASONING, index: block.index, text: block.text
      };
      this.emit(textEvent);
    }
  }

  private applyDelta(event: SseEvent): void {
    const wireIndex: number = event.index === undefined ? 0 : event.index;
    const block: OpenBlock | undefined = this.blocks.get(wireIndex);
    const delta: SseDelta | undefined = event.delta;
    if (block === undefined || block.closed || delta === undefined) {
      return;
    }
    const deltaType: string = delta.type === undefined ? '' : delta.type;
    if (deltaType === 'text_delta' && block.kind === BLOCK_TEXT) {
      const text: string = delta.text === undefined ? '' : delta.text;
      block.text += text;
      const evt: StreamEvent = { kind: EVT_TEXT, index: block.index, text: text };
      this.emit(evt);
      return;
    }
    if (deltaType === 'thinking_delta' && block.kind === BLOCK_REASONING) {
      const text: string = delta.thinking === undefined ? '' : delta.thinking;
      block.text += text;
      const evt: StreamEvent = { kind: EVT_REASONING, index: block.index, text: text };
      this.emit(evt);
      return;
    }
    if (deltaType === 'signature_delta' && block.kind === BLOCK_REASONING) {
      block.signature += delta.signature === undefined ? '' : delta.signature;
      return;
    }
    if (deltaType === 'input_json_delta' && block.kind === BLOCK_TOOL_CALL) {
      const fragment: string = delta.partial_json === undefined ? '' : delta.partial_json;
      block.json += fragment;
      const evt: StreamEvent = {
        kind: EVT_TOOL_DELTA, index: block.index,
        toolCallId: block.toolCallId, toolName: block.toolName, argumentsDelta: fragment
      };
      this.emit(evt);
    }
  }

  private stopBlock(event: SseEvent): void {
    const wireIndex: number = event.index === undefined ? 0 : event.index;
    const block: OpenBlock | undefined = this.blocks.get(wireIndex);
    if (block === undefined || block.closed) {
      return;
    }
    block.closed = true;
    const content: ContentBlock = LlmClient.toContent(block);
    const evt: StreamEvent = { kind: EVT_BLOCK_END, index: block.index, block: content };
    this.emit(evt);
  }

  /** Convert the accumulator into a durable block. */
  private static toContent(block: OpenBlock): ContentBlock {
    if (block.kind === BLOCK_TOOL_CALL) {
      const call: ContentBlock = {
        kind: BLOCK_TOOL_CALL,
        toolCallId: block.toolCallId,
        toolName: block.toolName,
        toolArguments: block.json.length > 0 ? block.json : '{}'
      };
      return call;
    }
    if (block.kind === BLOCK_REASONING) {
      const reasoning: ContentBlock = { kind: BLOCK_REASONING, text: block.text };
      if (block.signature.length > 0) {
        reasoning.signature = block.signature;
      }
      return reasoning;
    }
    const text: ContentBlock = { kind: BLOCK_TEXT, text: block.text };
    return text;
  }

  /** Emit final usage and finish, once. */
  private settle(): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.usage.totalTokens = this.usage.inputTokens + this.usage.outputTokens
      + this.usage.cacheReadTokens + this.usage.cacheWriteTokens;
    const usageEvent: StreamEvent = { kind: EVT_USAGE, index: -1, usage: this.usage };
    this.emit(usageEvent);
    if (this.finishKind === 'refusal') {
      const message: string = this.refused.length > 0
        ? `DeepSeek refused to answer: ${this.refused}`
        : 'DeepSeek refused to answer';
      const evt: StreamEvent = { kind: EVT_ERROR, index: -1, errorCode: 'CONTENT_REFUSED', errorText: message };
      this.emit(evt);
      return;
    }
    const finishEvent: StreamEvent = {
      kind: EVT_FINISH, index: -1, finishKind: this.finishKind.length > 0 ? this.finishKind : 'stop'
    };
    this.emit(finishEvent);
  }

  /** Consume a decoded text chunk, emitting one event per complete SSE line. */
  private feed(chunk: string): void {
    this.rawBody += chunk;
    this.lineBuffer += chunk;
    let newlineIndex: number = this.lineBuffer.indexOf('\n');
    while (newlineIndex >= 0) {
      const line: string = this.lineBuffer.slice(0, newlineIndex);
      this.lineBuffer = this.lineBuffer.slice(newlineIndex + 1);
      this.handleLine(line);
      newlineIndex = this.lineBuffer.indexOf('\n');
    }
  }

  /** Parse one SSE line. */
  private handleLine(rawLine: string): void {
    let line: string = rawLine;
    if (line.endsWith('\r')) {
      line = line.slice(0, line.length - 1);
    }
    if (line.length === 0 || line.startsWith(':')) {
      return;
    }
    if (line.startsWith('data:')) {
      this.handleEvent(line.slice(5));
    }
  }

  /**
   * Send one Messages request and stream the reply.
   *
   * @returns `undefined` on a clean finish, otherwise a normalised failure.
   */
  async stream(
    body: WireRequest,
    apiKey: string,
    baseUrl: string,
    onEvent: (evt: StreamEvent) => void,
    token: CancelToken
  ): Promise<LlmErrorInfo | undefined> {
    this.onEvent = onEvent;
    if (apiKey.trim().length === 0) {
      return { code: 'MISSING_CREDENTIAL', message: 'No API key configured' };
    }
    if (token.cancelled) {
      return { code: 'ABORTED', message: 'Cancelled' };
    }
    const url: string = joinUrl(baseUrl, MESSAGES_PATH);
    const request: http.HttpRequest = http.createHttp();
    this.request = request;

    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'application/json';
    headers['Accept'] = 'text/event-stream';
    headers['Cache-Control'] = 'no-cache';
    headers[HEADER_API_KEY] = apiKey;

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: JSON.stringify(body),
      connectTimeout: 30000,
      readTimeout: 300000,
      expectDataType: http.HttpDataType.STRING
    };

    const cancelListener = (): void => {
      this.abort();
    };
    token.onCancel(cancelListener);

    request.on('dataReceive', (data: ArrayBuffer) => {
      const bytes: Uint8Array = new Uint8Array(data);
      const text: string = this.decoder.decodeToString(bytes, STREAM_DECODE);
      this.feed(text);
    });
    request.on('dataEnd', () => {
      // A trailing partial line carries no complete payload.
    });

    let responseCode: number = 0;
    try {
      responseCode = await request.requestInStream(url, options);
    } catch (e) {
      token.offCancel(cancelListener);
      this.abort();
      if (token.cancelled) {
        return { code: 'ABORTED', message: 'Cancelled' };
      }
      const err = e as BusinessError;
      log.error(`transport failure ${err.code} ${err.message}`);
      const code: string = codeForTransport(err);
      return { code: code, message: err.message === undefined ? 'network error' : err.message };
    }
    token.offCancel(cancelListener);
    this.abort();

    if (token.cancelled) {
      return { code: 'ABORTED', message: 'Cancelled' };
    }
    if (responseCode >= 400) {
      const code: string = codeForStatus(responseCode);
      const message: string = messageFromBody(this.rawBody, `HTTP ${responseCode}`);
      log.error(`http ${responseCode} ${code}: ${message}`);
      return { code: code, message: message };
    }
    if (!this.settled) {
      return { code: 'STREAM_CLOSED', message: 'The stream ended unexpectedly' };
    }
    return undefined;
  }
}
