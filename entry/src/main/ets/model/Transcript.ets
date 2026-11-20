/**
 * Conversation → transcript.
 *
 * The memory extractor reads a flattened slice of the conversation rather than the
 * message objects, so this lives apart from any network or storage code and can be
 * tested directly.
 */

import { BLOCK_TEXT, ChatSession, ROLE_ASSISTANT, ROLE_USER } from './Types';
import { clipText } from '../common/FactParse';

/**
 * Flatten the tail of a conversation into `User:` / `Assistant:` lines.
 *
 * Tool results and system notices are skipped: they carry no durable facts about the
 * user and would only dilute the summariser's attention.
 *
 * @param session conversation to flatten
 * @param fromIndex first message to include
 * @param messageChars longest single message kept
 * @param budget total characters; the newest lines win
 */
export function buildTranscript(
  session: ChatSession,
  fromIndex: number,
  messageChars: number,
  budget: number
): string {
  const lines: Array<string> = [];
  for (let i = Math.max(0, fromIndex); i < session.messages.length; i++) {
    const message = session.messages[i];
    if (message.role !== ROLE_USER && message.role !== ROLE_ASSISTANT) {
      continue;
    }
    let text: string = '';
    for (let j = 0; j < message.blocks.length; j++) {
      const block = message.blocks[j];
      if (block.kind === BLOCK_TEXT && block.text !== undefined) {
        text += block.text;
      }
    }
    text = text.trim();
    if (text.length === 0) {
      continue;
    }
    const who: string = message.role === ROLE_USER ? 'User' : 'Assistant';
    lines.push(`${who}: ${clipText(text, messageChars)}`);
  }
  let total: number = 0;
  let start: number = lines.length;
  while (start > 0) {
    const size: number = lines[start - 1].length + 1;
    if (total + size > budget && start < lines.length) {
      break;
    }
    total += size;
    start--;
  }
  return lines.slice(start).join('\n');
}
