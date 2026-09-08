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
      } else if (isCloseBracket(tok)) {
        parenDepth--;
      } else if (tok.text === ':' && parenDepth === 0 && blockStack[blockStack.length - 1] === 'case') {
        mark(i);
      } else if (tok.text === ';' && parenDepth === 0) {
        mark(i);
      }
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
        startIdx: i + 1,
        endIdx: terminatorIdx - 1,
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

    conditions.push({
      kind: 'until',
      keywordIdx: i,
      startIdx: i + 1,
      endIdx: terminatorIdx - 1,
      terminatorIdx,
      position: 'statementList',
    });
  }

  return conditions;
}
