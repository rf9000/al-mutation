import * as fs from 'node:fs';
import * as path from 'node:path';
import { tokenize } from './tokenizer.js';
import { findObjectHeader, findProcedures } from './procedures.js';
import { findConditions, findSimpleStatements } from './statements.js';
import {
  isExcludedCondition,
  isExcludedFile,
  isExcludedRegion,
  isExcludedStatement,
} from './exclusions.js';
import { rewriteFile } from './schemata.js';
import type { LineMapEntry } from './schemata.js';
import { OPERATORS, OPERATOR_ORDER, assignOccurrences } from './operators/index.js';
import type { MutantCandidate, OperatorName } from './operators/types.js';
import { assignIds, sample } from './manifest.js';
import type { Mutant } from './manifest.js';
import { lintSchemata } from './lint.js';
import type { ProcedureSpan, Token } from './types.js';

export interface GenerateOptions {
  autDir: string;
  outDir: string;
  coreAppId: string;
  coreAppVersion: string;
  autVersion?: string;
  maxMutants: number;
  seed: number;
  onlyObjects: number[];
  operators: OperatorName[];
  includeBreak: boolean;
  excludeStableKeys: string[];
}

export interface Skip {
  file: string;
  line: number;
  reason: string;
}

export interface GenerateResult {
  mutants: Mutant[];
  skipped: Skip[];
  lineMap: Record<string, LineMapEntry[]>;
}

const SKIP_DIR_NAMES: ReadonlySet<string> = new Set(['.alpackages', '.snapshots', 'node_modules']);

/** Recursively lists every file under `dir` (any extension) except skipped dirs/`*.app`, as forward-slash relative paths, ordinally sorted. */
function listAllFiles(dir: string): string[] {
  const results: string[] = [];

  function walk(current: string, relPrefix: string): void {
    const entries = fs.readdirSync(current, { withFileTypes: true });
    for (const entry of entries) {
      const rel = relPrefix === '' ? entry.name : `${relPrefix}/${entry.name}`;
      if (entry.isDirectory()) {
        if (SKIP_DIR_NAMES.has(entry.name)) continue;
        walk(path.join(current, entry.name), rel);
      } else if (entry.isFile()) {
        if (/\.app$/i.test(entry.name)) continue;
        results.push(rel);
      }
    }
  }

  walk(dir, '');
  return results.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

function isSignificant(token: Token): boolean {
  return token.kind !== 'comment' && token.kind !== 'preprocessor';
}

/**
 * Strips a leading UTF-8 BOM (`﻿`), which `fs.readFileSync(..., 'utf8')`
 * keeps as the first character. Left in, it makes the tokenizer throw
 * (`Unexpected character` at line 1) and the whole file gets dropped as a
 * `tokenize-error`, even though the file is otherwise perfectly valid AL.
 */
function stripBom(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

interface Target {
  start: number;
  kind: 'condition' | 'statement';
  condIdx?: number;
  stmtIdx?: number;
}

/** Candidate produced by one operator application, tagged with its source file. */
type CandidateWithFile = MutantCandidate & { file: string };

/**
 * §6.4.8: enumerates all mutant candidates for one `.al` file, in the
 * required order (procedures in source order, targets by start offset,
 * operators by OPERATOR_ORDER, variants in generation order), recording
 * skips for excluded regions/conditions/statements as it goes.
 */
function generateCandidatesForFile(
  relPath: string,
  source: string,
  options: GenerateOptions,
): { candidates: CandidateWithFile[]; skipped: Skip[] } {
  const skipped: Skip[] = [];
  const excludedFileReason = isExcludedFile(relPath, source);
  if (excludedFileReason !== null) {
    skipped.push({ file: relPath, line: 0, reason: excludedFileReason });
    return { candidates: [], skipped };
  }

  const tokens = tokenize(source);
  const header = findObjectHeader(tokens);
  if (header === null) {
    skipped.push({ file: relPath, line: 0, reason: 'not-a-codeunit' });
    return { candidates: [], skipped };
  }

  const procedures: ProcedureSpan[] = findProcedures(tokens);
  const allowedOperators = new Set(options.operators);
  const candidates: CandidateWithFile[] = [];

  for (const span of procedures) {
    const conditions = findConditions(tokens, span);
    const statements = findSimpleStatements(tokens, span);

    const targets: Target[] = [
      ...conditions.map((cond, condIdx) => ({
        start: tokens[cond.startIdx]!.start,
        kind: 'condition' as const,
        condIdx,
      })),
      ...statements.map((stmt, stmtIdx) => ({
        start: tokens[stmt.startIdx]!.start,
        kind: 'statement' as const,
        stmtIdx,
      })),
    ].sort((a, b) => a.start - b.start);

    const procCandidates: MutantCandidate[] = [];

    for (const target of targets) {
      const ctx = { tokens, span, header, source };

      if (target.kind === 'condition') {
        const cond = conditions[target.condIdx!]!;
        const regionReason = isExcludedRegion(tokens, cond.startIdx, cond.endIdx);
        if (regionReason !== null) {
          skipped.push({ file: relPath, line: tokens[cond.startIdx]!.line, reason: regionReason });
          continue;
        }
        const condReason = isExcludedCondition(tokens, cond);
        if (condReason !== null) {
          skipped.push({ file: relPath, line: tokens[cond.startIdx]!.line, reason: condReason });
          continue;
        }
        for (const name of OPERATOR_ORDER) {
          const operator = OPERATORS[name];
          if (operator.kind !== 'condition') continue;
          if (!allowedOperators.has(name)) continue;
          procCandidates.push(...operator.apply(ctx, cond));
        }
      } else {
        const stmt = statements[target.stmtIdx!]!;
        const regionReason = isExcludedRegion(tokens, stmt.startIdx, stmt.endIdx);
        if (regionReason !== null) {
          skipped.push({ file: relPath, line: tokens[stmt.startIdx]!.line, reason: regionReason });
          continue;
        }
        const stmtReason = isExcludedStatement(tokens, stmt);
        if (stmtReason !== null) {
          skipped.push({ file: relPath, line: tokens[stmt.startIdx]!.line, reason: stmtReason });
          continue;
        }
        for (const name of OPERATOR_ORDER) {
          const operator = OPERATORS[name];
          if (operator.kind !== 'statement') continue;
          if (name === 'BREAK') {
            // BREAK is gated solely by --include-break (§6.4.5: "Only with --include-break"),
            // independent of --operators (which selects among the six normal operators). Fix
            // (T27, live run, 2026-09-09 -- see docs/issues.md): this used to also require
            // 'BREAK' to be listed in --operators, so a config that sets includeBreak = true
            // without also adding 'BREAK' to its operators list (exactly what this task's own
            // fixture config does, per the brief's instruction to flip only includeBreak)
            // silently generated zero BREAK mutants.
            if (!options.includeBreak) continue;
          } else if (!allowedOperators.has(name)) {
            continue;
          }
          procCandidates.push(...operator.apply(ctx, stmt));
        }
      }
    }

    const withOccurrence = assignOccurrences(procCandidates);
    for (const candidate of withOccurrence) {
      candidates.push({ ...candidate, file: relPath });
    }
  }

  return { candidates, skipped };
}

function writeJsonFile(filePath: string, data: unknown): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2) + '\n', 'utf8');
}

