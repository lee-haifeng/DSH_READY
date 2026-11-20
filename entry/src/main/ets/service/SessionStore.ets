/**
 * Session persistence.
 *
 * One JSON document per conversation under `<files>/sessions/`, plus a small index
 * that keeps the list screen cheap. Writes go through a temporary file and a rename so
 * a killed process can never leave a half-written conversation behind.
 */

import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SESSIONS_DIR, SESSION_INDEX_FILE } from '../common/Constants';
import {
  ChatMessage, ChatSession, SessionSummary, BLOCK_TEXT, BLOCK_REASONING, BLOCK_TOOL_CALL, BLOCK_IMAGE,
  ROLE_USER, ROLE_ASSISTANT, ContentBlock
} from '../model/Types';
import { AppContext } from './AppContext';
import { Log, clip, newId } from '../common/Utils';
import { KEY_SESSION_REVISION } from '../common/StateKeys';

const log = new Log('Sessions');

/** A search hit: the session plus the first matching line. */
export interface SearchHit {
  summary: SessionSummary;
  snippet: string;
}

/** Join a directory and a file name with a single separator. */
function join(dir: string, name: string): string {
  return dir.endsWith('/') ? `${dir}${name}` : `${dir}/${name}`;
}

/** Write a file atomically (temp file + rename). */
function writeAtomic(path: string, content: string): void {
  const tmp: string = `${path}.tmp`;
  const file: fileIo.File = fileIo.openSync(tmp,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, content);
  } finally {
    fileIo.closeSync(file);
  }
  if (fileIo.accessSync(path)) {
    fileIo.unlinkSync(path);
  }
  fileIo.renameSync(tmp, path);
}

/** Read a text file, returning an empty string when it does not exist. */
function readText(path: string): string {
  if (!fileIo.accessSync(path)) {
    return '';
  }
  try {
    return fileIo.readTextSync(path);
  } catch (e) {
    const err = e as BusinessError;
    log.warn(`read ${path} failed: ${err.code} ${err.message}`);
    return '';
  }
}

/** First user text in a message list, collapsed to one line. */
function previewOf(messages: Array<ChatMessage>): string {
  for (let i = 0; i < messages.length; i++) {
    const message: ChatMessage = messages[i];
    if (message.role !== ROLE_USER) {
      continue;
    }
    for (let j = 0; j < message.blocks.length; j++) {
      const block: ContentBlock = message.blocks[j];
      if (block.kind === BLOCK_TEXT && block.text !== undefined && block.text.trim().length > 0) {
        return clip(block.text, 80);
      }
    }
  }
  return '';
}

/** All searchable text of a message, for the search screen. */
function textOf(message: ChatMessage): string {
  let text: string = '';
  for (let i = 0; i < message.blocks.length; i++) {
    const block: ContentBlock = message.blocks[i];
    if (block.kind === BLOCK_TEXT && block.text !== undefined) {
      text += ` ${block.text}`;
    } else if (block.kind === BLOCK_REASONING && block.text !== undefined) {
      text += ` ${block.text}`;
    } else if (block.kind === BLOCK_TOOL_CALL && block.toolName !== undefined) {
      text += ` ${block.toolName}`;
    } else if (block.kind === BLOCK_IMAGE && block.name !== undefined) {
      text += ` ${block.name}`;
    }
  }
  return text;
}

export class SessionStore {
  private static cachedIndex: Array<SessionSummary> | undefined = undefined;

  /** Directory holding session documents, created on demand. */
  static dir(): string {
    const root: string = join(AppContext.filesDir(), SESSIONS_DIR);
    if (!fileIo.accessSync(root)) {
      fileIo.mkdirSync(root, true);
    }
    return root;
  }

  /** Path of one session document. */
  static fileOf(id: string): string {
    return join(SessionStore.dir(), `${id}.json`);
  }

  /** Path of the index document. */
  private static indexPath(): string {
    return join(SessionStore.dir(), SESSION_INDEX_FILE);
  }

