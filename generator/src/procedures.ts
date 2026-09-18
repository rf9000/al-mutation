import type { ObjectHeader, ProcedureSpan, Token } from './types.js';

function isSignificant(token: Token): boolean {
  return token.kind !== 'comment' && token.kind !== 'preprocessor';
}

function isOpenBracket(token: Token): boolean {
  return token.kind === 'punct' && (token.text === '(' || token.text === '[');
}

function isCloseBracket(token: Token): boolean {
  return token.kind === 'punct' && (token.text === ')' || token.text === ']');
}

function isKeyword(token: Token, lower: string): boolean {
  return token.kind === 'keyword' && token.text.toLowerCase() === lower;
}

/**
 * §6.4.2: the object header is the file's first three significant tokens:
 * a type-like identifier (`codeunit`), a `number` object id, and a
 * `quotedIdentifier`/`identifier` object name.
 */
export function findObjectHeader(tokens: readonly Token[]): ObjectHeader | null {
  const significant = tokens.filter(isSignificant);
  if (significant.length < 3) return null;

  const typeToken = significant[0]!;
  const idToken = significant[1]!;
  const nameToken = significant[2]!;

  if (typeToken.kind !== 'identifier' && typeToken.kind !== 'keyword') return null;
  if (idToken.kind !== 'number') return null;
  if (nameToken.kind !== 'quotedIdentifier' && nameToken.kind !== 'identifier') return null;

  const objectId = Number.parseInt(idToken.text, 10);
  if (!Number.isFinite(objectId)) return null;

  const objectName =
    nameToken.kind === 'quotedIdentifier' ? nameToken.text.slice(1, -1) : nameToken.text;

  return { objectType: typeToken.text, objectId, objectName };
}

/**
 * §6.4.2: scans for `procedure`/`trigger` keywords at brace-depth 1 of the
 * object body (`{ … }`; braces are only used for object bodies and property
 * blocks). For each, the header runs to the first `var`/`begin` keyword
 * outside parentheses/brackets, and the body runs from that `begin` to the
 * `end` that returns the begin/case nesting depth to 0. The object-level
 * `var` section (not preceded by `procedure`/`trigger`) is never a span.
 */
export function findProcedures(tokens: readonly Token[]): ProcedureSpan[] {
  const spans: ProcedureSpan[] = [];
  let braceDepth = 0;

  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i]!;

    if (tok.kind === 'punct' && tok.text === '{') {
      braceDepth++;
      continue;
    }
    if (tok.kind === 'punct' && tok.text === '}') {
      braceDepth--;
      continue;
    }

    if (braceDepth !== 1) continue;
    if (!(isKeyword(tok, 'procedure') || isKeyword(tok, 'trigger'))) continue;

    const headerStart = i;
    const kind: 'procedure' | 'trigger' = tok.text.toLowerCase() === 'procedure' ? 'procedure' : 'trigger';
    const name = tokens[i + 1] ? tokens[i + 1]!.text : '';

    // Header: scan forward (tracking paren/bracket depth) to the first
    // `var` or `begin` keyword outside parentheses/brackets.
    let parenDepth = 0;
    let varKeywordIdx: number | null = null;
    let beginIdx = -1;
    let k = i + 2;
    while (k < tokens.length) {
      const t = tokens[k]!;
      if (isOpenBracket(t)) parenDepth++;
      else if (isCloseBracket(t)) parenDepth--;
      else if (parenDepth === 0 && isKeyword(t, 'var')) {
        varKeywordIdx = k;
        break;
      } else if (parenDepth === 0 && isKeyword(t, 'begin')) {
        beginIdx = k;
        break;
      }
      k++;
    }

    if (varKeywordIdx !== null) {
      let varDepth = 0;
      let m = varKeywordIdx + 1;
      while (m < tokens.length) {
        const t = tokens[m]!;
        if (isOpenBracket(t)) varDepth++;
        else if (isCloseBracket(t)) varDepth--;
        else if (varDepth === 0 && isKeyword(t, 'begin')) {
          beginIdx = m;
          break;
        }
        m++;
      }
    }

    // Body: depth starts at 1 for the `begin` just found; +1 on nested
    // `begin`/`case`, -1 on `end`; `endIdx` is the `end` returning depth to 0.
    let depth = 1;
    let endIdx = -1;
    let e = beginIdx + 1;
    while (e < tokens.length) {
      const t = tokens[e]!;
      if (isKeyword(t, 'begin') || isKeyword(t, 'case')) {
        depth++;
      } else if (isKeyword(t, 'end')) {
        depth--;
        if (depth === 0) {
          endIdx = e;
          break;
        }
      }
      e++;
    }

    spans.push({ name, kind, headerStart, varKeywordIdx, beginIdx, endIdx });

    // Continue scanning after this procedure's body (skip past its endIdx);
    // if no `end` was found (malformed input), continue from k+1 defensively.
    i = endIdx !== -1 ? endIdx : k;
  }

  return spans;
}
