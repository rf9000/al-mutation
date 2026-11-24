import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { generate } from '../src/generate.js';
import type { GenerateOptions } from '../src/generate.js';
import { OPERATOR_ORDER } from '../src/operators/index.js';
import { tokenize } from '../src/tokenizer.js';

const APP_JSON = JSON.stringify(
  {
    id: '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4e',
    name: 'Later Operators Fixture',
    publisher: 'Continia Software',
    version: '1.0.0.0',
    dependencies: [],
    idRanges: [{ from: 50200, to: 50299 }],
    platform: '28.0.0.0',
    application: '28.0.0.0',
    runtime: '17.0',
    target: 'Cloud',
  },
  null,
  2,
);

const CODEUNIT = `codeunit 50230 "Later Ops"
{
    procedure Post(var Rec: Record Customer; Flag: Boolean): Boolean
    var
        Done: Boolean;
    begin
        Rec.TestField(Name);
        if Flag then begin
            Rec.Insert();
            Rec.Modify();
        end;
        while not Done do begin
            Done := true;
        end;
        exit(true);
    end;
}
`;

function setup(operators: GenerateOptions['operators']): { result: ReturnType<typeof generate>; outDir: string } {
  const autDir = fs.mkdtempSync(path.join(os.tmpdir(), 'al-mutation-later-aut-'));
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'al-mutation-later-out-'));
  fs.writeFileSync(path.join(autDir, 'app.json'), APP_JSON);
  fs.mkdirSync(path.join(autDir, 'src'));
  fs.writeFileSync(path.join(autDir, 'src', 'LaterOps.Codeunit.al'), CODEUNIT);
  const result = generate({
    autDir,
    outDir,
    coreAppId: '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b',
    coreAppVersion: '1.0.0.0',
    maxMutants: 0,
    seed: 1,
    onlyObjects: [],
    operators,
    includeBreak: false,
    excludeStableKeys: [],
  });
  return { result, outDir };
}

test('generate(): RET, BLOCK and DEL on TestField come out of a real file, while body skipped', () => {
  const { result, outDir } = setup([...OPERATOR_ORDER]);

  const byOp = (op: string) => result.mutants.filter((m) => m.operator === op);
  assert.ok(byOp('DEL').some((m) => m.original === 'Rec.TestField(Name)'));
  assert.deepEqual(byOp('RET').map((m) => m.mutated), ['exit(false)']);

  const blocks = byOp('BLOCK');
  assert.equal(blocks.length, 1, 'only the then-block; the while body is excluded');
  assert.equal(blocks[0]!.line, 9);
  assert.ok(result.skipped.some((s) => s.reason === 'while-loop-body' && s.line === 12));

  const schemata = fs.readFileSync(path.join(outDir, 'aut-schemata', 'src', 'LaterOps.Codeunit.al'), 'utf8');
  assert.match(schemata, new RegExp(`then begin if not MutationCore\\.Active\\(${blocks[0]!.id}\\) then begin`));
  assert.doesNotThrow(() => tokenize(schemata));
});

test('generate(): BLOCK and RET are left out when not in the operators list', () => {
  const { result } = setup(['REL', 'BOOL', 'NOT', 'COND', 'DEL', 'INSFLAG']);
  assert.equal(result.mutants.filter((m) => m.operator === 'BLOCK' || m.operator === 'RET').length, 0);
});
