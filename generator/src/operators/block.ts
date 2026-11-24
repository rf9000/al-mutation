import type { Block, Condition, SimpleStatement } from '../types.js';
import type { MutantCandidate, Operator, OperatorContext } from './types.js';

/** The rest of the physical line from `offset`, without the line break or trailing blanks. */
function restOfLine(source: string, offset: number): string {
  const newlineIdx = source.indexOf('\n', offset);
  return source.slice(offset, newlineIdx === -1 ? source.length : newlineIdx).trimEnd();
}

/**
 * §6.4.5 BLOCK: a nested `begin … end` block is emptied (one candidate per block). `mutated`
 * is `begin end`. `line` is the block's first statement, not its `begin`: coverage only reports
 * code lines, and a `begin` line has none. `original` is that statement's line, from its first
 * token on: the orchestrator's reports and fix briefs need a single line found on `line`.
 */
export const BLOCK: Operator = {
  name: 'BLOCK',
  kind: 'block',
  apply(ctx: OperatorContext, target: Condition | SimpleStatement | Block): MutantCandidate[] {
    const block = target as Block;
    const first = ctx.tokens[block.firstIdx]!;
    return [
      {
        operator: 'BLOCK',
        objectType: ctx.header.objectType,
        objectId: ctx.header.objectId,
        objectName: ctx.header.objectName,
        procedureName: ctx.span.name,
        line: first.line,
        target: { kind: 'block', block },
        original: restOfLine(ctx.source, first.start),
        mutated: 'begin end',
        occurrence: 0,
      },
    ];
  },
};
