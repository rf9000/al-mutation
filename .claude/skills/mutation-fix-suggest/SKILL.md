---
name: mutation-fix-suggest
description: Suggest AL test fixes for the surviving mutants of a mutation run and write the machine-readable fix report results/<RunNo>-fixes.json (plus fixes.md). Use when asked to "suggest fixes for surviving mutants", produce a "mutation fix report", "map AL test fixes to mutants", or run /mutation-fix-suggest <RunNo>.
---

# Suggest test fixes for surviving mutants

Invoked as `/mutation-fix-suggest <RunNo>`. A surviving mutant is a deliberate change in the app under test (AUT) that no
test noticed. For each one you suggest the test change that would catch it, or argue it is equivalent. A separate agent
applies the suggestions later, so precision matters more than speed.

Full rules: `docs/SPEC.md` §6.7.3 (procedure), §6.7.4 (validation rules, your output must satisfy all of them), §7.7 (brief
schema), §7.8 (report schema). This skill is the working summary.

## Hard rules

- Suggest only. Never compile, publish or run anything; no environment or DemoPortal calls.
- Never edit AUT sources, test-app sources, or anything under `out/`. Read them only.
- The only files you write are `results/<N>-fixes.json`, `results/<N>-fixes.md` (by the validator) and scratch part files
  outside the repo (use the session scratchpad).

## Paths and shell

The paths and commands in this skill use the defaults. Two environment variables, and the platform, change them:

- `results/` means the results folder: `$MUT_RESULTS_DIR` when that variable is set, else `results/` under the repo root.
  This applies to every `results/<N>-...` path below, including the ones in python snippets.
- `out/` means the work folder: `$MUT_WORK_DIR` when that variable is set, else the config's `workDir`.
- `powershell` means Windows PowerShell on Windows. On Linux, run the same command with `pwsh`.

Check them once at the start, for example with `pwsh -NoProfile -Command '$env:MUT_RESULTS_DIR; $env:MUT_WORK_DIR'` (or
`powershell` on Windows).

## Headless runs

If the prompt contains `HEADLESS RUN`, nobody is watching. Run unattended (SPEC §6.9.6):

- Never ask the user anything. Decide and continue.
- Take the config path from the prompt line `Config file: <cfg>`. Use it for every `-ConfigPath`.
- Finish only when `powershell -NoProfile -File orchestrator/Test-MutFixReport.ps1 -RunNo <N>` prints `ok`.
- Every hard rule above still applies.

Without `HEADLESS RUN`, if you need a config file and none is given, ask the user which one.

## Prerequisite

If `results/<N>-fix-briefs.json` is missing, create it (works on any past run, no environment needed):

```
powershell -NoProfile -File orchestrator/Export-MutFixBriefs.ps1 -ConfigPath <config> -RunNo <N>
```

## Reading the brief without flooding context

The brief and the test files can be huge; do not load them whole. The brief has a UTF-8 BOM, so use a short python script:

```python
import json
b = json.load(open('results/15-fix-briefs.json', encoding='utf-8-sig'))
for s in b['survivors']:            # filter to your batch ids
    print(s['mutantId'], s['procedure'], s['resolvedLine'], s['operator'], s['original'], '->', s['mutated'])
```

Print `context.text` only when needed. Print each covering codeunit's procedure list (name, startLine, endLine) once.
Read test files (`<testAppPath>/<coveringTests[].file>`) and AUT files (`<autPath>/<file>`) in chunks with offset/limit.
If `sourceDrift` is true, trust `context.text` over `line`; if `resolvedLine` is null, say so in the rationale and lower
the confidence.

## Procedure

1. Read the brief. Group survivors by covering test codeunit (first `coveringTests` entry).
2. For each survivor, find which existing test procedure executes the mutated line, with which inputs, and what it
   asserts. Read the libraries, fakes and handlers it uses. Then pick a verdict (below).
3. Mutants killed by the same change share one entry (several `mutantIds`). Every survivor id appears in exactly one
   entry; never name an id that is not a survivor.
4. Write `results/<N>-fixes.json` as `{ "runNo": N, "generatedUtc": "<UTC ISO>", "fixes": [...] }` (python
   `json.dump(indent=2, ensure_ascii=False)`), then validate (below).

### Fan-out for large runs

With more than ~30 survivors, split into batches by covering test codeunit (and by AUT procedure inside a big codeunit),
roughly 10-25 survivors each. Spawn one subagent per batch (in parallel). Give each: the batch id, its mutant ids, its
covering codeunit(s), the pointer to SPEC §6.7.3/§6.7.4/§7.8, the hard rules above, and this procedure. Each subagent
writes `{ "fixes": [...] }` to a scratch part file `fixes-part-<BATCH>.json`, using fixIds `<BATCH>001`, ... and a
**per-batch prefix in new-test procedure names** so names stay unique across batches. Each self-checks (all batch ids
present exactly once, enums valid, add-assert anchors inside the procedure range, new-test code contains `[Test]` and
`procedure <name>(`) and reports counts per verdict/confidence plus low-confidence entries. Then merge: concatenate the
`fixes`, renumber `fixId` to `F001`, `F002`, ... in order, wrap as `{ runNo, generatedUtc, fixes }`, write to
`results/<N>-fixes.json`.

