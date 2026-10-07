---
name: mutation-fix-verify
description: Verify the suggested AL test fixes of a mutation run on the environment, repair the failing ones with subagents, and deliver a patch of verified fixes only. Use when asked to "verify the suggested fixes", "apply mutation fixes", "make a verified test patch", or run /mutation-fix-verify <RunNo>.
---

# Verify, repair and deliver suggested test fixes

Invoked as `/mutation-fix-verify <RunNo>`. Input is `results/<N>-fixes.json` from `mutation-fix-suggest`. Output is
`results/<N>-verified.json`, `results/<N>-verified.md` and `results/<N>-tests.patch` (verified entries only).
A fix is **verified** when the patched test app compiles, the changed test passes on the unmutated AUT, and every mutant
the entry names is killed by that test. Full rules: `docs/SPEC.md` §6.8 (procedure) and §7.9 (verified schema).

## Hard rules

- One test job at a time. Never run two verify scripts, or any other environment command, concurrently.
- Never write the test-app repository (`testApp.sourcePath`) or anything under `out/test-app`. The tools work on copies
  in `<workDir>/fix-verify/<N>/`.
- Use the config the mutation run used (for example `mutation.u2.config.json`), so environment and settle probe match.
- Environment time: about 10 s per test job and about 80 s per test-app publish. Budget for it and run long steps in
  the background. The verify script always ends by republishing the unpatched test app and confirming
  `activeMutantId = 0`.
- `equivalent` entries are never applied (verdict `skipped-equivalent`).
- Repair agents edit only their own entry in `fixes.json`. Never use more than 2 repair rounds.

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
- Take the config path from the prompt line `Config file: <cfg>`. Use it for every `-ConfigPath` and for
  `Export-MutFixDelivery -Config <cfg>`.
- The prompt gives the fix ids. Run Step 1 with `-FixIds <the given ids>` instead of all entries. Do the repair rounds
  and the combined check for those ids only. Then deliver.
- If a script fails with `environment locked by ...`, stop and write a short report. Do not wait and do not retry.
- Every hard rule above still applies: one environment job at a time, never write `testApp.sourcePath` or
  `out/test-app`, equivalent entries are never applied, repair agents edit only their own entry, at most 2 repair rounds.

Without `HEADLESS RUN`, if the config file is not given, ask the user which one.

## Prerequisites

1. `results/<N>-fixes.json` exists and `powershell -NoProfile -File orchestrator/Test-MutFixReport.ps1 -RunNo <N>`
   prints `ok`.
2. `results/<N>-fix-briefs.json` exists (else `orchestrator/Export-MutFixBriefs.ps1 -ConfigPath <config> -RunNo <N>`).
3. You know the config file of the run (`<config>` below). If it is not given, ask the user which one (headless: see above).

## Step 1: full verify

Headless: add `-FixIds <the given ids>` to this command.

```
powershell -NoProfile -File orchestrator/Invoke-MutFixVerify.ps1 -ConfigPath <config> -RunNo <N>
```

Exit 0 means the step completed whatever the verdicts. Read `results/<N>-verified.json` (a UTF-8 file; print only
`fixId`, `revision`, `verdict` first, then the evidence of failing entries). Verdicts: `verified`, `compile-failed`,
`fails-on-original`, `not-killed`, `env-error`, `skipped-equivalent`.

## Step 2: repair rounds (at most 2)

Round = repair every entry with verdict `compile-failed`, `fails-on-original` or `not-killed`, then re-verify.

1. Spawn one subagent per failed entry (parallel is fine: they only edit JSON and read files; the environment is used
   by you alone afterwards). Use the prompt template below.
2. Each agent writes its repaired entry; you merge it into `results/<N>-fixes.json` (replace the entry with the same
   `fixId`, nothing else) and run `powershell -NoProfile -File orchestrator/Test-MutFixReport.ps1 -RunNo <N>` until `ok`.
   Send validation errors back to the agent that owns the entry.
