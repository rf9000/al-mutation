import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';
import { findBlocks, findSimpleStatements } from '../src/statements.js';
import { BLOCK } from '../src/operators/block.js';
import { DEL } from '../src/operators/del.js';
import { rewriteFile } from '../src/schemata.js';
import { isExcludedBlock } from '../src/exclusions.js';
import type { MutantCandidate, OperatorContext } from '../src/operators/types.js';
import type { Block, ObjectHeader, ProcedureSpan, Token } from '../src/types.js';

function contextFor(source: string): { ctx: OperatorContext; span: ProcedureSpan } {
  const tokens: Token[] = tokenize(source);
  const header: ObjectHeader | null = findObjectHeader(tokens);
  assert.ok(header, 'expected an object header in test fixture source');
  const spans: ProcedureSpan[] = findProcedures(tokens);
  assert.equal(spans.length, 1, 'expected exactly one procedure in test fixture source');
  const span = spans[0]!;
  return { ctx: { tokens, span, header: header!, source }, span };
}

function blockText(ctx: OperatorContext, block: Block): string {
  return ctx.source.slice(ctx.tokens[block.beginIdx]!.start, ctx.tokens[block.endIdx]!.end);
}

const NESTED = [
  'codeunit 50220 "X"',
  '{',
  '    procedure P(Flag: Boolean; Kind: Integer)',
  '    begin',
  '        if Flag then begin',
  '            case Kind of',
  '                1:',
  '                    begin',
  '                        Rec.Insert();',
  '                    end;',
  '            end;',
  '            Rec.Modify();',
  '        end else begin',
  '        end;',
  '    end;',
  '}',
  '',
].join('\n');

// --- findBlocks ---

test('findBlocks: nested begin..end blocks, not the procedure body, not an empty block', () => {
  const { ctx, span } = contextFor(NESTED);
  const blocks = findBlocks(ctx.tokens, span);

  assert.equal(blocks.length, 2);
  // Source order by `begin`; the case..end inside the first block does not end it early.
  assert.match(blockText(ctx, blocks[0]!), /^begin\s+case Kind of[\s\S]*Rec\.Modify\(\);\s+end$/);
  assert.match(blockText(ctx, blocks[1]!), /^begin\s+Rec\.Insert\(\);\s+end$/);
  assert.equal(ctx.tokens[blocks[0]!.firstIdx]!.text, 'case');
  assert.equal(ctx.tokens[blocks[1]!.firstIdx]!.text, 'Rec');
});