  /** Create a blank session with the given model settings. */
  static create(modelId: string, effort: string): ChatSession {
    const now: number = Date.now();
    const session: ChatSession = {
      id: newId('s'),
      title: '',
      createdAt: now,
      updatedAt: now,
      messages: [],
      modelId: modelId,
      effort: effort,
      todos: [],
      preview: ''
    };
    return session;
  }

  /** Fill in fields missing from an older or partially written document. */
  private static normalize(raw: ChatSession): ChatSession {
    const messages: Array<ChatMessage> = raw.messages === undefined || raw.messages === null ? [] : raw.messages;
    const todos = raw.todos === undefined || raw.todos === null ? [] : raw.todos;
    const session: ChatSession = {
      id: raw.id === undefined ? newId('s') : raw.id,
      title: raw.title === undefined ? '' : raw.title,
      createdAt: raw.createdAt === undefined ? Date.now() : raw.createdAt,
      updatedAt: raw.updatedAt === undefined ? Date.now() : raw.updatedAt,
      messages: messages,
      modelId: raw.modelId === undefined ? '' : raw.modelId,
      effort: raw.effort === undefined ? '' : raw.effort,
      todos: todos,
      preview: raw.preview === undefined ? previewOf(messages) : raw.preview
    };
    if (raw.goal !== undefined && raw.goal !== null) {
      session.goal = raw.goal;
    }
    return session;
  }

  /** Load one session, or `undefined` when the document is missing or unreadable. */
  static load(id: string): ChatSession | undefined {
    const raw: string = readText(SessionStore.fileOf(id));
    if (raw.length === 0) {
      return undefined;
    }
    try {
      const parsed: ChatSession = JSON.parse(raw) as ChatSession;
      return SessionStore.normalize(parsed);
    } catch (e) {
      log.error(`session ${id} is corrupt, ignored`);
      return undefined;
    }
  }

  /** Persist a session and refresh the index entry. */
  static save(session: ChatSession): void {
    session.updatedAt = Date.now();
    const text: string = JSON.stringify(session);
    writeAtomic(SessionStore.fileOf(session.id), text);
    const index: Array<SessionSummary> = SessionStore.list();
    const summary: SessionSummary = {
      id: session.id,
      title: session.title,
      updatedAt: session.updatedAt,
      createdAt: session.createdAt,
      messageCount: session.messages.length,
      preview: session.preview.length > 0 ? session.preview : previewOf(session.messages),
      goalPhase: session.goal === undefined ? '' : session.goal.phase
    };
    let replaced: boolean = false;
    const next: Array<SessionSummary> = [];
    for (let i = 0; i < index.length; i++) {
      if (index[i].id === summary.id) {
        next.push(summary);
        replaced = true;
      } else {
        next.push(index[i]);
      }
    }
    if (!replaced) {
      next.push(summary);
    }
    next.sort((a: SessionSummary, b: SessionSummary) => b.updatedAt - a.updatedAt);
    SessionStore.writeIndex(next);
    SessionStore.bumpRevision();
  }

  /** Remove a session document and its index entry. */
  static remove(id: string): void {
    const path: string = SessionStore.fileOf(id);
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
    const index: Array<SessionSummary> = SessionStore.list();
    const next: Array<SessionSummary> = index.filter((row: SessionSummary) => row.id !== id);
    SessionStore.writeIndex(next);
    SessionStore.bumpRevision();
  }

  private static writeIndex(rows: Array<SessionSummary>): void {
    SessionStore.cachedIndex = rows;
    writeAtomic(SessionStore.indexPath(), JSON.stringify(rows));
  }

  /** Notify list views that the index changed. */
  static bumpRevision(): void {
    const current: number | undefined = AppStorage.get<number>(KEY_SESSION_REVISION);
    AppStorage.setOrCreate<number>(KEY_SESSION_REVISION, current === undefined ? 1 : current + 1);
  }

