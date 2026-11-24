import type { Condition, SimpleStatement, Token } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';
import { statementCandidateBase, statementText } from './types.js';

function isSignificant(token: Token): boolean {
  return token.kind !== 'comment' && token.kind !== 'preprocessor';
}

/** The replacement for a returned literal, or null when the literal is not one RET changes. */
function replacementFor(literal: Token, negative: boolean): string | null {
  if (literal.kind === 'keyword' && !negative) {
    const lower = literal.text.toLowerCase();
    if (lower === 'true') return 'false';
    if (lower === 'false') return 'true';
    return null;
  }
  if (literal.kind === 'number') {
    return !negative && /^0+(\.0+)?$/.test(literal.text) ? '1' : '0';
  }
  if (literal.kind === 'string' && !negative) {
    return literal.text === "''" ? "'MUT'" : "''";
  }
  return null;
}

/**
 * §6.4.5 RET: `exit(<literal>)` returns a different value. The literal is the whole argument:
 * a boolean flips, a number becomes 0 (0 becomes 1, a leading `-` is dropped with it), a
 * text becomes '' ('' becomes 'MUT'). An expression or a variable is left alone: the
 * generator has no types, so it cannot pick a value of the right type.
 */
export const RET: Operator = {
  name: 'RET',
  kind: 'statement',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement): MutantCandidate[] {
    const stmt = target as SimpleStatement;
    const significant: number[] = [];
    for (let i = stmt.startIdx; i <= stmt.endIdx; i++) {
      if (isSignificant(ctx.tokens[i]!)) significant.push(i);
    }
    const tok = (n: number): Token => ctx.tokens[significant[n]!]!;

    if (significant.length !== 4 && significant.length !== 5) return [];
    if (tok(0).kind !== 'keyword' || tok(0).text.toLowerCase() !== 'exit') return [];
    if (tok(1).text !== '(' || tok(significant.length - 1).text !== ')') return [];

    const negative = significant.length === 5;
    if (negative && !(tok(2).kind === 'operator' && tok(2).text === '-')) return [];
    const literalPos = negative ? 3 : 2;
    const replacement = replacementFor(tok(literalPos), negative);
    if (replacement === null) return [];

    // Replace from the sign (if any) through the literal, keeping every other character.
    const text = statementText(ctx, stmt);
    const base = ctx.tokens[stmt.startIdx]!.start;
    const from = ctx.tokens[significant[2]!]!.start - base;
    const to = ctx.tokens[significant[literalPos]!]!.end - base;
    const mutated = text.slice(0, from) + replacement + text.slice(to);

    return [statementCandidateBase(ctx, stmt, 'RET', mutated)];
  },
};
