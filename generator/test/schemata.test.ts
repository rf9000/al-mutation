import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';
import { findConditions, findSimpleStatements } from '../src/statements.js';
import { REL } from '../src/operators/rel.js';
import { DEL } from '../src/operators/del.js';
import { INSFLAG } from '../src/operators/insflag.js';
import { rewriteFile } from '../src/schemata.js';
import type { MutantCandidate, OperatorContext } from '../src/operators/types.js';
import type { Condition, ObjectHeader, ProcedureSpan, SimpleStatement, Token } from '../src/types.js';

/** Builds the operator context for one procedure of `source` (there must be exactly one). */
function contextFor(source: string): { ctx: OperatorContext; span: ProcedureSpan } {
  const tokens: Token[] = tokenize(source);
  const header: ObjectHeader | null = findObjectHeader(tokens);
  assert.ok(header, 'expected an object header in test fixture source');
  const spans: ProcedureSpan[] = findProcedures(tokens);
  assert.equal(spans.length, 1, 'expected exactly one procedure in test fixture source');
  const span = spans[0]!;
  return { ctx: { tokens, span, header: header!, source }, span };
}

function withId(candidate: MutantCandidate, id: number): MutantCandidate {
  return { ...candidate, id };
}

/** Asserts the output never guards `MutationCore.Active(` with `and`/`or`/`xor` (F1, §4 item 3). */
function assertNoShortCircuitGuard(output: string): void {
  assert.doesNotMatch(
    output,
    /\b(?:and|or|xor)\b\s*MutationCore\.Active\(/i,
    'MutationCore.Active( must never be preceded by and/or/xor',
  );
  assert.doesNotMatch(
    output,
    /MutationCore\.Active\([^)]*\)\s*\b(?:and|or|xor)\b/i,
    'MutationCore.Active( must never be followed by and/or/xor',
  );
}

// --- (a): one `if` condition, REL + COND×2, existing var section ---

