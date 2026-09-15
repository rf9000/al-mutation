# Spike baseline

Numbers recorded by each spike task, per §7.6 of `docs/SPEC.md`.

## Environment

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| Environment Id | 30004698-209d-467c-96eb-9b412e9ee6ee | DemoPortal | 2026-09-07 | T03 |
| CreateDurationSec | n/a (created in attempt 2 at 2026-09-07 13:42:53 UTC; started manually) | DemoPortal | 2026-09-07 | T03 |
| StartDurationSec | 0 | DemoPortal | 2026-09-07 | T03 |
| ActivationInstallDurationSec | 2.0046002 | DemoPortal | 2026-09-07 | T03 |
| depsInstallSec (aut-original) | 1.4 | DemoPortal | 2026-09-08 | T12 |
| depsInstallSec (test-app) | 1.6 | DemoPortal | 2026-09-08 | T12 |
| autDeploySec | 73.0 (1,065 files; `continia deploy` direct CLI call, `--ruleset out/rulesets/.cli-ruleset-localdeploy.json --allow-downgrade --json`, exit 0, `published:true`) | DemoPortal | 2026-09-08 | T12 |
| testAppDeploySec | 31.5 (`Publish-MutApp -AllowDowngrade`, `Success:true`) | DemoPortal | 2026-09-08 | T12 |

## U1/U3

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| compileSec | 25.99 (`spikes/u1-guard-bench/New-GuardBenchApp.ps1` generated app; `continia.exe compile spikes/u1-guard-bench/app --json --no-raw-output --env 30004698-209d-467c-96eb-9b412e9ee6ee` → `exitCode:0`, `errorCount:0`, `warningCount:0`, `diagnosticCounts.info:2`) | DemoPortal | 2026-09-16 | T10 |
| publishSec | 39.90 (`continia.exe deploy 30004698-209d-467c-96eb-9b412e9ee6ee spikes/u1-guard-bench/app --json` → `compiled:true`, `published:true`, `readinessOutcome:"ready"`, 0 errors/0 warnings) | DemoPortal | 2026-09-16 | T10 |
| guarded100kSec | 36.116 (`continia.exe test run 30004698-209d-467c-96eb-9b412e9ee6ee 50501 --json --timeout 900`, test `Guarded_100k`, `result:"Pass"`) | DemoPortal | 2026-09-16 | T10 |
| unguarded100kSec | 1.61 (same job, test `Unguarded_100k`, `result:"Pass"`; job `summary.durationSeconds` 37.726 for both tests together) | DemoPortal | 2026-09-16 | T10 |
| ratio | 22.43 (36.116 / 1.61) | DemoPortal | 2026-09-16 | T10 |
| U3 verdict | **flag** — ratio 22.43 is far above the 2x threshold in §3's U3 mitigation ("If > 2x slowdown, `Active()` becomes a global-variable compare inside the AUT (id copied once per test)"); the 500-block `case true of MutationCore.Active(n)` guard as specified is not runtime-neutral and needs that mitigation before use at scale. Compile (25.99s) and publish (39.90s) for 500 guard blocks in one codeunit were both well within budget and produced 0 errors/0 warnings, so U1 (compiler/publish tolerance) is clean; only U3 (runtime overhead) is a concern. | DemoPortal | 2026-09-16 | T10 |

