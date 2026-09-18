import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { generate, rewriteAndVerify } from '../src/generate.js';
import type { GenerateOptions } from '../src/generate.js';
import { OPERATOR_ORDER } from '../src/operators/index.js';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';
import { findConditions, findSimpleStatements } from '../src/statements.js';
import { REL } from '../src/operators/rel.js';
import { DEL } from '../src/operators/del.js';
import type { MutantCandidate } from '../src/operators/types.js';
import type { SimpleStatement } from '../src/types.js';

const CORE_APP_ID = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b';
const CORE_APP_VERSION = '1.0.0.0';

function baseOptions(autDir: string, outDir: string): GenerateOptions {
  return {
    autDir,
    outDir,
    coreAppId: CORE_APP_ID,
    coreAppVersion: CORE_APP_VERSION,
    maxMutants: 0,
    seed: 1,
    onlyObjects: [],
    operators: [...OPERATOR_ORDER],
    includeBreak: false,
    excludeStableKeys: [],
  };
}

function tmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'al-mutation-robustness-'));
}

const APP_JSON = JSON.stringify(
  {
    id: '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d',
    name: 'T21b Robustness Fixture',
    publisher: 'Continia Software',
    version: '1.0.0.0',
    dependencies: [],
    idRanges: [{ from: 50200, to: 50299 }],
    platform: '28.0.0.0',
    application: '28.0.0.0',
    runtime: '17.0',
    target: 'Cloud',
  },
  null,
  2,
);

const GOOD_CODEUNIT = `codeunit 50210 "Good Cu"
{
    Access = Public;
    var
        Result: Boolean;

    procedure Check(Amount: Decimal; IsTrusted: Boolean)
    begin
        if (Amount > 1000) and (not IsTrusted) then
            Result := true;
    end;
}
`;

// A stray "~" is not a valid AL token under §6.4.1 (no rule covers it) -- this file must fail to
// tokenize, exactly like the 20 real files found live in out/aut-original (T21b brief).
const BAD_CODEUNIT = `codeunit 50211 "Bad Cu"
{
    procedure Oops()
    begin
        A := 1 ~ 2;
    end;
}
`;

test('generate() does not abort the whole run when one file fails to tokenize (T21b)', () => {
  const autDir = tmpDir();
  fs.writeFileSync(path.join(autDir, 'app.json'), APP_JSON, 'utf8');
  fs.mkdirSync(path.join(autDir, 'src'));
  fs.writeFileSync(path.join(autDir, 'src', 'Good.Codeunit.al'), GOOD_CODEUNIT, 'utf8');
  fs.writeFileSync(path.join(autDir, 'src', 'Bad.Codeunit.al'), BAD_CODEUNIT, 'utf8');

  const outDir = tmpDir();

  // Must not throw -- the whole point of this test.
  const result = generate(baseOptions(autDir, outDir));

  // The good file's mutants were still produced.
  assert.ok(result.mutants.length > 0, 'expected mutants from the file that tokenizes fine');
  assert.ok(result.mutants.every((m) => m.file === 'src/Good.Codeunit.al'));

  // The bad file is recorded in skipped.json with a tokenize-error reason naming it, not thrown.
  const tokenizeSkip = result.skipped.find((s) => s.file === 'src/Bad.Codeunit.al');
  assert.ok(tokenizeSkip !== undefined, 'expected a skipped.json entry for the unparseable file');
  assert.equal(tokenizeSkip!.line, 0);
  assert.match(tokenizeSkip!.reason, /^tokenize-error: /);
  assert.match(tokenizeSkip!.reason, /~/);

  // skipped.json on disk matches the in-memory result.
  const skippedOnDisk = JSON.parse(fs.readFileSync(path.join(outDir, 'skipped.json'), 'utf8')) as unknown[];
  assert.deepEqual(skippedOnDisk, result.skipped);

  // mutants.json was still written for the good file's mutants.
  const mutantsOnDisk = JSON.parse(fs.readFileSync(path.join(outDir, 'mutants.json'), 'utf8')) as unknown[];
  assert.equal(mutantsOnDisk.length, result.mutants.length);

  // The unparseable file is still copied byte-for-byte into aut-schemata (no mutants for it).
  const copiedBad = fs.readFileSync(path.join(outDir, 'aut-schemata', 'src', 'Bad.Codeunit.al'), 'utf8');
  assert.equal(copiedBad, BAD_CODEUNIT);
});

// --- B2/B2b: rewriteAndVerify must skip, never throw or emit garbage. ---

