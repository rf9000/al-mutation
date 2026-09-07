import { KEYWORDS } from './types.js';
import type { Token, TokenKind } from './types.js';

const TWO_CHAR_OPERATORS: readonly string[] = [
  ':=',
  '<>',
  '<=',
  '>=',
  '::',
  '..',
  '+=',
  '-=',
  '*=',
  '/=',
];

const ONE_CHAR_OPERATORS: ReadonlySet<string> = new Set(['<', '>', '=', '+', '-', '*', '/', '.']);

// `{` and `}` are only used for object bodies and property blocks (§6.4.2) and
// are emitted as `punct` tokens alongside the characters listed in §6.4.1.
const PUNCT: ReadonlySet<string> = new Set([';', ':', ',', '(', ')', '[', ']', '{', '}']);

function isIdentifierStart(ch: string): boolean {
  return /[A-Za-z_]/.test(ch);
}

function isIdentifierPart(ch: string): boolean {
  return /[A-Za-z0-9_]/.test(ch);
}

function isDigit(ch: string | undefined): boolean {
  return ch !== undefined && ch >= '0' && ch <= '9';
}

/**
 * Tokenizes AL source text per SPEC.md §6.4.1: a single left-to-right pass,
 * index-based, with longest-match-first operator scanning. Whitespace is not
 * tokenized; `start`/`end` are offsets into `source` so the text between
 * tokens (and thus the original formatting) can be reconstructed on rewrite.
 */
export function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  const length = source.length;
  let i = 0;
  let line = 1;
  let column = 1;

  const push = (
    kind: TokenKind,
    start: number,
    end: number,
    startLine: number,
    startColumn: number,
  ): void => {
    tokens.push({ kind, text: source.slice(start, end), start, end, line: startLine, column: startColumn });
  };

  const advance = (count: number): void => {
    for (let k = 0; k < count; k++) {
      if (source.charCodeAt(i) === 10 /* \n */) {
        line++;
        column = 1;
      } else {
        column++;
      }
      i++;
    }
  };

  while (i < length) {
    const ch = source[i]!;

    if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') {
      advance(1);
      continue;
    }

    const startIdx = i;
    const startLine = line;
    const startColumn = column;

    // Line comment: `//` to end of line (single token).
    if (ch === '/' && source[i + 1] === '/') {
      let j = i + 1;
      while (j < length && source[j] !== '\n') j++;
      push('comment', startIdx, j, startLine, startColumn);
      advance(j - i);
      continue;
    }

    // Block comment: `/* … */` (single token, may span lines).
    if (ch === '/' && source[i + 1] === '*') {
      let j = i + 2;
      while (j < length && !(source[j] === '*' && source[j + 1] === '/')) j++;
      const end = j < length ? j + 2 : length;
      push('comment', startIdx, end, startLine, startColumn);
      advance(end - i);
      continue;
    }

    // Preprocessor line: a line starting (after whitespace) with `#`.
    // Whitespace (including newlines) was just skipped above, so reaching
    // `#` here means it is the first non-whitespace character on its line.
    if (ch === '#') {
      let j = i + 1;
      while (j < length && source[j] !== '\n') j++;
      push('preprocessor', startIdx, j, startLine, startColumn);
      advance(j - i);
      continue;
    }

    // String literal: `'…'` with `''` as an escaped quote.
    if (ch === "'") {
      let j = i + 1;
      for (;;) {
        if (j >= length || source[j] === '\n') {
          throw new Error(`Unterminated string literal starting at line ${startLine}`);
        }
        if (source[j] === "'") {
          if (source[j + 1] === "'") {
            j += 2;
            continue;
          }
          j += 1;
          break;
        }
        j += 1;
      }
      push('string', startIdx, j, startLine, startColumn);
      advance(j - i);
      continue;
    }

    // Quoted identifier: `"…"`.
    if (ch === '"') {
      let j = i + 1;
      for (;;) {
        if (j >= length || source[j] === '\n') {
          throw new Error(`Unterminated quoted identifier starting at line ${startLine}`);
        }
        if (source[j] === '"') {
          j += 1;
          break;
        }
        j += 1;
      }
      push('quotedIdentifier', startIdx, j, startLine, startColumn);
      advance(j - i);
      continue;
    }

    // Number: digits with an optional `.` fraction.
    if (isDigit(ch)) {
      let j = i + 1;
      while (j < length && isDigit(source[j])) j++;
      if (source[j] === '.' && isDigit(source[j + 1])) {
        j++;
        while (j < length && isDigit(source[j])) j++;
      }
      push('number', startIdx, j, startLine, startColumn);
      advance(j - i);
      continue;
    }

    // Identifier / keyword.
    if (isIdentifierStart(ch)) {
      let j = i + 1;
      while (j < length && isIdentifierPart(source[j]!)) j++;
      const text = source.slice(startIdx, j);
      const kind: TokenKind = KEYWORDS.has(text.toLowerCase()) ? 'keyword' : 'identifier';
      push(kind, startIdx, j, startLine, startColumn);
      advance(j - i);
      continue;
    }

    // Operators, longest match first.
    const two = source.slice(i, i + 2);
    if (TWO_CHAR_OPERATORS.includes(two)) {
      push('operator', startIdx, i + 2, startLine, startColumn);
      advance(2);
      continue;
    }
    if (ONE_CHAR_OPERATORS.has(ch)) {
      push('operator', startIdx, i + 1, startLine, startColumn);
      advance(1);
      continue;
    }

    // Punctuation.
    if (PUNCT.has(ch)) {
      push('punct', startIdx, i + 1, startLine, startColumn);
      advance(1);
      continue;
    }

    throw new Error(`Unexpected character ${JSON.stringify(ch)} at line ${startLine}`);
  }

  return tokens;
}
