import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assignIds, sample, stableKey } from '../src/manifest.js';
import type { MutantCandidate } from '../src/operators/types.js';

/** A minimal condition-target candidate, file attached (as the pipeline would attach it). */
function candidate(overrides: Partial<MutantCandidate> & { file: string }): MutantCandidate & { file: string } {
  const base: MutantCandidate = {
    operator: 'REL',
    objectType: 'codeunit',
    objectId: 50200,
    objectName: 'MUT Fx Order Mgt',
    procedureName: 'IsLargeOrder',
    line: 7,
    target: { kind: 'condition', cond: { kind: 'if', keywordIdx: 0, startIdx: 1, endIdx: 3, terminatorIdx: 4, position: 'statementList' } },
    original: 'Quantity >= 10',
    mutated: 'Quantity > 10',
    occurrence: 0,
  };
  return { ...base, ...overrides };
}

test('assignIds: ids are 1..N in input order across two files', () => {
  const candidates = [
    candidate({ file: 'a.al', line: 1 }),
    candidate({ file: 'a.al', line: 2 }),
    candidate({ file: 'b.al', line: 1 }),
  ];
  const mutants = assignIds(candidates);
  assert.deepEqual(
    mutants.map((m) => m.id),
    [1, 2, 3],
  );
  assert.equal(mutants[0]!.file, 'a.al');
  assert.equal(mutants[2]!.file, 'b.al');
});

test('assignIds: does not mutate the input array', () => {
  const candidates = [candidate({ file: 'a.al' })];
  const copy = [...candidates];
  assignIds(candidates);
  assert.deepEqual(candidates, copy);
});

test('stableKey: 16 hex characters', () => {
  const key = stableKey(candidate({ file: 'a.al' }));
  assert.match(key, /^[0-9a-f]{16}$/);
});

test('stableKey: stable under whitespace changes in the original', () => {
  const a = stableKey(candidate({ file: 'a.al', original: 'Quantity  >=   10' }));
  const b = stableKey(candidate({ file: 'a.al', original: 'Quantity >= 10' }));
  assert.equal(a, b);
});

test('stableKey: differs when the operator differs', () => {
  const a = stableKey(candidate({ file: 'a.al', operator: 'REL' }));
  const b = stableKey(candidate({ file: 'a.al', operator: 'BOOL' }));
  assert.notEqual(a, b);
});

test('stableKey: differs when occurrence differs', () => {
  const a = stableKey(candidate({ file: 'a.al', occurrence: 0 }));
  const b = stableKey(candidate({ file: 'a.al', occurrence: 1 }));
  assert.notEqual(a, b);
});

test('sample: n=3 seed=1 returns the same 3 ids on every call', () => {
  const mutants = assignIds(
    Array.from({ length: 10 }, (_, i) => candidate({ file: 'a.al', line: i + 1 })),
  );
  const first = sample(mutants, 3, 1).map((m) => m.id);
  const second = sample(mutants, 3, 1).map((m) => m.id);
  assert.deepEqual(first, second);
  assert.equal(first.length, 3);
});

test('sample: different seed yields a different sample', () => {
  const mutants = assignIds(
    Array.from({ length: 10 }, (_, i) => candidate({ file: 'a.al', line: i + 1 })),
  );
  const seed1 = sample(mutants, 3, 1).map((m) => m.id);
  const seed2 = sample(mutants, 3, 2).map((m) => m.id);
  assert.notDeepEqual(seed1, seed2);
});

test('sample: result is re-sorted by id', () => {
  const mutants = assignIds(
    Array.from({ length: 10 }, (_, i) => candidate({ file: 'a.al', line: i + 1 })),
  );
  const sampled = sample(mutants, 5, 42).map((m) => m.id);
  const sorted = [...sampled].sort((a, b) => a - b);
  assert.deepEqual(sampled, sorted);
});

test('sample: n=0 returns all mutants, sorted by id', () => {
  const mutants = assignIds(
    Array.from({ length: 5 }, (_, i) => candidate({ file: 'a.al', line: i + 1 })),
  );
  const sampled = sample(mutants, 0, 1);
  assert.deepEqual(
    sampled.map((m) => m.id),
    [1, 2, 3, 4, 5],
  );
});

test('sample: does not mutate the input array', () => {
  const mutants = assignIds(
    Array.from({ length: 5 }, (_, i) => candidate({ file: 'a.al', line: i + 1 })),
  );
  const copy = [...mutants];
  sample(mutants, 3, 1);
  assert.deepEqual(mutants, copy);
});

test('exclude-stable-keys removes mutants but does not renumber remaining ids', () => {
  const mutants = assignIds(
    Array.from({ length: 5 }, (_, i) => candidate({ file: 'a.al', line: i + 1, occurrence: i })),
  );
  const excludeKey = mutants[1]!.stableKey; // id 2
  const remaining = mutants.filter((m) => m.stableKey !== excludeKey);
  assert.deepEqual(
    remaining.map((m) => m.id),
    [1, 3, 4, 5],
  );
});
