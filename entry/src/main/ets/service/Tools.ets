/**
 * Tool execution.
 *
 * Each tool returns a `ToolResult` instead of throwing: the agent loop always ends up
 * with a tool result message, which keeps the wire history valid (the Messages API
 * requires every `tool_use` block to be answered by a `tool_result`).
 */

import { MAX_GOAL_ROUNDS, MAX_TOOL_RESULT_CHARS } from '../common/Constants';
import {
  AppSettings, BLOCK_TEXT, ChatSession, Goal, GOAL_ACTIVE, GOAL_BLOCKED, GOAL_COMPLETE, GOAL_PAUSED,
  ROLE_ASSISTANT, ROLE_TOOL, ROLE_USER, TodoItem, TODO_COMPLETED, TODO_IN_PROGRESS, TODO_PENDING, ToolResult
} from '../model/Types';
import { clip, Log, newId } from '../common/Utils';
import {
  TOOL_ASK_USER, TOOL_FORGET, TOOL_GOAL_CREATE, TOOL_GOAL_GET, TOOL_GOAL_UPDATE, TOOL_READ_SESSION,
  TOOL_RECALL, TOOL_REMEMBER, TOOL_SEARCH_HISTORY, TOOL_TODO, TOOL_WEB_FETCH, TOOL_WEB_SEARCH
} from './Prompt';
import { fetchPage, formatResults, SearchResult, searchWeb } from './WebTool';
import { SearchHit, SessionStore } from './SessionStore';
import { MemoryEntry, MemoryStore } from './MemoryStore';

const log = new Log('Tools');

/** Everything a tool may read or mutate during one execution. */
export interface ToolContext {
  session: ChatSession;
  settings: AppSettings;
  /** Ask the user a question and resolve with their answer, or an empty string. */
  askUser: (question: string, options: Array<string>) => Promise<string>;
}

/**
 * Typed reader over the model-supplied JSON arguments.
 *
 * Deliberately defensive: a stream cut mid-argument yields invalid JSON, and a tool must
 * still answer rather than abort the turn.
 */
class Args {
  private data: Record<string, Object> = {};

  constructor(raw: string) {
    if (raw.trim().length === 0) {
      return;
    }
    try {
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      if (parsed !== null && parsed !== undefined) {
        this.data = parsed;
      }
    } catch (e) {
      this.data = {};
    }
  }

  /** String argument, or an empty string. */
  str(key: string): string {
    const value: Object | undefined = this.data[key];
    if (typeof value === 'string') {
      return value as string;
    }
    return '';
  }

  /** Numeric argument, or the fallback. */
  num(key: string, fallback: number): number {
    const value: Object | undefined = this.data[key];
    if (typeof value === 'number') {
      return value as number;
    }
    return fallback;
  }

  /** Array argument as raw entries, or an empty array. */
  arr(key: string): Array<Object> {
    const value: Object | undefined = this.data[key];
    if (value === undefined || value === null || !Array.isArray(value)) {
      return [];
    }
    const source: Array<Object> = value as Array<Object>;
    const copy: Array<Object> = [];
    for (let i = 0; i < source.length; i++) {
      copy.push(source[i]);
    }
    return copy;
  }

  /** Read one field of one array entry as a string. */
  static fieldStr(entry: Object, key: string): string {
    if (entry === null || entry === undefined) {
      return '';
    }
    const record: Record<string, Object> = entry as Record<string, Object>;
    const value: Object | undefined = record[key];
    if (typeof value === 'string') {
      return value as string;
    }
    return '';
  }
}

/** Clip a result so one runaway page cannot blow up the context window. */
function cap(text: string): string {
  if (text.length <= MAX_TOOL_RESULT_CHARS) {
    return text;
  }
  return `${text.slice(0, MAX_TOOL_RESULT_CHARS)}\n\n[truncated: ${text.length - MAX_TOOL_RESULT_CHARS} more characters]`;
}

/** Build a successful result. */
function ok(content: string, summary: string): ToolResult {
  return { content: cap(content), isError: false, summary: summary };
}

/** Build a failed result. */
function fail(content: string, summary: string): ToolResult {
  return { content: cap(content), isError: true, summary: summary };
}

/** Normalise a status string onto the three accepted values. */
function normalizeStatus(status: string): string {
  if (status === TODO_COMPLETED) {
    return TODO_COMPLETED;
  }
  if (status === TODO_IN_PROGRESS || status === 'in-progress' || status === 'inprogress' || status === 'doing') {
    return TODO_IN_PROGRESS;
  }
  return TODO_PENDING;
}