  /** Session summaries, most recently updated first. */
  static list(): Array<SessionSummary> {
    const cached: Array<SessionSummary> | undefined = SessionStore.cachedIndex;
    if (cached !== undefined) {
      return cached;
    }
    const raw: string = readText(SessionStore.indexPath());
    if (raw.length > 0) {
      try {
        const rows: Array<SessionSummary> = JSON.parse(raw) as Array<SessionSummary>;
        rows.sort((a: SessionSummary, b: SessionSummary) => b.updatedAt - a.updatedAt);
        SessionStore.cachedIndex = rows;
        return rows;
      } catch (e) {
        log.warn('session index corrupt, rebuilding');
      }
    }
    const rebuilt: Array<SessionSummary> = SessionStore.rebuildIndex();
    SessionStore.writeIndex(rebuilt);
    return rebuilt;
  }

  /** Reconstruct the index by scanning the documents on disk. */
  static rebuildIndex(): Array<SessionSummary> {
    const rows: Array<SessionSummary> = [];
    const dir: string = SessionStore.dir();
    let names: Array<string> = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return rows;
    }
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!name.endsWith('.json') || name === SESSION_INDEX_FILE) {
        continue;
      }
      const id: string = name.slice(0, name.length - 5);
      const session: ChatSession | undefined = SessionStore.load(id);
      if (session === undefined) {
        continue;
      }
      const summary: SessionSummary = {
        id: session.id,
        title: session.title,
        updatedAt: session.updatedAt,
        createdAt: session.createdAt,
        messageCount: session.messages.length,
        preview: session.preview.length > 0 ? session.preview : previewOf(session.messages),
        goalPhase: session.goal === undefined ? '' : session.goal.phase
      };
      rows.push(summary);
    }
    rows.sort((a: SessionSummary, b: SessionSummary) => b.updatedAt - a.updatedAt);
    return rows;
  }

  /** Full-text search across every conversation, newest first. */
  static search(query: string): Array<SearchHit> {
    const needle: string = query.trim().toLowerCase();
    const hits: Array<SearchHit> = [];
    if (needle.length === 0) {
      return hits;
    }
    const rows: Array<SessionSummary> = SessionStore.list();
    for (let i = 0; i < rows.length; i++) {
      const summary: SessionSummary = rows[i];
      if (summary.title.toLowerCase().indexOf(needle) >= 0) {
        hits.push({ summary: summary, snippet: summary.title });
        continue;
      }
      const session: ChatSession | undefined = SessionStore.load(summary.id);
      if (session === undefined) {
        continue;
      }
      let matched: string = '';
      for (let j = 0; j < session.messages.length; j++) {
        const message: ChatMessage = session.messages[j];
        const text: string = textOf(message);
        const at: number = text.toLowerCase().indexOf(needle);
        if (at >= 0) {
          const from: number = Math.max(0, at - 30);
          matched = `…${text.slice(from, at + needle.length + 60).trim()}…`;
          break;
        }
      }
      if (matched.length > 0) {
        hits.push({ summary: summary, snippet: matched });
      }
    }
    return hits;
  }

  /** Delete every conversation. Used by the destructive action in settings. */
  static clearAll(): void {
    const rows: Array<SessionSummary> = SessionStore.list();
    for (let i = 0; i < rows.length; i++) {
      const path: string = SessionStore.fileOf(rows[i].id);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    }
    SessionStore.writeIndex([]);
    SessionStore.bumpRevision();
  }

  /** Render the conversation as plain text, used by the share action. */
  static toPlainText(session: ChatSession): string {
    const lines: Array<string> = [];
    for (let i = 0; i < session.messages.length; i++) {
      const message: ChatMessage = session.messages[i];
      if (message.role !== ROLE_USER && message.role !== ROLE_ASSISTANT) {
        continue;
      }
      const who: string = message.role === ROLE_USER ? 'You' : 'DSH';
      let body: string = '';
      for (let j = 0; j < message.blocks.length; j++) {
        const block: ContentBlock = message.blocks[j];
        if (block.kind === BLOCK_TEXT && block.text !== undefined) {
          body += block.text;
        } else if (block.kind === BLOCK_TOOL_CALL && block.toolName !== undefined) {
          body += ` [tool: ${block.toolName}]`;
        }
      }
      if (body.trim().length > 0) {
        lines.push(`${who}: ${body}`);
        lines.push('');
      }
    }
    return lines.join('\n');
  }
}
