/**
 * Prompt assembly.
 *
 * The desktop harness composes its system prompt from many plugins. On a phone the
 * surface is smaller, so this file keeps the parts that actually change model
 * behaviour: environment facts, tool policy, formatting, goal state and the clock.
 */

import { APP_NAME, MAX_GOAL_ROUNDS, UPSTREAM_VERSION } from '../common/Constants';
import { AppSettings, ChatSession, Goal, GOAL_ACTIVE, TodoItem, TODO_COMPLETED } from '../model/Types';

/** A tool declaration; `schemaJson` is parsed into the wire shape at request time. */
export interface ToolDef {
  name: string;
  description: string;
  schemaJson: string;
}

/** Tool names, used by the executor and the localisation layer. */
export const TOOL_WEB_SEARCH: string = 'web_search';
export const TOOL_WEB_FETCH: string = 'web_fetch';
export const TOOL_TODO: string = 'todo_write';
export const TOOL_ASK_USER: string = 'ask_user_question';
export const TOOL_GOAL_CREATE: string = 'create_goal';
export const TOOL_GOAL_GET: string = 'get_goal';
export const TOOL_GOAL_UPDATE: string = 'update_goal';

/** Every tool the model may call. */
export function toolDefs(): Array<ToolDef> {
  const search: ToolDef = {
    name: TOOL_WEB_SEARCH,
    description: 'Search the public web and return titles, URLs and snippets. Use it whenever the answer depends on current information.',
    schemaJson: '{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"max_results":{"type":"integer","description":"How many results to return, 1-10. Default 6."}},"required":["query"]}'
  };
  const fetch: ToolDef = {
    name: TOOL_WEB_FETCH,
    description: 'Download one web page and return its readable text. Use it after a search to read a promising result in full.',
    schemaJson: '{"type":"object","properties":{"url":{"type":"string","description":"Absolute http(s) URL"},"max_chars":{"type":"integer","description":"Maximum characters to return. Default 8000."}},"required":["url"]}'
  };
  const todo: ToolDef = {
    name: TOOL_TODO,
    description: 'Replace the task list shown to the user. Use it for any task with three or more steps so the user can follow progress. Keep at most one item in_progress.',
    schemaJson: '{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["content","status"]}}},"required":["todos"]}'
  };
  const ask: ToolDef = {
    name: TOOL_ASK_USER,
    description: 'Ask the user a question and wait for the answer. Use it only when a decision genuinely blocks progress and cannot be inferred.',
    schemaJson: '{"type":"object","properties":{"question":{"type":"string","description":"The question to ask"},"options":{"type":"array","items":{"type":"string"},"description":"Optional short answers the user can pick"}},"required":["question"]}'
  };
  const goalCreate: ToolDef = {
    name: TOOL_GOAL_CREATE,
    description: 'Create a long-running objective that keeps being worked on across rounds until complete. Only use it when the user explicitly wants sustained work.',
    schemaJson: `{"type":"object","properties":{"objective":{"type":"string","description":"The concrete outcome to achieve"},"max_rounds":{"type":"integer","description":"Continuation round cap, 1-${MAX_GOAL_ROUNDS}. Default ${MAX_GOAL_ROUNDS}."}},"required":["objective"]}`
  };
  const goalGet: ToolDef = {
    name: TOOL_GOAL_GET,
    description: 'Read the current goal, including its phase, round count and any blocking reason.',
    schemaJson: '{"type":"object","properties":{}}'
  };
  const goalUpdate: ToolDef = {
    name: TOOL_GOAL_UPDATE,
    description: 'Change the current goal: pause it, resume it, mark it complete, or report it blocked.',
    schemaJson: '{"type":"object","properties":{"action":{"type":"string","enum":["pause","resume","complete","blocked"]},"reason":{"type":"string","description":"Required when action is blocked"}},"required":["action"]}'
  };
  return [search, fetch, todo, ask, goalCreate, goalGet, goalUpdate];
}

/** Format the user's todo list for the prompt so the model remembers its own plan. */
function renderTodos(todos: Array<TodoItem>): string {
  if (todos.length === 0) {
    return '';
  }
  const lines: Array<string> = ['Current task list:'];
  for (let i = 0; i < todos.length; i++) {
    const item: TodoItem = todos[i];
    const mark: string = item.status === TODO_COMPLETED ? 'x' : ' ';
    const suffix: string = item.status === 'in_progress' ? ' (in progress)' : '';
    lines.push(`- [${mark}] ${item.content}${suffix}`);
  }
  return lines.join('\n');
}