/** §6.4.9: patches `app.json`'s `version` (if `autVersion` given) and appends the core app dependency. */
function patchAppJson(source: string, options: GenerateOptions): string {
  const obj = JSON.parse(source) as Record<string, unknown>;
  if (options.autVersion !== undefined) {
    obj['version'] = options.autVersion;
  }
  const dependencies = Array.isArray(obj['dependencies']) ? [...(obj['dependencies'] as unknown[])] : [];
  dependencies.push({
    id: options.coreAppId,
    name: 'Mutation Core',
    publisher: 'Continia Software',
    version: options.coreAppVersion,
  });
  obj['dependencies'] = dependencies;
  return JSON.stringify(obj, null, 2) + '\n';
}

/** The result of rewriting one file's mutants, or a reason it could not be safely emitted. */
export type RewriteOutcome = { output: string; lineMap: LineMapEntry[] } | { skipReason: string };

/**
 * B2/B2b: applies `rewriteFile` and, only on success, re-tokenizes its
 * output as a cheap end-to-end sanity check that the rewrite is still valid
 * AL. Never throws: any failure (an overlapping-candidate throw from
 * `rewriteFile`, per §6.4.7's invariant, or the output failing to tokenize)
 * is turned into a `skipReason` so the caller can skip this one file --
 * exactly like the tokenize-error path (§6.4.9) -- instead of emitting
 * broken AL or aborting the whole run.
 */
export function rewriteAndVerify(source: string, mutants: readonly MutantCandidate[]): RewriteOutcome {
  let rewritten: { output: string; lineMap: LineMapEntry[] };
  try {
    rewritten = rewriteFile(source, mutants);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { skipReason: `overlapping-candidates: ${message}` };
  }

  try {
    tokenize(rewritten.output);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { skipReason: `rewrite-verification-failed: ${message}` };
  }

  return rewritten;
}

function toManifestEntry(m: Mutant): Record<string, unknown> {
  return {
    id: m.id,
    stableKey: m.stableKey,
    objectType: m.objectType,
    objectId: m.objectId,
    objectName: m.objectName,
    procedure: m.procedureName,
    line: m.line,
    operator: m.operator,
    original: m.original,
    mutated: m.mutated,
    file: m.file,
  };
}

/**
 * @internal Test-only seam for the per-file rewrite step (defaults to the real
 * `rewriteAndVerify`). No current operator can make a real file's candidates trip
 * `rewriteAndVerify`'s overlap or re-tokenize checks (that is the point of B2/B2b being
 * invariant-enforcement, not a live bug), so this is how a test exercises `generate()`'s own
 * skip/copy/mutants.json-exclusion branch end-to-end without faking the assertions. Not part of
 * the CLI-facing contract (§6.4.9 lists only `--aut`/`--out`/etc.) -- the CLI never passes this.
 */