## U4

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| eventsFire | yes — `OnBeforeTestMethodRun`/`OnAfterTestMethodRun` on codeunit 130454 fire under the DemoPortal test job; runner chain seen in a live stack trace: `"Test Runner - Isol. Codeunit"(130450).OnRun` → `"Test Runner - Mgt"(130454).RunTests` → `"Test Suite Mgt."(130456)` → `"Command Line Test Tool"(130455)`. | DemoPortal | 2026-09-08 | T04b |
| tableReadInTestSession | no — `Setup.Get(0)` inside `MUT Test Hooks` (declared `Permissions = tabledata "MUT Mutation Setup" = R`) is denied even for a SUPER user granted permission set "MUT Core All": `Sorry, the current permissions prevented the action. (TableData 50000 MUT Mutation Setup IndirectRead: Mutation Core)`. An API session as the same user reads/writes the table fine — only the DemoPortal test job's runtime is restricted. | DemoPortal | 2026-09-08 | T04b |
| experimentA_disabledMode | pass — with `TestPermissions = Disabled;` added to codeunit 50400 "MUT Mut Tests", `test run <env> 50400 --json` → 4 total, 4 passed, 0 failed; `HookErrorIsEmpty` passes (empty `LastHookError`). Confirms the restriction is TestPermissions-mode-specific, not a deeper platform limitation. Property reverted and core-app-test redeployed afterward (control only; not shipped). | DemoPortal | 2026-09-08 | T04b |
| experimentB_isolatedStorage | pass — table 50000 gained `OnInsert`/`OnModify` triggers calling `MirrorToIsolatedStorage()` (`IsolatedStorage.Set('ActiveMutantId'/'CurrentRunNo', Format(<field>, 0, 9), DataScope::Module)`); `MUT Test Hooks`' `TryReadActiveMutant` now reads `IsolatedStorage.Get(..., DataScope::Module, Value)` + `Evaluate(..., Value, 9)` instead of `Setup.Get(0)`, defaulting to 0 on a missing key. Under the DEFAULT (restrictive) TestPermissions mode, after PATCHing `mutationSetup(0)` once to write the mirror: `test run <env> 50400 --json` → 4 total, 4 passed, 0 failed; `HookErrorIsEmpty` passes. IsolatedStorage reads are not subject to table permissions, so this channel survives the restricted test session. | DemoPortal | 2026-09-08 | T04b |
| killedRowWrittenByHooks | yes — PATCHed `activeMutantId = 999, currentRunNo = 1`; `test run <env> 50301 --json` → 2 total, 1 passed (`U4_Passing`), 1 failed (`U4_Failing`, `errorMessage: "deliberate U4 failure"`); GET `mutantResults` returned exactly one row `{runNo:1, mutantId:999, status:"Killed", killingTest:"MUT Fx U4 Spike Tests:U4_Failing"}`. The brief expected this insert to probably fail (table-permission denial on `MUT Mutant Result`), but it succeeded live — the hooks codeunit's own `Permissions = tabledata "MUT Mutant Result" = RI` is sufficient for a direct `Insert()` executed inside the same codeunit (unlike the read, which failed only because of `GetOrCreate()`/table-method indirection in earlier rounds, see T04/T04-fix-round-2 in `docs/issues.md`). A follow-up run of codeunit 50400 (`HookErrorIsEmpty`) with `activeMutantId` still 999 confirmed no swallowed error (4/4 pass, `LastHookError` empty). Setup PATCHed back to `activeMutantId = 0, currentRunNo = 0` and confirmed via GET. | DemoPortal | 2026-09-08 | T04b |
| u4ScriptRun | pass (exit 0) — `spikes/u4-runner-events/Invoke-U4Spike.ps1` run against `mut-spike-01`: PATCH `mutationSetup(0)` `{activeMutantId:999, currentRunNo:1}`, `Invoke-MutTests` on codeunit 50301, GET `mutantResults` filtered `runNo eq 1 and mutantId eq 999`, PATCH setup back to `{activeMutantId:0, currentRunNo:0}` (confirmed by GET), DELETE the row by key `mutantResults(runNo=1,mutantId=999)` (accepted on the first try — no fallback to the `mutantResults(1,999)` form was needed). First invocation reported a false PASS: the environment had just been auto-started from `Stopped` by the script and the test job briefly returned 0 total/0 passed/0 failed (same empty-result-right-after-start class of defect recorded in the Fixture-run section below), so the row the script found was the T04b spike's own stale row from 2026-09-08 (never cleaned up), not a fresh write. Re-run after the environment settled (confirmed by a diagnostic `Invoke-MutTests` call returning the expected 1 passed/1 failed) produced a genuine fresh row (`recordedAt: 2026-09-15T21:54:06.627Z`) and is the run recorded here. Concern: the script has no settle delay after auto-starting a stopped environment; a real orchestrator run should not hit this because the environment is normally already running. | DemoPortal | 2026-09-15 | T09 |
| u4KilledRowPresent | yes — exactly one row, `{runNo:1, mutantId:999, status:"Killed", durationMs:0, killingTest:"MUT Fx U4 Spike Tests:U4_Failing", recordedAt:"2026-09-15T21:54:06.627Z"}`; deleted after recording so the table stays clean, setup left at `activeMutantId:0` (verified by GET). | DemoPortal | 2026-09-15 | T09 |
| u4KillingTest | `MUT Fx U4 Spike Tests:U4_Failing` | DemoPortal | 2026-09-15 | T09 |

