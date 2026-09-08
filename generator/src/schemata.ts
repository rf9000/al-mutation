import { tokenize } from './tokenizer.js';
import { findProcedures } from './procedures.js';
import type { Condition, ProcedureSpan, SimpleStatement, Token } from './types.js';
import type { MutantCandidate } from './operators/types.js';

/**
 * §6.4.7: one guard block in the rewritten output — either a condition block
 * (Shape B, inserted before `if`/`until`) or a statement block (Shape A,
 * replacing a simple statement's span). `startLine`/`endLine` are 1-based
 * line numbers in the **output**, spanning from the block's `case true of`
 * line to its closing `end;`/`end` line (inclusive).
 */
export interface LineMapEntry {
  mutantIds: number[];
  startLine: number;
  endLine: number;
}

/** An edit on the original source: replace `[start, end)` with `text`. */
interface Edit {
  start: number;
  end: number;
  text: string;
  /** Present only for the edit that emits a `case true of … end` guard block. */
  block?: { mutantIds: number[]; coreNewlines: number };
}

interface ConditionGroup {
  cond: Condition;
  candidates: MutantCandidate[];
}

interface StatementGroup {
  stmt: SimpleStatement;
  candidates: MutantCandidate[];
}

interface ProcGroup {
  proc: ProcedureSpan;
  conditions: Map<string, ConditionGroup>;
  statements: Map<string, StatementGroup>;
}

function isSignificant(token: Token): boolean {
  return token.kind !== 'comment' && token.kind !== 'preprocessor';
}

function countNewlines(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 10 /* \n */) count++;
  }
  return count;
}

/**
 * §6.4.7's "the same indentation" rule: the whitespace between the previous
 * newline and `tokenStart`, i.e. the indentation of the line `tokenStart`
 * sits on.
 */
function lineIndent(source: string, tokenStart: number): string {
  const newlineIdx = source.lastIndexOf('\n', tokenStart - 1);
  return source.slice(newlineIdx + 1, tokenStart);
}

function previousSignificantToken(tokens: readonly Token[], fromIdx: number): Token | undefined {
  for (let i = fromIdx; i >= 0; i--) {
    const tok = tokens[i]!;
    if (isSignificant(tok)) return tok;
  }
  return undefined;
}

function sortById(candidates: readonly MutantCandidate[]): MutantCandidate[] {
  return [...candidates].sort((a, b) => a.id! - b.id!);
}

/**
 * §6.4.7: turns `source` plus its assigned-id `candidates` into the schemata
 * source, guarding every mutant with `case true of MutationCore.Active(<id>)`
 * (F4: `case` is the only documented lazy construct, so this is the only
 * guard template used — never `and`/`or`/`xor` next to `Active(`, F1).
 */
