import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { conditionCandidateBase, conditionWithTokenReplaced } from './types.js';

/** §6.4.5 REL: each relational operator swaps to its boundary-shifted counterpart. */
const SWAP: Readonly<Record<string, string>> = {
  '>': '>=',
  '>=': '>',
  '<': '<=',
  '<=': '<',
  '=': '<>',
  '<>': '=',
};

/**
 * §6.4.5: for each `operator` token in the condition whose text is one of
 * `< <= > >= = <>`, one candidate that replaces just that token.
 */
export const REL: Operator = {
  name: 'REL',
  kind: 'condition',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const cond = target as Condition;
    const candidates: MutantCandidate[] = [];

    for (let i = cond.startIdx; i <= cond.endIdx; i++) {
      const tok = ctx.tokens[i]!;
      if (tok.kind !== 'operator') continue;
      const replacement = SWAP[tok.text];
      if (replacement === undefined) continue;

      const mutated = conditionWithTokenReplaced(ctx, cond, i, replacement);
      candidates.push(conditionCandidateBase(ctx, cond, 'REL', mutated));
    }

    return candidates;
  },
};
