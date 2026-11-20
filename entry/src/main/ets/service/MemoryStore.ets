/**
 * Long-term memory.
 *
 * A deliberately small, curated store of facts worth remembering about the user: their
 * projects, preferences and standing instructions. It is the "semantic" tier — a few
 * dozen short lines that can be injected into every prompt for free, in contrast to the
 * conversation history, which is retrieved on demand.
 *
 * Everything stays in the app sandbox; nothing is uploaded except the handful of lines the
 * model needs for the current turn.
 */

import { Log, clip, newId } from '../common/Utils';
import { rank, relevance } from '../common/TextRank';
import { readTextFile, writeAtomic } from '../common/FileText';
import { AppContext } from './AppContext';

const log = new Log('Memory');

/** One remembered fact. */
export interface MemoryEntry {
  id: string;
  /** The fact itself, one sentence, written so it survives out of context. */
  text: string;
  createdAt: number;
  updatedAt: number;
  /** Session the fact was captured in, for provenance. */
  sourceSession: string;
  /** Pinned entries are injected regardless of the current question. */
  pinned: boolean;
}

/** Hard cap on stored entries; the oldest unpinned entries are evicted beyond it. */
const MAX_ENTRIES: number = 300;
/** Longest single fact accepted. */
const MAX_TEXT_CHARS: number = 240;
/** Entries injected per turn. */
const INJECT_ENTRIES: number = 8;
/** Character budget for the injected block. */
const INJECT_CHARS: number = 1200;

/** Normalised form used for duplicate detection. */
function normalize(text: string): string {
  return text.replace(/\s+/g, ' ').trim().toLowerCase();
}

export class MemoryStore {
  private static cached: Array<MemoryEntry> | undefined = undefined;

  /** Path of the memory document. */
  static file(): string {
    return `${AppContext.filesDir()}/memory.json`;
  }

  /** All remembered facts, oldest first. */
  static all(): Array<MemoryEntry> {
    const cached: Array<MemoryEntry> | undefined = MemoryStore.cached;
    if (cached !== undefined) {
      return cached;
    }
    const raw: string = readTextFile(MemoryStore.file());
    if (raw.length === 0) {
      MemoryStore.cached = [];
      return MemoryStore.cached;
    }
    try {
      const parsed: Array<MemoryEntry> = JSON.parse(raw) as Array<MemoryEntry>;
      const entries: Array<MemoryEntry> = [];
      for (let i = 0; i < parsed.length; i++) {
        const row: MemoryEntry = parsed[i];
        if (row === null || row === undefined || row.text === undefined) {
          continue;
        }
        entries.push({
          id: row.id === undefined ? newId('mem') : row.id,
          text: row.text,
          createdAt: row.createdAt === undefined ? Date.now() : row.createdAt,
          updatedAt: row.updatedAt === undefined ? Date.now() : row.updatedAt,
          sourceSession: row.sourceSession === undefined ? '' : row.sourceSession,
          pinned: row.pinned === true
        });
      }
      MemoryStore.cached = entries;
      return entries;
    } catch (e) {
      log.error('memory document is corrupt, starting empty');
      MemoryStore.cached = [];
      return MemoryStore.cached;
    }
  }

  private static persist(entries: Array<MemoryEntry>): void {
    MemoryStore.cached = entries;
    writeAtomic(MemoryStore.file(), JSON.stringify(entries));
  }

  /** Number of remembered facts. */
  static count(): number {
    return MemoryStore.all().length;
  }

