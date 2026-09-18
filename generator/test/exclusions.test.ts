import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';
import { findConditions, findSimpleStatements } from '../src/statements.js';
import {
  isExcludedCondition,
  isExcludedFile,
  isExcludedRegion,
  isExcludedStatement,
} from '../src/exclusions.js';
import type { Condition, ProcedureSpan, SimpleStatement, Token } from '../src/types.js';

function oneProcedure(source: string): { tokens: Token[]; span: ProcedureSpan } {
  const tokens = tokenize(source);
  const spans = findProcedures(tokens);
  assert.equal(spans.length, 1, 'expected exactly one procedure in test fixture source');
  return { tokens, span: spans[0]! };
}

// ---------------------------------------------------------------------------
// isExcludedFile
// ---------------------------------------------------------------------------

test('isExcludedFile: table object is not-a-codeunit', () => {
  const source = ['table 50200 "X"', '{', '}', ''].join('\n');
  assert.equal(isExcludedFile('Table.al', source), 'not-a-codeunit');
});

test('isExcludedFile: leading comments/preprocessor are skipped before checking the first token', () => {
  const source = ['// a comment', '#if false', 'codeunit 50200 "X"', '{', '}', ''].join('\n');
  assert.equal(isExcludedFile('Codeunit.al', source), null);
});

test('isExcludedFile: path under Obsolete Objects (forward slash) is obsolete-folder', () => {
  const source = ['codeunit 50200 "X"', '{', '}', ''].join('\n');
  assert.equal(isExcludedFile('Obsolete Objects/Codeunit.al', source), 'obsolete-folder');
});

test('isExcludedFile: path under Obsolete Objects (backslash) is obsolete-folder', () => {
  const source = ['codeunit 50200 "X"', '{', '}', ''].join('\n');
  assert.equal(isExcludedFile('Obsolete Objects\\Codeunit.al', source), 'obsolete-folder');
});

test('isExcludedFile: Subtype = Test property is test-codeunit', () => {
  const source = ['codeunit 50200 "X"', '{', '    Subtype = Test;', '}', ''].join('\n');
  assert.equal(isExcludedFile('Codeunit.al', source), 'test-codeunit');
});

test('isExcludedFile: file name ending in .Test.al is test-codeunit', () => {
  const source = ['codeunit 50200 "X"', '{', '}', ''].join('\n');
  assert.equal(isExcludedFile('MyCodeunit.Test.al', source), 'test-codeunit');
});

test('isExcludedFile: obsolete-folder takes priority over test-codeunit', () => {
  const source = ['codeunit 50200 "X"', '{', '    Subtype = Test;', '}', ''].join('\n');
  assert.equal(isExcludedFile('Obsolete Objects/Codeunit.Test.al', source), 'obsolete-folder');
});

test('isExcludedFile: test-codeunit takes priority over not-a-codeunit', () => {
  const source = ['table 50200 "X"', '{', '}', ''].join('\n');
  assert.equal(isExcludedFile('MyTable.Test.al', source), 'test-codeunit');
});

test('isExcludedFile: an ordinary codeunit is not excluded', () => {
  const source = ['codeunit 50200 "X"', '{', '    procedure P()', '    begin', '    end;', '}', ''].join('\n');
  assert.equal(isExcludedFile('Codeunit.al', source), null);
});

// ---------------------------------------------------------------------------
// isExcludedRegion
// ---------------------------------------------------------------------------

