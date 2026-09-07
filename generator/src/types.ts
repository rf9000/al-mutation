export type TokenKind =
  | 'identifier'
  | 'quotedIdentifier'
  | 'keyword'
  | 'string'
  | 'number'
  | 'comment'
  | 'preprocessor'
  | 'operator'
  | 'punct';

export interface Token {
  kind: TokenKind;
  text: string;
  start: number;
  end: number;
  line: number;
  column: number;
}

export const KEYWORDS: ReadonlySet<string> = new Set([
  'procedure',
  'trigger',
  'var',
  'begin',
  'end',
  'if',
  'then',
  'else',
  'while',
  'do',
  'repeat',
  'until',
  'case',
  'of',
  'for',
  'to',
  'downto',
  'foreach',
  'in',
  'exit',
  'not',
  'and',
  'or',
  'xor',
  'div',
  'mod',
  'true',
  'false',
  'local',
  'internal',
  'protected',
]);
