/**
 * Vector maths for the reserved semantic-recall path.
 *
 * No embedding model ships with this app, so nothing here runs today. It exists so the
 * swap-in point is real code rather than prose: when a provider is registered (a local
 * MindSpore Lite model, or a remote embeddings endpoint), only `EmbeddingRegistry` needs
 * an implementation and everything below already works.
 *
 * Kept free of platform imports so it can be tested under plain Node.
 */

/** Dot product of two equal-length vectors; 0 when lengths differ. */
export function dot(a: Array<number>, b: Array<number>): number {
  if (a.length === 0 || a.length !== b.length) {
    return 0;
  }
  let sum: number = 0;
  for (let i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

/** Euclidean length of a vector. */
export function norm(a: Array<number>): number {
  let sum: number = 0;
  for (let i = 0; i < a.length; i++) {
    sum += a[i] * a[i];
  }
  return Math.sqrt(sum);
}

/**
 * Cosine similarity, mapped from [-1, 1] onto [0, 1].
 *
 * @returns 0 when either vector is empty, mismatched or zero-length
 */
export function cosine(a: Array<number>, b: Array<number>): number {
  if (a.length === 0 || a.length !== b.length) {
    return 0;
  }
  const lengthA: number = norm(a);
  const lengthB: number = norm(b);
  if (lengthA === 0 || lengthB === 0) {
    return 0;
  }
  const raw: number = dot(a, b) / (lengthA * lengthB);
  const clamped: number = raw < -1 ? -1 : raw > 1 ? 1 : raw;
  return (clamped + 1) / 2;
}

/** Scale a vector to unit length; returns it unchanged when already zero. */
export function unit(a: Array<number>): Array<number> {
  const length: number = norm(a);
  if (length === 0) {
    return a;
  }
  const out: Array<number> = [];
  for (let i = 0; i < a.length; i++) {
    out.push(a[i] / length);
  }
  return out;
}

/** Whether a value looks like a usable embedding. */
export function isVector(value: Object | undefined): boolean {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return false;
  }
  const list: Array<Object> = value as Array<Object>;
  if (list.length === 0) {
    return false;
  }
  for (let i = 0; i < list.length; i++) {
    if (typeof list[i] !== 'number') {
      return false;
    }
  }
  return true;
}

/** Convert a loose JSON array of numbers into a typed vector. */
export function toVector(value: Object | undefined): Array<number> | undefined {
  if (!isVector(value)) {
    return undefined;
  }
  const list: Array<Object> = value as Array<Object>;
  const out: Array<number> = [];
  for (let i = 0; i < list.length; i++) {
    out.push(list[i] as number);
  }
  return out;
}