export function rewriteFile(
  source: string,
  candidates: readonly MutantCandidate[],
): { output: string; lineMap: LineMapEntry[] } {
  for (const candidate of candidates) {
    if (candidate.id === undefined) {
      throw new Error(
        `rewriteFile: candidate for procedure "${candidate.procedureName}" (operator ${candidate.operator}, line ${candidate.line}) has no id assigned`,
      );
    }
  }

  const eol = source.includes('\r\n') ? '\r\n' : '\n';
  const tokens = tokenize(source);
  const procedures = findProcedures(tokens);

  function findEnclosingProcedure(tokenIdx: number): ProcedureSpan {
    const proc = procedures.find((p) => tokenIdx >= p.beginIdx && tokenIdx <= p.endIdx);
    if (!proc) {
      throw new Error(`rewriteFile: no enclosing procedure found for token index ${tokenIdx}`);
    }
    return proc;
  }

  // --- Group candidates by procedure, then by target span (§6.4.7 decisions). ---
  const procGroups = new Map<ProcedureSpan, ProcGroup>();

  for (const candidate of candidates) {
    const tokenIdx =
      candidate.target.kind === 'condition'
        ? candidate.target.cond.startIdx
        : candidate.target.stmt.startIdx;
    const proc = findEnclosingProcedure(tokenIdx);

    let group = procGroups.get(proc);
    if (!group) {
      group = { proc, conditions: new Map(), statements: new Map() };
      procGroups.set(proc, group);
    }

    if (candidate.target.kind === 'condition') {
      const cond = candidate.target.cond;
      const key = `${cond.startIdx}:${cond.endIdx}`;
      let condGroup = group.conditions.get(key);
      if (!condGroup) {
        condGroup = { cond, candidates: [] };
        group.conditions.set(key, condGroup);
      }
      condGroup.candidates.push(candidate);
    } else {
      const stmt = candidate.target.stmt;
      const key = `${stmt.startIdx}:${stmt.endIdx}`;
      let stmtGroup = group.statements.get(key);
      if (!stmtGroup) {
        stmtGroup = { stmt, candidates: [] };
        group.statements.set(key, stmtGroup);
      }
      stmtGroup.candidates.push(candidate);
    }
  }

  const edits: Edit[] = [];

  for (const group of procGroups.values()) {
    // §6.4.7 "Declarations": MutCond_<n> blocks are numbered 1..N per
    // procedure, in source order (by the condition's startIdx).
    const condGroupsInOrder = [...group.conditions.values()].sort(
      (a, b) => a.cond.startIdx - b.cond.startIdx,
    );
    const condNumberByKey = new Map<string, number>();
    const declLines: string[] = ['MutationCore: Codeunit "MUT Mut";'];
    condGroupsInOrder.forEach((condGroup, index) => {
      const n = index + 1;
      condNumberByKey.set(`${condGroup.cond.startIdx}:${condGroup.cond.endIdx}`, n);
      declLines.push(`MutCond_${n}: Boolean;`);
    });

    const beginTok = tokens[group.proc.beginIdx]!;
    const beginIndent = lineIndent(source, beginTok.start);
    let declText: string;
    if (group.proc.varKeywordIdx === null) {
      // No `var` section: insert `    var` (at begin's own indentation) plus
      // the declarations (begin's indentation + 4) before `begin`.
      const lines = ['var', ...declLines.map((l) => beginIndent + '    ' + l)];
      declText = lines.join(eol) + eol + beginIndent;
    } else {
      // Existing `var` section: append the declarations (begin's indentation
      // + 4) right before `begin`; the first line reuses begin's own
      // preceding whitespace, so it only needs one extra indent level.
      const lines = declLines.map((l, index) =>
        index === 0 ? '    ' + l : beginIndent + '    ' + l,
      );
      declText = lines.join(eol) + eol + beginIndent;
    }
    edits.push({ start: beginTok.start, end: beginTok.start, text: declText });

    // --- Condition guards (Shape B, §6.4.7). ---
    for (const condGroup of condGroupsInOrder) {
      const cond = condGroup.cond;
      const n = condNumberByKey.get(`${cond.startIdx}:${cond.endIdx}`)!;
      const sorted = sortById(condGroup.candidates);
      const anchorTok = tokens[cond.keywordIdx]!;
      const indent = lineIndent(source, anchorTok.start);
      const originalText = source.slice(tokens[cond.startIdx]!.start, tokens[cond.endIdx]!.end);

      const lines: string[] = ['case true of'];
      for (const candidate of sorted) {
        lines.push(indent + '    ' + `MutationCore.Active(${candidate.id!}):`);
        lines.push(indent + '        ' + `MutCond_${n} := ${candidate.mutated};`);
      }
      lines.push(indent + '    ' + 'else');
      lines.push(indent + '        ' + `MutCond_${n} := ${originalText};`);
      lines.push(indent + 'end;');
      const coreText = lines.join(eol);

      edits.push({
        start: anchorTok.start,
        end: anchorTok.start,
        text: coreText + eol + indent,
        block: { mutantIds: sorted.map((c) => c.id!), coreNewlines: countNewlines(coreText) },
      });

      edits.push({
        start: tokens[cond.startIdx]!.start,
        end: tokens[cond.endIdx]!.end,
        text: `MutCond_${n}`,
      });

      if (cond.kind === 'until') {
        const prevTok = previousSignificantToken(tokens, cond.keywordIdx - 1);
        const alreadyTerminated =
          prevTok !== undefined &&
          ((prevTok.kind === 'punct' && prevTok.text === ';') ||
            (prevTok.kind === 'keyword' && prevTok.text.toLowerCase() === 'repeat'));
        if (prevTok !== undefined && !alreadyTerminated) {
          edits.push({ start: prevTok.end, end: prevTok.end, text: ';' });
        }
      }
    }

    // --- Statement guards (Shape A, §6.4.7). ---
    for (const stmtGroup of group.statements.values()) {
      const stmt = stmtGroup.stmt;
      const sorted = sortById(stmtGroup.candidates);
      const startTok = tokens[stmt.startIdx]!;
      const endTok = tokens[stmt.endIdx]!;
      const indent = lineIndent(source, startTok.start);
      const originalText = source.slice(startTok.start, endTok.end);

      const lines: string[] = ['case true of'];
      for (const candidate of sorted) {
        lines.push(indent + '    ' + `MutationCore.Active(${candidate.id!}):`);
        if (candidate.operator === 'DEL') {
          lines.push(indent + '        ' + 'begin');
          lines.push(indent + '        ' + 'end;');
        } else {
          lines.push(indent + '        ' + `${candidate.mutated};`);
        }
      }
      lines.push(indent + '    ' + 'else');
      lines.push(indent + '        ' + `${originalText};`);
      lines.push(indent + 'end');
      const coreText = lines.join(eol);

      edits.push({
        start: startTok.start,
        end: endTok.end,
        text: coreText,
        block: { mutantIds: sorted.map((c) => c.id!), coreNewlines: countNewlines(coreText) },
      });
    }
  }

  // §6.4.7: "computes all edits ... sorts by start descending, and applies
  // them, so offsets stay valid." Equivalently (and to compute the lineMap
  // in the same pass), we build the output by copying ascending and tracking
  // the output line number as we go.
  edits.sort((a, b) => a.start - b.start);

  let output = '';
  let cursor = 0;
  let outputLine = 1;
  const lineMap: LineMapEntry[] = [];

  for (const edit of edits) {
    const before = source.slice(cursor, edit.start);
    output += before;
    outputLine += countNewlines(before);

    const startLine = outputLine;
    output += edit.text;
    outputLine += countNewlines(edit.text);

    if (edit.block) {
      lineMap.push({
        mutantIds: edit.block.mutantIds,
        startLine,
        endLine: startLine + edit.block.coreNewlines,
      });
    }

    cursor = edit.end;
  }
  output += source.slice(cursor);

  return { output, lineMap };
}