## Validate until ok

```
powershell -NoProfile -File orchestrator/Test-MutFixReport.ps1 -RunNo <N>
```

Each error line starts with the fixId (or `report`). Fix them in the JSON and re-run until it prints `ok` (exit 0); that
run also writes `results/<N>-fixes.md`.

## Mutation runtime facts

Check these before calling a mutant equivalent or designing a test.

- COND mutants replace the whole condition, including calls. `if X.FindLast() then` -> `if true then` means `FindLast`
  never runs, so the record is not positioned by it and keeps whatever position the caller left. Look at
  `out/runs/<N>/gen/aut-schemata/` to see how a mutant actually compiles.
- AL `and`/`or` do not short-circuit: both operands always run, including calls with var parameters and side effects.
- Test sessions run in restricted permission mode, not SUPER. Permission guards (`WritePermission()`) are testable by
  lowering permissions with the test library. A codeunit's `Permissions` property only turns the user's indirect
  permission into success; it does not give a read-only user write rights. `WritePermission()` means Insert, Modify and
  Delete together. Before lowering permissions, find every other write on the path (caches, logs) and seed or avoid it,
  or the test fails on the original.
- The build runs CodeCop as errors. Declare `var` sections in type order (AA0021: Record, Report, Codeunit, XmlPort,
  Page, Query, Notification, ... then any order), with no unused variables (AA0137) and one statement per line.
- A test that silently `exit`s on a missing precondition (for example only one company) kills nothing: make it fail with
  an explicit error and state the environment requirement in the rationale.
- "Equivalent" needs proof that no input can tell the two versions apart. Public interfaces and test fakes widen what is
  observable, so do not argue only from the shipped implementations.
- `Init()` keeps primary-key fields. Reset an AutoIncrement key to 0 before reusing a record variable for a second
  `Insert`, or the insert reuses the first key and raises a duplicate-key error.

## Entry shape

`fixId`, `mutantIds`, `verdict`, `target` `{ codeunitId, codeunitName, file, procedure, isNewProcedure }`, `change`,
`anchor` `{ afterLine }` or null, `alCode`, `rationale`, `expectedEffect`, `confidence`.
`target.codeunitId` must be a covering codeunit of every mutant in the entry; `target.file` is the brief's file path.

## Verdicts and change kinds

**fix + add-assert.** An existing test reaches the mutated line with an input where original and mutant behave
differently, but does not assert the difference. `alCode` = only the lines to insert; `anchor.afterLine` = the line after
which they go, inside that procedure's `[startLine, endLine]`. Use ONLY variables the procedure already declares; if you
need a new variable, use modify-test. Example: mutant `Count() > 0` -> `>= 0`; the test runs with no matching accounts
but never checks the buffer. alCode: `        Assert.RecordIsEmpty(TempAuthShareTarget);`.

**fix + modify-test.** The existing test needs a different input or new variables. `alCode` = the complete replacement
procedure including its attribute lines; `anchor` null. Example: test uses Quantity 100 for `Quantity >= 10`; replace it
with a version using exactly 10 and asserting `IsLargeOrder` is true.

**new-test.** No test reaches the line with a distinguishing input. `change` = `new-test`, `isNewProcedure` = true,
`anchor` null. `alCode` = a complete new procedure with `[Test]`, in the codeunit's own style (its `Assert` variable,
libraries, fakes, handler functions, GIVEN/WHEN/THEN comments). The name is unique, descriptive, contains the AUT
procedure name, and is not already in the codeunit (use the batch prefix when fanning out). Example: nothing covers the
`else` branch of `PostLine`; add `[Test] procedure PostLine_NegativeAmount_RaisesError()` that asserts the error.

**equivalent.** No test can observe the difference, with a concrete reason (e.g. "`Count() > 0` and `Count() >= 1` are
identical for integers"). `target`, `change`, `anchor` = null and `alCode` = `""`. Use sparingly; when unsure, prefer
new-test with low confidence.

## Wording and style

- `rationale`: name the mutated line and say why the current tests miss it.
- `expectedEffect`: "fails on mutant N because ...; passes on the original because ...". Must be non-empty for fix and
  new-test.
- `confidence`: `high` | `medium` | `low`, honestly. Low when the fixture setup is unclear, the line is hard to reach, or
  you could not trace the inputs.
- AL style: one statement per line, 4-space indentation matching the file, labels and text constants the way the
  codeunit does them, declare every new variable, reuse the codeunit's `Assert` variable and helpers. Use only
  identifiers that exist in the codeunit or that your code declares.

## Downstream note

The consuming agent locates procedures by name; line numbers refer to the `out/test-app` snapshot and are advisory (SPEC
§6.7.5). Do not try to compensate for drift beyond what the brief reports.
