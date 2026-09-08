import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { conditionCandidateBase, conditionWithTokenRemoved } from './types.js';

/**
 * §6.4.5 NOT: for each `not` keyword in the condition, one candidate that
 * removes it (and exactly one following whitespace character, if present).
 */
export const NOT: Operator = {
  name: 'NOT',
  kind: 'condition',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const cond = target as Condition;
    const candidates: MutantCandidate[] = [];

    for (let i = cond.startIdx; i <= cond.endIdx; i++) {
      const tok = ctx.tokens[i]!;
      if (tok.kind !== 'keyword' || tok.text.toLowerCase() !== 'not') continue;

      const mutated = conditionWithTokenRemoved(ctx, cond, i);
      candidates.push(conditionCandidateBase(ctx, cond, 'NOT', mutated));
    }

    return candidates;
  },
};
