/**
 * Lightweight text relevance.
 *
 * Local recall must work offline, so there is no embedding model here: Chinese has no
 * spaces, so runs of CJK characters are expanded into character bigrams, and Latin runs
 * become lowercased words. Overlap scoring over those tokens is crude compared with a
 * vector index, but for personal conversation recall ("we discussed the migration
 * project", "I told you I prefer Chinese") it is fast, dependency free and surprisingly
 * effective, and it never fails because a model file is missing.
 */

/** Whether a code unit is part of a Latin word for tokenisation purposes. */
function isWordChar(code: number): boolean {
  const isDigit: boolean = code >= 48 && code <= 57;
  const isLower: boolean = code >= 97 && code <= 122;
  const isUpper: boolean = code >= 65 && code <= 90;
  return isDigit || isLower || isUpper || code === 95;
}

/** Whether a code unit is a CJK ideograph, which gets bigram treatment. */
function isCjk(code: number): boolean {
  return (code >= 0x4E00 && code <= 0x9FFF) || (code >= 0x3400 && code <= 0x4DBF);
}

/** Push the bigrams of a CJK run; a single character stays a unigram. */
function pushCjk(tokens: Array<string>, run: string): void {
  if (run.length === 0) {
    return;
  }
  if (run.length === 1) {
    tokens.push(run);
    return;
  }
  for (let i = 0; i + 1 < run.length; i++) {
    tokens.push(run.slice(i, i + 2));
  }
}

/**
 * Split text into searchable tokens.
 *
 * @param text any user or stored text
 * @returns lowercased Latin words plus CJK character bigrams
 */
export function tokenize(text: string): Array<string> {
  const lower: string = text.toLowerCase();
  const tokens: Array<string> = [];
  let word: string = '';
  let run: string = '';
  for (let i = 0; i < lower.length; i++) {
    const code: number = lower.charCodeAt(i);
    if (isWordChar(code)) {
      if (run.length > 0) {
        pushCjk(tokens, run);
        run = '';
      }
      word += lower.charAt(i);
    } else if (isCjk(code)) {
      if (word.length > 0) {
        tokens.push(word);
        word = '';
      }
      run += lower.charAt(i);
    } else {
      if (word.length > 0) {
        tokens.push(word);
        word = '';
      }
      if (run.length > 0) {
        pushCjk(tokens, run);
        run = '';
      }
    }
  }
  if (word.length > 0) {
    tokens.push(word);
  }
  if (run.length > 0) {
    pushCjk(tokens, run);
  }
  return tokens;
}

/** Distinct tokens of a text, used as a lookup set. */
export function tokenSet(text: string): Set<string> {
  const list: Array<string> = tokenize(text);
  const set: Set<string> = new Set();
  for (let i = 0; i < list.length; i++) {
    set.add(list[i]);
  }
  return set;
}

/**
 * Score how well `text` answers `query`.
 *
 * Deliberately simple: the fraction of query tokens that appear in the text, damped by
 * text length so an essay does not beat a precise sentence. Returns 0 when nothing
 * overlaps, which callers use as the cut-off.
 *
 * @param query what the user just asked
 * @param text candidate memory or snippet
 */
export function relevance(query: string, text: string): number {
  const queryTokens: Array<string> = tokenize(query);
  if (queryTokens.length === 0) {
    return 0;
  }
  const textTokens: Set<string> = tokenSet(text);
  if (textTokens.size === 0) {
    return 0;
  }
  let hits: number = 0;
  const seen: Set<string> = new Set();
  for (let i = 0; i < queryTokens.length; i++) {
    const token: string = queryTokens[i];
    if (seen.has(token)) {
      continue;
    }
    seen.add(token);
    if (textTokens.has(token)) {
      hits++;
    }
  }
  if (hits === 0) {
    return 0;
  }
  const coverage: number = hits / seen.size;
  const damping: number = 1 + Math.log(1 + textTokens.size);
  return coverage / damping;
}

