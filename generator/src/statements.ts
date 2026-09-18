import type { Condition, ProcedureSpan, SimpleStatement, Token } from './types.js';

function isSignificant(token: Token): boolean {
  return token.kind !== 'comment' && token.kind !== 'preprocessor';
}

function isOpenBracket(token: Token): boolean {
  return token.kind === 'punct' && (token.text === '(' || token.text === '[');
}

function isCloseBracket(token: Token): boolean {
  return token.kind === 'punct' && (token.text === ')' || token.text === ']');
}

function lowerKeyword(token: Token): string | null {
  return token.kind === 'keyword' ? token.text.toLowerCase() : null;
}

function nextSignificantIdx(tokens: readonly Token[], from: number, limit: number): number {
  let i = from;
  while (i <= limit && !isSignificant(tokens[i]!)) i++;
  return i;
}

function previousSignificant(tokens: readonly Token[], from: number): Token | undefined {
  let i = from;
  while (i >= 0) {
    const tok = tokens[i]!;
    if (isSignificant(tok)) return tok;
    i--;
  }
  return undefined;
}

/**
 * §6.4.3: statement-start indices inside a procedure body — the token after
 * `begin`, `;` (paren-depth 0), `repeat`, `then`, `else`, `do`, and after a
 * case-branch `:` (paren-depth 0, directly inside a `case … of` block; case
 * nesting is tracked so a `:` inside a nested `begin` block does not count).
 */
function findStatementStarts(tokens: readonly Token[], span: ProcedureSpan): number[] {
  const starts = new Set<number>();
  let parenDepth = 0;
  const blockStack: Array<'begin' | 'case'> = [];
  // B1 (live-AUT construct, found while verifying the real-AUT acceptance count): a ternary's
  // `?`/`:` can appear at paren-depth 0 (the brackets of its own operands balance out before the
  // `:` is reached), which is indistinguishable from a genuine case-branch-label `:` by bracket
  // depth alone. Tracked per paren-depth exactly like `looksLikeCaseLabel` below, so an unmatched
  // `?` "absorbs" the next depth-0 `:` instead of it being misread as ending a branch label (and
  // marking whatever follows -- the ternary's false branch -- as a bogus second statement start).
  //
  // Fix round 1 (review blocker): this must self-balance a `?`/`:` pair regardless of what is on
  // top of blockStack at the time -- a ternary living in an ordinary `begin` block (its normal
  // habitat) previously left its `?` uncounted against the depth-0 `:` (only consumed when
  // blockStack top was 'case'), so the credit survived past a statement that legally ends without
  // `;` (before `else`/`end`/`until`) and was later spent on a REAL case-branch label's colon in a
  // following case block, silently un-marking that branch's statement start (no skip entry, no
  // error -- the branch is just never mutated).
  const ternaryPending: number[] = [0];

  const mark = (afterIdx: number): void => {
    const idx = nextSignificantIdx(tokens, afterIdx + 1, span.endIdx);
    if (idx <= span.endIdx) starts.add(idx);
  };

  for (let i = span.beginIdx; i <= span.endIdx; i++) {
    const tok = tokens[i]!;
    if (!isSignificant(tok)) continue;

    if (tok.kind === 'punct') {
      if (isOpenBracket(tok)) {
        parenDepth++;
        ternaryPending[parenDepth] = 0;
      } else if (isCloseBracket(tok)) {
        parenDepth--;
      } else if (tok.text === ':' && parenDepth === 0) {
        // Self-balancing: a depth-0 `:` first resolves a pending ternary `?`, REGARDLESS of what
        // is on top of blockStack. A ternary normally lives in an ordinary `begin` block, not a
        // `case` block, so gating this consumption on blockStack top === 'case' (the original
        // bug) left the credit unconsumed there; it then survived past a statement that legally
        // ends without `;` (before `else`/`end`/`until`) and was spent on a LATER, genuine
        // case-branch label's colon instead, silently un-marking that branch's statement start.
        if ((ternaryPending[0] ?? 0) > 0) {
          ternaryPending[0] = ternaryPending[0]! - 1;
        } else if (blockStack[blockStack.length - 1] === 'case') {
          mark(i);
        }
      } else if (tok.text === ';' && parenDepth === 0) {
        mark(i);
      }
      continue;
    }

    if (tok.kind === 'operator' && tok.text === '?') {
      ternaryPending[parenDepth] = (ternaryPending[parenDepth] ?? 0) + 1;
      continue;
    }

    const lower = lowerKeyword(tok);
    if (lower === null) continue;

    if (lower === 'begin') {
      blockStack.push('begin');
      mark(i);
    } else if (lower === 'case') {
      blockStack.push('case');
    } else if (lower === 'end') {
      blockStack.pop();
    } else if (lower === 'repeat' || lower === 'then' || lower === 'else' || lower === 'do') {
      mark(i);
    }
  }

  return [...starts].sort((a, b) => a - b);
}