export interface GenerateDeps {
  rewriteAndVerify: typeof rewriteAndVerify;
}

const defaultDeps: GenerateDeps = Object.freeze({ rewriteAndVerify });

/** §6.4.9: the whole generator pipeline — pure enumeration plus file I/O against `options.autDir`/`options.outDir`. */
export function generate(options: GenerateOptions, deps: GenerateDeps = defaultDeps): GenerateResult {
  const allFiles = listAllFiles(options.autDir);
  const alFiles = allFiles.filter((f) => /\.al$/i.test(f));

  const allCandidates: CandidateWithFile[] = [];
  const allSkipped: Skip[] = [];

  for (const relPath of alFiles) {
    // §6.4.9: one file's tokenizer error (or any other failure in this per-file step) must not
    // abort the whole run -- it is recorded as a skip and the remaining files still generate.
    try {
      const source = stripBom(fs.readFileSync(path.join(options.autDir, relPath), 'utf8'));
      const { candidates, skipped } = generateCandidatesForFile(relPath, source, options);
      allCandidates.push(...candidates);
      allSkipped.push(...skipped);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      allSkipped.push({ file: relPath, line: 0, reason: `tokenize-error: ${message}` });
    }
  }

  // §6.4.8: ids 1..N over the full enumeration (all files, requested operators), before any filter below.
  const allMutants = assignIds(allCandidates);

  const excludeSet = new Set(options.excludeStableKeys);
  let selected = allMutants.filter((m) => !excludeSet.has(m.stableKey));

  if (options.onlyObjects.length > 0) {
    const onlySet = new Set(options.onlyObjects);
    selected = selected.filter((m) => onlySet.has(m.objectId));
  }

  selected = sample(selected, options.maxMutants, options.seed);

  const selectedByFile = new Map<string, Mutant[]>();
  for (const mutant of selected) {
    const list = selectedByFile.get(mutant.file) ?? [];
    list.push(mutant);
    selectedByFile.set(mutant.file, list);
  }

  const lineMap: Record<string, LineMapEntry[]> = {};
  const failedFiles = new Set<string>();

  const schemataDir = path.join(options.outDir, 'aut-schemata');
  for (const relPath of allFiles) {
    // Any error escaping this per-file step must name the relative file path (§6.4.9) -- this
    // step still aborts the run (unlike the tokenize step above), since a file reaching here
    // already tokenized and generated candidates successfully, so a failure here is unexpected.
    // The one expected failure mode -- rewriteAndVerify rejecting this file's mutants (B2/B2b) --
    // is handled below without throwing: it is recorded as a skip and the original file is
    // copied through unmutated, exactly like the tokenize-error path never aborts the run.
    try {
      const srcAbs = path.join(options.autDir, relPath);
      const destAbs = path.join(schemataDir, relPath);
      fs.mkdirSync(path.dirname(destAbs), { recursive: true });

      if (relPath === 'app.json') {
        const source = fs.readFileSync(srcAbs, 'utf8');
        fs.writeFileSync(destAbs, patchAppJson(source, options), 'utf8');
        continue;
      }

      const mutantsForFile = selectedByFile.get(relPath);
      if (mutantsForFile !== undefined) {
        const source = stripBom(fs.readFileSync(srcAbs, 'utf8'));
        const outcome = deps.rewriteAndVerify(source, mutantsForFile);
        if ('skipReason' in outcome) {
          allSkipped.push({ file: relPath, line: 0, reason: outcome.skipReason });
          failedFiles.add(relPath);
          fs.copyFileSync(srcAbs, destAbs);
        } else {
          fs.writeFileSync(destAbs, outcome.output, 'utf8');
          lineMap[relPath] = outcome.lineMap;
        }
      } else {
        fs.copyFileSync(srcAbs, destAbs);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      throw new Error(`${relPath}: ${message}`);
    }
  }

  // A file whose rewrite was rejected (B2/B2b) was copied unmutated above, so its mutants were
  // never actually applied -- exclude them from the manifest (their ids stay reserved, §6.4.8).
  if (failedFiles.size > 0) {
    selected = selected.filter((m) => !failedFiles.has(m.file));
  }

  const findings = lintSchemata(schemataDir);
  if (findings.length > 0) {
    const details = findings.map((f) => `${f.file}:${f.line}: ${f.text}`).join('\n');
    throw new Error(`lint failed with ${findings.length} finding(s):\n${details}`);
  }

  writeJsonFile(path.join(options.outDir, 'mutants.json'), selected.map(toManifestEntry));
  writeJsonFile(path.join(options.outDir, 'skipped.json'), allSkipped);
  writeJsonFile(path.join(options.outDir, 'linemap.json'), lineMap);

  return { mutants: selected, skipped: allSkipped, lineMap };
}
