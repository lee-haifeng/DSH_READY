/**
 * Conversation → render model.
 *
 * The chat screen must not render raw `ChatMessage` records: tool results arrive as
 * separate messages, and reasoning, prose and tool cards need to appear in the exact
 * order the model produced them. This module turns the durable log into an ordered,
 * flat view model that components can render without any pairing logic of their own.
 */

import {
  BLOCK_IMAGE, BLOCK_REASONING, BLOCK_TEXT, BLOCK_TOOL_CALL, ChatMessage, ContentBlock,
  ROLE_ASSISTANT, ROLE_SYSTEM, ROLE_TOOL, ROLE_USER, TokenUsage
} from './Types';

/** One ordered piece of an assistant turn. */
export interface RenderPart {
  /** `text`, `reasoning` or `tool`. */
  kind: string;
  /** Payload for text and reasoning parts. */
  text: string;
  /** Index into `RenderItem.tools` for tool parts. */
  toolIndex: number;
}

/** A tool call joined with its result. */
export interface ToolPair {
  toolCallId: string;
  name: string;
  argsJson: string;
  /** `running` while the call streams, then `done` or `error`. */
  state: string;
  summary: string;
  resultText: string;
  isError: boolean;
}

/** One renderable row in the conversation. */
export interface RenderItem {
  kind: string;
  messageId: string;
  parts: Array<RenderPart>;
  images: Array<ContentBlock>;
  tools: Array<ToolPair>;
  createdAt: number;
  /** Assistant-only token accounting. */
  usage?: TokenUsage;
  durationMs: number;
  errorText: string;
}

/** Build a `ToolPair` from a call block. */
function emptyPair(call: ContentBlock): ToolPair {
  return {
    toolCallId: call.toolCallId === undefined ? '' : call.toolCallId,
    name: call.toolName === undefined ? '' : call.toolName,
    argsJson: call.toolArguments === undefined ? '' : call.toolArguments,
    state: 'running',
    summary: '',
    resultText: '',
    isError: false
  };
}

/**
 * Convert the durable message log into render rows.
 *
 * Tool messages are folded into the assistant turn that issued the call, so a turn
 * reads as one coherent block: reasoning, prose, tool cards, prose again.
 *
 * @param messages durable log, oldest first
 * @returns render rows in display order
 */
export function buildRenderItems(messages: Array<ChatMessage>): Array<RenderItem> {
  const items: Array<RenderItem> = [];
  let current: RenderItem | undefined = undefined;
  const pairIndex: Map<string, number> = new Map();

  for (let i = 0; i < messages.length; i++) {
    const message: ChatMessage = messages[i];

    if (message.role === ROLE_TOOL) {
      const owner: RenderItem | undefined = current;
      if (owner === undefined) {
        continue;
      }
      const id: string = message.toolCallId === undefined ? '' : message.toolCallId;
      const index: number | undefined = pairIndex.get(id);
      if (index === undefined) {
        continue;
      }
      const pair: ToolPair = owner.tools[index];
      pair.state = message.isError === true ? 'error' : 'done';
      pair.isError = message.isError === true;
      pair.summary = message.toolSummary === undefined ? '' : message.toolSummary;
      let result: string = '';
      for (let j = 0; j < message.blocks.length; j++) {
        const block: ContentBlock = message.blocks[j];
        if (block.kind === BLOCK_TEXT && block.text !== undefined) {
          result += block.text;
        }
      }
      pair.resultText = result;
      continue;
    }

    if (message.role === ROLE_SYSTEM) {
      let text: string = '';
      for (let j = 0; j < message.blocks.length; j++) {
        const block: ContentBlock = message.blocks[j];
        if (block.kind === BLOCK_TEXT && block.text !== undefined) {
          text += block.text;
        }
      }
      const systemItem: RenderItem = {
        kind: 'system',
        messageId: message.id,
        parts: [{ kind: 'text', text: text, toolIndex: -1 }],
        images: [],
        tools: [],
        createdAt: message.createdAt,
        durationMs: 0,
        errorText: ''
      };
      items.push(systemItem);
      current = undefined;
      continue;
    }

    const item: RenderItem = {
      kind: message.role,
      messageId: message.id,
      parts: [],
      images: [],
      tools: [],
      createdAt: message.createdAt,
      durationMs: message.durationMs === undefined ? 0 : message.durationMs,
      errorText: message.errorText === undefined ? '' : message.errorText
    };
    if (message.usage !== undefined) {
      item.usage = message.usage;
    }
    pairIndex.clear();
    for (let j = 0; j < message.blocks.length; j++) {
      const block: ContentBlock = message.blocks[j];
      if (block.kind === BLOCK_TEXT) {
        const text: string = block.text === undefined ? '' : block.text;
        if (text.length > 0) {
          item.parts.push({ kind: 'text', text: text, toolIndex: -1 });
        }
      } else if (block.kind === BLOCK_REASONING) {
        const text: string = block.text === undefined ? '' : block.text;
        if (text.length > 0) {
          item.parts.push({ kind: 'reasoning', text: text, toolIndex: -1 });
        }
      } else if (block.kind === BLOCK_TOOL_CALL) {
        const toolIndex: number = item.tools.length;
        item.tools.push(emptyPair(block));
        const id: string = block.toolCallId === undefined ? '' : block.toolCallId;
        pairIndex.set(id, toolIndex);
        item.parts.push({ kind: 'tool', text: '', toolIndex: toolIndex });
      } else if (block.kind === BLOCK_IMAGE) {
        item.images.push(block);
      }
    }
    if (item.kind === ROLE_ASSISTANT || item.kind === ROLE_USER) {
      items.push(item);
      if (item.kind === ROLE_ASSISTANT) {
        current = item;
      } else {
        current = undefined;
      }
    }
  }
  // Unanswered calls stay `running`, which is exactly what the spinner shows.
  return items;
}

/** Total visible characters of an assistant row, used to decide whether to collapse. */
export function textLength(item: RenderItem): number {
  let total: number = 0;
  for (let i = 0; i < item.parts.length; i++) {
    const part: RenderPart = item.parts[i];
    if (part.kind === 'text') {
      total += part.text.length;
    }
  }
  return total;
}
