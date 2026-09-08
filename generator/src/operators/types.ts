import type { Condition, ObjectHeader, ProcedureSpan, SimpleStatement, Token } from '../types.js';

/** §6.4.4: the full catalog; only REL/BOOL/NOT/COND are registered until T18. */
export type OperatorName = 'REL' | 'BOOL' | 'NOT' | 'COND' | 'DEL' | 'INSFLAG' | 'BREAK';

/** §6.4.4, verbatim. */
export interface MutantCandidate {
  id?: number; // assigned by manifest.assignIds (§6.4.8); required by schemata.rewriteFile
  operator: OperatorName;
  objectType: string;
  objectId: number;
  objectName: string;
  procedureName: string;
  line: number; // 1-based line of the first token of the original span
  target: { kind: 'condition'; cond: Condition } | { kind: 'statement'; stmt: SimpleStatement };
  original: string; // original condition or statement text (tokens joined with original spacing)
  mutated: string; // replacement text; '' for DEL
  occurrence: number; // 0-based index among candidates with the same (procedure, operator, original, mutated)
}

/**
 * §6.4.4 plus one addition beyond the spec: `source`, the original file
 * text, so operators can slice it by token offsets to build `original` and
 * `mutated` while preserving the source's exact spacing.
 */
export interface OperatorContext {
  tokens: Token[];
  span: ProcedureSpan;
  header: ObjectHeader;
  source: string;
}

/** §6.4.4, verbatim (apply's ctx type is OperatorContext, see above). */
export interface Operator {
  name: OperatorName;
  kind: 'condition' | 'statement';
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[];
}

/** The original source slice of a condition, preserving its original spacing. */
export function conditionText(ctx: OperatorContext, cond: Condition): string {
  return ctx.source.slice(ctx.tokens[cond.startIdx]!.start, ctx.tokens[cond.endIdx]!.end);
}

/**
 * The condition's source text with the token at `tokenIdx` (which must lie
 * within `cond`'s span) replaced by `replacement`; every other character,
 * including original inter-token spacing, is preserved.
 */
export function conditionWithTokenReplaced(
  ctx: OperatorContext,
  cond: Condition,
  tokenIdx: number,
  replacement: string,
): string {
  const spanStart = ctx.tokens[cond.startIdx]!.start;
  const spanEnd = ctx.tokens[cond.endIdx]!.end;
  const tok = ctx.tokens[tokenIdx]!;
  return (
    ctx.source.slice(spanStart, tok.start) + replacement + ctx.source.slice(tok.end, spanEnd)
  );
}

/**
 * The condition's source text with the token at `tokenIdx` removed, along
 * with exactly one following whitespace character if present (NOT's rule).
 */
export function conditionWithTokenRemoved(
  ctx: OperatorContext,
  cond: Condition,
  tokenIdx: number,
): string {
  const spanStart = ctx.tokens[cond.startIdx]!.start;
  const spanEnd = ctx.tokens[cond.endIdx]!.end;
  const tok = ctx.tokens[tokenIdx]!;
  const hasFollowingSpace =
    tok.end < spanEnd && /\s/.test(ctx.source.charAt(tok.end));
  const suffixStart = hasFollowingSpace ? tok.end + 1 : tok.end;
  return ctx.source.slice(spanStart, tok.start) + ctx.source.slice(suffixStart, spanEnd);
}

/**
 * Builds the fields common to every condition-operator candidate (§6.4.4).
 * `occurrence` is always 0 here — apply() cannot see sibling candidates from
 * other targets in the same procedure; assignOccurrences fills it in later.
 */
export function conditionCandidateBase(
  ctx: OperatorContext,
  cond: Condition,
  operator: OperatorName,
  mutated: string,
): MutantCandidate {
  return {
    operator,
    objectType: ctx.header.objectType,
    objectId: ctx.header.objectId,
    objectName: ctx.header.objectName,
    procedureName: ctx.span.name,
    line: ctx.tokens[cond.startIdx]!.line,
    target: { kind: 'condition', cond },
    original: conditionText(ctx, cond),
    mutated,
    occurrence: 0,
  };
}

/**
 * Given all candidates produced for one procedure, in generation order,
 * returns copies with `occurrence` filled: a 0-based index among candidates
 * sharing the same (operator, original, mutated) group key. Operators set
 * `occurrence: 0` on every candidate they emit (they apply() per target and
 * cannot see siblings); the pipeline (T21) calls this once per procedure,
 * over all of that procedure's candidates in enumeration order (§6.4.8),
 * before moving to the next procedure.
 */
export function assignOccurrences(candidates: readonly MutantCandidate[]): MutantCandidate[] {
  const counts = new Map<string, number>();
  return candidates.map((c) => {
    const key = JSON.stringify([c.operator, c.original, c.mutated]);
    const occurrence = counts.get(key) ?? 0;
    counts.set(key, occurrence + 1);
    return { ...c, occurrence };
  });
}
