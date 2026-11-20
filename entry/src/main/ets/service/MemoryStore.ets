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
import { combineScore, scoreWithKeywords } from '../common/TextRank';
import { cosine, toVector } from '../common/Vector';
import { readTextFile, writeAtomic } from '../common/FileText';
import { AppContext } from './AppContext';
import { EmbeddingRegistry } from './Embedding';

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
  /**
   * Alternative words that should also retrieve this fact.
   *
   * This is the stand-in for an embedding index: a small phone has no room for a vector
   * model, so the model that writes the memory also records the synonyms it would accept.
   */
  keywords?: Array<string>;
  /**
   * Reserved: the embedding of `text`, written only once an `EmbeddingProvider` is
   * registered. Absent means lexical recall is used for this entry.
   */
  vector?: Array<number>;
}

/** A candidate with its score, used for sorting. */
interface ScoredMemory {
  entry: MemoryEntry;
  score: number;
}

/** Hard cap on stored entries; the oldest unpinned entries are evicted beyond it. */
const MAX_ENTRIES: number = 300;
/** Longest single fact accepted. */
const MAX_TEXT_CHARS: number = 240;
/** Entries injected per turn. */
const INJECT_ENTRIES: number = 8;
/** Character budget for the injected block. */
const INJECT_CHARS: number = 1200;
/** How many memories one backfill pass embeds, to bound a single request. */
const BACKFILL_BATCH: number = 32;

/** Normalised form used for duplicate detection. */
function normalize(text: string): string {
  return text.replace(/\s+/g, ' ').trim().toLowerCase();
}

export class MemoryStore {
  private static cached: Array<MemoryEntry> | undefined = undefined;
  /**
   * Reserved: embedding of the current user message, set before a prompt is assembled.
   * Undefined while no provider is registered, which keeps the lexical path in charge.
   */
  private static pendingQueryVector: Array<number> | undefined = undefined;

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
        const entry: MemoryEntry = {
          id: row.id === undefined ? newId('mem') : row.id,
          text: row.text,
          createdAt: row.createdAt === undefined ? Date.now() : row.createdAt,
          updatedAt: row.updatedAt === undefined ? Date.now() : row.updatedAt,
          sourceSession: row.sourceSession === undefined ? '' : row.sourceSession,
          pinned: row.pinned === true
        };
        if (row.keywords !== undefined && Array.isArray(row.keywords)) {
          const words: Array<string> = [];
          const source: Array<Object> = row.keywords as Array<Object>;
          for (let j = 0; j < source.length; j++) {
            if (typeof source[j] === 'string') {
              words.push(source[j] as string);
            }
          }
          if (words.length > 0) {
            entry.keywords = words;
          }
        }
        const vector: Array<number> | undefined = toVector(row.vector);
        if (vector !== undefined) {
          entry.vector = vector;
        }
        entries.push(entry);
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
   * @param keywords synonyms that should also retrieve this fact
   * @returns the stored entry, or `undefined` when the text was empty
   */
  static add(text: string, sourceSession: string, keywords: Array<string>): MemoryEntry | undefined {
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
        if (keywords.length > 0) {
          entries[i].keywords = keywords;
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
    if (keywords.length > 0) {
      entry.keywords = keywords;
    }
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
  /**
   * How well one entry answers a query.
   *
   * Lexical tiers come from `scoreWithKeywords` (literal, synonyms, fuzzy). When an
   * embedding provider is registered and this entry has a vector, cosine similarity is
   * blended in through `combineScore`; until then the semantic term is 0 and this is
   * exactly the lexical score.
   */
  static score(query: string, entry: MemoryEntry): number {
    const keywords: Array<string> = entry.keywords === undefined ? [] : entry.keywords;
    const lexical: number = scoreWithKeywords(query, entry.text, keywords);
    const queryVector: Array<number> | undefined = MemoryStore.pendingQueryVector;
    const entryVector: Array<number> | undefined = entry.vector;
    if (queryVector === undefined || entryVector === undefined) {
      return lexical;
    }
    return combineScore(lexical, cosine(queryVector, entryVector));
  }

  /** Reserved: stash the current query embedding before building a prompt. */
  static setQueryVector(vector: Array<number> | undefined): void {
    MemoryStore.pendingQueryVector = vector;
  }

  /** Whether embedded recall is active for this turn. */
  static semanticReady(): boolean {
    return MemoryStore.pendingQueryVector !== undefined && EmbeddingRegistry.isAvailable();
  }

  /**
   * Reserved: embed memories that do not have a vector yet.
   *
   * @returns how many entries were embedded; 0 while no provider is registered
   */
  static async refreshVectors(): Promise<number> {
    const provider = EmbeddingRegistry.provider();
    if (provider === undefined) {
      return 0;
    }
    const entries: Array<MemoryEntry> = MemoryStore.all();
    const pending: Array<MemoryEntry> = [];
    for (let i = 0; i < entries.length && pending.length < BACKFILL_BATCH; i++) {
      if (entries[i].vector === undefined) {
        pending.push(entries[i]);
      }
    }
    if (pending.length === 0) {
      return 0;
    }
    const texts: Array<string> = [];
    for (let i = 0; i < pending.length; i++) {
      texts.push(pending[i].text);
    }
    const vectors: Array<Array<number>> | undefined = await EmbeddingRegistry.embedTexts(texts);
    if (vectors === undefined) {
      return 0;
    }
    let stamped: number = 0;
    for (let i = 0; i < pending.length && i < vectors.length; i++) {
      pending[i].vector = vectors[i];
      stamped++;
    }
    if (stamped > 0) {
      MemoryStore.persist(entries);
    }
    return stamped;
  }

  /** Entries matching a query, best first, for the `recall` tool. */
  static search(query: string, limit: number): Array<MemoryEntry> {
    const entries: Array<MemoryEntry> = MemoryStore.all();
    const scored: Array<ScoredMemory> = [];
    for (let i = 0; i < entries.length; i++) {
      const score: number = MemoryStore.score(query, entries[i]);
      if (score <= 0) {
        continue;
      }
      scored.push({ entry: entries[i], score: score });
    }
    scored.sort((a: ScoredMemory, b: ScoredMemory) => b.score - a.score);
    const out: Array<MemoryEntry> = [];
    for (let i = 0; i < scored.length && i < limit; i++) {
      out.push(scored[i].entry);
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
      const scored: Array<ScoredMemory> = [];
      for (let i = 0; i < entries.length; i++) {
        if (seen.has(entries[i].id)) {
          continue;
        }
        const score: number = MemoryStore.score(query, entries[i]);
        if (score <= 0) {
          continue;
        }
        scored.push({ entry: entries[i], score: score });
      }
      scored.sort((a: ScoredMemory, b: ScoredMemory) => b.score - a.score);
      for (let i = 0; i < scored.length; i++) {
        if (picked.length >= INJECT_ENTRIES || budget <= 0) {
          break;
        }
        const entry: MemoryEntry = scored[i].entry;
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
}
