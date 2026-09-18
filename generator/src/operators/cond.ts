import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { conditionCandidateBase } from './types.js';

function isSignificant(kind: string): boolean {
  return kind !== 'comment' && kind !== 'preprocessor';
}

/** True when the condition is nothing but a single `true`/`false` literal. */
function isSingleBooleanLiteral(ctx: OperatorContext, cond: Condition): boolean {
  const significant = ctx.tokens
    .slice(cond.startIdx, cond.endIdx + 1)
    .filter((t) => isSignificant(t.kind));
  if (significant.length !== 1) return false;
  const tok = significant[0]!;
  return tok.kind === 'keyword' && (tok.text.toLowerCase() === 'true' || tok.text.toLowerCase() === 'false');
}

/**
 * §6.4.5 COND: two candidates, the whole condition replaced by `true` and by
 * `false`; skipped entirely when the condition is already a single
 * `true`/`false` token (both mutations would be no-ops or trivial).
 */
export const COND: Operator = {
  name: 'COND',
  kind: 'condition',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const cond = target as Condition;
    if (isSingleBooleanLiteral(ctx, cond)) return [];

    return [
      conditionCandidateBase(ctx, cond, 'COND', 'true'),
      conditionCandidateBase(ctx, cond, 'COND', 'false'),
    ];
  },
};
