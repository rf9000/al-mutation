import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generate } from '../src/generate.js';
import type { GenerateOptions } from '../src/generate.js';
import { OPERATOR_ORDER } from '../src/operators/index.js';

const FIXTURES_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../fixtures/generator',
);
const CORE_APP_ID = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b';
const CORE_APP_VERSION = '1.0.0.0';

const CASES = [
  '01-if-rel-bool-not-cond',
  '02-until-and-next-exclusion',
  '03-del-insflag-positions',
  '04-exclusions',
  '05-fixture-aut',
  '06-shared-line-if-then',
  '07-case-branch-labels',
];

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
  return fs.mkdtempSync(path.join(os.tmpdir(), 'al-mutation-golden-'));
}

/** Recursively lists every file under `dir`, as forward-slash relative paths, sorted. */
function listAllFiles(dir: string): string[] {
  const results: string[] = [];
  function walk(current: string, relPrefix: string): void {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const rel = relPrefix === '' ? entry.name : `${relPrefix}/${entry.name}`;
      if (entry.isDirectory()) {
        walk(path.join(current, entry.name), rel);
      } else if (entry.isFile()) {
        results.push(rel);
      }
    }
  }
  walk(dir, '');
  return results.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

/** A minimal unified-diff-style rendering of the first differing lines of two texts. */
function firstDiff(expected: string, actual: string): string {
  const expLines = expected.split(/\r\n|\n/);
  const actLines = actual.split(/\r\n|\n/);
  const max = Math.max(expLines.length, actLines.length);
  for (let i = 0; i < max; i++) {
    if (expLines[i] !== actLines[i]) {
      const context = 2;
      const start = Math.max(0, i - context);
      const endExp = Math.min(expLines.length, i + context + 1);
      const endAct = Math.min(actLines.length, i + context + 1);
      const lines: string[] = [`@@ line ${i + 1} @@`];
      for (let k = start; k < i; k++) lines.push(`  ${expLines[k]}`);
      for (let k = i; k < endExp; k++) lines.push(`- ${expLines[k]}`);
      for (let k = i; k < endAct; k++) lines.push(`+ ${actLines[k]}`);
      return lines.join('\n');
    }
  }
  return '(no line-level difference found; lengths differ)';
}

function compareDirsByteForByte(expectedDir: string, actualDir: string, label: string): void {
  const expectedFiles = listAllFiles(expectedDir);
  const actualFiles = listAllFiles(actualDir);
  assert.deepEqual(
    actualFiles,
    expectedFiles,
    `${label}: file listing differs (expected ${JSON.stringify(expectedFiles)}, got ${JSON.stringify(actualFiles)})`,
  );

  for (const rel of expectedFiles) {
    const expectedBuf = fs.readFileSync(path.join(expectedDir, rel));
    const actualBuf = fs.readFileSync(path.join(actualDir, rel));
    if (!expectedBuf.equals(actualBuf)) {
      const diff = firstDiff(expectedBuf.toString('utf8'), actualBuf.toString('utf8'));
      assert.fail(`${label}: ${rel} differs from expected:\n${diff}`);
    }
  }
}

for (const caseName of CASES) {
  test(`golden case ${caseName}: matches expected/ byte-for-byte`, () => {
    const caseDir = path.join(FIXTURES_ROOT, caseName);
    const autDir = path.join(caseDir, 'input');
    const expectedDir = path.join(caseDir, 'expected');
    const outDir = tmpDir();

    generate(baseOptions(autDir, outDir));

    compareDirsByteForByte(
      path.join(expectedDir, 'aut-schemata'),
      path.join(outDir, 'aut-schemata'),
      `${caseName} aut-schemata`,
    );

    const expectedMutants = fs.readFileSync(path.join(expectedDir, 'mutants.json'), 'utf8');
    const actualMutants = fs.readFileSync(path.join(outDir, 'mutants.json'), 'utf8');
    assert.equal(actualMutants, expectedMutants, `${caseName}: mutants.json differs`);
  });
}

test('golden case 05-fixture-aut: yields exactly the 26 mutants of SPEC.md sec.6.3.3', () => {
  const caseDir = path.join(FIXTURES_ROOT, '05-fixture-aut');
  const outDir = tmpDir();
  const result = generate(baseOptions(path.join(caseDir, 'input'), outDir));
  assert.equal(result.mutants.length, 26);
  assert.deepEqual(
    result.mutants.map((m) => m.id),
    Array.from({ length: 26 }, (_, i) => i + 1),
  );
});