function isSimpleStatementStartToken(token: Token): boolean {
  if (token.kind === 'identifier' || token.kind === 'quotedIdentifier') return true;
  return lowerKeyword(token) === 'exit';
}

/**
 * B1 fix: a candidate statement start must be rejected when its token
 * sequence actually forms a `case` branch label rather than a statement --
 * i.e. scanning forward from `start` at paren-depth 0, a bare `:` (not `:=`,
 * not `::`) is reached before any `;`/`end`/`else`/`until`. This happens for
 * every branch label from the SECOND branch onward, because it immediately
 * follows the previous branch's `;` (a genuine statement-start trigger) --
 * see findStatementStarts. Labels covered: a plain identifier, a quoted
 * identifier, an enum-qualified value (`Rec."Date Format Type"::Day:`), and
 * a comma-separated list (`A, B:`).
 *
 * A bare `:` can also close a ternary (`cond ? a : b`, §6.4.1) rather than
 * terminate a label, so `?`/`:` pairs are tracked per paren-depth and only an
 * *unmatched* `:` counts as a label terminator (this is what keeps a real
 * statement like `ok := c ? x : Rec.Modify(true);` from being misdetected as
 * a label -- see the INSFLAG anchor fix, which relies on this statement
 * being found intact).
 */
function looksLikeCaseLabel(tokens: readonly Token[], start: number, limit: number): boolean {
  let parenDepth = 0;
  const ternaryPending: number[] = [0];

  for (let i = start; i <= limit; i++) {
    const tok = tokens[i]!;
    if (!isSignificant(tok)) continue;

    if (isOpenBracket(tok)) {
      parenDepth++;
      ternaryPending[parenDepth] = 0;
      continue;
    }
    if (isCloseBracket(tok)) {
      parenDepth--;
      continue;
    }
    if (tok.kind === 'operator' && tok.text === '?') {
      ternaryPending[parenDepth] = (ternaryPending[parenDepth] ?? 0) + 1;
      continue;
    }
    if (tok.kind === 'punct' && tok.text === ':') {
      if (parenDepth === 0) {
        if ((ternaryPending[0] ?? 0) > 0) {
          ternaryPending[0] = ternaryPending[0]! - 1;
          continue;
        }
        return true;
      }
      continue;
    }
    if (parenDepth === 0) {
      if (tok.kind === 'punct' && tok.text === ';') return false;
      const lower = lowerKeyword(tok);
      if (lower === 'end' || lower === 'else' || lower === 'until') return false;
    }
  }

  return false;
}

/**
 * §6.4.3: a simple statement starts at a statement-start position with an
 * `identifier`/`quotedIdentifier`/`exit` token (not a compound keyword such
 * as `if`/`while`/`repeat`/`case`/`for`/`foreach`/`begin`) and ends at the
 * first `;` at paren-depth 0 (`terminator: 'semicolon'`) or at `end`/`else`/
 * `until` at paren-depth 0 (`terminator: 'none'`).
 */
export function findSimpleStatements(tokens: readonly Token[], span: ProcedureSpan): SimpleStatement[] {
  const statements: SimpleStatement[] = [];

  for (const start of findStatementStarts(tokens, span)) {
    if (!isSimpleStatementStartToken(tokens[start]!)) continue;
    if (looksLikeCaseLabel(tokens, start, span.endIdx)) continue;

    let parenDepth = 0;
    let endIdx = start;
    let terminator: 'semicolon' | 'none' | null = null;

    for (let i = start; i <= span.endIdx; i++) {
      const tok = tokens[i]!;
      if (!isSignificant(tok)) continue;

      if (tok.kind === 'punct') {
        if (isOpenBracket(tok)) {
          parenDepth++;
        } else if (isCloseBracket(tok)) {
          parenDepth--;
        } else if (tok.text === ';' && parenDepth === 0) {
          terminator = 'semicolon';
          break;
        }
      } else if (parenDepth === 0) {
        const lower = lowerKeyword(tok);
        if (lower === 'end' || lower === 'else' || lower === 'until') {
          terminator = 'none';
          break;
        }
      }

      endIdx = i;
    }

    if (terminator === null) continue; // malformed/unterminated; skip defensively
    statements.push({ startIdx: start, endIdx, terminator });
  }

  return statements;
}

