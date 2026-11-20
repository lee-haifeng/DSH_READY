/**
 * Reserved embedding hook.
 *
 * The app ships no embedding model: the phone build cannot carry a quantised model file,
 * and an implementation that cannot be loaded is worse than none. What is reserved is the
 * *shape* — an interface the app already calls, a registry that is empty by default, and
 * storage that already persists vectors when they exist.
 *
 * To switch semantic recall on later, three things are needed and nothing else changes:
 *
 * 1. implement `EmbeddingProvider` (an HTTP embeddings endpoint, or a MindSpore Lite
 *    session wrapping a local model);
 * 2. call `EmbeddingRegistry.register(provider)` during startup;
 * 3. let `MemoryStore.refreshVectors()` backfill vectors for existing memories.
 *
 * From then on `MemoryStore.score()` blends cosine similarity with the lexical score, and
 * `pages/Index.ets` supplies the query vector before each turn.
 */

/** Anything that can turn text into vectors. */
export interface EmbeddingProvider {
  /** Stable identifier, used in logs and in the reserved settings entry. */
  id: string;
  /** Expected vector length, or 0 when unknown. */
  dimensions(): number;
  /**
   * Embed a batch of texts.
   *
   * @returns one vector per input, in the same order; throw or return fewer entries to
   * report failure, in which case the caller falls back to lexical recall
   */
  embed(texts: Array<string>): Promise<Array<Array<number>>>;
}

export class EmbeddingRegistry {
  private static current: EmbeddingProvider | undefined = undefined;

  /** Install the active provider. Called once during startup by whoever builds it. */
  static register(provider: EmbeddingProvider): void {
    EmbeddingRegistry.current = provider;
  }

  /** Remove the active provider, falling back to lexical recall. */
  static clear(): void {
    EmbeddingRegistry.current = undefined;
  }

  /** The active provider, or undefined when semantic recall is unavailable. */
  static provider(): EmbeddingProvider | undefined {
    return EmbeddingRegistry.current;
  }

  /** Whether semantic recall can run at all. */
  static isAvailable(): boolean {
    return EmbeddingRegistry.current !== undefined;
  }

  /**
   * Embed a batch, normalising provider failures into `undefined`.
   *
   * A provider that returns the wrong number of vectors is treated as a failure rather
   * than silently mismatching texts to vectors.
   */
  static async embedTexts(texts: Array<string>): Promise<Array<Array<number>> | undefined> {
    const provider: EmbeddingProvider | undefined = EmbeddingRegistry.current;
    if (provider === undefined || texts.length === 0) {
      return undefined;
    }
    try {
      const vectors: Array<Array<number>> = await provider.embed(texts);
      if (vectors === undefined || vectors === null || vectors.length !== texts.length) {
        return undefined;
      }
      return vectors;
    } catch (e) {
      return undefined;
    }
  }

  /** Embed a single text. */
  static async embedOne(text: string): Promise<Array<number> | undefined> {
    if (text.trim().length === 0) {
      return undefined;
    }
    const vectors: Array<Array<number>> | undefined = await EmbeddingRegistry.embedTexts([text]);
    if (vectors === undefined || vectors.length === 0) {
      return undefined;
    }
    return vectors[0];
  }
}
