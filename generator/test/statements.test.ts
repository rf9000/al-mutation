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

// --- B1: non-numeric case-branch labels must never be treated as statement starts. ---
// Every existing case-label test above uses NUMERIC labels, which
// `isSimpleStatementStartToken` already rejects (number tokens aren't
// identifier/quotedIdentifier/exit) -- that's why this bug was invisible.

test('findSimpleStatements: identifier case labels do not create bogus overlapping statements (B1)', () => {
  const source = [
    'codeunit 50904 "P5 Cu"',
    '{',
    '    procedure Route(Code: Text)',
    '    var',
    '        Rec: Record "Probe Tbl";',
    "        ALbl: Label 'A';",
    "        BLbl: Label 'B';",
    '    begin',
    '        case Code of',
    '            ALbl:',
    '                Rec.Insert(true);',
    '            BLbl:',
    '                Rec.Modify(true);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 2);
  assert.equal(textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx), 'Rec . Insert ( true )');
  assert.equal(textOf(tokens, statements[1]!.startIdx, statements[1]!.endIdx), 'Rec . Modify ( true )');
  assert.ok(statements[0]!.endIdx < statements[1]!.startIdx, 'statement spans must not overlap');
});

test('findSimpleStatements: quoted-identifier case labels do not create bogus statements (B1)', () => {
  const source = [
    'codeunit 50905 "P5b Cu"',
    '{',
    '    procedure Route(Code: Text)',
    '    var',
    '        Rec: Record "Probe Tbl";',
    '    begin',
    '        case Code of',
    '            "A Lbl":',
    '                Rec.Insert(true);',
    '            "B Lbl":',
    '                Rec.Modify(true);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 2);
  assert.equal(textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx), 'Rec . Insert ( true )');
  assert.equal(textOf(tokens, statements[1]!.startIdx, statements[1]!.endIdx), 'Rec . Modify ( true )');
  assert.ok(statements[0]!.endIdx < statements[1]!.startIdx, 'statement spans must not overlap');
});

test('findSimpleStatements: enum-qualified case labels do not create bogus statements (B1)', () => {
  const source = [
    'codeunit 50906 "P5c Cu"',
    '{',
    '    procedure Route(Rec: Record "Probe Tbl")',
    '    begin',
    '        case Rec."Date Format Type" of',
    '            Rec."Date Format Type"::Day:',
    '                Rec.Insert(true);',
    '            Rec."Date Format Type"::Month:',
    '                Rec.Modify(true);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 2);
  assert.equal(textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx), 'Rec . Insert ( true )');
  assert.equal(textOf(tokens, statements[1]!.startIdx, statements[1]!.endIdx), 'Rec . Modify ( true )');
  assert.ok(statements[0]!.endIdx < statements[1]!.startIdx, 'statement spans must not overlap');
});

test('findSimpleStatements: comma-separated case label lists do not create bogus statements (B1)', () => {
  const source = [
    'codeunit 50907 "P5d Cu"',
    '{',
    '    procedure Route(Code: Text)',
    '    var',
    '        Rec: Record "Probe Tbl";',
    "        ALbl: Label 'A';",
    "        BLbl: Label 'B';",
    "        CLbl: Label 'C';",
    '    begin',
    '        case Code of',
    '            ALbl:',
    '                Rec.Insert(true);',
    '            BLbl, CLbl:',
    '                Rec.Modify(true);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 2);
  assert.equal(textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx), 'Rec . Insert ( true )');
  assert.equal(textOf(tokens, statements[1]!.startIdx, statements[1]!.endIdx), 'Rec . Modify ( true )');
  assert.ok(statements[0]!.endIdx < statements[1]!.startIdx, 'statement spans must not overlap');
});

