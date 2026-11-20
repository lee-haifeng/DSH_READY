/**
 * Parsing half of memory extraction.
 *
 * Kept free of platform imports so the logic can be exercised under plain Node: the model
 * is asked for a JSON array, but a real reply arrives wrapped in prose, fences, or an
 * apology, and everything here has to survive that without throwing.
 *
 * Each entry may be a bare string or an object carrying synonyms. The synonyms are what
 * let recall find "锻炼" when the user later asks about "健身" without any embedding model.
 */

/** One extracted fact plus the words that should also match it. */
export interface ParsedFact {
  text: string;
  keywords: Array<string>;
}

/** Longest accepted synonym. */
const MAX_KEYWORD_CHARS: number = 24;
/** Most synonyms kept per fact. */
const MAX_KEYWORDS: number = 4;

/** Clip text to a maximum length, appending an ellipsis when shortened. */
export function clipText(text: string, max: number): string {
  const flat: string = text.trim();
  if (flat.length <= max) {
    return flat;
  }
  return `${flat.slice(0, max)}…`;
}

/** Read a string field from a loose JSON object. */
function fieldOf(entry: Record<string, Object>, names: Array<string>): string {
  for (let i = 0; i < names.length; i++) {
    const value: Object | undefined = entry[names[i]];
    if (typeof value === 'string' && (value as string).trim().length > 0) {
      return value as string;
    }
  }
  return '';
}

/** Read and clean the synonym array of one entry. */
function keywordsOf(entry: Record<string, Object>): Array<string> {
  const raw: Object | undefined = entry['keywords'];
  const out: Array<string> = [];
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  const list: Array<Object> = raw as Array<Object>;
  const seen: Set<string> = new Set();
  for (let i = 0; i < list.length && out.length < MAX_KEYWORDS; i++) {
    if (typeof list[i] !== 'string') {
      continue;
    }
    const word: string = clipText(list[i] as string, MAX_KEYWORD_CHARS);
    if (word.length < 2) {
      continue;
    }
    const key: string = word.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(word);
  }
  return out;
}

/**
 * Extract facts from a model reply.
 *
 * Accepts both `["fact"]` and `[{"fact":"...","keywords":["..."]}]` so a model that
 * ignores the requested shape still produces usable memories.
 *
 * @param raw the model's reply, possibly with markdown fences or surrounding prose
 * @param maxFacts how many facts to keep
 * @param maxChars longest accepted fact
 * @returns cleaned, de-duplicated facts; empty when nothing usable was found
 */
export function parseFacts(raw: string, maxFacts: number, maxChars: number): Array<ParsedFact> {
  const facts: Array<ParsedFact> = [];
  const start: number = raw.indexOf('[');
  const end: number = raw.lastIndexOf(']');
  if (start < 0 || end <= start) {
    return facts;
  }
  let parsed: Array<Object> = [];
  try {
    parsed = JSON.parse(raw.slice(start, end + 1)) as Array<Object>;
  } catch (e) {
    return facts;
  }
  const seen: Set<string> = new Set();
  for (let i = 0; i < parsed.length && facts.length < maxFacts; i++) {
    const value: Object = parsed[i];
    let text: string = '';
    let keywords: Array<string> = [];
    if (typeof value === 'string') {
      text = clipText(value as string, maxChars);
    } else if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      const record: Record<string, Object> = value as Record<string, Object>;
      text = clipText(fieldOf(record, ['fact', 'text', 'content']), maxChars);
      keywords = keywordsOf(record);
    }
    if (text.length < 4) {
      continue;
    }
    const key: string = text.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    const fact: ParsedFact = { text: text, keywords: keywords };
    facts.push(fact);
  }
  return facts;
}
