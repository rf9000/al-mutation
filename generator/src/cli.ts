import * as fs from 'node:fs';
import { generate } from './generate.js';
import type { GenerateOptions } from './generate.js';
import { lintSchemata } from './lint.js';
import { OPERATOR_ORDER } from './operators/index.js';
import type { OperatorName } from './operators/types.js';

/** Hand-rolled `--flag value` / `--flag` (boolean) parsing (§6.4.9), no dependencies. */
function parseFlags(args: readonly string[]): Map<string, string> {
  const flags = new Map<string, string>();
  let i = 0;
  while (i < args.length) {
    const arg = args[i]!;
    if (!arg.startsWith('--')) {
      i++;
      continue;
    }
    const key = arg.slice(2);
    const next = args[i + 1];
    if (next !== undefined && !next.startsWith('--')) {
      flags.set(key, next);
      i += 2;
    } else {
      flags.set(key, 'true');
      i += 1;
    }
  }
  return flags;
}

function usageError(message: string): number {
  process.stderr.write(`error: ${message}\n`);
  return 2;
}

/** Thrown by the `parse*` helpers below on a malformed flag value; caught in `runGenerate`. */
class UsageError extends Error {}

const VALID_OPERATOR_NAMES: ReadonlySet<string> = new Set(OPERATOR_ORDER);

/** Validates every entry against the known operator catalog (§6.4.4) so a typo never silently matches nothing. */
function parseOperatorList(value: string | undefined): OperatorName[] {
  if (value === undefined) return [...OPERATOR_ORDER];
  const requested = value
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  for (const name of requested) {
    if (!VALID_OPERATOR_NAMES.has(name)) {
      throw new UsageError(
        `--operators: unknown operator ${JSON.stringify(name)} (valid: ${OPERATOR_ORDER.join(', ')})`,
      );
    }
  }
  return requested as OperatorName[];
}

/** Validates every entry is a plain integer so a typo never silently becomes NaN (matching nothing, i.e. 0 mutants). */
function parseObjectList(value: string | undefined): number[] {
  if (value === undefined) return [];
  return value
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((s) => {
      if (!/^-?\d+$/.test(s)) {
        throw new UsageError(`--only-objects: ${JSON.stringify(s)} is not an integer`);
      }
      return Number.parseInt(s, 10);
    });
}

/** Validates a required-integer flag so a typo never silently becomes NaN (e.g. --max-mutants abc silently ignoring the cap). */
function parseRequiredInt(value: string, flagName: string): number {
  if (!/^-?\d+$/.test(value)) {
    throw new UsageError(`--${flagName} must be an integer, got ${JSON.stringify(value)}`);
  }
  return Number.parseInt(value, 10);
}

function runGenerate(args: readonly string[]): number {
  const flags = parseFlags(args);

  const autDir = flags.get('aut');
  const outDir = flags.get('out');
  const coreAppId = flags.get('core-app-id');
  const coreAppVersion = flags.get('core-app-version');

  if (autDir === undefined) return usageError('--aut <dir> is required');
  if (outDir === undefined) return usageError('--out <dir> is required');
  if (coreAppId === undefined) return usageError('--core-app-id <guid> is required');
  if (coreAppVersion === undefined) return usageError('--core-app-version <ver> is required');

  let excludeStableKeys: string[] = [];
  const excludeFile = flags.get('exclude-stable-keys');
  if (excludeFile !== undefined) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(excludeFile, 'utf8'));
    } catch (err) {
      return usageError(`failed to read --exclude-stable-keys file: ${(err as Error).message}`);
    }
    const keys = (parsed as { stableKeys?: unknown }).stableKeys;
    if (!Array.isArray(keys)) return usageError('--exclude-stable-keys file must contain { "stableKeys": [] }');
    excludeStableKeys = keys as string[];
  }

  let options: GenerateOptions;
  try {
    options = {
      autDir,
      outDir,
      coreAppId,
      coreAppVersion,
      autVersion: flags.get('aut-version'),
      maxMutants: flags.has('max-mutants') ? parseRequiredInt(flags.get('max-mutants')!, 'max-mutants') : 0,
      seed: flags.has('seed') ? Number.parseInt(flags.get('seed')!, 10) : 1,
      onlyObjects: parseObjectList(flags.get('only-objects')),
      operators: parseOperatorList(flags.get('operators')),
      includeBreak: flags.has('include-break'),
      excludeStableKeys,
    };
  } catch (err) {
    if (err instanceof UsageError) return usageError(err.message);
    throw err;
  }

  try {
    const result = generate(options);
    process.stdout.write(`generated ${result.mutants.length} mutants, skipped ${result.skipped.length}\n`);
    return 0;
  } catch (err) {
    process.stderr.write(`generate failed: ${(err as Error).message}\n`);
    return 1;
  }
}

function runLint(args: readonly string[]): number {
  const flags = parseFlags(args);
  const schemataDir = flags.get('schemata');
  if (schemataDir === undefined) return usageError('--schemata <dir> is required');

  try {
    const findings = lintSchemata(schemataDir);
    if (findings.length > 0) {
      for (const finding of findings) {
        process.stdout.write(`${finding.file}:${finding.line}: ${finding.text}\n`);
      }
      process.stdout.write(`lint failed with ${findings.length} finding(s)\n`);
      return 1;
    }
    process.stdout.write('lint: ok\n');
    return 0;
  } catch (err) {
    process.stderr.write(`lint failed: ${(err as Error).message}\n`);
    return 1;
  }
}

function main(argv: readonly string[]): number {
  const [command, ...rest] = argv;
  if (command === 'generate') return runGenerate(rest);
  if (command === 'lint') return runLint(rest);
  process.stderr.write('usage: cli.js generate --aut <dir> --out <dir> --core-app-id <guid> --core-app-version <ver> [...]\n');
  process.stderr.write('       cli.js lint --schemata <dir>\n');
  return 2;
}

process.exitCode = main(process.argv.slice(2));