/** Extract a display host from a URL, for the tool card header. */
function hostOf(url: string): string {
  const noScheme: string = url.startsWith('https://') ? url.slice(8) : url.startsWith('http://') ? url.slice(7) : url;
  const slash: number = noScheme.indexOf('/');
  return slash >= 0 ? noScheme.slice(0, slash) : noScheme;
}

/** `YYYY-MM-DD` for search results. */
function dayOf(ms: number): string {
  const d: Date = new Date(ms);
  const month: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const mm: string = month < 10 ? `0${month}` : `${month}`;
  const dd: string = day < 10 ? `0${day}` : `${day}`;
  return `${d.getFullYear()}-${mm}-${dd}`;
}

export class ToolRunner {
  /** Execute one tool call. Never throws. */
  static async execute(name: string, argsJson: string, ctx: ToolContext): Promise<ToolResult> {
    try {
      if (name === TOOL_WEB_SEARCH) {
        return await ToolRunner.webSearch(argsJson, ctx);
      }
      if (name === TOOL_WEB_FETCH) {
        return await ToolRunner.webFetch(argsJson);
      }
      if (name === TOOL_TODO) {
        return ToolRunner.todoWrite(argsJson, ctx);
      }
      if (name === TOOL_ASK_USER) {
        return await ToolRunner.askUser(argsJson, ctx);
      }
      if (name === TOOL_GOAL_CREATE) {
        return ToolRunner.goalCreate(argsJson, ctx);
      }
      if (name === TOOL_GOAL_GET) {
        return ToolRunner.goalGet(ctx);
      }
      if (name === TOOL_GOAL_UPDATE) {
        return ToolRunner.goalUpdate(argsJson, ctx);
      }
      if (name === TOOL_SEARCH_HISTORY) {
        return ToolRunner.searchHistory(argsJson, ctx);
      }
      if (name === TOOL_READ_SESSION) {
        return ToolRunner.readSession(argsJson);
      }
      if (name === TOOL_REMEMBER) {
        return ToolRunner.remember(argsJson, ctx);
      }
      if (name === TOOL_RECALL) {
        return ToolRunner.recall(argsJson);
      }
      if (name === TOOL_FORGET) {
        return ToolRunner.forget(argsJson);
      }
      return fail(`Unknown tool "${name}".`, 'unknown tool');
    } catch (e) {
      const message: string = e instanceof Error ? (e as Error).message : `${e}`;
      log.error(`tool ${name} threw: ${message}`);
      return fail(`The tool failed: ${message}`, 'tool error');
    }
  }

  private static async webSearch(argsJson: string, ctx: ToolContext): Promise<ToolResult> {
    const args: Args = new Args(argsJson);
    const query: string = args.str('query').trim();
    if (query.length === 0) {
      return fail('A non-empty "query" is required.', 'missing query');
    }
    let limit: number = args.num('max_results', 6);
    if (limit < 1) {
      limit = 1;
    }
    if (limit > 10) {
      limit = 10;
    }
    const results: Array<SearchResult> = await searchWeb(query, ctx.settings.searchProvider, limit);
    return ok(formatResults(query, results), results.length === 0 ? 'no results' : `${results.length} results`);
  }

  private static async webFetch(argsJson: string): Promise<ToolResult> {
    const args: Args = new Args(argsJson);
    const url: string = args.str('url').trim();
    if (url.length === 0) {
      return fail('A non-empty "url" is required.', 'missing url');
    }
    let maxChars: number = args.num('max_chars', 8000);
    if (maxChars < 500) {
      maxChars = 500;
    }
    if (maxChars > 30000) {
      maxChars = 30000;
    }
    const text: string = await fetchPage(url, maxChars);
    const failed: boolean = text.startsWith('HTTP ') || text.startsWith('network failure');
    return failed ? fail(text, hostOf(url)) : ok(text, hostOf(url));
  }

  private static todoWrite(argsJson: string, ctx: ToolContext): ToolResult {
    const args: Args = new Args(argsJson);
    const raw: Array<Object> = args.arr('todos');
    const next: Array<TodoItem> = [];
    let inProgress: number = 0;
    for (let i = 0; i < raw.length; i++) {
      const content: string = Args.fieldStr(raw[i], 'content').trim();
      if (content.length === 0) {
        continue;
      }
      let status: string = normalizeStatus(Args.fieldStr(raw[i], 'status'));
      if (status === TODO_IN_PROGRESS) {
        inProgress++;
        if (inProgress > 1) {
          status = TODO_PENDING;
        }
      }
      next.push({ content: content, status: status });
    }
    ctx.session.todos = next;
    let done: number = 0;
    for (let i = 0; i < next.length; i++) {
      if (next[i].status === TODO_COMPLETED) {
        done++;
      }
    }
    return ok(`Task list updated: ${next.length} items, ${done} completed.`, `${done}/${next.length} done`);
  }

