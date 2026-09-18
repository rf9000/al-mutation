import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { statementCandidateBase } from './types.js';

/**
 * §6.4.5 BREAK: every simple statement mutates to a call to an undefined
 * procedure, so the mutant fails to compile. Used to test compile-error
 * handling; only generated with `--include-break` (the pipeline's job, not
 * this operator's — it is registered in OPERATORS unconditionally).
 */
export const BREAK: Operator = {
  name: 'BREAK',
  kind: 'statement',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const stmt = target as SimpleStatement;
    return [statementCandidateBase(ctx, stmt, 'BREAK', 'MutBreak_ThisDoesNotCompile()')];
  },
};
