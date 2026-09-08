import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';
import { findSimpleStatements, findConditions } from '../src/statements.js';
import type { Token, ProcedureSpan } from '../src/types.js';

function textOf(tokens: Token[], startIdx: number, endIdx: number): string {
  return tokens
    .slice(startIdx, endIdx + 1)
    .map((t) => t.text)
    .join(' ');
}

function oneProcedure(source: string): { tokens: Token[]; span: ProcedureSpan } {
  const tokens = tokenize(source);
  const spans = findProcedures(tokens);
  assert.equal(spans.length, 1, 'expected exactly one procedure in test fixture source');
  return { tokens, span: spans[0]! };
}

test('findSimpleStatements: if/then/else yields two statements with terminators none and semicolon', () => {
  const source = [
    'codeunit 50202 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        if A then X.Insert() else Y.Modify();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 2);
  assert.equal(textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx), 'X . Insert ( )');
  assert.equal(statements[0]!.terminator, 'none');
  assert.equal(textOf(tokens, statements[1]!.startIdx, statements[1]!.endIdx), 'Y . Modify ( )');
  assert.equal(statements[1]!.terminator, 'semicolon');
});

test('findSimpleStatements: last statement before end without ; has terminator none', () => {
  const source = [
    'codeunit 50203 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        X.Insert()',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 1);
  assert.equal(textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx), 'X . Insert ( )');
  assert.equal(statements[0]!.terminator, 'none');
});

test('findSimpleStatements: a case branch yields a statement', () => {
  const source = [
    'codeunit 50204 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        case 1 of',
    '            1:',
    '                Z.Delete();',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 1);
  assert.equal(textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx), 'Z . Delete ( )');
  assert.equal(statements[0]!.terminator, 'semicolon');
});

test('findConditions: if preceded by begin is statementList', () => {
  const source = [
    'codeunit 50205 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        if (A > 1) and B then',
    '            X.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  assert.equal(conditions.length, 1);
  const cond = conditions[0]!;
  assert.equal(cond.kind, 'if');
  assert.equal(textOf(tokens, cond.startIdx, cond.endIdx), '( A > 1 ) and B');
  assert.equal(tokens[cond.terminatorIdx]!.text, 'then');
  assert.equal(cond.position, 'statementList');
});

test('findConditions: else if is position other', () => {
  const source = [
    'codeunit 50206 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        if A then',
    '            X.Insert()',
    '        else if C then',
    '            Y.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  assert.equal(conditions.length, 2);
  const elseIf = conditions[1]!;
  assert.equal(elseIf.kind, 'if');
  assert.equal(textOf(tokens, elseIf.startIdx, elseIf.endIdx), 'C');
  assert.equal(elseIf.position, 'other');
});

test('findConditions: until with a semicolon terminator', () => {
  const source = [
    'codeunit 50207 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        repeat',
    '            X.Insert();',
    '        until Rec.Next() = 0;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  const until = conditions.find((c) => c.kind === 'until');
  assert.ok(until);
  assert.equal(textOf(tokens, until!.startIdx, until!.endIdx), 'Rec . Next ( ) = 0');
  assert.equal(tokens[until!.terminatorIdx]!.text, ';');
  assert.equal(until!.position, 'statementList');
});

test('findConditions: until without a semicolon before end', () => {
  const source = [
    'codeunit 50208 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        repeat',
    '            X.Insert();',
    '        until Rec.Next() = 0',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  const until = conditions.find((c) => c.kind === 'until');
  assert.ok(until);
  assert.equal(textOf(tokens, until!.startIdx, until!.endIdx), 'Rec . Next ( ) = 0');
  assert.equal(tokens[until!.terminatorIdx]!.text, 'end');
  assert.equal(until!.position, 'statementList');
});

test('findConditions: while true do is not returned', () => {
  const source = [
    'codeunit 50209 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        while true do begin',
    '            X.Insert();',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);
  assert.equal(conditions.length, 0);
});

const fixturePath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../fixtures/fixture-aut/src/MUTFxOrderMgt.Codeunit.al',
);

test('fixture integration: MUTFxOrderMgt procedures, conditions and simple statements', () => {
  const source = readFileSync(fixturePath, 'utf8');
  const tokens = tokenize(source);

  const header = findObjectHeader(tokens);
  assert.deepEqual(header, {
    objectType: 'codeunit',
    objectId: 50200,
    objectName: 'MUT Fx Order Mgt',
  });

  const procedures = findProcedures(tokens);
  assert.deepEqual(
    procedures.map((p) => p.name),
    ['IsLargeOrder', 'RequiresApproval', 'PostOrder', 'CountBatches', 'FirstMultipleAbove'],
  );

  const allConditions = procedures.flatMap((span) => findConditions(tokens, span));
  const ifConditions = allConditions.filter((c) => c.kind === 'if');
  const untilConditions = allConditions.filter((c) => c.kind === 'until');

  assert.equal(ifConditions.length, 4);
  assert.ok(ifConditions.every((c) => c.position === 'statementList'));
  assert.deepEqual(
    ifConditions.map((c) => textOf(tokens, c.startIdx, c.endIdx)),
    [
      'Quantity >= 10',
      '( Amount > 1000 ) and ( not IsTrusted )',
      'FxOrder . Quantity <= 0',
      'Candidate > Threshold',
    ],
  );

  assert.equal(untilConditions.length, 1);
  assert.equal(untilConditions[0]!.position, 'statementList');
  assert.equal(textOf(tokens, untilConditions[0]!.startIdx, untilConditions[0]!.endIdx), 'Remaining <= 0');

  const allStatements = procedures.flatMap((span) => findSimpleStatements(tokens, span));
  const delTargetPattern =
    /^([A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*\.)?(Insert|Modify|Delete|DeleteAll|ModifyAll|Validate|Error|Commit|Message|exit)\s*(\(.*\))?$/i;
  const delTargets = allStatements
    .map((s) => source.slice(tokens[s.startIdx]!.start, tokens[s.endIdx]!.end))
    .filter((text) => delTargetPattern.test(text));

  assert.deepEqual(
    delTargets.sort(),
    [
      'Error(QtyErr)',
      'FxOrder.Modify(true)',
      'exit(Batches)',
      'exit(Candidate)',
      'exit(false)',
      'exit(false)',
      'exit(true)',
      'exit(true)',
    ].sort(),
  );
});
