import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { lintSchemata } from '../src/lint.js';

function tmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'al-mutation-lint-'));
}

function writeAl(dir: string, relPath: string, content: string): void {
  const abs = path.join(dir, relPath);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, content, 'utf8');
}

test('lintSchemata: flags MutationCore.Active( followed by and', () => {
  const dir = tmpDir();
  writeAl(dir, 'X.al', 'if MutationCore.Active(1) and X then\n');
  const findings = lintSchemata(dir);
  assert.equal(findings.length, 1);
  assert.equal(findings[0]!.file, 'X.al');
  assert.equal(findings[0]!.line, 1);
});

test('lintSchemata: flags MutationCore.Active( preceded by or', () => {
  const dir = tmpDir();
  writeAl(dir, 'X.al', 'if X or MutationCore.Active(2) then\n');
  const findings = lintSchemata(dir);
  assert.equal(findings.length, 1);
  assert.equal(findings[0]!.line, 1);
});

test('lintSchemata: flags MutationCore.Active( nested inside another call', () => {
  const dir = tmpDir();
  writeAl(dir, 'X.al', 'if Foo(MutationCore.Active(3)) then\n');
  const findings = lintSchemata(dir);
  assert.equal(findings.length, 1);
  assert.equal(findings[0]!.line, 1);
});

test('lintSchemata: accepts a valid case block', () => {
  const dir = tmpDir();
  writeAl(
    dir,
    'X.al',
    [
      'case true of',
      '    MutationCore.Active(1):',
      '        MutCond_1 := true;',
      '    else',
      '        MutCond_1 := Quantity >= 10;',
      'end;',
      '',
    ].join('\n'),
  );
  const findings = lintSchemata(dir);
  assert.deepEqual(findings, []);
});

test('lintSchemata: flags MutationCore.Active( preceded by xor', () => {
  const dir = tmpDir();
  writeAl(dir, 'X.al', 'if X xor MutationCore.Active(4) then\n');
  const findings = lintSchemata(dir);
  assert.equal(findings.length, 1);
});

test('lintSchemata: reports the correct line number among several lines', () => {
  const dir = tmpDir();
  writeAl(
    dir,
    'X.al',
    ['codeunit 1 "X"', '{', '    // fine', '    if X or MutationCore.Active(1) then;', '}', ''].join('\n'),
  );
  const findings = lintSchemata(dir);
  assert.equal(findings.length, 1);
  assert.equal(findings[0]!.line, 4);
});

test('lintSchemata: scans multiple files under nested directories', () => {
  const dir = tmpDir();
  writeAl(dir, 'src/A.al', 'MutationCore.Active(1);\n');
  writeAl(dir, 'src/sub/B.al', 'if X and MutationCore.Active(2) then;\n');
  const findings = lintSchemata(dir);
  assert.equal(findings.length, 1);
  assert.equal(findings[0]!.file, 'src/sub/B.al');
});