/** Format the active goal block. */
function renderGoal(goal: Goal): string {
  const lines: Array<string> = [];
  lines.push('Active goal:');
  lines.push(`- Objective: ${goal.objective}`);
  lines.push(`- Phase: ${goal.phase}`);
  lines.push(`- Round: ${goal.rounds} of ${goal.maxRounds}`);
  if (goal.blockedReason !== undefined && goal.blockedReason.length > 0) {
    lines.push(`- Blocked because: ${goal.blockedReason}`);
  }
  if (goal.phase === GOAL_ACTIVE) {
    lines.push('Keep making concrete progress each round. When the objective is achieved, call update_goal with action "complete". If the user must decide something, ask instead of guessing.');
  }
  return lines.join('\n');
}

/** Two-digit pad. */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** Human readable local timestamp for the time-context block. */
export function formatClock(now: Date): string {
  const offsetMinutes: number = -now.getTimezoneOffset();
  const sign: string = offsetMinutes >= 0 ? '+' : '-';
  const abs: number = Math.abs(offsetMinutes);
  const offset: string = `${sign}${pad2(Math.floor(abs / 60))}:${pad2(abs % 60)}`;
  return `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())} `
    + `${pad2(now.getHours())}:${pad2(now.getMinutes())} (UTC${offset})`;
}

/** Build the full system prompt for one turn. */
export function buildSystemPrompt(settings: AppSettings, session: ChatSession, now: Date): string {
  const parts: Array<string> = [];

  parts.push(`You are ${APP_NAME}, the HarmonyOS phone client of DeepSeek Harness (upstream ${UPSTREAM_VERSION}). `
    + 'You are a capable, direct assistant. You answer questions, research the web and carry out multi-step work for the user.');

  parts.push([
    '# Environment',
    '- You run on a HarmonyOS phone inside a native chat app. There is no shell, no local repository and no filesystem access.',
    '- You have network tools and a task list. Everything you know about the outside world must come from these tools or from the conversation.',
    '- The app renders Markdown. Tables wider than a phone screen and very long code blocks are hard to read, so prefer short paragraphs, lists and narrow tables.',
    '- Do not invent tool names, file paths, URLs or search results. If a tool fails you, say what failed and what you would try next.',
    `- Current time: ${formatClock(now)}.`
  ].join('\n'));

  parts.push([
    '# Tool policy',
    `- \`${TOOL_WEB_SEARCH}\` for anything recent, factual or ambiguous. Follow up with \`${TOOL_WEB_FETCH}\` when a snippet is not enough.`,
    `- Cite the URLs you actually fetched, inline, as markdown links. Never cite a URL you did not open.`,
    `- \`${TOOL_TODO}\` for any task with three or more steps. Update it as you go; keep at most one item in progress.`,
    `- \`${TOOL_ASK_USER}\` only when a real decision blocks you. Do not ask for confirmation you do not need.`,
    `- \`${TOOL_GOAL_CREATE}\` only when the user asks for sustained, multi-round work. Never create a goal for a single answer.`
  ].join('\n'));

  parts.push([
    '# Style',
    '- Reply in the language the user wrote in. Match their register; be warm but not chatty.',
    '- Lead with the answer, then the supporting detail. No preamble, no "certainly", no restating the question.',
    '- Use Markdown: bold for key terms, lists for steps, fenced code blocks with a language tag for code.',
    '- Keep answers tight. On a phone, a wall of text is a failure.'
  ].join('\n'));

  const todosText: string = renderTodos(session.todos);
  if (todosText.length > 0) {
    parts.push(`# Plan\n${todosText}`);
  }

  const goal: Goal | undefined = session.goal;
  if (goal !== undefined && goal.phase !== 'complete') {
    parts.push(`# ${renderGoal(goal)}`);
  }

  const persona: string = settings.systemPrompt.trim();
  if (persona.length > 0) {
    parts.push(`# Additional instructions\n${persona}`);
  }

  return parts.join('\n\n');
}

/** Prompt used to name a conversation after its first exchange. */
export function buildTitlePrompt(firstUser: string, firstAssistant: string): string {
  const user: string = firstUser.length > 600 ? `${firstUser.slice(0, 600)}…` : firstUser;
  const assistant: string = firstAssistant.length > 400 ? `${firstAssistant.slice(0, 400)}…` : firstAssistant;
  return [
    'Write a title for the conversation below.',
    'Rules: at most 12 Chinese characters or 6 English words, no quotes, no trailing punctuation, no "Conversation about".',
    'Reply with the title only.',
    '',
    `User: ${user}`,
    `Assistant: ${assistant}`
  ].join('\n');
}

/** Instruction injected when a goal continues automatically. */
export function buildGoalContinuation(goal: Goal): string {
  return [
    `This is round ${goal.rounds + 1} of ${goal.maxRounds} for the active goal.`,
    `Goal: ${goal.objective}`,
    'Continue from where you stopped. Do concrete work, do not recap. '
    + 'If the objective is achieved, call update_goal with action "complete". '
    + 'If something genuinely blocks you, call update_goal with action "blocked" and a reason.'
  ].join(' ');
}
