/**
 * Localised display names for tools.
 *
 * The model knows tools by their wire name; the UI should not show `web_search` to a
 * Chinese user. Unknown tools fall back to their wire name so a future tool is still
 * usable before it gets a translation.
 */

import { translate } from '../i18n/Strings';

/** Keys used by `translate`. */
const WEB_SEARCH: string = 'tool.webSearch';
const WEB_FETCH: string = 'tool.webFetch';
const TODO: string = 'tool.todo';
const ASK_USER: string = 'tool.askUser';
const GOAL_CREATE: string = 'tool.goalCreate';
const GOAL_GET: string = 'tool.goalGet';
const GOAL_UPDATE: string = 'tool.goalUpdate';

/** Human readable tool name for the current language. */
export function toolLabel(lang: string, name: string): string {
  let key: string = '';
  if (name === 'web_search') {
    key = WEB_SEARCH;
  } else if (name === 'web_fetch') {
    key = WEB_FETCH;
  } else if (name === 'todo_write') {
    key = TODO;
  } else if (name === 'ask_user_question') {
    key = ASK_USER;
  } else if (name === 'create_goal') {
    key = GOAL_CREATE;
  } else if (name === 'get_goal') {
    key = GOAL_GET;
  } else if (name === 'update_goal') {
    key = GOAL_UPDATE;
  }
  if (key.length === 0) {
    return name;
  }
  const label: string = translate(lang, key);
  return label === key ? name : label;
}

/** A single glyph that hints at the tool family, drawn as text to avoid asset bloat. */
export function toolGlyph(name: string): string {
  if (name === 'web_search') {
    return '⌕';
  }
  if (name === 'web_fetch') {
    return '↗';
  }
  if (name === 'todo_write') {
    return '☑';
  }
  if (name === 'ask_user_question') {
    return '?';
  }
  if (name === 'create_goal' || name === 'get_goal' || name === 'update_goal') {
    return '◎';
  }
  return '◇';
}
