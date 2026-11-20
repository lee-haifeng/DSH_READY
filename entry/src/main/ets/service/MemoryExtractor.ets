/**
 * Automatic memory extraction.
 *
 * The `remember` tool only fires when the model decides to call it, which in practice is
 * rare. This module asks the same model, once, to summarise what in the recent
 * conversation is worth keeping forever — the "semantic" half of long-term memory.
 *
 * It runs off the critical path: the reply is already on screen and persisted before this
 * call starts, so a failure here can only lose a memory, never a message.
 */

import { AppSettings, BLOCK_TEXT, ChatSession, EVT_TEXT, ROLE_ASSISTANT, ROLE_USER, StreamEvent } from '../model/Types';
import { CancelToken } from '../common/Cancel';
import { Log } from '../common/Utils';
import { parseFacts, ParsedFact } from '../common/FactParse';
import { buildTranscript } from '../model/Transcript';
import { LlmClient } from './LlmClient';
import { MemoryEntry } from './MemoryStore';
import { WireRequest } from './Wire';

const log = new Log('Extract');

/** Longest transcript sent for summarisation. */
const TRANSCRIPT_CHARS: number = 6000;
/** Longest single message kept in the transcript. */
const MESSAGE_CHARS: number = 500;
/** Longest accepted fact. */
const FACT_CHARS: number = 200;
/** Most facts accepted from one pass. */
const MAX_FACTS: number = 3;
/** Existing facts shown to the model so it does not repeat them. */
const SHOWN_EXISTING: number = 20;

export class MemoryExtractor {
  /** Flatten the tail of a conversation into a transcript for the extractor. */
  static buildTranscript(session: ChatSession, fromIndex: number): string {
    return buildTranscript(session, fromIndex, MESSAGE_CHARS, TRANSCRIPT_CHARS);
  }

  /** Pull the JSON array out of a model response, tolerating fences and prose. */
  static parseFacts(raw: string): Array<ParsedFact> {
    return parseFacts(raw, MAX_FACTS, FACT_CHARS);
  }

  /** Prompt asking for a JSON array of durable facts. */
  static buildPrompt(transcript: string, existing: Array<MemoryEntry>): string {
    const parts: Array<string> = [];
    parts.push('You maintain the long-term memory of a personal assistant app.');
    parts.push('From the conversation excerpt below, extract facts worth remembering forever:');
    parts.push('projects the user is working on, their preferences (language, tone, tools), standing instructions, constraints, and personal context they chose to share.');
    parts.push('');
    parts.push('Rules:');
    parts.push('- Only durable facts. Never transient task details, open questions, or anything the assistant said about itself.');
    parts.push('- Each fact: one self-contained sentence in the user\'s language, written as "The user ...".');
    parts.push(`- At most ${MAX_FACTS} facts. Fewer is better than padding.`);
    parts.push('- Give each fact 2 to 4 "keywords": short alternative words a user might use when asking about it');
    parts.push('  (synonyms, or the English and Chinese form of the same idea). Same language as the fact. No sentences.');
    parts.push('- Reply with a JSON array and nothing else, in this shape:');
    parts.push('  [{"fact": "The user is building a HarmonyOS port of DeepSeek Harness.", "keywords": ["鸿蒙", "移植", "HarmonyOS"]}]');
    parts.push('- Reply [] if nothing qualifies.');
    if (existing.length > 0) {
      parts.push('');
      parts.push('Already remembered (do not repeat these):');
      for (let i = 0; i < existing.length && i < SHOWN_EXISTING; i++) {
        parts.push(`- ${existing[i].text}`);
      }
    }
    parts.push('');
    parts.push('Conversation:');
    parts.push(transcript);
    return parts.join('\n');
  }

  /**
   * Ask the model for facts worth remembering.
   *
   * @returns up to three facts, or an empty array on any failure
   */
  static async extract(
    settings: AppSettings,
    apiKey: string,
    transcript: string,
    existing: Array<MemoryEntry>
  ): Promise<Array<ParsedFact>> {
    if (apiKey.length === 0 || transcript.trim().length === 0) {
      return [];
    }
    const request: WireRequest = {
      model: settings.modelId,
      stream: true,
      max_tokens: 400,
      messages: [{ role: 'user', content: [{ type: 'text', text: MemoryExtractor.buildPrompt(transcript, existing) }] }],
      thinking: { type: 'disabled' }
    };
    let collected: string = '';
    const handler = (evt: StreamEvent): void => {
      if (evt.kind === EVT_TEXT && evt.text !== undefined) {
        collected += evt.text;
      }
    };
    const client: LlmClient = new LlmClient();
    const error = await client.stream(request, apiKey, settings.baseUrl, handler, new CancelToken());
    if (error !== undefined) {
      log.warn(`extraction failed: ${error.code} ${error.message}`);
      return [];
    }
    return MemoryExtractor.parseFacts(collected);
  }
}
