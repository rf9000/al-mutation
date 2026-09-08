import type { Operator, OperatorName } from './types.js';
import { REL } from './rel.js';
import { BOOL } from './bool.js';
import { NOT } from './not.js';
import { COND } from './cond.js';

/**
 * §6.4.4: registered operators. `Partial` because DEL/INSFLAG/BREAK (T18)
 * are not implemented yet; once they are, this becomes a full
 * `Record<OperatorName, Operator>`.
 */
export const OPERATORS: Partial<Record<OperatorName, Operator>> = {
  REL,
  BOOL,
  NOT,
  COND,
};

/** §6.4.4, the full seven-name catalog, in generation order (§6.4.8). */
export const OPERATOR_ORDER: OperatorName[] = ['REL', 'BOOL', 'NOT', 'COND', 'DEL', 'INSFLAG', 'BREAK'];

export { REL, BOOL, NOT, COND };
export type { Operator, OperatorName, MutantCandidate, OperatorContext } from './types.js';
export { assignOccurrences } from './types.js';
