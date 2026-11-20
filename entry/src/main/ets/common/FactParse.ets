/**
 * Parsing half of memory extraction.
 *
 * Kept free of platform imports so the logic can be exercised under plain Node: the model
 * is asked for a JSON array, but a real reply arrives wrapped in prose, fences, or an
 * apology, and everything here has to survive that without throwing.
 */

/** Clip text to a maximum length, appending an ellipsis when shortened. */
export function clipText(text: string, max: number): string {
  const flat: string = text.trim();
  if (flat.length <= max) {
    return flat;
  }
  return `${flat.slice(0, max)}…`;
}

/**
 * Extract fact strings from a model reply.
 *
 * @param raw the model's reply, possibly with markdown fences or surrounding prose
 * @param maxFacts how many facts to keep
 * @param maxChars longest accepted fact
 * @returns cleaned, de-duplicated facts; empty when nothing usable was found
 */
export function parseFacts(raw: string, maxFacts: number, maxChars: number): Array<string> {
  const facts: Array<string> = [];
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
    if (typeof value !== 'string') {
      continue;
    }
    const text: string = clipText(value as string, maxChars);
    if (text.length < 4) {
      continue;
    }
    const key: string = text.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    facts.push(text);
  }
  return facts;
}
