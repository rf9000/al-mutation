import { createHash } from 'node:crypto';
import { KEYWORDS } from './types.js';
import type { MutantCandidate } from './operators/types.js';

/** §6.4.8: a candidate with an assigned id/stableKey, plus the relative file it came from. */
export type Mutant = MutantCandidate & { id: number; stableKey: string; file: string };

/**
 * §6.4.8 `normalize`: collapses whitespace runs to one space and lower-cases
 * only tokens that are AL keywords (case-insensitive match against KEYWORDS).
 */
function normalize(text: string): string {
  const collapsed = text.replace(/\s+/g, ' ').trim();
  return collapsed.replace(/[A-Za-z_][A-Za-z0-9_]*/g, (word) =>
    KEYWORDS.has(word.toLowerCase()) ? word.toLowerCase() : word,
  );
}

/**
 * §6.4.8: `sha256(objectType|objectId|procedureName|operator|normalize(original)|
 * normalize(mutated)|occurrence).slice(0,16)`.
 */
export function stableKey(c: MutantCandidate): string {
  const parts = [
    c.objectType,
    String(c.objectId),
    c.procedureName,
    c.operator,
    normalize(c.original),
    normalize(c.mutated),
    String(c.occurrence),
  ].join('|');
  return createHash('sha256').update(parts, 'utf8').digest('hex').slice(0, 16);
}

/**
 * §6.4.8: assigns ids `1..N` in the given (already fully enumerated) order,
 * and computes each candidate's stableKey. Never mutates the input.
 */
export function assignIds(candidates: readonly (MutantCandidate & { file: string })[]): Mutant[] {
  return candidates.map((c, index) => ({ ...c, id: index + 1, stableKey: stableKey(c) }));
}

/** Mulberry32 PRNG (§6.4.8), seeded deterministically. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function next(): number {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Fisher–Yates shuffle of a copy of `items`, using `rand()` in [0,1). */
function shuffle<T>(items: readonly T[], rand: () => number): T[] {
  const result = [...items];
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    const tmp = result[i]!;
    result[i] = result[j]!;
    result[j] = tmp;
  }
  return result;
}

/**
 * §6.4.8: mulberry32-seeded Fisher–Yates shuffle, take `n`, re-sort by id.
 * `n <= 0` means "all". Never mutates the input.
 */
export function sample(mutants: readonly Mutant[], n: number, seed: number): Mutant[] {
  const count = n > 0 ? Math.min(n, mutants.length) : mutants.length;
  const shuffled = shuffle(mutants, mulberry32(seed));
  return shuffled.slice(0, count).sort((a, b) => a.id - b.id);
}