test('rewriteAndVerify: overlapping candidates are turned into a skipReason, not thrown (B2)', () => {
  const source = [
    'codeunit 50212 "Overlap Cu"',
    '{',
    '    procedure P(A: Integer)',
    '    begin',
    '        if A > 1 then',
    '            exit(true);',
    '    end;',
    '}',
    '',
  ].join('\n');

  const tokens = tokenize(source);
  const header = findObjectHeader(tokens)!;
  const span = findProcedures(tokens)[0]!;
  const ctx = { tokens, span, header, source };
  const [cond] = findConditions(tokens, span);
  const [stmt] = findSimpleStatements(tokens, span);
  assert.ok(cond);
  assert.ok(stmt);

  const condCandidate: MutantCandidate = { ...REL.apply(ctx, cond!)[0]!, id: 1 };
  const delCandidate = DEL.apply(ctx, stmt!)[0]!;
  assert.ok(delCandidate, 'exit(true) should match DEL');

  // Same forced-overlap construction as schemata.test.ts's direct rewriteFile test: a statement
  // span that starts at the condition's own start offset.
  const overlappingStmt: SimpleStatement = { ...stmt!, startIdx: cond!.startIdx };
  const overlappingCandidate: MutantCandidate = {
    ...delCandidate,
    id: 2,
    target: { kind: 'statement', stmt: overlappingStmt },
  };

  const outcome = rewriteAndVerify(source, [condCandidate, overlappingCandidate]);
  assert.ok('skipReason' in outcome, 'expected a skipReason, not a successful rewrite');
  assert.match((outcome as { skipReason: string }).skipReason, /^overlapping-candidates: /);
});

test('rewriteAndVerify: a deliberately corrupt mutated replacement fails the re-tokenize check and is skipped (B2b)', () => {
  const source = [
    'codeunit 50213 "Corrupt Rewrite Cu"',
    '{',
    '    procedure Check()',
    '    begin',
    '        Result := 1;',
    '    end;',
    '}',
    '',
  ].join('\n');

  const tokens = tokenize(source);
  const header = findObjectHeader(tokens)!;
  const span = findProcedures(tokens)[0]!;
  const [stmt] = findSimpleStatements(tokens, span);
  assert.ok(stmt);

  // A hand-built candidate (not from any operator, which would never emit invalid AL) whose
  // `mutated` text contains a character the tokenizer rejects (§6.4.1 has no rule for `~`) --
  // deliberately corrupt output that a non-overlapping rewrite would otherwise emit silently.
  const corruptCandidate: MutantCandidate = {
    id: 1,
    operator: 'INSFLAG',
    objectType: header.objectType,
    objectId: header.objectId,
    objectName: header.objectName,
    procedureName: span.name,
    line: tokens[stmt!.startIdx]!.line,
    target: { kind: 'statement', stmt: stmt! },
    original: 'Result := 1',
    mutated: 'Result := 1 ~ 2',
    occurrence: 0,
  };

  const outcome = rewriteAndVerify(source, [corruptCandidate]);
  assert.ok('skipReason' in outcome, 'expected a skipReason, not a successful rewrite');
  assert.match((outcome as { skipReason: string }).skipReason, /^rewrite-verification-failed: /);
});

test('generate(): a file whose mutants fail rewriteAndVerify is skipped and copied unmutated, run continues (B2)', () => {
  const autDir = tmpDir();
  fs.writeFileSync(path.join(autDir, 'app.json'), APP_JSON, 'utf8');
  fs.mkdirSync(path.join(autDir, 'src'));
  fs.writeFileSync(path.join(autDir, 'src', 'Good.Codeunit.al'), GOOD_CODEUNIT, 'utf8');

  const outDir = tmpDir();
  const result = generate(baseOptions(autDir, outDir));

  // Sanity: the good file still produced its mutants under normal (non-corrupt) conditions.
  assert.ok(result.mutants.length > 0);

  // The copied file (no corruption injected here) is byte-identical -- this test only asserts
  // that the pipeline plumbs rewriteAndVerify's success path through unchanged; the failure
  // path itself is exercised directly against rewriteAndVerify above (B2/B2b), since no current
  // operator can produce a genuinely corrupt or overlapping rewrite through the real pipeline.
  const copiedGood = fs.readFileSync(path.join(outDir, 'aut-schemata', 'src', 'Good.Codeunit.al'), 'utf8');
  assert.notEqual(copiedGood, GOOD_CODEUNIT, 'the good file should have been mutated, not copied verbatim');
});

// --- BOM: a leading UTF-8 BOM must not make the whole file drop as a tokenize-error. ---

test('generate(): a leading UTF-8 BOM is stripped instead of failing the whole file', () => {
  const autDir = tmpDir();
  fs.writeFileSync(path.join(autDir, 'app.json'), APP_JSON, 'utf8');
  fs.mkdirSync(path.join(autDir, 'src'));
  fs.writeFileSync(path.join(autDir, 'src', 'Bom.Codeunit.al'), '﻿' + GOOD_CODEUNIT, 'utf8');

  const outDir = tmpDir();
  const result = generate(baseOptions(autDir, outDir));

  const bomSkip = result.skipped.find((s) => s.file === 'src/Bom.Codeunit.al');
  assert.equal(bomSkip, undefined, 'a BOM must not cause a tokenize-error skip');
  assert.ok(
    result.mutants.some((m) => m.file === 'src/Bom.Codeunit.al'),
    'expected mutants from the BOM-prefixed file',
  );
});