test('(a) if condition with REL+COND×2: block before if, "if MutCond_1 then", declarations appended to existing var section', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure IsLargeOrder(Quantity: Integer): Boolean',
    '    var',
    '        Dummy: Integer;',
    '    begin',
    '        if Quantity >= 10 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [cond] = findConditions(ctx.tokens, span);
  assert.ok(cond);

  const rel = REL.apply(ctx, cond!);
  assert.equal(rel.length, 1);
  const candidates: MutantCandidate[] = [
    withId(rel[0]!, 1),
    withId({ ...rel[0]!, operator: 'COND', mutated: 'true' }, 2),
    withId({ ...rel[0]!, operator: 'COND', mutated: 'false' }, 3),
  ];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure IsLargeOrder(Quantity: Integer): Boolean',
    '    var',
    '        Dummy: Integer;',
    '        MutationCore: Codeunit "MUT Mut";',
    '        MutCond_1: Boolean;',
    '    begin',
    '        case true of',
    '            MutationCore.Active(1):',
    '                MutCond_1 := Quantity > 10;',
    '            MutationCore.Active(2):',
    '                MutCond_1 := true;',
    '            MutationCore.Active(3):',
    '                MutCond_1 := false;',
    '            else',
    '                MutCond_1 := Quantity >= 10;',
    '        end;',
    '        if MutCond_1 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

// --- (b): procedure without a var section ---

test('(b) procedure without a var section gets "    var" inserted before begin', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure IsLargeOrder(Quantity: Integer): Boolean',
    '    begin',
    '        if Quantity >= 10 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [cond] = findConditions(ctx.tokens, span);
  assert.ok(cond);

  const rel = REL.apply(ctx, cond!);
  assert.equal(rel.length, 1);
  const candidates: MutantCandidate[] = [withId(rel[0]!, 1)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure IsLargeOrder(Quantity: Integer): Boolean',
    '    var',
    '        MutationCore: Codeunit "MUT Mut";',
    '        MutCond_1: Boolean;',
    '    begin',
    '        case true of',
    '            MutationCore.Active(1):',
    '                MutCond_1 := Quantity > 10;',
    '            else',
    '                MutCond_1 := Quantity >= 10;',
    '        end;',
    '        if MutCond_1 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

// --- (c): until condition, last body statement has no trailing ';' ---

test('(c) until condition where the last body statement has no \';\' gets one inserted before the case block', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure CountBatches(Total: Integer; BatchSize: Integer): Integer',
    '    var',
    '        Remaining: Integer;',
    '        Batches: Integer;',
    '    begin',
    '        Remaining := Total;',
    '        Batches := 0;',
    '        repeat',
    '            Remaining -= BatchSize;',
    '            Batches += 1',
    '        until Remaining <= 0;',
    '        exit(Batches);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const conditions = findConditions(ctx.tokens, span);
  assert.equal(conditions.length, 1);
  const cond = conditions[0]!;
  assert.equal(cond.kind, 'until');

  const rel = REL.apply(ctx, cond);
  assert.equal(rel.length, 1);
  const candidates: MutantCandidate[] = [withId(rel[0]!, 1)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure CountBatches(Total: Integer; BatchSize: Integer): Integer',
    '    var',
    '        Remaining: Integer;',
    '        Batches: Integer;',
    '        MutationCore: Codeunit "MUT Mut";',
    '        MutCond_1: Boolean;',
    '    begin',
    '        Remaining := Total;',
    '        Batches := 0;',
    '        repeat',
    '            Remaining -= BatchSize;',
    '            Batches += 1;',
    '        case true of',
    '            MutationCore.Active(1):',
    '                MutCond_1 := Remaining < 0;',
    '            else',
    '                MutCond_1 := Remaining <= 0;',
    '        end;',
    '        until MutCond_1;',
    '        exit(Batches);',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

// --- (d): DEL on a statement in `then` position followed by `else` ---

test('(d) DEL on a then-position statement followed by else compiles structurally', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Choose(Flag: Boolean)',
    '    var',
    '        Dummy: Integer;',
    '    begin',
    '        if Flag then',
    '            Rec.Insert()',
    '        else',
    '            Dummy := 1;',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const statements: SimpleStatement[] = findSimpleStatements(ctx.tokens, span);
  const thenStmt = statements.find((s) => ctx.source.slice(ctx.tokens[s.startIdx]!.start, ctx.tokens[s.endIdx]!.end) === 'Rec.Insert()');
  assert.ok(thenStmt);

  const del = DEL.apply(ctx, thenStmt!);
  assert.equal(del.length, 1);
  const candidates: MutantCandidate[] = [withId(del[0]!, 1)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Choose(Flag: Boolean)',
    '    var',
    '        Dummy: Integer;',
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        if Flag then',
    '            case true of',
    '                MutationCore.Active(1):',
    '                    begin',
    '                    end;',
    '                else',
    '                    Rec.Insert();',
    '            end',
    '        else',
    '            Dummy := 1;',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

// --- (e): DEL + INSFLAG on the same statement ---

test('(e) DEL+INSFLAG on the same statement: one case block, two branches then else', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure PostOrder(var FxOrder: Record "MUT Fx Order")',
    '    var',
    "        QtyErr: Label 'Quantity must be positive.';",
    '    begin',
    '        FxOrder.Modify(true);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [stmt] = findSimpleStatements(ctx.tokens, span);
  assert.ok(stmt);

  const del = DEL.apply(ctx, stmt!);
  const insflag = INSFLAG.apply(ctx, stmt!);
  assert.equal(del.length, 1);
  assert.equal(insflag.length, 1);
  const candidates: MutantCandidate[] = [withId(del[0]!, 1), withId(insflag[0]!, 2)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure PostOrder(var FxOrder: Record "MUT Fx Order")',
    '    var',
    "        QtyErr: Label 'Quantity must be positive.';",
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        case true of',
    '            MutationCore.Active(1):',
    '                begin',
    '                end;',
    '            MutationCore.Active(2):',
    '                FxOrder.Modify(false);',
    '            else',
    '                FxOrder.Modify(true);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

// --- (f): statement whose terminator is 'none' because it is last before `end` ---

test("(f) statement with terminator 'none' (last before end): no ';' after our end", () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Foo(var Rec: Record "MUT Fx Order")',
    '    begin',
    '        Rec.Modify(true)',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [stmt] = findSimpleStatements(ctx.tokens, span);
  assert.ok(stmt);
  assert.equal(stmt!.terminator, 'none');

  const insflag = INSFLAG.apply(ctx, stmt!);
  assert.equal(insflag.length, 1);
  const candidates: MutantCandidate[] = [withId(insflag[0]!, 1)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Foo(var Rec: Record "MUT Fx Order")',
    '    var',
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        case true of',
    '            MutationCore.Active(1):',
    '                Rec.Modify(false);',
    '            else',
    '                Rec.Modify(true);',
    '        end',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

// --- (g): lineMap entries cover each block's start/end lines and list all ids ---

test('(g) lineMap entries cover each guard block\'s start/end lines and list all ids', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Foo(Quantity: Integer)',
    '    var',
    '        Dummy: Integer;',
    '    begin',
    '        if Quantity >= 10 then',
    '            Dummy := 1;',
    '        Rec.Insert();',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [cond] = findConditions(ctx.tokens, span);
  assert.ok(cond);
  const statements = findSimpleStatements(ctx.tokens, span);
  const insertStmt = statements.find(
    (s) => ctx.source.slice(ctx.tokens[s.startIdx]!.start, ctx.tokens[s.endIdx]!.end) === 'Rec.Insert()',
  );
  assert.ok(insertStmt);

  const rel = REL.apply(ctx, cond!);
  assert.equal(rel.length, 1);
  const del = DEL.apply(ctx, insertStmt!);
  assert.equal(del.length, 1);

  const candidates: MutantCandidate[] = [withId(rel[0]!, 1), withId(del[0]!, 2)];

  const { output, lineMap } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Foo(Quantity: Integer)',
    '    var',
    '        Dummy: Integer;',
    '        MutationCore: Codeunit "MUT Mut";',
    '        MutCond_1: Boolean;',
    '    begin',
    '        case true of',
    '            MutationCore.Active(1):',
    '                MutCond_1 := Quantity > 10;',
    '            else',
    '                MutCond_1 := Quantity >= 10;',
    '        end;',
    '        if MutCond_1 then',
    '            Dummy := 1;',
    '        case true of',
    '            MutationCore.Active(2):',
    '                begin',
    '                end;',
    '            else',
    '                Rec.Insert();',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  assert.equal(output, expected);

  // Confirm the hand-derived line numbers against the expected text itself.
  const expectedLines = expected.split('\n');
  assert.equal(expectedLines[8], '        case true of'); // line 9 (1-based)
  assert.equal(expectedLines[13], '        end;'); // line 14 (1-based)
  assert.equal(expectedLines[16], '        case true of'); // line 17 (1-based)
  assert.equal(expectedLines[22], '        end;'); // line 23 (1-based)

  assert.deepEqual(lineMap, [
    { mutantIds: [1], startLine: 9, endLine: 14 },
    { mutantIds: [2], startLine: 17, endLine: 23 },
  ]);

  assertNoShortCircuitGuard(output);
});

// --- (h): two conditions in one procedure get MutCond_1 and MutCond_2 ---

test('(h) two conditions in one procedure get MutCond_1 and MutCond_2, numbered in source order', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Foo(A: Integer; B: Integer): Boolean',
    '    var',
    '        Dummy: Integer;',
    '    begin',
    '        if A >= 10 then',
    '            exit(true);',
    '        if B >= 20 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const conditions = findConditions(ctx.tokens, span);
  assert.equal(conditions.length, 2);

  const rel1 = REL.apply(ctx, conditions[0]!);
  const rel2 = REL.apply(ctx, conditions[1]!);
  assert.equal(rel1.length, 1);
  assert.equal(rel2.length, 1);
  const candidates: MutantCandidate[] = [withId(rel1[0]!, 1), withId(rel2[0]!, 2)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Foo(A: Integer; B: Integer): Boolean',
    '    var',
    '        Dummy: Integer;',
    '        MutationCore: Codeunit "MUT Mut";',
    '        MutCond_1: Boolean;',
    '        MutCond_2: Boolean;',
    '    begin',
    '        case true of',
    '            MutationCore.Active(1):',
    '                MutCond_1 := A > 10;',
    '            else',
    '                MutCond_1 := A >= 10;',
    '        end;',
    '        if MutCond_1 then',
    '            exit(true);',
    '        case true of',
    '            MutationCore.Active(2):',
    '                MutCond_2 := B > 20;',
    '            else',
    '                MutCond_2 := B >= 20;',
    '        end;',
    '        if MutCond_2 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

// --- M8: a statement that shares its physical line with its own `if … then` ---
// (§6.4.7 requirement: indentation must be the leading whitespace of the anchor's
// physical line, never arbitrary preceding source text such as `if <cond> then `.)

test('(i) M8: "if <cond> then exit;" on one physical line, DEL on exit: guard block indented by the line\'s whitespace, "if <cond> then" prefix emitted exactly once', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Guard(Flag: Boolean)',
    '    begin',
    '        if Flag then exit;',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const statements: SimpleStatement[] = findSimpleStatements(ctx.tokens, span);
  const exitStmt = statements.find(
    (s) => ctx.source.slice(ctx.tokens[s.startIdx]!.start, ctx.tokens[s.endIdx]!.end) === 'exit',
  );
  assert.ok(exitStmt);

  const del = DEL.apply(ctx, exitStmt!);
  assert.equal(del.length, 1);
  const candidates: MutantCandidate[] = [withId(del[0]!, 1)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Guard(Flag: Boolean)',
    '    var',
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        if Flag then case true of',
    '            MutationCore.Active(1):',
    '                begin',
    '                end;',
    '            else',
    '                exit;',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected, 'the "if Flag then " prefix must be emitted exactly once, not repeated on every guard-block line');
  assertNoShortCircuitGuard(output);
});

test('(j) M8: same shared-line shape with a non-DEL statement mutant (INSFLAG)', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Guard(Flag: Boolean; var FxOrder: Record "MUT Fx Order")',
    '    var',
    '        Dummy: Integer;',
    '    begin',
    '        if Flag then FxOrder.Modify(true);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [stmt] = findSimpleStatements(ctx.tokens, span);
  assert.ok(stmt);

  const insflag = INSFLAG.apply(ctx, stmt!);
  assert.equal(insflag.length, 1);
  const candidates: MutantCandidate[] = [withId(insflag[0]!, 1)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Guard(Flag: Boolean; var FxOrder: Record "MUT Fx Order")',
    '    var',
    '        Dummy: Integer;',
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        if Flag then case true of',
    '            MutationCore.Active(1):',
    '                FxOrder.Modify(false);',
    '            else',
    '                FxOrder.Modify(true);',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected);
  assertNoShortCircuitGuard(output);
});

test('(k) M8: a statement preceded on its line by something other than "if … then" (an "else" arm)', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Guard(Flag: Boolean)',
    '    var',
    '        Dummy: Integer;',
    '    begin',
    '        if Flag then',
    '            Dummy := 1',
    '        else exit;',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const statements: SimpleStatement[] = findSimpleStatements(ctx.tokens, span);
  const exitStmt = statements.find(
    (s) => ctx.source.slice(ctx.tokens[s.startIdx]!.start, ctx.tokens[s.endIdx]!.end) === 'exit',
  );
  assert.ok(exitStmt);

  const del = DEL.apply(ctx, exitStmt!);
  assert.equal(del.length, 1);
  const candidates: MutantCandidate[] = [withId(del[0]!, 1)];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50210 "X"',
    '{',
    '    procedure Guard(Flag: Boolean)',
    '    var',
    '        Dummy: Integer;',
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        if Flag then',
    '            Dummy := 1',
    '        else case true of',
    '            MutationCore.Active(1):',
    '                begin',
    '                end;',
    '            else',
    '                exit;',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');

  assert.equal(output, expected, 'the "else " prefix must be emitted exactly once, indentation must come from the line\'s leading whitespace, not the word "else"');
  assertNoShortCircuitGuard(output);
});

// --- Additional acceptance assertions ---

test('rewriteFile throws when a candidate has no id assigned', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure IsLargeOrder(Quantity: Integer): Boolean',
    '    begin',
    '        if Quantity >= 10 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [cond] = findConditions(ctx.tokens, span);
  const rel = REL.apply(ctx, cond!);
  assert.equal(rel.length, 1);

  assert.throws(() => rewriteFile(source, [rel[0]!]), /id/);
});

test('rewriteFile is deterministic: same input twice yields identical output', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure IsLargeOrder(Quantity: Integer): Boolean',
    '    var',
    '        Dummy: Integer;',
    '    begin',
    '        if Quantity >= 10 then',
    '            exit(true);',
    '        exit(false);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [cond] = findConditions(ctx.tokens, span);
  const rel = REL.apply(ctx, cond!);
  const candidates: MutantCandidate[] = [
    withId(rel[0]!, 1),
    withId({ ...rel[0]!, operator: 'COND', mutated: 'true' }, 2),
    withId({ ...rel[0]!, operator: 'COND', mutated: 'false' }, 3),
  ];

  const first = rewriteFile(source, candidates);
  const second = rewriteFile(source, candidates);

  assert.equal(first.output, second.output);
  assert.deepEqual(first.lineMap, second.lineMap);
});

// --- B2: rewriteFile must never silently apply overlapping edits. ---

test('rewriteFile throws when two candidate spans overlap (B2 invariant)', () => {
  const source = [
    'codeunit 50210 "X"',
    '{',
    '    procedure P(A: Integer)',
    '    begin',
    '        if A > 1 then',
    '            exit(true);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const { ctx, span } = contextFor(source);
  const [cond] = findConditions(ctx.tokens, span);
  const [stmt] = findSimpleStatements(ctx.tokens, span);
  assert.ok(cond);
  assert.ok(stmt);

  const condCandidate = withId(REL.apply(ctx, cond!)[0]!, 1);
  const delCandidate = DEL.apply(ctx, stmt!)[0]!;
  assert.ok(delCandidate, 'exit(true) should match DEL');

  // Force an overlap deliberately: a statement candidate whose span starts
  // at the condition's own start offset (this is the shape B1's bug
  // produced -- a bogus "statement" span sharing tokens with another
  // candidate's span -- but constructed directly here so this test does not
  // depend on B1's fix ever regressing).
  const overlappingStmt: SimpleStatement = { ...stmt!, startIdx: cond!.startIdx };
  const overlappingCandidate = withId(
    { ...delCandidate, target: { kind: 'statement', stmt: overlappingStmt } },
    2,
  );

  assert.throws(() => rewriteFile(source, [condCandidate, overlappingCandidate]), /overlap/i);
});
