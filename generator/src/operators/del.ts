import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { statementCandidateBase, statementText } from './types.js';

/** §6.4.5 DEL: `<ident>` allows a bare identifier or a quoted identifier. */
const IDENT = '(?:[A-Za-z_][A-Za-z0-9_]*|"[^"]+")';

/** §6.4.5 DEL: the deletable call/exit names, matched case-insensitively. */
const METHODS = 'Insert|Modify|Delete|DeleteAll|ModifyAll|Validate|Error|Commit|Message|exit';

/**
 * §6.4.5 DEL, verbatim: an optional dotted receiver (bare or quoted
 * identifiers), one of the deletable names, and an optional `(...)` call —
 * matched against the whole statement text.
 */
const DEL_PATTERN = new RegExp(
  `^(?:${IDENT}(?:\\.${IDENT})*\\.)?(?:${METHODS})\\s*(?:\\(.*\\))?$`,
  'i',
);

/**
 * §6.4.5 DEL: a simple statement whose text matches DEL_PATTERN is deleted
 * entirely — one candidate with `mutated: ''`.
 */
export const DEL: Operator = {
  name: 'DEL',
  kind: 'statement',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const stmt = target as SimpleStatement;
    const text = statementText(ctx, stmt);
    if (!DEL_PATTERN.test(text)) return [];

    return [statementCandidateBase(ctx, stmt, 'DEL', '')];
  },
};
