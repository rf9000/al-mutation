import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

// §6.4.9 CLI: before this task, none of these flags were validated --
// `--operators REL,BOOl` silently matched nothing, `--only-objects abc` and
// `--max-mutants abc` silently became NaN (0 mutants / an ignored cap). This
// spawns the real compiled CLI (rather than importing cli.ts directly) since
// the module runs `main()` as a side effect of import against `process.argv`.

const CLI_JS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../src/cli.js');

const FIXTURES_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../fixtures/generator',
);
const VALID_AUT_DIR = path.join(FIXTURES_ROOT, '01-if-rel-bool-not-cond', 'input');
const CORE_APP_ID = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b';
const CORE_APP_VERSION = '1.0.0.0';

function tmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'al-mutation-cli-'));
}

function runCli(args: readonly string[]): { status: number | null; stdout: string; stderr: string } {
  const result = spawnSync(process.execPath, [CLI_JS, ...args], { encoding: 'utf8' });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

function validArgs(outDir: string, extra: readonly string[] = []): string[] {
  return [
    'generate',
    '--aut',
    VALID_AUT_DIR,
    '--out',
    outDir,
    '--core-app-id',
    CORE_APP_ID,
    '--core-app-version',
    CORE_APP_VERSION,
    ...extra,
  ];
}

test('cli generate: a valid invocation succeeds (baseline)', () => {
  const { status, stdout } = runCli(validArgs(tmpDir()));
  assert.equal(status, 0);
  assert.match(stdout, /^generated \d+ mutants, skipped \d+\n$/);
});

test('cli generate: --operators with an unknown/misspelled name exits non-zero with a clear message', () => {
  const { status, stderr, stdout } = runCli(validArgs(tmpDir(), ['--operators', 'REL,BOOl']));
  assert.notEqual(status, 0);
  assert.equal(stdout, '');
  assert.match(stderr, /operators/i);
  assert.match(stderr, /BOOl/);
});

test('cli generate: --only-objects with a non-numeric entry exits non-zero instead of silently matching 0 mutants', () => {
  const { status, stderr } = runCli(validArgs(tmpDir(), ['--only-objects', 'abc']));
  assert.notEqual(status, 0);
  assert.match(stderr, /only-objects/i);
});

test('cli generate: --max-mutants with a non-numeric value exits non-zero instead of silently ignoring the cap', () => {
  const { status, stderr } = runCli(validArgs(tmpDir(), ['--max-mutants', 'abc']));
  assert.notEqual(status, 0);
  assert.match(stderr, /max-mutants/i);
});

test('cli generate: missing a required flag still exits with usage error 2', () => {
  const { status, stderr } = runCli(['generate', '--out', tmpDir()]);
  assert.equal(status, 2);
  assert.match(stderr, /--aut/);
});
