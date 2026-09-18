import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { conditionCandidateBase, conditionWithTokenReplaced } from './types.js';

const SWAP: Readonly<Record<string, string>> = { and: 'or', or: 'and' };

/**
 * §6.4.5 BOOL: for each `and`/`or` keyword in the condition (matched
 * case-insensitively), one candidate that swaps it, emitting a lower-case
 * replacement regardless of the original token's casing.
 */
export const BOOL: Operator = {
  name: 'BOOL',
  kind: 'condition',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const cond = target as Condition;
    const candidates: MutantCandidate[] = [];

    for (let i = cond.startIdx; i <= cond.endIdx; i++) {
      const tok = ctx.tokens[i]!;
      if (tok.kind !== 'keyword') continue;
      const replacement = SWAP[tok.text.toLowerCase()];
      if (replacement === undefined) continue;

      const mutated = conditionWithTokenReplaced(ctx, cond, i, replacement);
      candidates.push(conditionCandidateBase(ctx, cond, 'BOOL', mutated));
    }

    return candidates;
  },
};