test('generate is deterministic: running twice yields byte-identical output', () => {
  const caseDir = path.join(FIXTURES_ROOT, '05-fixture-aut');
  const autDir = path.join(caseDir, 'input');
  const outDir1 = tmpDir();
  const outDir2 = tmpDir();

  generate(baseOptions(autDir, outDir1));
  generate(baseOptions(autDir, outDir2));

  compareDirsByteForByte(path.join(outDir1, 'aut-schemata'), path.join(outDir2, 'aut-schemata'), 'determinism');
  assert.equal(
    fs.readFileSync(path.join(outDir1, 'mutants.json'), 'utf8'),
    fs.readFileSync(path.join(outDir2, 'mutants.json'), 'utf8'),
  );
});

test('exclude-stable-keys removes mutants without renumbering the remaining ids', () => {
  const caseDir = path.join(FIXTURES_ROOT, '05-fixture-aut');
  const autDir = path.join(caseDir, 'input');
  const outDir = tmpDir();
  const full = generate(baseOptions(autDir, outDir));
  const excludeKey = full.mutants[1]!.stableKey; // id 2

  const excludeFile = path.join(outDir, 'exclude.json');
  fs.writeFileSync(excludeFile, JSON.stringify({ stableKeys: [excludeKey] }));

  const outDir2 = tmpDir();
  const filtered = generate({
    ...baseOptions(autDir, outDir2),
    excludeStableKeys: [excludeKey],
  });

  assert.equal(filtered.mutants.length, full.mutants.length - 1);
  assert.ok(!filtered.mutants.some((m) => m.stableKey === excludeKey));
  assert.deepEqual(
    filtered.mutants.map((m) => m.id),
    full.mutants.filter((m) => m.stableKey !== excludeKey).map((m) => m.id),
  );
});

test('sample is stable by seed: same seed and maxMutants yield the same ids across runs', () => {
  const caseDir = path.join(FIXTURES_ROOT, '05-fixture-aut');
  const autDir = path.join(caseDir, 'input');

  const run1 = generate({ ...baseOptions(autDir, tmpDir()), maxMutants: 5, seed: 7 });
  const run2 = generate({ ...baseOptions(autDir, tmpDir()), maxMutants: 5, seed: 7 });
  const run3 = generate({ ...baseOptions(autDir, tmpDir()), maxMutants: 5, seed: 8 });

  assert.deepEqual(
    run1.mutants.map((m) => m.id),
    run2.mutants.map((m) => m.id),
  );
  assert.notDeepEqual(
    run1.mutants.map((m) => m.id),
    run3.mutants.map((m) => m.id),
  );
  assert.equal(run1.mutants.length, 5);
});

test('includeBreak: true produces BREAK mutants even when --operators lists only the six non-BREAK operators (regression, T27 live-run fix)', () => {
  // Reproduces mutation.fixture.config.json's own generator.operators list verbatim (§6.5.1:
  // ["REL","BOOL","NOT","COND","DEL","INSFLAG"], no "BREAK") with includeBreak flipped to true --
  // exactly what T27's brief instructs for the BREAK acceptance run (flip only includeBreak,
  // leave the operators list as-is). Before the fix, BREAK candidates were gated by BOTH
  // includeBreak AND membership in the --operators list, so a config like this one silently
  // produced zero BREAK mutants.
  const caseDir = path.join(FIXTURES_ROOT, '05-fixture-aut');
  const autDir = path.join(caseDir, 'input');

  const result = generate({
    ...baseOptions(autDir, tmpDir()),
    operators: ['REL', 'BOOL', 'NOT', 'COND', 'DEL', 'INSFLAG'],
    includeBreak: true,
  });

  const breakMutants = result.mutants.filter((m) => m.operator === 'BREAK');
  assert.ok(breakMutants.length > 0, 'expected at least one BREAK mutant with includeBreak: true');
  assert.ok(
    breakMutants.every((m) => m.mutated === 'MutBreak_ThisDoesNotCompile();' || m.mutated === 'MutBreak_ThisDoesNotCompile()'),
    'every BREAK mutant should mutate to a call to the deliberately-undefined MutBreak_ThisDoesNotCompile',
  );

  // The six normal operators must still be present and unaffected -- exactly the 26 mutants of
  // §6.3.3, unchanged by BREAK being added.
  const nonBreakMutants = result.mutants.filter((m) => m.operator !== 'BREAK');
  assert.equal(nonBreakMutants.length, 26);
});

test('includeBreak: false still produces zero BREAK mutants regardless of the --operators list (no regression the other way)', () => {
  const caseDir = path.join(FIXTURES_ROOT, '05-fixture-aut');
  const autDir = path.join(caseDir, 'input');

  const result = generate({
    ...baseOptions(autDir, tmpDir()),
    operators: [...OPERATOR_ORDER],
    includeBreak: false,
  });

  assert.equal(result.mutants.filter((m) => m.operator === 'BREAK').length, 0);
});
