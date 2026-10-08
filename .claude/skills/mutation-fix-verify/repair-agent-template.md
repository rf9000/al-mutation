# Repair-agent prompt template

Used by `mutation-fix-verify` (Step 2) and `mutation-fix-repair`. Fill the `<...>` parts. Get the brief entries with a
short python script (the brief has a BOM: `json.load(open(p, encoding='utf-8-sig'))`) and filter `survivors` to the
entry's `mutantIds`.

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