/**
 * Rank candidates by relevance to a query.
 *
 * @param query what the user just asked
 * @param candidates texts to rank, in their original order
 * @param limit maximum number of results
 * @returns indices of the best candidates, best first, omitting zero scores
 */
export function rank(query: string, candidates: Array<string>, limit: number): Array<number> {
  const scored: Array<number> = [];
  const scores: Array<number> = [];
  for (let i = 0; i < candidates.length; i++) {
    const score: number = relevance(query, candidates[i]);
    if (score <= 0) {
      continue;
    }
    let at: number = 0;
    while (at < scores.length && scores[at] >= score) {
      at++;
    }
    scores.splice(at, 0, score);
    scored.splice(at, 0, i);
  }
  return scored.slice(0, limit);
}

/** Strip everything that carries no meaning, keeping Latin words and CJK ideographs. */
function compact(text: string): string {
  const lower: string = text.toLowerCase();
  let out: string = '';
  for (let i = 0; i < lower.length; i++) {
    const code: number = lower.charCodeAt(i);
    if (isWordChar(code) || isCjk(code)) {
      out += lower.charAt(i);
    }
  }
  return out;
}

/**
 * Fuzzy matches must reach this before they count at all; below it, unrelated short
 * sentences overlap enough by accident to produce noise.
 */
export const FUZZY_FLOOR: number = 0.4;

/**
 * Score a stored fact against a query, using its synonyms when the words differ.
 *
 * Three tiers, cheapest first:
 * 1. literal token overlap with the fact text
 * 2. token overlap with the synonyms saved alongside it — this is what bridges true
 *    synonyms ("健身" vs "锻炼") without an embedding model
 * 3. fuzzy character overlap, which catches typos and reordered phrasing
 *
 * @param query the user's latest message
 * @param text the stored fact
 * @param keywords synonyms saved with the fact, possibly empty
 */
export function scoreWithKeywords(query: string, text: string, keywords: Array<string>): number {
  let best: number = relevance(query, text);
  if (keywords.length > 0) {
    let joined: string = '';
    for (let i = 0; i < keywords.length; i++) {
      joined += i === 0 ? keywords[i] : ` ${keywords[i]}`;
    }
    // A synonym hit is a deliberate match, so it outranks an incidental word hit.
    const synonymScore: number = relevance(query, joined) * 1.2;
    if (synonymScore > best) {
      best = synonymScore;
    }
  }
  if (best <= 0) {
    const fuzzy: number = similarity(query, text);
    if (fuzzy >= FUZZY_FLOOR) {
      best = fuzzy * 0.5;
    }
  }
  return best;
}

/**
 * Dice coefficient over character bigrams.
 *
 * Catches typos, inflections and reordered phrasing that exact matching misses. It cannot
 * bridge true synonyms — that is what `scoreWithKeywords` uses the synonym list for.
 *
 * @returns 0 when either side is too short or nothing overlaps
 */
export function similarity(a: string, b: string): number {
  const x: string = compact(a);
  const y: string = compact(b);
  if (x.length < 2 || y.length < 2) {
    return 0;
  }
  const bagX: Map<string, number> = new Map();
  for (let i = 0; i + 1 < x.length; i++) {
    const gram: string = x.slice(i, i + 2);
    const seen: number | undefined = bagX.get(gram);
    bagX.set(gram, seen === undefined ? 1 : seen + 1);
  }
  let overlap: number = 0;
  let total: number = 0;
  const bagY: Map<string, number> = new Map();
  for (let i = 0; i + 1 < y.length; i++) {
    const gram: string = y.slice(i, i + 2);
    const seen: number | undefined = bagY.get(gram);
    bagY.set(gram, seen === undefined ? 1 : seen + 1);
  }
  bagY.forEach((count: number, gram: string) => {
    total += count;
    const other: number | undefined = bagX.get(gram);
    if (other !== undefined) {
      overlap += Math.min(count, other);
    }
  });
  let sizeX: number = 0;
  bagX.forEach((count: number) => {
    sizeX += count;
  });
  if (sizeX + total === 0) {
    return 0;
  }
  return (2 * overlap) / (sizeX + total);
}