  /**
   * Remember a fact, updating an existing near-identical entry instead of duplicating it.
   *
   * @param text the fact, in the user's own terms
   * @param sourceSession session it came from
   * @returns the stored entry, or `undefined` when the text was empty
   */
  static add(text: string, sourceSession: string): MemoryEntry | undefined {
    const clean: string = clip(text, MAX_TEXT_CHARS);
    if (clean.length === 0) {
      return undefined;
    }
    const entries: Array<MemoryEntry> = MemoryStore.all();
    const key: string = normalize(clean);
    const now: number = Date.now();
    for (let i = 0; i < entries.length; i++) {
      if (normalize(entries[i].text) === key) {
        entries[i].updatedAt = now;
        if (sourceSession.length > 0) {
          entries[i].sourceSession = sourceSession;
        }
        MemoryStore.persist(entries);
        return entries[i];
      }
    }
    const entry: MemoryEntry = {
      id: newId('mem'),
      text: clean,
      createdAt: now,
      updatedAt: now,
      sourceSession: sourceSession,
      pinned: false
    };
    entries.push(entry);
    while (entries.length > MAX_ENTRIES) {
      let victim: number = -1;
      for (let i = 0; i < entries.length; i++) {
        if (!entries[i].pinned) {
          victim = i;
          break;
        }
      }
      if (victim < 0) {
        break;
      }
      entries.splice(victim, 1);
    }
    MemoryStore.persist(entries);
    return entry;
  }

  /** Delete one entry by id. */
  static remove(id: string): boolean {
    const entries: Array<MemoryEntry> = MemoryStore.all();
    const next: Array<MemoryEntry> = [];
    let removed: boolean = false;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === id) {
        removed = true;
      } else {
        next.push(entries[i]);
      }
    }
    if (removed) {
      MemoryStore.persist(next);
    }
    return removed;
  }

  /** Pinned entries are always injected. */
  static setPinned(id: string, pinned: boolean): void {
    const entries: Array<MemoryEntry> = MemoryStore.all();
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === id) {
        entries[i].pinned = pinned;
        entries[i].updatedAt = Date.now();
        MemoryStore.persist(entries);
        return;
      }
    }
  }

  /** Drop every remembered fact. */
  static clear(): void {
    MemoryStore.persist([]);
  }

  /** Facts matching a query, best first, for the `recall` tool. */
  static search(query: string, limit: number): Array<MemoryEntry> {
    const entries: Array<MemoryEntry> = MemoryStore.all();
    const texts: Array<string> = [];
    for (let i = 0; i < entries.length; i++) {
      texts.push(entries[i].text);
    }
    const order: Array<number> = rank(query, texts, limit);
    const out: Array<MemoryEntry> = [];
    for (let i = 0; i < order.length; i++) {
      out.push(entries[order[i]]);
    }
    return out;
  }

  /**
   * Entries worth injecting for this turn: pinned first, then the most relevant ones.
   *
   * @param query the user's latest message
   * @returns entries within the per-turn character budget
   */
  static relevant(query: string): Array<MemoryEntry> {
    const entries: Array<MemoryEntry> = MemoryStore.all();
    if (entries.length === 0) {
      return [];
    }
    const picked: Array<MemoryEntry> = [];
    const seen: Set<string> = new Set();
    let budget: number = INJECT_CHARS;
    for (let i = 0; i < entries.length; i++) {
      if (!entries[i].pinned) {
        continue;
      }
      seen.add(entries[i].id);
      picked.push(entries[i]);
      budget -= entries[i].text.length;
    }
    if (query.trim().length > 0 && budget > 0) {
      const candidates: Array<MemoryEntry> = [];
      const texts: Array<string> = [];
      for (let i = 0; i < entries.length; i++) {
        if (seen.has(entries[i].id)) {
          continue;
        }
        candidates.push(entries[i]);
        texts.push(entries[i].text);
      }
      const order: Array<number> = rank(query, texts, INJECT_ENTRIES);
      for (let i = 0; i < order.length; i++) {
        if (picked.length >= INJECT_ENTRIES || budget <= 0) {
          break;
        }
        const entry: MemoryEntry = candidates[order[i]];
        if (seen.has(entry.id)) {
          continue;
        }
        seen.add(entry.id);
        picked.push(entry);
        budget -= entry.text.length;
      }
    }
    return picked;
  }

  /** Relevance of one entry, used by tests and the memory screen. */
  static score(query: string, entry: MemoryEntry): number {
    return relevance(query, entry.text);
  }
}
