/**
 * Conversation titles.
 *
 * Mirrors the desktop `session-titles` bundle: a tiny second request names the session
 * after the first exchange. Failure is silent — an untitled session is a cosmetic
 * problem, not a reason to disturb the user.
 */

import { AppSettings, ContentBlock, EVT_FINISH, EVT_TEXT, StreamEvent } from '../model/Types';
import { CancelToken } from '../common/Cancel';
import { Log, clip } from '../common/Utils';
import { LlmClient } from './LlmClient';
import { buildTitlePrompt } from './Prompt';
import { WireRequest } from './Wire';

const log = new Log('Titles');

/** Strip quotes, list markers and trailing punctuation from a generated title. */
export function normalizeTitle(raw: string): string {
  let title: string = raw.trim();
  title = title.replace(/^["'“”‘’`#*\-\s]+/, '');
  title = title.replace(/["'“”‘’`]+$/, '');
  title = title.replace(/[。．.!！?？,，;；:：]+$/, '');
  const newline: number = title.indexOf('\n');
  if (newline >= 0) {
    title = title.slice(0, newline).trim();
  }
  return clip(title, 40);
}

export class TitleService {
  /**
   * Ask the model for a short title.
   *
   * @returns the title, or an empty string when generation failed or produced nothing usable
   */
  static async generate(
    settings: AppSettings,
    apiKey: string,
    firstUser: string,
    firstAssistant: string
  ): Promise<string> {
    if (firstUser.trim().length === 0) {
      return '';
    }
    const request: WireRequest = {
      model: settings.modelId,
      stream: true,
      max_tokens: 64,
      messages: [{ role: 'user', content: [{ type: 'text', text: buildTitlePrompt(firstUser, firstAssistant) }] }],
      thinking: { type: 'disabled' }
    };
    let collected: string = '';
    const handler = (evt: StreamEvent): void => {
      if (evt.kind === EVT_TEXT && evt.text !== undefined) {
        collected += evt.text;
      } else if (evt.kind === EVT_FINISH) {
        // Settled; nothing else to do.
      }
    };
    const token: CancelToken = new CancelToken();
    const client: LlmClient = new LlmClient();
    const error = await client.stream(request, apiKey, settings.baseUrl, handler, token);
    if (error !== undefined) {
      log.warn(`title generation failed: ${error.code} ${error.message}`);
      return '';
    }
    const title: string = normalizeTitle(collected);
    if (title.length === 0) {
      return '';
    }
    return title;
  }

  /** Fallback title derived from the first user message, used when generation is off. */
  static fallback(firstUser: string): string {
    const flat: string = firstUser.replace(/\s+/g, ' ').trim();
    if (flat.length === 0) {
      return '';
    }
    return clip(flat, 24);
  }

  /** Extract plain text of an assistant message for the title prompt. */
  static textOf(blocks: Array<ContentBlock>): string {
    let text: string = '';
    for (let i = 0; i < blocks.length; i++) {
      const block: ContentBlock = blocks[i];
      if (block.kind === 'text' && block.text !== undefined) {
        text += block.text;
      }
    }
    return text;
  }
}
