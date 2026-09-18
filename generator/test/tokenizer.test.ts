import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { tokenize } from '../src/tokenizer.js';
import type { Token } from '../src/types.js';

const fixturesDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../fixtures/tokenizer',
);

interface GoldenToken {
  kind: string;
  text: string;
  line: number;
  column: number;
}

function project(tokens: Token[]): GoldenToken[] {
  return tokens.map((t) => ({ kind: t.kind, text: t.text, line: t.line, column: t.column }));
}

function loadGolden(name: string): GoldenToken[] {
  const raw = readFileSync(path.join(fixturesDir, `${name}.tokens.json`), 'utf8');
  return JSON.parse(raw) as GoldenToken[];
}

function loadSource(name: string): string {
  return readFileSync(path.join(fixturesDir, `${name}.al`), 'utf8');
}

const fixtures = ['comments-and-strings', 'operators', 'preprocessor', 'filter-and-ternary'];

for (const name of fixtures) {
  test(`tokenize matches golden fixture: ${name}`, () => {
    const source = loadSource(name);
    const tokens = tokenize(source);
    const expected = loadGolden(name);
    assert.deepEqual(project(tokens), expected);
  });
}

test('start/end offsets slice back to text for every token', () => {
  for (const name of fixtures) {
    const source = loadSource(name);
    const tokens = tokenize(source);
    for (const token of tokens) {
      assert.equal(
        source.slice(token.start, token.end),
        token.text,
        `token ${JSON.stringify(token)} in fixture ${name} does not slice back to its text`,
      );
    }
  }
});

test('filter pipe "|" lexes as a standalone operator token (real-world AL, T21b)', () => {
  // e.g. `where("External Code Type" = filter("Regulatory Reporting" | "Local Instrument"))`
  const source = 'a := filter("A" | "B");';
  const tokens = tokenize(source);
  const kindsAndText = tokens.map((t) => ({ kind: t.kind, text: t.text }));
  assert.deepEqual(kindsAndText, [
    { kind: 'identifier', text: 'a' },
    { kind: 'operator', text: ':=' },
    { kind: 'identifier', text: 'filter' },
    { kind: 'punct', text: '(' },
    { kind: 'quotedIdentifier', text: '"A"' },
    { kind: 'operator', text: '|' },
    { kind: 'quotedIdentifier', text: '"B"' },
    { kind: 'punct', text: ')' },
    { kind: 'punct', text: ';' },
  ]);
});

test('ternary "?" and ":" lex as separate operator/punct tokens (real-world AL, T21b)', () => {
  // e.g. `OutputText := X.StartsWith('-') ? X.Substring(2) : '-' + X;`
  const source = "a := b ? '1' : '2';";
  const tokens = tokenize(source);
  const kindsAndText = tokens.map((t) => ({ kind: t.kind, text: t.text }));
  assert.deepEqual(kindsAndText, [
    { kind: 'identifier', text: 'a' },
    { kind: 'operator', text: ':=' },
    { kind: 'identifier', text: 'b' },
    { kind: 'operator', text: '?' },
    { kind: 'string', text: "'1'" },
    { kind: 'punct', text: ':' },
    { kind: 'string', text: "'2'" },
    { kind: 'punct', text: ';' },
  ]);
  // `?` and `:` must be two distinct tokens, not merged into one.
  const questionToken = tokens.find((t) => t.text === '?');
  const colonToken = tokens.find((t) => t.text === ':');
  assert.ok(questionToken !== undefined && colonToken !== undefined);
  assert.notEqual(questionToken!.start, colonToken!.start);
});

test('unterminated string throws with the line number', () => {
  const source = "codeunit 1 \"X\"\n{\n    procedure P()\n    begin\n        a := 'unterminated;\n    end;\n}\n";
  assert.throws(
    () => tokenize(source),
    (err: unknown) => {
      assert.ok(err instanceof Error);
      assert.match(err.message, /line 5/);
      return true;
    },
  );
});