test('isExcludedRegion: candidate inside #if...#endif is preprocessor-region', () => {
  const source = [
    'codeunit 50201 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '#if DEBUG',
    '        X.Insert();',
    '#endif',
    '        Y.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const insertX = tokens.findIndex((t) => t.text === 'X');
  const insertY = tokens.findIndex((t) => t.text === 'Y');
  assert.equal(isExcludedRegion(tokens, insertX, insertX), 'preprocessor-region');
  assert.equal(isExcludedRegion(tokens, insertY, insertY), null);
});

test('isExcludedRegion: nested #if closed by a single #endif is still open', () => {
  const source = [
    'codeunit 50202 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '#if A',
    '#if B',
    '#endif',
    '        X.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const insertX = tokens.findIndex((t) => t.text === 'X');
  assert.equal(isExcludedRegion(tokens, insertX, insertX), 'preprocessor-region');
});

test('isExcludedRegion: #else/#elif keep the region open', () => {
  const source = [
    'codeunit 50203 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '#if A',
    '#else',
    '        X.Insert();',
    '#endif',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const insertX = tokens.findIndex((t) => t.text === 'X');
  assert.equal(isExcludedRegion(tokens, insertX, insertX), 'preprocessor-region');
});

test('isExcludedRegion: candidate with mutation:ignore comment on same line is ignore-comment', () => {
  const source = [
    'codeunit 50204 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        X.Insert(); // mutation:ignore',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const insertX = tokens.findIndex((t) => t.text === 'X');
  assert.equal(isExcludedRegion(tokens, insertX, insertX), 'ignore-comment');
});

test('isExcludedRegion: mutation:ignore comment on a different line does not exclude', () => {
  const source = [
    'codeunit 50205 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        // mutation:ignore',
    '        X.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const insertX = tokens.findIndex((t) => t.text === 'X');
  assert.equal(isExcludedRegion(tokens, insertX, insertX), null);
});

test('isExcludedRegion: ordinary candidate with no comment or preprocessor is not excluded', () => {
  const source = [
    'codeunit 50206 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        X.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const insertX = tokens.findIndex((t) => t.text === 'X');
  assert.equal(isExcludedRegion(tokens, insertX, insertX), null);
});

// ---------------------------------------------------------------------------
// isExcludedCondition
// ---------------------------------------------------------------------------

function firstCondition(source: string, kind: 'if' | 'until'): { tokens: Token[]; cond: Condition } {
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);
  const cond = conditions.find((c) => c.kind === kind);
  assert.ok(cond, `expected an ${kind} condition in test fixture source`);
  return { tokens, cond: cond! };
}

test('isExcludedCondition: until Rec.Next() = 0 is until-next-loop', () => {
  const source = [
    'codeunit 50207 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        repeat',
    '        until Rec.Next() = 0;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, cond } = firstCondition(source, 'until');
  assert.equal(isExcludedCondition(tokens, cond), 'until-next-loop');
});

test('isExcludedCondition: until without Next(...) is not excluded', () => {
  const source = [
    'codeunit 50208 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        repeat',
    '        until A = 0;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, cond } = firstCondition(source, 'until');
  assert.equal(isExcludedCondition(tokens, cond), null);
});

test('isExcludedCondition: position other is condition-position', () => {
  const source = [
    'codeunit 50209 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        X := if A then 1 else 2;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, cond } = firstCondition(source, 'if');
  assert.equal(cond.position, 'other');
  assert.equal(isExcludedCondition(tokens, cond), 'condition-position');
});

test('isExcludedCondition: statementList if condition is not excluded', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        if A = 0 then',
    '            X.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, cond } = firstCondition(source, 'if');
  assert.equal(cond.position, 'statementList');
  assert.equal(isExcludedCondition(tokens, cond), null);
});

// ---------------------------------------------------------------------------
// isExcludedStatement
// ---------------------------------------------------------------------------

function firstStatement(source: string): { tokens: Token[]; stmt: SimpleStatement } {
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);
  assert.ok(statements.length > 0, 'expected at least one simple statement in test fixture source');
  return { tokens, stmt: statements[0]! };
}

test('isExcludedStatement: statement containing Evaluate is evaluate', () => {
  const source = [
    'codeunit 50211 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        Evaluate(X, Y);',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, stmt } = firstStatement(source);
  assert.equal(isExcludedStatement(tokens, stmt), 'evaluate');
});

test('isExcludedStatement: EVALUATE is case-insensitive', () => {
  const source = [
    'codeunit 50212 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        EVALUATE(X, Y);',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, stmt } = firstStatement(source);
  assert.equal(isExcludedStatement(tokens, stmt), 'evaluate');
});

test('isExcludedStatement: an ordinary statement is not excluded', () => {
  const source = [
    'codeunit 50213 "X"',
    '{',
    '    procedure P()',
    '    begin',
    '        X.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, stmt } = firstStatement(source);
  assert.equal(isExcludedStatement(tokens, stmt), null);
});