  private static async askUser(argsJson: string, ctx: ToolContext): Promise<ToolResult> {
    const args: Args = new Args(argsJson);
    const question: string = args.str('question').trim();
    if (question.length === 0) {
      return fail('A non-empty "question" is required.', 'missing question');
    }
    const rawOptions: Array<Object> = args.arr('options');
    const options: Array<string> = [];
    for (let i = 0; i < rawOptions.length; i++) {
      const value: Object = rawOptions[i];
      if (typeof value === 'string' && (value as string).trim().length > 0) {
        options.push((value as string).trim());
      }
    }
    const answer: string = await ctx.askUser(question, options);
    if (answer.trim().length === 0) {
      return ok('The user dismissed the question without answering. '
        + 'Continue with your best judgement, or stop and explain what you need.', 'no answer');
    }
    return ok(`The user answered: ${answer}`, 'answered');
  }

  private static goalCreate(argsJson: string, ctx: ToolContext): ToolResult {
    const args: Args = new Args(argsJson);
    const objective: string = args.str('objective').trim();
    if (objective.length === 0) {
      return fail('A non-empty "objective" is required.', 'missing objective');
    }
    let maxRounds: number = args.num('max_rounds', MAX_GOAL_ROUNDS);
    if (maxRounds < 1) {
      maxRounds = 1;
    }
    if (maxRounds > MAX_GOAL_ROUNDS) {
      maxRounds = MAX_GOAL_ROUNDS;
    }
    const now: number = Date.now();
    const goal: Goal = {
      id: newId('g'),
      objective: objective,
      phase: GOAL_ACTIVE,
      rounds: 0,
      maxRounds: maxRounds,
      createdAt: now,
      updatedAt: now
    };
    ctx.session.goal = goal;
    return ok(`Goal created: "${objective}" (up to ${maxRounds} rounds).`, 'goal created');
  }

  private static goalGet(ctx: ToolContext): ToolResult {
    const goal: Goal | undefined = ctx.session.goal;
    if (goal === undefined) {
      return ok('There is no goal for this conversation.', 'no goal');
    }
    const lines: Array<string> = [];
    lines.push(`Objective: ${goal.objective}`);
    lines.push(`Phase: ${goal.phase}`);
    lines.push(`Round: ${goal.rounds} of ${goal.maxRounds}`);
    if (goal.blockedReason !== undefined && goal.blockedReason.length > 0) {
      lines.push(`Blocked because: ${goal.blockedReason}`);
    }
    return ok(lines.join('\n'), goal.phase);
  }

  private static goalUpdate(argsJson: string, ctx: ToolContext): ToolResult {
    const args: Args = new Args(argsJson);
    const action: string = args.str('action').trim();
    const goal: Goal | undefined = ctx.session.goal;
    if (goal === undefined) {
      return fail('There is no goal to update.', 'no goal');
    }
    if (action === 'pause') {
      goal.phase = GOAL_PAUSED;
    } else if (action === 'resume') {
      goal.phase = GOAL_ACTIVE;
    } else if (action === 'complete') {
      goal.phase = GOAL_COMPLETE;
    } else if (action === 'blocked') {
      goal.phase = GOAL_BLOCKED;
      goal.blockedReason = args.str('reason');
    } else {
      return fail('"action" must be one of pause, resume, complete or blocked.', 'bad action');
    }
    goal.updatedAt = Date.now();
    return ok(`Goal phase is now "${goal.phase}".`, goal.phase);
  }

  /* ------------------------------ long-term memory ----------------------------- */

  private static searchHistory(argsJson: string, ctx: ToolContext): ToolResult {
    const args: Args = new Args(argsJson);
    const query: string = args.str('query').trim();
    if (query.length === 0) {
      return fail('A non-empty "query" is required.', 'missing query');
    }
    let limit: number = args.num('limit', 5);
    if (limit < 1) {
      limit = 1;
    }
    if (limit > 10) {
      limit = 10;
    }
    const hits: Array<SearchHit> = SessionStore.search(query);
    const lines: Array<string> = [];
    let shown: number = 0;
    for (let i = 0; i < hits.length; i++) {
      const hit: SearchHit = hits[i];
      // The current conversation is already in context; skip it to avoid noise.
      if (hit.summary.id === ctx.session.id) {
        continue;
      }
      const title: string = hit.summary.title.length > 0 ? hit.summary.title : '(untitled)';
      lines.push(`[${hit.summary.id}] ${title} — ${dayOf(hit.summary.updatedAt)}`);
      lines.push(`  ${hit.snippet}`);
      shown++;
      if (shown >= limit) {
        break;
      }
    }
    if (shown === 0) {
      return ok(`No earlier conversation mentions "${query}".`, 'no match');
    }
    lines.push('');
    lines.push('Call read_session with one of these ids to see more of that conversation.');
    return ok(lines.join('\n'), `${shown} conversations`);
  }