## U5

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|

## U6

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| option a (same-version) | success — generated `out/gen-fixture` with no `--aut-version` (schemata `app.json` version stays `1.0.0.0`, same as the already-installed fixture AUT and fixture test app); `.tools/continia.exe compile out/gen-fixture/aut-schemata --json --no-raw-output` → 0 errors, 11 warnings, 3 info (15 s); `continia.exe publish 30004698-209d-467c-96eb-9b412e9ee6ee "out/gen-fixture/aut-schemata/Continia Software_MUT Fixture AUT_1.0.0.0.app" --json` → `{success:true, message:"Publication successful", readinessOutcome:"ready"}` (5 s), with the fixture test app (id `9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e`) left installed throughout and never unpublished. Options b/c were not attempted — a was tried first and succeeded, per the ladder in this task's brief. | DemoPortal | 2026-09-08 | T22 |
| schemataCompileSec | 15 | DemoPortal | 2026-09-08 | T22 |
| schemataPublishSec | 5 | DemoPortal | 2026-09-08 | T22 |
| inactiveSuite | 9/9 pass — after publish, PATCH `mutationSetup(0)` `{activeMutantId:0, currentRunNo:0}` (confirmed by GET), `continia test run 30004698-209d-467c-96eb-9b412e9ee6ee 50300 --json` → 9 total, 9 passed, 0 failed, 0 skipped. Schemata is behaviour-preserving when inactive. | DemoPortal | 2026-09-08 | T22 |
| activatedMutantKilled | yes — looked up mutant id 3 in `out/gen-fixture/mutants.json` (procedure `IsLargeOrder`, operator `COND`, `original:"Quantity >= 10"`, `mutated:"false"`, matching §6.3.3's "IsLargeOrder COND → false, Killed by Twelve_IsTrue" row); PATCH `mutationSetup(0)` `{activeMutantId:3, currentRunNo:2}` (confirmed by GET); `test run 50300 --json` → 9 total, 8 passed, 1 failed — the single failure was `IsLargeOrder_Twelve_IsTrue` (`Assert.IsTrue failed. Order with quantity 12 should be large.`), all 8 others passed. Matches expectation exactly. | DemoPortal | 2026-09-08 | T22 |
| killedRowWritten | yes — GET `mutantResults?$filter=runNo eq 2 and mutantId eq 3` returned exactly one row `{runNo:2, mutantId:3, status:"Killed", killingTest:"MUT Fx Order Tests:IsLargeOrder_Twelve_IsTrue", durationMs:0}`, written automatically by the hooks (no orchestrator-side POST fallback needed, consistent with the T04b finding). Setup PATCHed back to `{activeMutantId:0, currentRunNo:0}` and confirmed via GET; environment left with the fixture schemata (mutation-instrumented AUT) installed and inactive, as later tasks expect. | DemoPortal | 2026-09-08 | T22 |

## U7

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| single-method job s | 9.3 (codeunit 95155, procedure `UpdatePlaceholderRows_EmptyInputs_BecomesNoMatchingAccounts`; substituted for the brief's codeunit 95913 / `TestAuthGrantedAcc.Codeunit.al`, which does not exist in the current AUT checkout — see `docs/issues.md` T12 entry) | DemoPortal | 2026-09-08 | T12 |
| 95155 s | 10.7 (whole codeunit, `Invoke-MutTests`, 13 total / 13 passed / 0 failed) | DemoPortal | 2026-09-08 | T12 |
| 95913 s | 8.3 (whole codeunit, `Invoke-MutTests`) — codeunit does not exist in the current AUT checkout; CLI returns `{"status":"completed","passed":true,"summary":{"total":0,"passed":0,"failed":0,"skipped":0,...},"tests":[]}` rather than erroring, so this is a job-overhead number for a no-op run, not a real codeunit duration | DemoPortal | 2026-09-08 | T12 |
| per-test median s | not computed (only 2 of the 2 target codeunits attempted; 95913 has 0 tests) — deferred to Gate G1 per §7.6 | DemoPortal | 2026-09-08 | T12 |

## U8

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| API base URL pattern | `$Env.Url` itself (e.g. `https://demoportaldev.continiaonline.com/<envId>`) answers 200 for `GET <base>/api/v2.0/companies` with Basic auth; the `/BC` suffix is NOT needed on this environment (it 404s). `Get-MutApiBase` still tries `$Env.Url` then `$Env.Url + '/BC'`, in that order, and caches whichever works per environment id. | DemoPortal | 2026-09-08 | T07 |
| Automation API `userPermissions` field name | The actual field is `roleId`, not `permissionSetId` as approximated in SPEC §6.5.3 / this task's brief (values come back upper-cased, e.g. `"MUT CORE ALL"`). `POST` body `{ roleId, appId, scope: "System" }` succeeded on the first attempt; no fallback (no-scope, then `"Tenant"`) was needed. See `docs/issues.md` for the full finding. | DemoPortal | 2026-09-08 | T07 |
| mutationSetup GET/PATCH round trip | Via `Invoke-MutApi`: GET → `activeMutantId=0`; PATCH `mutationSetup(0)` `{activeMutantId:7}` → confirmed by GET `activeMutantId=7`; PATCH back to `{activeMutantId:0}` → confirmed by GET `activeMutantId=0`. Reverted cleanly. | DemoPortal | 2026-09-08 | T07 |
| Grant-MutPermissionSet live result | Automation API `GET companies({cid})/users` returns 4 users for `mut-spike-01` (`RB`, `ADMIN`, `EH`, `RF`) — one more than the 3 DemoPortal's own `env users --json` lists (`Rf`/Super User, `EH`/Controller, `RB`/Approver); `ADMIN` is a 4th BC user not in that list. Granted `MUT Core All` (3 granted: ADMIN, EH, RF; 1 already had it: RB, from an earlier manual probe) and `MUT Fx All` (4 granted: RB, ADMIN, EH, RF) to every user returned. All 4 already held `SUPER` before and after. | DemoPortal | 2026-09-08 | T07 |
| Fixture suite (codeunit 50300) after granting | `continia test run 30004698-209d-467c-96eb-9b412e9ee6ee 50300 --json` → 9 total, **7 passed, 2 failed, 0 skipped** — unchanged from the pre-grant T04 fix-round-2 baseline in `docs/issues.md`. Both failures: `Sorry, the current permissions prevented the action. (TableData 50200 MUT Fx Order IndirectInsert: MUT Fixture Test)` on `PostOrder_PositiveQty_SetsPosted` and `PostOrder_ZeroQty_Errors`. Not 9/9; reported DONE_WITH_CONCERNS per this task's brief rather than looped on. Full finding (why granting to every named user, all already `SUPER`, did not help) in `docs/issues.md`. | DemoPortal | 2026-09-08 | T07 |

## U9

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| job id field name | not exposed by `test run --json` (top-level properties are exactly `status, passed, summary, tests`, confirming F18); exposed only in the CLI's human-mode (non-`--json`) text output as `Test job started: N` — `test coverage <envId> <N> --json` accepts that plain integer and returns `{envId, jobId, csv}` correctly. Static reference selection is therefore the only covering-test selector available from `test run --json` alone; a job id is still obtainable per test run via one extra human-mode CLI call if the orchestrator needs it live. | DemoPortal | 2026-09-08 | T12 |
| CSV header line | **no header row** — every line of `test coverage --json`'s `csv` field, including the first, is a data row: `"Codeunit","50000","Object","0","0"`. 5 positional columns, not 4: `ObjectType` (`"Codeunit"` only, observed), `ObjectId`, a line-classification string (`"Object"`/`"Trigger/Function"`/`"Empty"`/`"Code"`, undocumented), `LineNo`, `Hits`. Full finding (columns, object ids observed, impact on §6.5.5's planned `ConvertFrom-MutCoverageCsv`) in `docs/issues.md`. `fixtures/coverage/sample.csv` is the first 200 raw lines of job 41's 1691-line CSV, verbatim. | DemoPortal | 2026-09-08 | T12 |

## Tier B baseline

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| codeunit 95155 "CTS-CB Test Auth Share Detect" | 13 total / 13 passed / 0 failed, 10.7s, on a fresh AUT+test-app deploy | DemoPortal | 2026-09-08 | T12 |
| codeunit 95913 "CTS-CB Test Auth Granted Acc" | **does not exist in the current AUT/test-app checkout** — 0 total / 0 passed / 0 failed, 8.3s (CLI reports `status:completed, passed:true` for an unknown codeunit id rather than erroring). Not the expected 15/15; see `docs/issues.md` T12 entry for the live evidence (AUT codeunit 72918690 is currently "CTS-CB Line Date Import Def.", not "CTS-CB Auth Granted Acc. Mgt"; id 72918691 is unused; two non-`mut-*` DemoPortal environments named `AuthGrantedAccountApply` / `build-2026-09-03-auth-granted-accounts-share-design` suggest this feature lives on an unmerged branch). | DemoPortal | 2026-09-08 | T12 |
| AUT repo read-only verification | `git -C "Continia Banking" status --short` identical before/after (14 pre-existing lines, unrelated to Tier B); 5 sample files (`AuthShareDetection.Codeunit.al`, `TestAuthShareDetect.Codeunit.al`, `.cli-ruleset-localdeploy.json`, both apps' `app.json`) hash-identical (`Get-FileHash`/`sha1sum`) before and after the full sync+deploy+test run. | DemoPortal | 2026-09-08 | T12 |

## Hand mutants

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|

## Fixture run

`Invoke-MutationRun.ps1 -ConfigPath mutation.fixture.config.json -RunNo 1` (§8 orchestrator acceptance) against `mut-spike-01`. First attempts hit five live-only defects across the orchestrator and one in the generator (all fixed under this task, full detail in `docs/issues.md`); the numbers below are the final, clean run.

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| Wall clock (results/1.json, final clean invocation) | 00:24:22 (2026-09-08T23:22:01Z → 2026-09-08T23:46:24Z) | DemoPortal | 2026-09-09 | T27 |
| Wall clock (cumulative, including the live-debugging attempts below) | ≈2h45m real time across 7 pipeline launches on the same environment/run number, most of it idle waiting on `Reset-MutEnvironment` polls and re-diagnosing each defect between attempts, not orchestrator overhead per se | DemoPortal | 2026-09-09 | T27 |
| Mutant count | 26 (matches §6.3.3 exactly) | DemoPortal | 2026-09-09 | T27 |
| Killed / Survived / Timeout / CompileError / Uncovered | 18 / 5 / 3 / 0 / 0 | DemoPortal | 2026-09-09 | T27 |
| Score | 0.8077 (matches §6.3.3's stated `(18+3)/26 = 0.8077` exactly) | DemoPortal | 2026-09-09 | T27 |
| `Compare-MutExpectedResults results/1.json fixtures/expected-results.json` | **0 mismatches**, 26/26 | DemoPortal | 2026-09-09 | T27 |
| Timeout→Killed tolerance (§8 item 1) used | **None needed** — all 3 actual `Timeout` mutants (`CountBatches` COND→false id 21; `FirstMultipleAbove` COND→false id 25; `FirstMultipleAbove` DEL exit(Candidate) id 26) matched §6.3.3's own `Timeout` expectation exactly; no mutant expected `Timeout` came back `Killed` instead | DemoPortal | 2026-09-09 | T27 |
| §8 acceptance item 4 (inactive schemata passes full suite) | 9/9 pass, both runs (RunNo 1 and RunNo 2) | DemoPortal | 2026-09-09 | T27 |
| BREAK acceptance (§8 item 2): `out/fixture-break.config.json` (`generator.includeBreak = true`), `-RunNo 2` | 41 total mutants (26 normal + 15 BREAK, one per simple statement); **all 15 BREAK mutants → CompileError** (0 exceptions); run completed, `results/2.json`/`-summary.md` produced (not committed, per the brief) | DemoPortal | 2026-09-09 | T27 |
| BREAK acceptance side effect (concern, not a failure of the stated criterion) | 9 additional non-BREAK mutants (all `DEL`, one `INSFLAG`) also came back `CompileError` — every simple statement eligible for `DEL`/`INSFLAG` is also eligible for `BREAK` and shares ONE guard block with it (§6.4.7); a BREAK compile error is attributed to that whole block's line range (§6.4.9 `linemap.json` is block-, not candidate-, granular), so excluding the offending BREAK candidate's stableKey also swept up its DEL/INSFLAG block-mates. Total CompileError = 24 (15 BREAK + 9 collateral); remaining 17 non-BREAK mutants behaved identically in kind to run 1's corresponding mutations (13 Killed, 2 Survived, 2 Timeout). Architectural, pre-existing (generator/Schemata.psm1 exclusion granularity); not fixed under this task — flagged here for a future task | DemoPortal | 2026-09-09 | T27 |
| Live defects found and fixed (see `docs/issues.md` for full detail) | (1) `timeouts.minSeconds` too tight for the fixture's fast baseline (60→120s, precautionary); (2) `MutantLoop.psm1`'s `Invoke-MutTestsWithBudget` used `Start-Job`, which hung indefinitely spawning the backend CLI as a further child process — replaced with a background runspace; (3) a test run immediately after `Reset-MutEnvironment` twice returned an empty (0-test) result recorded as a false `Survived`/non-`Timeout` — fixed with a settle delay plus a retry-on-empty-result; (4) `Run.psm1`'s own `Build-MutSchemataStep` corrupted its `schemata.json` cache (a `ConvertFrom-Json`-sourced array re-serializes as `{"value":[...],"Count":N}` once nested) — fixed by rebuilding the array via `ForEach-Object` before caching; (5) `MutantLoop.psm1`'s `Survived` POST path was not idempotent across a resumed run (unlike `Killed`) — fixed by swallowing only an `EntityWithSameKeyExists` conflict; (6) `Run.psm1`'s `Ensure-MutEnvironment` skip path never primed the backend's own module-scoped CLI-path state, crashing the first `Invoke-MutApi` call of a run resumed past that step — fixed by always re-checking the environment cheaply; (7) `generator/src/generate.ts` gated BREAK candidates by BOTH `includeBreak` and membership in `--operators`, silently producing zero BREAK mutants for this task's own fixture-break config — fixed to gate BREAK by `includeBreak` alone; (8) `Run.psm1` never gave a compile-error mutant (e.g. BREAK) any row to report in the final export at all — fixed by threading `Schemata.psm1`'s new `ExcludedMutants` list through to `Export-MutResultsStep`; (9) `Run.psm1`'s `Push-MutManifest` checked only `id`, not the `MUT Mutant` table's actual unique index on `stableKey`, and crashed posting RunNo 2's differently-numbered manifest against an environment that already had RunNo 1's — fixed to also skip on an existing stableKey. All fixes covered by new/updated Pester or `node:test` unit tests; 194 orchestrator Pester tests and 105 generator tests green at the end | DemoPortal | 2026-09-09 | T27 |

## Recommendation

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
