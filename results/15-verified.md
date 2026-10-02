# Verified test fixes for run 15

## Verdicts

- verified: 45
- compile-failed: 1
- fails-on-original: 0
- not-killed: 0
- env-error: 0
- skipped-equivalent: 19

## Entries

- F001: verified, killed 2/2, revision 0
- F002: verified, killed 2/2, revision 1
- F003: verified, killed 1/1, revision 1
- F004: verified, killed 4/4, revision 2
- F005: verified, killed 1/1, revision 1
- F006: verified, killed 5/5, revision 1
- F007: verified, killed 4/4, revision 1
- F008: verified, killed 6/6, revision 1
- F009: verified, killed 4/4, revision 2
- F010: verified, killed 2/2, revision 2
- F011: verified, killed 4/4, revision 1
- F012: skipped-equivalent, killed 0/0, revision 0
- F013: skipped-equivalent, killed 0/0, revision 0
- F014: skipped-equivalent, killed 0/0, revision 0
- F015: skipped-equivalent, killed 0/0, revision 0
- F016: skipped-equivalent, killed 0/0, revision 0
- F017: skipped-equivalent, killed 0/0, revision 0
- F018: skipped-equivalent, killed 0/0, revision 0
- F019: skipped-equivalent, killed 0/0, revision 0
- F020: verified, killed 5/5, revision 0
- F021: verified, killed 6/6, revision 0
- F022: verified, killed 4/4, revision 1
- F023: skipped-equivalent, killed 0/0, revision 0
- F024: verified, killed 3/3, revision 0
- F025: verified, killed 2/2, revision 0
- F027: verified, killed 8/8, revision 0
- F028: verified, killed 2/2, revision 0
- F029: verified, killed 2/2, revision 0
- F030: skipped-equivalent, killed 0/0, revision 0
- F031: skipped-equivalent, killed 0/0, revision 0
- F032: verified, killed 1/1, revision 0
- F033: verified, killed 1/1, revision 0
- F034: verified, killed 1/1, revision 0
- F035: verified, killed 1/1, revision 0
- F036: verified, killed 1/1, revision 0
- F037: skipped-equivalent, killed 0/0, revision 0
- F038: verified, killed 2/2, revision 0
- F039: verified, killed 2/2, revision 0
- F040: verified, killed 1/1, revision 0
- F041: verified, killed 1/1, revision 0
- F042: verified, killed 1/1, revision 0
- F043: verified, killed 2/2, revision 0
- F044: verified, killed 1/1, revision 0
- F045: verified, killed 2/2, revision 0
- F046: verified, killed 6/6, revision 0
- F047: verified, killed 3/3, revision 0
- F048: verified, killed 1/1, revision 0
- F049: verified, killed 1/1, revision 0
- F050: skipped-equivalent, killed 0/0, revision 0
- F051: skipped-equivalent, killed 0/0, revision 0
- F052: skipped-equivalent, killed 0/0, revision 0
- F053: skipped-equivalent, killed 0/0, revision 0
- F054: verified, killed 1/1, revision 0
- F055: compile-failed, killed 0/0, revision 0
- F056: verified, killed 1/1, revision 0
- F057: verified, killed 2/2, revision 0
- F058: verified, killed 2/2, revision 0
- F059: skipped-equivalent, killed 0/0, revision 0
- F060: verified, killed 4/4, revision 0
- F061: verified, killed 5/5, revision 0
- F062: skipped-equivalent, killed 0/0, revision 0
- F063: verified, killed 1/1, revision 0
- F064: verified, killed 1/1, revision 0
- F065: verified, killed 1/1, revision 0
- F066: skipped-equivalent, killed 0/0, revision 0

## Not verified

### F055: compile-failed

- compile: Yapily\IntBatchDispTests.Codeunit.al(655): AL0185 Codeunit 'CTS-CB Fake Batch Strategy' is missing

## Applying the patch

Patch: results/15-tests.patch (45 verified entries). In the test-app root run:

    git apply -p1 <path-to>/15-tests.patch

Line numbers in the fixes come from the out/test-app snapshot (SPEC 6.7.5); procedures are located by name, so a drifted repository may still need a manual merge. After applying, re-run each changed test.
