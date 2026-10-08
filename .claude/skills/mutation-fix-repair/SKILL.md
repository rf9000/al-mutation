---
name: mutation-fix-repair
description: Repair suggested AL test fixes that failed verification, by editing their entries in results/<N>-fixes.json with one subagent per entry. Never runs anything on the environment. Use when asked to "repair the failed fixes" or run /mutation-fix-repair <RunNo>.
---

# Repair failed test fixes

Invoked as `/mutation-fix-repair <RunNo>` with the fix ids to repair. Input: `results/<N>-fixes.json`,
`results/<N>-verified.json` (the evidence) and `results/<N>-fix-briefs.json`. Output: the repaired entries in
`results/<N>-fixes.json`, and `Test-MutFixReport.ps1` printing `ok`. The caller re-verifies afterwards.

## Hard rules

- Never run `Invoke-MutFixVerify.ps1`, `Invoke-MutationRun.ps1`, `Export-MutFixDelivery` or any other command that
  talks to the environment. This skill edits JSON only.
- Never write the test-app repository (`testApp.sourcePath`) or anything under `out/test-app`.
- Edit only the entries whose fixId the prompt names. Replace the whole entry with the same fixId; touch nothing else.
- One repair per entry per session: each entry gets revision + 1 at most once.
- `equivalent` entries are not repaired.

## Paths and shell

Same as `mutation-fix-verify`: `results/` is `$MUT_RESULTS_DIR` when set, `powershell` is `pwsh` on Linux, `python`
is `python3` on Linux, and JSON files are read with `encoding='utf-8-sig'`.

## Headless runs

If the prompt contains `HEADLESS RUN`, nobody is watching: never ask, decide and continue. Take the fix ids from the
prompt line `Repair only these fix ids: ...`. If the prompt says the ids failed only together with the other verified
fixes, tell each agent so in its EVIDENCE part.

## Steps

1. For each id, read its entry from `results/<N>-fixes.json`, its evidence from `results/<N>-verified.json` (compile
   diagnostics, the original-run error, or the surviving mutant ids with per-mutant outcomes) and its survivors from
   `results/<N>-fix-briefs.json` (filtered to the entry's `mutantIds`).
2. Spawn one subagent per id with the template in `.claude/skills/mutation-fix-verify/repair-agent-template.md`
   (parallel is fine: they only read files and answer with JSON).
3. Merge each answer into `results/<N>-fixes.json`: replace the entry with the same fixId, nothing else. An agent that
   leaves its entry unchanged: keep the entry as it is.
4. Run `powershell -NoProfile -File orchestrator/Test-MutFixReport.ps1 -RunNo <N>` until it prints `ok`. Send
   validation errors back to the agent that owns the entry.

## Report

One line per id: new revision, or `equivalent`, or unchanged with the agent's reason.
