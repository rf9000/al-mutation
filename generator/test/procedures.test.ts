import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenize } from '../src/tokenizer.js';
import { findObjectHeader, findProcedures } from '../src/procedures.js';

test('findObjectHeader parses type, id and name', () => {
  const tokens = tokenize('codeunit 50200 "MUT Fx Order Mgt"\n{\n}\n');
  const header = findObjectHeader(tokens);
  assert.deepEqual(header, {
    objectType: 'codeunit',
    objectId: 50200,
    objectName: 'MUT Fx Order Mgt',
  });
});

test('findObjectHeader returns null when the header does not match', () => {
  assert.equal(findObjectHeader(tokenize('')), null);
  assert.equal(findObjectHeader(tokenize('procedure Foo()')), null);
});

test('findProcedures: object-level var, two procedures (one with var, one without), a trigger', () => {
  const source = [
    'codeunit 50200 "MUT Fx Order Mgt"',
    '{',
    '    var',
    '        GlobalX: Integer;',
    '',
    '    procedure NoVars()',
    '    begin',
    '        Message(\'hi\');',
    '    end;',
    '',
    '    procedure WithVars()',
    '    var',
    '        Local: Integer;',
    '    begin',
    '        Local := 1;',
    '    end;',
    '',
    '    trigger OnRun()',
    '    begin',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const spans = findProcedures(tokens);

  assert.equal(spans.length, 3);

  const [noVars, withVars, onRun] = spans;

  assert.equal(noVars!.name, 'NoVars');
  assert.equal(noVars!.kind, 'procedure');
  assert.equal(noVars!.varKeywordIdx, null);
  assert.equal(tokens[noVars!.beginIdx]!.text, 'begin');
  assert.equal(tokens[noVars!.endIdx]!.text, 'end');
  assert.equal(tokens[noVars!.headerStart]!.text, 'procedure');

  assert.equal(withVars!.name, 'WithVars');
  assert.equal(withVars!.kind, 'procedure');
  assert.notEqual(withVars!.varKeywordIdx, null);
  assert.equal(tokens[withVars!.varKeywordIdx!]!.text, 'var');
  assert.equal(tokens[withVars!.beginIdx]!.text, 'begin');
  assert.equal(tokens[withVars!.endIdx]!.text, 'end');

  assert.equal(onRun!.name, 'OnRun');
  assert.equal(onRun!.kind, 'trigger');
  assert.equal(onRun!.varKeywordIdx, null);
  assert.equal(tokens[onRun!.beginIdx]!.text, 'begin');
  assert.equal(tokens[onRun!.endIdx]!.text, 'end');
});

test('findProcedures: nested begin/end and a case block — endIdx is the outer end', () => {
  const source = [
    'codeunit 50201 "X"',
    '{',
    '    procedure P(): Integer',
    '    begin',
    '        if true then begin',
    '            case 1 of',
    '                1:',
    '                    exit(1);',
    '                else',
    '                    exit(0);',
    '            end;',
    '        end;',
    '        exit(2);',
    '    end;',
    '}',
    '',
  ].join('\n');
  const tokens = tokenize(source);
  const spans = findProcedures(tokens);

  assert.equal(spans.length, 1);
  const [p] = spans;
  assert.equal(tokens[p!.beginIdx]!.text, 'begin');
  assert.equal(tokens[p!.endIdx]!.text, 'end');
  // the outer `end` is the one immediately followed by `;` then `}` (the object close brace).
  const afterEnd = tokens[p!.endIdx + 1]!;
  assert.equal(afterEnd.text, ';');
  const afterSemicolon = tokens[p!.endIdx + 2]!;
  assert.equal(afterSemicolon.text, '}');
});
