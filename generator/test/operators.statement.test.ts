import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';
import { findSimpleStatements } from '../src/statements.js';
import { DEL } from '../src/operators/del.js';
import { INSFLAG } from '../src/operators/insflag.js';
import { BREAK } from '../src/operators/break.js';
import type { MutantCandidate, OperatorContext } from '../src/operators/types.js';
import type { ObjectHeader, ProcedureSpan, SimpleStatement, Token } from '../src/types.js';

/**
 * Builds a one-procedure fixture whose single statement is `bodyLine`
 * (terminated with `;`), returning the operator context and that statement.
 */
function procedureFixture(bodyLine: string): { ctx: OperatorContext; stmt: SimpleStatement } {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure P()',
    '    begin',
    `        ${bodyLine};`,
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens: Token[] = tokenize(source);
  const header: ObjectHeader | null = findObjectHeader(tokens);
  assert.ok(header, 'expected an object header in test fixture source');
  const spans: ProcedureSpan[] = findProcedures(tokens);
  assert.equal(spans.length, 1, 'expected exactly one procedure in test fixture source');
  const span = spans[0]!;
  const statements = findSimpleStatements(tokens, span);
  assert.equal(statements.length, 1, 'expected exactly one statement in test fixture source');
  return { ctx: { tokens, span, header: header!, source }, stmt: statements[0]! };
}

function assertCommonFields(c: MutantCandidate, ctx: OperatorContext, stmt: SimpleStatement): void {
  assert.equal(c.objectType, 'codeunit');
  assert.equal(c.objectId, 50210);
  assert.equal(c.objectName, 'X');
  assert.equal(c.procedureName, 'P');
  assert.equal(c.line, ctx.tokens[stmt.startIdx]!.line);
  assert.equal(c.target.kind, 'statement');
  assert.equal(c.occurrence, 0);
}

// --- DEL: positive matches ---

const DEL_MATCHES = [
  'FxOrder.Modify(true)',
  'Error(QtyErr)',
  'exit(true)',
  'exit',
  'Rec.DeleteAll()',
  'Commit()',
  'Message(Txt)',
];

for (const text of DEL_MATCHES) {
  test(`DEL: matches and deletes '${text}'`, () => {
    const { ctx, stmt } = procedureFixture(text);
    const candidates = DEL.apply(ctx, stmt);

    assert.equal(candidates.length, 1);
    const c = candidates[0]!;
    assert.equal(c.operator, 'DEL');
    assert.equal(c.original, text);
    assert.equal(c.mutated, '');
    assertCommonFields(c, ctx, stmt);
  });
}

test('DEL: case-insensitive on the method name (ERROR)', () => {
  const { ctx, stmt } = procedureFixture('ERROR(QtyErr)');
  const candidates = DEL.apply(ctx, stmt);

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0]!.mutated, '');
});

// --- DEL: negative matches ---

const DEL_NON_MATCHES = ['Candidate += Base', 'Rec.SetRange(X, Y)', 'Foo.Bar()'];

for (const text of DEL_NON_MATCHES) {
  test(`DEL: does not match '${text}'`, () => {
    const { ctx, stmt } = procedureFixture(text);
    const candidates = DEL.apply(ctx, stmt);
    assert.equal(candidates.length, 0);
  });
}

// --- INSFLAG ---

test('INSFLAG: FxOrder.Modify(true) yields FxOrder.Modify(false)', () => {
  const { ctx, stmt } = procedureFixture('FxOrder.Modify(true)');
  const candidates = INSFLAG.apply(ctx, stmt);

  assert.equal(candidates.length, 1);
  const c = candidates[0]!;
  assert.equal(c.operator, 'INSFLAG');
  assert.equal(c.original, 'FxOrder.Modify(true)');
  assert.equal(c.mutated, 'FxOrder.Modify(false)');
  assertCommonFields(c, ctx, stmt);
});

test('INSFLAG: Rec.Insert(false) yields Rec.Insert(true)', () => {
  const { ctx, stmt } = procedureFixture('Rec.Insert(false)');
  const candidates = INSFLAG.apply(ctx, stmt);

  assert.equal(candidates.length, 1);
  const c = candidates[0]!;
  assert.equal(c.original, 'Rec.Insert(false)');
  assert.equal(c.mutated, 'Rec.Insert(true)');
});

test('INSFLAG: Rec.Insert() with no argument yields no candidate', () => {
  const { ctx, stmt } = procedureFixture('Rec.Insert()');
  const candidates = INSFLAG.apply(ctx, stmt);
  assert.equal(candidates.length, 0);
});

test('INSFLAG: case-insensitive on the method and the literal (RESULT.INSERT(TRUE))', () => {
  const { ctx, stmt } = procedureFixture('Result.INSERT(TRUE)');
  const candidates = INSFLAG.apply(ctx, stmt);

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0]!.mutated, 'Result.INSERT(false)');
});

test('INSFLAG: an assignment whose RHS happens to end in .Modify(true) is NOT a candidate (unanchored-regex fix)', () => {
  // The receiver must be the WHOLE statement, not just its suffix -- otherwise the regex fires on
  // any statement/expression that happens to END with a call shaped like `.Modify(true)`, such as
  // this ternary assignment (`ok := c ? x : Rec.Modify(true)`), which is not an Insert/Modify/
  // Delete *call statement* at all.
  const { ctx, stmt } = procedureFixture('ok := c ? x : Rec.Modify(true)');
  const candidates = INSFLAG.apply(ctx, stmt);
  assert.equal(candidates.length, 0);
});

// --- BREAK ---

test('BREAK: every simple statement mutates to MutBreak_ThisDoesNotCompile()', () => {
  const { ctx, stmt } = procedureFixture('Candidate += Base');
  const candidates = BREAK.apply(ctx, stmt);

  assert.equal(candidates.length, 1);
  const c = candidates[0]!;
  assert.equal(c.operator, 'BREAK');
  assert.equal(c.original, 'Candidate += Base');
  assert.equal(c.mutated, 'MutBreak_ThisDoesNotCompile()');
  assertCommonFields(c, ctx, stmt);
});

test('BREAK: also applies to statements DEL would delete', () => {
  const { ctx, stmt } = procedureFixture('Rec.Insert()');
  const candidates = BREAK.apply(ctx, stmt);

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0]!.mutated, 'MutBreak_ThisDoesNotCompile()');
});
