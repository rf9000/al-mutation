import type { Operator, OperatorName } from './types.js';
import { REL } from './rel.js';
import { BOOL } from './bool.js';
import { NOT } from './not.js';
import { COND } from './cond.js';
import { DEL } from './del.js';
import { INSFLAG } from './insflag.js';
import { BREAK } from './break.js';

/** §6.4.4: the full registered operator catalog. */
export const OPERATORS: Record<OperatorName, Operator> = {
  REL,
  BOOL,
  NOT,
  COND,
  DEL,
  INSFLAG,
  BREAK,
};

/** §6.4.4, the full seven-name catalog, in generation order (§6.4.8). */
export const OPERATOR_ORDER: OperatorName[] = ['REL', 'BOOL', 'NOT', 'COND', 'DEL', 'INSFLAG', 'BREAK'];

export { REL, BOOL, NOT, COND, DEL, INSFLAG, BREAK };
export type { Operator, OperatorName, MutantCandidate, OperatorContext } from './types.js';
export { assignOccurrences } from './types.js';