function scanForTerminator(
  tokens: readonly Token[],
  from: number,
  limit: number,
  isTerminator: (token: Token, parenDepth: number) => boolean,
): number {
  let parenDepth = 0;
  for (let i = from; i <= limit; i++) {
    const tok = tokens[i]!;
    if (!isSignificant(tok)) continue;

    if (isOpenBracket(tok)) parenDepth++;
    else if (isCloseBracket(tok)) parenDepth--;

    if (isTerminator(tok, parenDepth)) return i;
  }
  return -1;
}

const UNTIL_TERMINATOR_KEYWORDS = new Set(['end', 'else', 'until']);

/**
 * B3 fix: trims comment (and preprocessor) tokens off both ends of a raw
 * `[startIdx, endIdx]` condition span, so a trailing `// comment` (or a
 * leading one) can never become the condition's first/last token -- unlike
 * `findSimpleStatements`, which already excludes comments via `isSignificant`
 * in its own scan, the raw index arithmetic here (`i + 1` / `terminatorIdx -
 * 1`) does not. Returns `null` when trimming leaves no tokens (a
 * comment-only span), so the caller can skip it defensively.
 */
function trimToSignificant(
  tokens: readonly Token[],
  startIdx: number,
  endIdx: number,
): { startIdx: number; endIdx: number } | null {
  let start = startIdx;
  let end = endIdx;
  while (start <= end && !isSignificant(tokens[start]!)) start++;
  while (end >= start && !isSignificant(tokens[end]!)) end--;
  if (start > end) return null;
  return { startIdx: start, endIdx: end };
}

/**
 * §6.4.3: an `if` condition runs from just after `if` to its matching `then`
 * (paren-depth 0); an `until` condition runs from just after `until` to the
 * first `;`/`end`/`else`/`until` at paren-depth 0. `position` is
 * `statementList` when the previous significant token before `if` is
 * `begin`, `;`, or `repeat` (always `statementList` for `until`).
 */
export function findConditions(tokens: readonly Token[], span: ProcedureSpan): Condition[] {
  const conditions: Condition[] = [];

  for (let i = span.beginIdx; i <= span.endIdx; i++) {
    const tok = tokens[i]!;
    const lower = lowerKeyword(tok);
    if (lower !== 'if' && lower !== 'until') continue;

    if (lower === 'if') {
      const terminatorIdx = scanForTerminator(
        tokens,
        i + 1,
        span.endIdx,
        (t, depth) => depth === 0 && lowerKeyword(t) === 'then',
      );
      if (terminatorIdx === -1) continue; // malformed; skip defensively

      const trimmed = trimToSignificant(tokens, i + 1, terminatorIdx - 1);
      if (trimmed === null) continue; // comment-only condition; malformed, skip defensively

      const prev = previousSignificant(tokens, i - 1);
      const position: 'statementList' | 'other' =
        prev !== undefined &&
        ((prev.kind === 'punct' && prev.text === ';') ||
          lowerKeyword(prev) === 'begin' ||
          lowerKeyword(prev) === 'repeat')
          ? 'statementList'
          : 'other';

      conditions.push({
        kind: 'if',
        keywordIdx: i,
        startIdx: trimmed.startIdx,
        endIdx: trimmed.endIdx,
        terminatorIdx,
        position,
      });
      continue;
    }

    // until
    const terminatorIdx = scanForTerminator(
      tokens,
      i + 1,
      span.endIdx,
      (t, depth) =>
        depth === 0 &&
        ((t.kind === 'punct' && t.text === ';') ||
          (t.kind === 'keyword' && UNTIL_TERMINATOR_KEYWORDS.has(t.text.toLowerCase()))),
    );
    if (terminatorIdx === -1) continue; // malformed; skip defensively

    const trimmedUntil = trimToSignificant(tokens, i + 1, terminatorIdx - 1);
    if (trimmedUntil === null) continue; // comment-only condition; malformed, skip defensively

    conditions.push({
      kind: 'until',
      keywordIdx: i,
      startIdx: trimmedUntil.startIdx,
      endIdx: trimmedUntil.endIdx,
      terminatorIdx,
      position: 'statementList',
    });
  }

  return conditions;
}
