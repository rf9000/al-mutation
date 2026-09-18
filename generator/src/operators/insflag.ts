import type { Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { statementCandidateBase, statementText } from './types.js';

/** §6.4.5 INSFLAG: `<ident>` allows a bare identifier or a quoted identifier (same as DEL's). */
const IDENT = '(?:[A-Za-z_][A-Za-z0-9_]*|"[^"]+")';

/**
 * §6.4.5 INSFLAG, verbatim: a call to `Insert`/`Modify`/`Delete` on a
 * dotted receiver with a literal `true`/`false` argument, matched
 * case-insensitively (method name and literal) against the WHOLE statement
 * text -- anchored at both ends, so this only matches a call statement, not
 * an assignment or any other statement that merely happens to end in
 * `.Insert(true)`/`.Modify(true)`/`.Delete(true)` (e.g.
 * `ok := c ? x : Rec.Modify(true)`).
 */
// `d` (hasIndices): review blocker 2 -- anchoring the pattern to the whole statement (above) made
// `match.index` always 0 and `match[0]` the WHOLE statement text, not just `.Insert(true)`. The
// old `match[0].replace(literal, flipped)` then let String.replace's plain-string search hit the
// FIRST occurrence of "true"/"false" anywhere in that whole text -- including inside the
// receiver, e.g. `Rec."true value".Insert(true)` renamed the field instead of flipping the flag.
// `indices` gives the captured literal's own [start, end] in `text`, so it is replaced at its own
// offset regardless of what else in the statement happens to read "true"/"false".
const INSFLAG_PATTERN = new RegExp(
  `^${IDENT}(?:\\.${IDENT})*\\.(?:Insert|Modify|Delete)\\((true|false)\\)$`,
  'id',
);

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
    const [literalStart, literalEnd] = match.indices![1]!;
    const mutated = text.slice(0, literalStart) + flipped + text.slice(literalEnd);

    return [statementCandidateBase(ctx, stmt, 'INSFLAG', mutated)];
  },
};