  private static readSession(argsJson: string): ToolResult {
    const args: Args = new Args(argsJson);
    const id: string = args.str('session_id').trim();
    if (id.length === 0) {
      return fail('A non-empty "session_id" is required.', 'missing id');
    }
    let limit: number = args.num('limit', 12);
    if (limit < 1) {
      limit = 1;
    }
    if (limit > 30) {
      limit = 30;
    }
    const session: ChatSession | undefined = SessionStore.load(id);
    if (session === undefined) {
      return fail(`No conversation with id "${id}".`, 'not found');
    }
    const messages = session.messages;
    const from: number = Math.max(0, messages.length - limit);
    const title: string = session.title.length > 0 ? session.title : '(untitled)';
    const lines: Array<string> = [`Conversation "${title}" (${dayOf(session.updatedAt)}), last ${messages.length - from} of ${messages.length} messages:`];
    for (let i = from; i < messages.length; i++) {
      const message = messages[i];
      if (message.role !== ROLE_USER && message.role !== ROLE_ASSISTANT && message.role !== ROLE_TOOL) {
        continue;
      }
      let text: string = '';
      for (let j = 0; j < message.blocks.length; j++) {
        const block = message.blocks[j];
        if (block.kind === BLOCK_TEXT && block.text !== undefined) {
          text += block.text;
        }
      }
      if (text.trim().length === 0) {
        continue;
      }
      if (message.role === ROLE_TOOL) {
        const toolName: string = message.toolName === undefined ? 'tool' : message.toolName;
        lines.push(`[tool:${toolName}] ${clip(text, 600)}`);
      } else {
        const who: string = message.role === ROLE_USER ? 'User' : 'Assistant';
        lines.push(`${who}: ${clip(text, 1200)}`);
      }
    }
    const shown: number = messages.length - from;
    return ok(lines.join('\n'), `${shown} messages`);
  }

  private static remember(argsJson: string, ctx: ToolContext): ToolResult {
    const args: Args = new Args(argsJson);
    const text: string = args.str('text').trim();
    if (text.length === 0) {
      return fail('A non-empty "text" is required.', 'missing text');
    }
    const rawKeywords: Array<Object> = args.arr('keywords');
    const keywords: Array<string> = [];
    for (let i = 0; i < rawKeywords.length && keywords.length < 4; i++) {
      const value: Object = rawKeywords[i];
      if (typeof value === 'string' && (value as string).trim().length > 0) {
        keywords.push((value as string).trim());
      }
    }
    const entry: MemoryEntry | undefined = MemoryStore.add(text, ctx.session.id, keywords);
    if (entry === undefined) {
      return fail('The memory was empty after trimming.', 'empty');
    }
    return ok(`Remembered: ${entry.text}`, 'remembered');
  }

  private static recall(argsJson: string): ToolResult {
    const args: Args = new Args(argsJson);
    const query: string = args.str('query').trim();
    let limit: number = args.num('limit', 8);
    if (limit < 1) {
      limit = 1;
    }
    if (limit > 20) {
      limit = 20;
    }
    const entries: Array<MemoryEntry> = query.length === 0
      ? MemoryStore.all().slice(0, limit)
      : MemoryStore.search(query, limit);
    if (entries.length === 0) {
      return ok(query.length === 0
        ? 'Nothing has been remembered yet.'
        : `Nothing remembered matches "${query}".`, 'empty');
    }
    const lines: Array<string> = [];
    for (let i = 0; i < entries.length; i++) {
      const marker: string = entries[i].pinned ? ' (pinned)' : '';
      lines.push(`- [${entries[i].id}] ${entries[i].text}${marker}`);
    }
    return ok(lines.join('\n'), `${entries.length} entries`);
  }

  private static forget(argsJson: string): ToolResult {
    const args: Args = new Args(argsJson);
    const id: string = args.str('memory_id').trim();
    if (id.length === 0) {
      return fail('A non-empty "memory_id" is required. Call recall first to get one.', 'missing id');
    }
    if (!MemoryStore.remove(id)) {
      return fail(`No remembered fact with id "${id}".`, 'not found');
    }
    return ok('That fact is no longer remembered.', 'forgotten');
  }
}
