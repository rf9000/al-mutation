import * as fs from 'node:fs';
import * as path from 'node:path';

/** §6.4.10 */
export interface LintFinding {
  file: string;
  line: number;
  text: string;
}

const SKIP_DIR_NAMES: ReadonlySet<string> = new Set(['.alpackages', '.snapshots', 'node_modules']);

/** Recursively lists `.al` files under `dir`, as relative paths with forward slashes, sorted. */
function listAlFiles(dir: string): string[] {
  const results: string[] = [];

  function walk(current: string, relPrefix: string): void {
    const entries = fs.readdirSync(current, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (SKIP_DIR_NAMES.has(entry.name)) continue;
        walk(path.join(current, entry.name), relPrefix === '' ? entry.name : `${relPrefix}/${entry.name}`);
      } else if (entry.isFile() && /\.al$/i.test(entry.name)) {
        results.push(relPrefix === '' ? entry.name : `${relPrefix}/${entry.name}`);
      }
    }
  }

  walk(dir, '');
  return results.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

const KEYWORD_BEFORE = /\b(?:and|or|xor)\b\s*MutationCore\.Active\(/i;
const KEYWORD_AFTER = /MutationCore\.Active\([^()]*\)\s*\b(?:and|or|xor)\b/i;

/**
 * True when `MutationCore.Active(` appears with an already-open, different
 * call's parenthesis before it on the line (a `(` that is not its own).
 */
function hasNestedActiveCall(line: string): boolean {
  const lower = line.toLowerCase();
  const marker = 'mutationcore.active(';
  let depth = 0;
  let i = 0;
  while (i < line.length) {
    if (lower.startsWith(marker, i)) {
      if (depth > 0) return true;
      depth++;
      i += marker.length;
      continue;
    }
    const ch = line[i];
    if (ch === '(') depth++;
    else if (ch === ')') depth = Math.max(0, depth - 1);
    i++;
  }
  return false;
}

function isBadLine(line: string): boolean {
  if (!/MutationCore\.Active\(/i.test(line)) return false;
  return KEYWORD_BEFORE.test(line) || KEYWORD_AFTER.test(line) || hasNestedActiveCall(line);
}

/**
 * §6.4.10: scans every `.al` file under `dir` and reports any line where
 * `MutationCore.Active(` is preceded/followed (same line, ignoring
 * whitespace) by `and`/`or`/`xor`, or appears nested inside another call's
 * parenthesised argument list.
 */
export function lintSchemata(dir: string): LintFinding[] {
  const findings: LintFinding[] = [];

  for (const relPath of listAlFiles(dir)) {
    const content = fs.readFileSync(path.join(dir, relPath), 'utf8');
    const lines = content.split(/\r\n|\n/);
    lines.forEach((lineText, index) => {
      if (isBadLine(lineText)) {
        findings.push({ file: relPath, line: index + 1, text: lineText });
      }
    });
  }

  return findings;
}
