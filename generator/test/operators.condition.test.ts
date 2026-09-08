import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';
import { findConditions } from '../src/statements.js';
import { REL } from '../src/operators/rel.js';
import { BOOL } from '../src/operators/bool.js';
import { NOT } from '../src/operators/not.js';
import { COND } from '../src/operators/cond.js';
import { assignOccurrences } from '../src/operators/types.js';
import type { MutantCandidate, OperatorContext } from '../src/operators/types.js';
import type { Condition, ObjectHeader, ProcedureSpan, Token } from '../src/types.js';

function procedureFixture(bodyLine: string): { ctx: OperatorContext; cond: Condition } {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure P()',
    '    begin',
    `        ${bodyLine}`,
    '            X.Insert();',
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
  const conditions = findConditions(tokens, span);
  assert.equal(conditions.length, 1, 'expected exactly one condition in test fixture source');
  return { ctx: { tokens, span, header: header!, source }, cond: conditions[0]! };
}

test('REL: Quantity >= 10 yields one candidate mutated Quantity > 10', () => {
  const { ctx, cond } = procedureFixture('if Quantity >= 10 then');
  const candidates = REL.apply(ctx, cond);

  assert.equal(candidates.length, 1);
  const c = candidates[0]!;
  assert.equal(c.operator, 'REL');
  assert.equal(c.original, 'Quantity >= 10');
  assert.equal(c.mutated, 'Quantity > 10');
  assert.equal(c.target.kind, 'condition');
  assert.equal(c.objectType, 'codeunit');
  assert.equal(c.objectId, 50210);
  assert.equal(c.objectName, 'X');
  assert.equal(c.procedureName, 'P');
  assert.equal(c.line, ctx.tokens[cond.startIdx]!.line);
  assert.equal(c.occurrence, 0);
});

test('REL: (A > 1) and (B <> C) yields two candidates, > and <>', () => {
  const { ctx, cond } = procedureFixture('if (A > 1) and (B <> C) then');
  const candidates = REL.apply(ctx, cond);

  assert.equal(candidates.length, 2);
  assert.deepEqual(
    candidates.map((c) => c.mutated),
    ['(A >= 1) and (B <> C)', '(A > 1) and (B = C)'],
  );
  assert.ok(candidates.every((c) => c.original === '(A > 1) and (B <> C)'));
});

test('BOOL: and swaps to or, one candidate', () => {
  const { ctx, cond } = procedureFixture('if (A > 1) and (B <> C) then');
  const candidates = BOOL.apply(ctx, cond);

  assert.equal(candidates.length, 1);
  const c = candidates[0]!;
  assert.equal(c.operator, 'BOOL');
  assert.equal(c.original, '(A > 1) and (B <> C)');
  assert.equal(c.mutated, '(A > 1) or (B <> C)');
});

test('NOT: removes not and the following space', () => {
  const { ctx, cond } = procedureFixture('if (Amount > 1000) and (not IsTrusted) then');
  const candidates = NOT.apply(ctx, cond);

  assert.equal(candidates.length, 1);
  const c = candidates[0]!;
  assert.equal(c.operator, 'NOT');
  assert.equal(c.original, '(Amount > 1000) and (not IsTrusted)');
  assert.equal(c.mutated, '(Amount > 1000) and (IsTrusted)');
});

test('COND: yields two candidates, true and false', () => {
  const { ctx, cond } = procedureFixture('if Quantity >= 10 then');
  const candidates = COND.apply(ctx, cond);

  assert.equal(candidates.length, 2);
  assert.deepEqual(
    candidates.map((c) => c.mutated),
    ['true', 'false'],
  );
  assert.ok(candidates.every((c) => c.operator === 'COND'));
  assert.ok(candidates.every((c) => c.original === 'Quantity >= 10'));
});

test('COND: a condition that is a single true/false token yields zero candidates', () => {
  const { ctx, cond } = procedureFixture('if true then');
  const candidates = COND.apply(ctx, cond);
  assert.equal(candidates.length, 0);
});

test('original preserves original internal spacing', () => {
  const { ctx, cond } = procedureFixture('if Quantity   >=   10 then');
  const candidates = REL.apply(ctx, cond);
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0]!.original, 'Quantity   >=   10');
  assert.equal(candidates[0]!.mutated, 'Quantity   >   10');
});

test('assignOccurrences: increments occurrence for identical (operator, original, mutated) within a procedure', () => {
  const base: MutantCandidate = {
    operator: 'REL',
    objectType: 'codeunit',
    objectId: 1,
    objectName: 'X',
    procedureName: 'P',
    line: 1,
    target: { kind: 'condition', cond: {} as Condition },
    original: 'A > B',
    mutated: 'A >= B',
    occurrence: 0,
  };
  const other: MutantCandidate = { ...base, mutated: 'A < B' };
  const result = assignOccurrences([base, base, other, base]);

  assert.deepEqual(
    result.map((c) => c.occurrence),
    [0, 1, 0, 2],
  );
  // assignOccurrences must not mutate its input
  assert.equal(base.occurrence, 0);
});