test('findBlocks: a block holding only a comment counts as empty', () => {
  const source = [
    'codeunit 50220 "X"',
    '{',
    '    procedure P(Flag: Boolean)',
    '    begin',
    '        if Flag then begin',
    '            // nothing yet',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { ctx, span } = contextFor(source);
  assert.equal(findBlocks(ctx.tokens, span).length, 0);
});

// --- BLOCK operator ---

test('BLOCK: one candidate per block; original is the first line of the body (single line, found on `line`)', () => {
  const { ctx, span } = contextFor(NESTED);
  const block = findBlocks(ctx.tokens, span)[1]!;
  const candidates = BLOCK.apply(ctx, block);

  assert.equal(candidates.length, 1);
  const c = candidates[0]!;
  assert.equal(c.operator, 'BLOCK');
  assert.equal(c.original, 'Rec.Insert();');
  assert.equal(ctx.source.split(/\n/)[c.line - 1]!.includes(c.original), true);
  assert.equal(c.mutated, 'begin end');
  assert.equal(c.line, 9);
  assert.equal(c.procedureName, 'P');
  assert.equal(c.target.kind, 'block');
  assert.equal(c.occurrence, 0);
});

// --- schemata ---

test('rewriteFile: BLOCK wraps the body in "if not MutationCore.Active(<id>) then begin … end", outer begin/end kept', () => {
  const source = [
    'codeunit 50220 "X"',
    '{',
    '    procedure P(Flag: Boolean)',
    '    begin',
    '        if Flag then begin',
    '            Rec.Insert();',
    '            Rec.Modify();',
    '        end else',
    '            Rec.Delete();',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { ctx, span } = contextFor(source);
  const block = findBlocks(ctx.tokens, span)[0]!;
  const candidates: MutantCandidate[] = [{ ...BLOCK.apply(ctx, block)[0]!, id: 4 }];

  const { output, lineMap } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50220 "X"',
    '{',
    '    procedure P(Flag: Boolean)',
    '    var',
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        if Flag then begin if not MutationCore.Active(4) then begin',
    '            Rec.Insert();',
    '            Rec.Modify();',
    '        end end else',
    '            Rec.Delete();',
    '    end;',
    '}',
    '',
  ].join('\n');
  assert.equal(output, expected);
  assert.deepEqual(lineMap, [{ mutantIds: [4], startLine: 7, endLine: 7 }]);
});

test('rewriteFile: BLOCK plus a DEL guard on a statement inside the same block do not overlap', () => {
  const source = [
    'codeunit 50220 "X"',
    '{',
    '    procedure P(Flag: Boolean)',
    '    begin',
    '        if Flag then begin',
    '            Rec.Insert()',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { ctx, span } = contextFor(source);
  const block = findBlocks(ctx.tokens, span)[0]!;
  const stmt = findSimpleStatements(ctx.tokens, span)[0]!;
  const candidates: MutantCandidate[] = [
    { ...BLOCK.apply(ctx, block)[0]!, id: 1 },
    { ...DEL.apply(ctx, stmt)[0]!, id: 2 },
  ];

  const { output } = rewriteFile(source, candidates);

  const expected = [
    'codeunit 50220 "X"',
    '{',
    '    procedure P(Flag: Boolean)',
    '    var',
    '        MutationCore: Codeunit "MUT Mut";',
    '    begin',
    '        if Flag then begin if not MutationCore.Active(1) then begin',
    '            case true of',
    '                MutationCore.Active(2):',
    '                    begin',
    '                    end;',
    '                else',
    '                    Rec.Insert();',
    '            end',
    '        end end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  assert.equal(output, expected);
});

// --- exclusions ---

function loopSource(loopLine: string): string {
  return [
    'codeunit 50220 "X"',
    '{',
    '    procedure P()',
    '    begin',
    `        ${loopLine} begin`,
    '            Done := true;',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
}

test("isExcludedBlock: a while body is skipped as 'while-loop-body' (emptied, it never ends)", () => {
  const { ctx, span } = contextFor(loopSource('while not Done do'));
  const block = findBlocks(ctx.tokens, span)[0]!;
  assert.equal(isExcludedBlock(ctx.tokens, block), 'while-loop-body');
});

test('isExcludedBlock: a while condition with a call (parentheses) is still a while body', () => {
  const { ctx, span } = contextFor(loopSource('while (I < Count(A)) and not Done do'));
  const block = findBlocks(ctx.tokens, span)[0]!;
  assert.equal(isExcludedBlock(ctx.tokens, block), 'while-loop-body');
});

test('isExcludedBlock: for and foreach bodies and then-blocks are kept', () => {
  for (const line of ['for I := 1 to 3 do', 'foreach Item in Items do', 'if Done then']) {
    const { ctx, span } = contextFor(loopSource(line));
    const block = findBlocks(ctx.tokens, span)[0]!;
    assert.equal(isExcludedBlock(ctx.tokens, block), null, line);
  }
});

test("isExcludedBlock: a block with a preprocessor directive inside is skipped as 'preprocessor-region'", () => {
  const source = [
    'codeunit 50220 "X"',
    '{',
    '    procedure P(Flag: Boolean)',
    '    begin',
    '        if Flag then begin',
    '#if CLEAN25',
    '            Rec.Insert();',
    '#endif',
    '        end;',
    '    end;',
    '}',
    '',
  ].join('\n');
  const { ctx, span } = contextFor(source);
  const block = findBlocks(ctx.tokens, span)[0]!;
  assert.equal(isExcludedBlock(ctx.tokens, block), 'preprocessor-region');
});
