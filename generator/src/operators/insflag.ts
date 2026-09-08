import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { statementCandidateBase, statementText } from './types.js';

/**
 * §6.4.5 INSFLAG, verbatim: a call to `Insert`/`Modify`/`Delete` on a
 * dotted receiver with a literal `true`/`false` argument, at the end of the
 * statement text; matched case-insensitively (method name and literal).
 */
const INSFLAG_PATTERN = /\.(?:Insert|Modify|Delete)\((true|false)\)$/i;

/**
 * §6.4.5 INSFLAG: when the statement text ends in `.Insert(<flag>)` /
 * `.Modify(<flag>)` / `.Delete(<flag>)`, one candidate with the boolean
 * literal flipped.
 */
export const INSFLAG: Operator = {
  name: 'INSFLAG',
  kind: 'statement',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const stmt = target as SimpleStatement;
    const text = statementText(ctx, stmt);
    const match = INSFLAG_PATTERN.exec(text);
    if (match === null) return [];

    const literal = match[1]!;
    const flipped = literal.toLowerCase() === 'true' ? 'false' : 'true';
    const mutated = text.slice(0, match.index) + match[0].replace(literal, flipped);

    return [statementCandidateBase(ctx, stmt, 'INSFLAG', mutated)];
  },
};