test('findSimpleStatements: nested case inside a branch keeps every branch label rejected at every depth (B1)', () => {
  const source = [
    'codeunit 50908 "P5e Cu"',
    '{',
    '    procedure Route(Code: Text; Code2: Text)',
    '    var',
    '        Rec: Record "Probe Tbl";',
    "        ALbl: Label 'A';",
    "        BLbl: Label 'B';",
    "        XLbl: Label 'X';",
    "        YLbl: Label 'Y';",
    '    begin',
    '        case Code of',
    '            ALbl:',
    '                begin',
    '                    case Code2 of',
    '                        XLbl:',
    '                            Rec.Insert(true);',
    '                        YLbl:',
    '                            Rec.Modify(true);',
    '                    end;',
    '                end;',
    '            BLbl:',
    '                Rec.Delete(true);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  const texts = statements.map((s) => textOf(tokens, s.startIdx, s.endIdx));
  assert.deepEqual(texts, ['Rec . Insert ( true )', 'Rec . Modify ( true )', 'Rec . Delete ( true )']);
  for (let i = 1; i < statements.length; i++) {
    assert.ok(statements[i - 1]!.endIdx < statements[i]!.startIdx, 'statement spans must not overlap');
  }
});

// --- B3: a trailing/leading comment must never become the first/last token of a condition. ---

test('findConditions: if with a trailing line comment before then excludes the comment (B3)', () => {
  const source = [
    'codeunit 50909 "P5f Cu"',
    '{',
    '    procedure P(A: Integer; B: Integer)',
    '    begin',
    '        if (A > 1) and',
    '           (B > 2) // both must hold',
    '        then',
    '            exit(true);',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  assert.equal(conditions.length, 1);
  const cond = conditions[0]!;
  assert.equal(tokens[cond.endIdx]!.kind !== 'comment', true);
  assert.equal(textOf(tokens, cond.startIdx, cond.endIdx), '( A > 1 ) and ( B > 2 )');
});

test('findConditions: if with a leading line comment after if excludes the comment (B3)', () => {
  const source = [
    'codeunit 50910 "P5g Cu"',
    '{',
    '    procedure P(A: Integer)',
    '    begin',
    '        if // leading comment',
    '           (A > 1)',
    '        then',
    '            exit(true);',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  assert.equal(conditions.length, 1);
  const cond = conditions[0]!;
  assert.equal(tokens[cond.startIdx]!.kind !== 'comment', true);
  assert.equal(textOf(tokens, cond.startIdx, cond.endIdx), '( A > 1 )');
});

test('findConditions: until with a trailing line comment excludes the comment (B3)', () => {
  const source = [
    'codeunit 50911 "P5h Cu"',
    '{',
    '    procedure P(N: Integer; A: Integer)',
    '    begin',
    '        repeat',
    '            N += 1;',
    '        until N > A // done',
    '        ;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  const until = conditions.find((c) => c.kind === 'until');
  assert.ok(until);
  assert.equal(tokens[until!.endIdx]!.kind !== 'comment', true);
  assert.equal(textOf(tokens, until!.startIdx, until!.endIdx), 'N > A');
});

test('findConditions: block comment at both ends of an if condition is excluded (B3)', () => {
  const source = [
    'codeunit 50912 "P5i Cu"',
    '{',
    '    procedure P(A: Integer)',
    '    begin',
    '        if /* lead */ (A > 1) /* trail */ then',
    '            exit(true);',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const conditions = findConditions(tokens, span);

  assert.equal(conditions.length, 1);
  const cond = conditions[0]!;
  assert.equal(tokens[cond.startIdx]!.kind !== 'comment', true);
  assert.equal(tokens[cond.endIdx]!.kind !== 'comment', true);
  assert.equal(textOf(tokens, cond.startIdx, cond.endIdx), '( A > 1 )');
});

test('findSimpleStatements: a ternary inside a case-branch statement does not create a bogus overlapping statement (B1, live-AUT construct)', () => {
  // Real construct found in out/aut-original/Templates/Codeunits/TemplateValues.Codeunit.al: a
  // `case true of` with boolean-expression branch labels (not simple identifiers), where one
  // branch's statement is an assignment whose RHS is a ternary. The ternary's own `?`/`:` are
  // balanced-bracket-neutral (the `)` before `:` returns paren-depth to 0), so the bare `:` sits
  // at paren-depth 0 with the case block on top of the block stack -- exactly the shape
  // `findStatementStarts` uses to detect a genuine case-branch label terminator. Without ternary
  // tracking in `findStatementStarts` itself (not just in the label-rejection scan), this `:` is
  // misread as ending a branch label, and the token right after it (the ternary's false branch)
  // is treated as a second, overlapping statement start.
  const source = [
    'codeunit 50913 "P5j Cu"',
    '{',
    '    procedure P(Flag: Boolean; A: Text; B: Text)',
    '    var',
    '        OutputText: Text;',
    '    begin',
    '        case true of',
    '            Flag:',
    '                OutputText := Flag ? A.Substring(1, 2) : B.Substring(1, 2);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  assert.equal(statements.length, 1);
  assert.equal(
    textOf(tokens, statements[0]!.startIdx, statements[0]!.endIdx),
    'OutputText := Flag ? A . Substring ( 1 , 2 ) : B . Substring ( 1 , 2 )',
  );
});

// --- Fix round 1 (review blocker 1): a ternary OUTSIDE a case block must not leak a stale
// "pending ?" credit into a LATER case block's genuine branch-label colon. AL statements legally
// end without `;` before `else`/`end`/`until`, so the credit survives past exactly those
// terminators; every existing ternary test put the ternary INSIDE a case branch, where the bug
// happened not to matter (the leaked credit is consumed by the branch's own colon, not a later
// one), so this shape was never exercised.

test('findSimpleStatements: a ternary outside a case block (statement ends at "else", no ";") does not swallow the next case branch\'s label (blocker 1)', () => {
  const source = [
    'codeunit 50914 "P5k Cu"',
    '{',
    '    procedure T1(b: Boolean; c: Boolean; y: Integer)',
    '    var',
    '        FxRec: Record "Probe Tbl";',
    '    begin',
    '        if b then',
    '            y := c ? 1 : 2',
    '        else',
    '            case y of',
    '                1:',
    '                    FxRec.Insert(true);',
    '                2:',
    '                    FxRec.Modify(true);',
    '            end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  const texts = statements.map((s) => textOf(tokens, s.startIdx, s.endIdx));
  assert.deepEqual(texts, [
    'y := c ? 1 : 2',
    'FxRec . Insert ( true )',
    'FxRec . Modify ( true )',
  ]);
  for (let i = 1; i < statements.length; i++) {
    assert.ok(statements[i - 1]!.endIdx < statements[i]!.startIdx, 'statement spans must not overlap');
  }
});

test('findSimpleStatements: a ternary outside a case block (statement ends at "end", no ";") does not swallow the next case branch\'s label (blocker 1)', () => {
  const source = [
    'codeunit 50915 "P5l Cu"',
    '{',
    '    procedure T2(b: Boolean; c: Boolean; y: Integer)',
    '    var',
    '        FxRec: Record "Probe Tbl";',
    '    begin',
    '        if b then',
    '            begin',
    '                y := c ? 1 : 2',
    '            end',
    '        else',
    '            case y of',
    '                1:',
    '                    FxRec.Insert(true);',
    '                2:',
    '                    FxRec.Modify(true);',
    '            end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { tokens, span } = oneProcedure(source);
  const statements = findSimpleStatements(tokens, span);

  const texts = statements.map((s) => textOf(tokens, s.startIdx, s.endIdx));
  assert.deepEqual(texts, [
    'y := c ? 1 : 2',
    'FxRec . Insert ( true )',
    'FxRec . Modify ( true )',
  ]);
  for (let i = 1; i < statements.length; i++) {
    assert.ok(statements[i - 1]!.endIdx < statements[i]!.startIdx, 'statement spans must not overlap');
  }
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
