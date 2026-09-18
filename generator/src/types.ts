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

/** §6.4.2: the object's `<type> <id> <name>` header line. */
export interface ObjectHeader {
  objectType: string;
  objectId: number;
  objectName: string;
}

/** §6.4.2: a `procedure`/`trigger` header plus its `begin … end` body, as token indices. */
export interface ProcedureSpan {
  name: string;
  kind: 'procedure' | 'trigger';
  headerStart: number;
  varKeywordIdx: number | null;
  beginIdx: number;
  endIdx: number;
}

/** §6.4.3: a call/assignment statement, as token indices; excludes its terminator. */
export interface SimpleStatement {
  startIdx: number;
  endIdx: number; // last token before the terminator
  terminator: 'semicolon' | 'none';
}

/** §6.4.3: an `if`/`until` condition, as token indices; excludes `then`/the until terminator. */
export interface Condition {
  kind: 'if' | 'until';
  keywordIdx: number;
  startIdx: number;
  endIdx: number; // last token of the condition
  terminatorIdx: number; // the `then`, or the `;`/`end`/`else`/`until` after an until-condition
  position: 'statementList' | 'other';
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
