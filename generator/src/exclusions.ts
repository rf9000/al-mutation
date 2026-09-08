import { tokenize } from './tokenizer.js';
import type { Condition, SimpleStatement, Token } from './types.js';

function isSignificant(token: Token): boolean {
  return token.kind !== 'comment' && token.kind !== 'preprocessor';
}

function lowerText(token: Token): string {
  return token.text.toLowerCase();
}

/** The directive word of a `preprocessor` token, e.g. `#if DEBUG` → `if`. */
function preprocessorDirective(token: Token): string | null {
  const match = /^#\s*([A-Za-z]+)/.exec(token.text);
  return match ? match[1]!.toLowerCase() : null;
}

const OPEN_DIRECTIVES: ReadonlySet<string> = new Set(['if', 'ifdef', 'ifndef']);

/**
 * §6.4.6: path contains a path segment `Obsolete Objects`, either `/` or
 * `\`-separated.
 */
function isUnderObsoleteFolder(relPath: string): boolean {
  return relPath.split(/[\\/]/).includes('Obsolete Objects');
}

/**
 * §6.4.6: the object has a `Subtype = Test` property. Approximated with the
 * tokenizer: adjacent significant tokens `Subtype`, `=`, `Test`
 * (case-insensitive on the identifier text).
 */
function hasTestSubtype(tokens: readonly Token[]): boolean {
  const significant = tokens.filter(isSignificant);
  for (let i = 0; i + 2 < significant.length; i++) {
    const subtypeTok = significant[i]!;
    const eqTok = significant[i + 1]!;
    const testTok = significant[i + 2]!;
    if (
      lowerText(subtypeTok) === 'subtype' &&
      eqTok.kind === 'operator' &&
      eqTok.text === '=' &&
      lowerText(testTok) === 'test'
    ) {
      return true;
    }
  }
  return false;
}

/**
 * §6.4.6 file-level exclusions, checked in order: `obsolete-folder`,
 * `test-codeunit`, `not-a-codeunit`. Never throws.
 */
export function isExcludedFile(relPath: string, source: string): string | null {
  if (isUnderObsoleteFolder(relPath)) return 'obsolete-folder';

  if (/\.test\.al$/i.test(relPath)) return 'test-codeunit';

  let tokens: Token[];
  try {
    tokens = tokenize(source);
  } catch {
    return null;
  }

  if (hasTestSubtype(tokens)) return 'test-codeunit';

  const firstSignificant = tokens.find(isSignificant);
  if (firstSignificant === undefined) return 'not-a-codeunit';
  if (firstSignificant.kind !== 'identifier' || lowerText(firstSignificant) !== 'codeunit') {
    return 'not-a-codeunit';
  }

  return null;
}

/**
 * §6.4.6 region-level exclusions for a candidate span `[startIdx, endIdx]`:
 * `preprocessor-region` when the span sits inside an unclosed `#if`/
 * `#ifdef`/`#ifndef` block (nesting tracked; `#else`/`#elif` keep the region
 * open); `ignore-comment` when a `comment` token on the same source line as
 * `tokens[startIdx]` contains `mutation:ignore` (case-insensitive). Never
 * throws.
 */
export function isExcludedRegion(tokens: readonly Token[], startIdx: number, _endIdx: number): string | null {
  let depth = 0;
  for (let i = 0; i < startIdx && i < tokens.length; i++) {
    const tok = tokens[i]!;
    if (tok.kind !== 'preprocessor') continue;
    const directive = preprocessorDirective(tok);
    if (directive === null) continue;
    if (OPEN_DIRECTIVES.has(directive)) {
      depth++;
    } else if (directive === 'endif') {
      depth = Math.max(0, depth - 1);
    }
    // `else`/`elif` leave depth unchanged: the region stays open.
  }
  if (depth > 0) return 'preprocessor-region';

  const startToken = tokens[startIdx];
  if (startToken !== undefined) {
    const onSameLine = tokens.some(
      (tok) =>
        tok.kind === 'comment' &&
        tok.line === startToken.line &&
        tok.text.toLowerCase().includes('mutation:ignore'),
    );
    if (onSameLine) return 'ignore-comment';
  }

  return null;
}

/** True when `Next` is immediately followed by `(` among the condition's tokens. */
function hasNextCall(tokens: readonly Token[], cond: Condition): boolean {
  const significant: Token[] = [];
  for (let i = cond.startIdx; i <= cond.endIdx; i++) {
    const tok = tokens[i];
    if (tok !== undefined && isSignificant(tok)) significant.push(tok);
  }
  for (let i = 0; i + 1 < significant.length; i++) {
    const tok = significant[i]!;
    const next = significant[i + 1]!;
    if (tok.kind === 'identifier' && lowerText(tok) === 'next' && next.kind === 'punct' && next.text === '(') {
      return true;
    }
  }
  return false;
}

/**
 * §6.4.6 condition-level exclusions, checked in order: `until-next-loop`
 * (an `until` condition calling an identifier `Next(...)`, which would only
 * produce infinite loops), `condition-position` (`position === 'other'`).
 * Never throws.
 */
export function isExcludedCondition(tokens: readonly Token[], cond: Condition): string | null {
  if (cond.kind === 'until' && hasNextCall(tokens, cond)) return 'until-next-loop';
  if (cond.position === 'other') return 'condition-position';
  return null;
}

/**
 * §6.4.6 statement-level exclusion: `evaluate` when any token of the
 * statement is the identifier `Evaluate` (case-insensitive). Never throws.
 */
export function isExcludedStatement(tokens: readonly Token[], stmt: SimpleStatement): string | null {
  for (let i = stmt.startIdx; i <= stmt.endIdx; i++) {
    const tok = tokens[i];
    if (tok !== undefined && tok.kind === 'identifier' && lowerText(tok) === 'evaluate') {
      return 'evaluate';
    }
  }
  return null;
}