3. Re-verify only the repaired ids:
   `powershell -NoProfile -File orchestrator/Invoke-MutFixVerify.ps1 -ConfigPath <config> -RunNo <N> -FixIds F022,F031`
   (comma-separated). Results merge into `verified.json` by fixId.
4. `env-error` entries are re-run with `-FixIds`, never rewritten. A second env-error in a row: report it, stop.
5. Entries still failing after round 2 stay as they are; their evidence goes into `verified.md`.

### Repair-agent prompt template

Fill the `<...>` parts. Get the brief entries with a short python script (the brief has a BOM:
`json.load(open(p, encoding='utf-8-sig'))`) and filter `survivors` to the entry's `mutantIds`.

```
You repair one suggested AL test fix for a mutation-testing run. You cannot run anything; you reason from the files.

ENTRY (from results/<N>-fixes.json, revision <R>):
<the entry JSON>

BRIEF for its mutants (from results/<N>-fix-briefs.json, survivors with these mutantIds):
<the brief survivor objects>

EVIDENCE from the environment (results/<N>-verified.json, exact text):
<compile diagnostics | the original-run error | surviving mutant ids with the per-mutant outcomes>

MUTATION RUNTIME FACTS: <paste the "Mutation runtime facts" section of .claude/skills/mutation-fix-suggest/SKILL.md>

Read the test file (<testAppPath>/<target.file>) and the AUT file in chunks. Diagnostics point to the patched copy: the
entry's inserted lines start where the entry was inserted, so map a diagnostic line back to your alCode.

Rules:
- Keep the fixId. Set "revision" to <R+1>.
- Append to "rationale" the evidence you answered and what you changed ("Rev <R+1>: compile error AL0118 ... fixed by ...").
- Fix the cause shown by the evidence; do not just retry. A not-killed entry needs a test that fails under the
  surviving mutant; a fails-on-original entry must pass on the unmutated code (check permissions, preconditions, data).
- Or give up: set verdict "equivalent" with a proof that no input distinguishes the versions (target, change, anchor =
  null, alCode = ""), or leave the entry unchanged and say why in your answer.
- Edit only this entry. Output the complete repaired entry as JSON in your answer (no other file edits).
Keep the schema of docs/SPEC.md §7.8 (target, change, anchor, alCode, rationale, expectedEffect, confidence).
```

## Step 3: combined check

Entries verified apart can clash (same procedure, same anchor, shared state). Run once on the whole verified set:

```
powershell -NoProfile -File orchestrator/Invoke-MutFixVerify.ps1 -ConfigPath <config> -RunNo <N> -FixIds <all verified ids, comma-separated>
```

An entry that fails here goes back into the repair loop if rounds are left (give the agent the new evidence and say it
failed only in combination). Otherwise its new verdict stands and it leaves the patch.

## Step 4: deliver

```
powershell -NoProfile -Command "Import-Module orchestrator/lib/FixVerify.psm1 -Force; Export-MutFixDelivery -RunNo <N> -Config '<config>'"
```

This applies only the `verified` entries to `<workDir>/fix-verify/<N>/delivery/test-app`, writes
`results/<N>-tests.patch` (diff against `<workDir>/test-app`, paths `a/<file>`, `b/<file>`) and `results/<N>-verified.md`
(counts per verdict, one line per entry with mutants killed/total and revision, evidence for every failure, how to
apply). Check the patch before reporting: `git apply -p1 --check` against a scratch copy of `out/test-app`
(never against the test-app repository).

## Report

Tell the user: counts per verdict, ids that stayed unverified and why, the paths of the patch and `verified.md`, and
that the owning team applies it with `git apply -p1 <patch>` in the test-app root and re-runs each test (line numbers
come from the `out/test-app` snapshot, SPEC §6.7.5). Never commit to or write into the test-app repository yourself.
