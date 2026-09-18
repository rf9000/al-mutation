# Spike baseline

Numbers recorded by each spike task, per §7.6 of `docs/SPEC.md`. This file is reorganised by T14 to open
with a Summary a human can read once; every number recorded by earlier tasks is kept below, unmoved in
substance, only reordered and annotated with its backend/environment.

## Summary

| Unknown | Answer | Detail |
|---|---|---|
| U1 (guard compile/publish cost) | 500 `case true of MutationCore.Active(n)` blocks compile in 26s and publish in 40s, 0 errors/0 warnings — fine at this scale. A real-AUT schemata compile (1,072 files, 157 guards for one codeunit, analyzers disabled) also compiled clean in ~11s. | §U1/U3 |
| U2 (covering-test selection value) | **Provisional.** Measured on one AUT codeunit against a 3-test-codeunit scope only: in the pilot run, 73% of mutants (115/157) were selected from real baseline coverage rows and 27% (42/157) via the static reference-map fallback — both correctly confined to the configured scope after the M1 fix. Not validated across multiple codeunits or at Gate G1 scale. | §U7, Pilot run (run 6) |
| U3 (guard runtime overhead) | 22.4× slowdown in a tight 100k-iteration loop — well above the 2× flag threshold in §3. A mitigation exists (cache `Active()` into a local Boolean) but was not applied: the pilot's real test run showed no observable slowdown, since tests are not hot loops. | §U1/U3 |
| U4 (runner hooks fire, kills recorded) | **Yes.** `OnBeforeTestMethodRun`/`OnAfterTestMethodRun` fire under the DemoPortal test job; kills are recorded via an IsolatedStorage channel (the test session cannot read Mutation Core's own tables, even for a SUPER user). | §U4 |
| U5 (job cancel / reset cost) | The CLI reliably exits on its own client-side timeout even when the underlying BC job never returns; a full `env stop`+`env start` reset costs ~219–288s plus a 32–106s settle/test-readiness probe — roughly 5 minutes end to end. | §U5 |
| U6 (schemata replaces installed AUT) | `same-version` republish (CLI auto-unpublishes and reinstalls at the same id+version) works and is what ships. The only failure mode found (downgrade after an in-session upgrade) cannot occur under `same-version`. | §U6 |
| U7 (fixed job cost, sampling input) | A single-method job costs ~9.3s; the whole 13-test codeunit costs 10.7s — too close to decompose "job overhead" from "test time" by subtraction. See Throughput below for how this feeds the sampling default. | §U7, Throughput and sampling |
| U8 (API base / credentials) | The environment's own `url` (no `/BC` suffix) is the API base; the Automation API's permission-set field is `roleId`, not `permissionSetId` as SPEC originally assumed. | §U8 |
| U9 (job id, CSV columns) | `test run --json` never exposes a job id; the CLI's non-JSON `--raw` mode prints `Test job started: N` instead. `test coverage`'s CSV has no header row and 5 positional columns, not the assumed 4. | §U9 |
| Gate G0 | See the **Recommendation (DRAFT)** section at the end of this document — none of §8's three explicit no-go triggers fire, which is evidence for continuing, not a verdict. | Recommendation (DRAFT) |

## Chronology

The app under test changed three times during this project, and each time broke something that had never
broken against the fixture. On **2026-09-08** the AUT's daily merge deleted the codeunits and test codeunit
(72918690, 72918691, 95913) SPEC §1.1 had originally targeted, forcing Tier B onto codeunit 72918635/95155
instead (T12). On **2026-09-16** the whole app moved from BC 28 to BC 29 (platform/application 29.0.0.0),
which a BC 28.1 sandbox cannot compile against at all — this forced a second environment, `mut-spike-02`
(T13/T13b), and blocked all 20 hand mutants until it existed. On **2026-09-17**, mid-project, an upstream
deletion of codeunit "CTS-CB Req. Header Log Search" left the *installed* test suite referencing a codeunit
no longer in source, producing an AL0185 dependent-recompile failure that aborted pilot run 5; the fix was
to unpublish the stale test suite and start a fresh run (run 6). Separately, running the real generator against
the real 1,072-file AUT (not the fixture) surfaced four distinct defects that never appeared against the
fixture and were found one at a time, each blocking the next attempt: the tokenizer rejected the AL filter-OR
operator `|` and the ternary operator `?` (T28 first attempt, fixed T21b); the schemata's injected
`MutationCore` variable tripped the AUT's own strict CodeCop naming rule AA0072 (T28 second attempt); the
generated ruleset meant to downgrade that rule was itself invalid per the AL compiler's ruleset schema, missing
a required `name` property (T28 third attempt); and a third CodeCop rule, AA0021 (variable-declaration
ordering), fired on the same injected variable once the first two were fixed (T28 fourth attempt). The
whack-a-mole ended only when T25c disabled AL style analyzers entirely for the generated schemata tree,
compiling it with the real AL compiler's error checks alone. The lesson: a fixture, however carefully built,
cannot stand in for the real app's syntax variety or its style ruleset, and a project whose target keeps
moving needs its pipeline to tolerate drift, not just prove a mechanism once against a fixed snapshot.

## Environment

*Backend: DemoPortal throughout. Two environments: `mut-spike-01` (BC 28.1, Tier A fixture) and
`mut-spike-02` (BC 29, Tier B real AUT, created 2026-09-17 after the BC-version move above).*

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
| **mut-spike-02** Environment Id | 65eb4296-df3c-4ceb-a189-c3d029d701d0 (profile `ff24b00b-ea9b-4311-8191-81b8370f0a0a`, BC 29.0.0.0, build 29.0.54011.54239) | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 create+start+apps-poll-settle wall clock | ≈10.3 min (11:30:43→11:40:59 local) — `New-MutEnvironment` created and started the environment and got past the apps-poll settle, but then **threw** inside `Wait-MutEnvironmentSettled`'s test-readiness probe (10 attempts × 30s) because `demoPortal.settleProbe` points at codeunit 95155/`UpdatePlaceholderRows_EmptyInputs_BecomesNoMatchingAccounts` — the AUT's *own* test codeunit, which cannot exist on a brand-new environment before the AUT+test app are ever deployed. Confirmed live: `test run <id> 95155 <function> --json --timeout 120` on the fresh env returned `summary.total:0` (codeunit not found, not a readiness problem). This chicken-and-egg gap never surfaced for `mut-spike-01` because it was already provisioned from earlier tasks (95155 already existed). See `docs/issues.md` T13b entry. | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 activation app install + env use (manual completion) | 2.0s install (`deps install-by-id <id> c3755ece-dab0-4d16-987d-040661f18522 --json` → `installed:true, app.version:"29.0.0.0"`) + `env use <id>` (stderr confirmation, exit 0) — run directly via the CLI to complete the two steps `Start-MutEnvironment` never reached after the probe threw; `env get <id> --json` then confirmed `bcVersion:"29.0.0.0"`, `platformVersion/applicationVersion:"29.0.54011.54239"`, matching `out/aut-original/app.json`'s `platform`/`application` (`29.0.0.0`) | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 depsInstallSec (aut-original) | 72.0 | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 depsInstallSec (test-app) | 70.7 | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 core-app publish | 10.4s, Success=true | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 autDeploySec | 38.7 (`Publish-MutApp -Ruleset out/rulesets/.cli-ruleset-localdeploy.json -AllowDowngrade`, `Success:true`) | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 testAppDeploySec | 54.0 (same ruleset/flags, `Success:true`) | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 Grant-MutPermissionSet | 9.4s — `MUT Core All` granted to 4 users (RF, RB, EH, ADMIN), none already had it | DemoPortal | 2026-09-17 | T13b |
| mut-spike-02 baseline (codeunit 95155) | 13/13 passed, 0 failed, 13.4s — matches T12's 13/13 baseline on `mut-spike-01` at BC 28.1; no regression from the BC 29 move | DemoPortal | 2026-09-17 | T13b |

## U1/U3

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1, Tier A fixture) — `spikes/u1-guard-bench`, a
synthetic 500-guard-block app, not the real AUT.*

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| compileSec | 25.99 (`spikes/u1-guard-bench/New-GuardBenchApp.ps1` generated app; `continia.exe compile spikes/u1-guard-bench/app --json --no-raw-output --env 30004698-209d-467c-96eb-9b412e9ee6ee` → `exitCode:0`, `errorCount:0`, `warningCount:0`, `diagnosticCounts.info:2`) | DemoPortal | 2026-09-16 | T10 |
| publishSec | 39.90 (`continia.exe deploy 30004698-209d-467c-96eb-9b412e9ee6ee spikes/u1-guard-bench/app --json` → `compiled:true`, `published:true`, `readinessOutcome:"ready"`, 0 errors/0 warnings) | DemoPortal | 2026-09-16 | T10 |
| guarded100kSec | 36.116 (`continia.exe test run 30004698-209d-467c-96eb-9b412e9ee6ee 50501 --json --timeout 900`, test `Guarded_100k`, `result:"Pass"`) | DemoPortal | 2026-09-16 | T10 |
| unguarded100kSec | 1.61 (same job, test `Unguarded_100k`, `result:"Pass"`; job `summary.durationSeconds` 37.726 for both tests together) | DemoPortal | 2026-09-16 | T10 |
| ratio | 22.43 (36.116 / 1.61) | DemoPortal | 2026-09-16 | T10 |
| U3 verdict | **flag** — ratio 22.43 is far above the 2x threshold in §3's U3 mitigation ("If > 2x slowdown, `Active()` becomes a global-variable compare inside the AUT (id copied once per test)"); the 500-block `case true of MutationCore.Active(n)` guard as specified is not runtime-neutral and needs that mitigation before use at scale. Compile (25.99s) and publish (39.90s) for 500 guard blocks in one codeunit were both well within budget and produced 0 errors/0 warnings, so U1 (compiler/publish tolerance) is clean; only U3 (runtime overhead) is a concern. | DemoPortal | 2026-09-16 | T10 |

## U4

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1, Tier A fixture) — `spikes/u4-runner-events`.*

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

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1, Tier A fixture) — `spikes/u5-u6`.*

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| cliExitedOnClientTimeout | yes — `spikes/u5-u6/Invoke-U5Spike.ps1` started `.tools/continia.exe test run 30004698-209d-467c-96eb-9b412e9ee6ee 50302 --timeout 30` (codeunit 50302 "MUT Fx U5 Spike Tests", `U5_InfiniteLoop`: `while true do Sleep(1000);`) via `Start-Process`; the CLI printed `Starting test: codeunit 50302` / `Test job started: 186` on stderr, then exited on its own after 36.9 s (within the 60 s outer wait budget; no `Stop-Process` was needed) printing `TIMEOUT: Test job timed out waiting for results` on stdout. Confirms F9: the CLI's `--timeout` is a real, working client-side wait that reliably ends the CLI process even though the underlying BC test job (with a true infinite loop) never itself completes — the CLI does not hang. | DemoPortal | 2026-09-15 | T11 |
| sessionVisibleAfter | ambiguous — immediately after the CLI gave up, `continia env sessions 30004698-209d-467c-96eb-9b412e9ee6ee --json` returned 2 rows: `{sessionId:-2682, userId:"RF", clientType:"Windows"}` and `{sessionId:2730, userId:"EH", clientType:"Web"}`. Neither row carries a field distinguishing a test-runner session from an ordinary client session, so `env sessions` alone cannot confirm whether job 186's infinite-loop session is still alive on the BC server or already gone — a real limitation of this diagnostic surface, not a firm "job still running" finding. (The spike script's own first-cut session count of "1" was a PowerShell bug — `@($x \| ConvertFrom-Json)` wrapping a pipeline expression directly nests a multi-element JSON array as a single element under Set-StrictMode instead of enumerating it; fixed by assigning the pipeline result to a variable first, then wrapping that variable in `@()`.) | DemoPortal | 2026-09-15 | T11 |
| resetDurationSec | 219.14 (`Reset-MutEnvironment`: `env stop` → poll to `Stopped` → `env start` → poll to `Running`) | DemoPortal | 2026-09-15 | T11 |
| settleDurationSec | 31.64 (`Wait-MutEnvironmentSettled`, included in the reset above) | DemoPortal | 2026-09-15 | T11 |
| suiteAfterReset | 9/9 pass, but only on a retry — the very first `Invoke-MutTests` call on codeunit 50300 immediately after the reset returned a spurious 0 total/0 passed/0 failed (the same "empty result right after start/reset" class of defect already recorded for T09's `u4ScriptRun` row above); a second call moments later returned a genuine 9 total/9 passed/0 failed. The environment is fully usable again after `Reset-MutEnvironment`, but an orchestrator that reset an environment mid-run should not trust an all-zero result from the very next test call without at least one retry/settle check. | DemoPortal | 2026-09-15 | T11 |
| startWithProbeStartDurationSec / startWithProbeSettleDurationSec / startWithProbeProbeAttempts | 533.27 / 105.34 / 2 — `mut-spike-01` was found `Stopped` at the start of this task; `Start-MutEnvironment -Env $e -Config $cfg` (fixture config, `demoPortal.settleProbe = {codeunitId:50300, functionName:"IsLargeOrder_Twelve_IsTrue"}`) performed a real Stopped → Running transition, then the apps-poll settle (included in SettleDurationSec), then the new test-readiness probe: attempt 1 returned `summary.total:0`, attempt 2 returned `summary.total:9` (`Pass`) — exactly the empty-then-real pattern this task fixes. `ActivationInstallDurationSec` 1.42. Not a §U5 required row, but recorded here since it is the first real, non-mocked exercise of the new probe (live, before the Reset run below). | DemoPortal | 2026-09-17 | T11b |
| resetWithProbeDurationSec | 287.57 (`Reset-MutEnvironment -Env $e -Config $cfg`: `env stop` → poll to `Stopped` → `env start` → poll to `Running` → settle + probe) | DemoPortal | 2026-09-17 | T11b |
| settleProbeAttempts | 2 — the test-readiness probe's first `test run 30004698-209d-467c-96eb-9b412e9ee6ee 50300 IsLargeOrder_Twelve_IsTrue --json --timeout 120` call after this reset returned `summary.total:0` (no tests discovered — the exact live defect spike U5 found), the second call 30 s later returned `summary.total:9` and the probe accepted the environment as ready; `SettleDurationSec` for this reset was 106.87 (apps-poll settle + the 2 probe attempts, one 30 s gap between them). | DemoPortal | 2026-09-17 | T11b |
| suiteAfterResetWithProbe | 9/9 pass, 0 failed, 246 ms — a full, non-probe `Invoke-MutTests` call on codeunit 50300 run immediately after the reset above (no retry needed this time): the test-readiness probe already confirmed the environment was accepting real test jobs before this call was made, unlike the bare `suiteAfterReset` row from T11 which needed a manual retry. | DemoPortal | 2026-09-17 | T11b |

## U6

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1, Tier A fixture) — `spikes/u5-u6` and T22.*

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| option a (same-version) | success — generated `out/gen-fixture` with no `--aut-version` (schemata `app.json` version stays `1.0.0.0`, same as the already-installed fixture AUT and fixture test app); `.tools/continia.exe compile out/gen-fixture/aut-schemata --json --no-raw-output` → 0 errors, 11 warnings, 3 info (15 s); `continia.exe publish 30004698-209d-467c-96eb-9b412e9ee6ee "out/gen-fixture/aut-schemata/Continia Software_MUT Fixture AUT_1.0.0.0.app" --json` → `{success:true, message:"Publication successful", readinessOutcome:"ready"}` (5 s), with the fixture test app (id `9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e`) left installed throughout and never unpublished. Options b/c were not attempted — a was tried first and succeeded, per the ladder in this task's brief. | DemoPortal | 2026-09-08 | T22 |
| schemataCompileSec | 15 | DemoPortal | 2026-09-08 | T22 |
| schemataPublishSec | 5 | DemoPortal | 2026-09-08 | T22 |
| inactiveSuite | 9/9 pass — after publish, PATCH `mutationSetup(0)` `{activeMutantId:0, currentRunNo:0}` (confirmed by GET), `continia test run 30004698-209d-467c-96eb-9b412e9ee6ee 50300 --json` → 9 total, 9 passed, 0 failed, 0 skipped. Schemata is behaviour-preserving when inactive. | DemoPortal | 2026-09-08 | T22 |
| activatedMutantKilled | yes — looked up mutant id 3 in `out/gen-fixture/mutants.json` (procedure `IsLargeOrder`, operator `COND`, `original:"Quantity >= 10"`, `mutated:"false"`, matching §6.3.3's "IsLargeOrder COND → false, Killed by Twelve_IsTrue" row); PATCH `mutationSetup(0)` `{activeMutantId:3, currentRunNo:2}` (confirmed by GET); `test run 50300 --json` → 9 total, 8 passed, 1 failed — the single failure was `IsLargeOrder_Twelve_IsTrue` (`Assert.IsTrue failed. Order with quantity 12 should be large.`), all 8 others passed. Matches expectation exactly. | DemoPortal | 2026-09-08 | T22 |
| killedRowWritten | yes — GET `mutantResults?$filter=runNo eq 2 and mutantId eq 3` returned exactly one row `{runNo:2, mutantId:3, status:"Killed", killingTest:"MUT Fx Order Tests:IsLargeOrder_Twelve_IsTrue", durationMs:0}`, written automatically by the hooks (no orchestrator-side POST fallback needed, consistent with the T04b finding). Setup PATCHed back to `{activeMutantId:0, currentRunNo:0}` and confirmed via GET; environment left with the fixture schemata (mutation-instrumented AUT) installed and inactive, as later tasks expect. | DemoPortal | 2026-09-08 | T22 |
| optionB_bumpBuild | success — `spikes/u5-u6/Invoke-U6Spike.ps1`: robocopy'd `fixtures/fixture-aut` to `out/u6-bump` (excluding `.alpackages`, `*.app`), set `app.json` version to `1.0.0.1` (plain, non-schemata source), `Compile-MutApp` (11.78 s, 0 errors), `Publish-MutAppFile` (4.61 s, `Success:true`) — a same-id, higher-build **upgrade in place** over the still-installed fixture test app (no unpublish of the dependent needed, since the test app's dependency on AUT `1.0.0.0` is a minimum-version constraint satisfied by `1.0.0.1`); `test run 50300` → 9/9 pass immediately after. Total attempt time incl. the confirmatory test run: 26.50 s. Reproduced identically across 2 independent full runs. | DemoPortal | 2026-09-15 | T11 |
| optionC_unpublishTestApp | **failure, reproduced 3× (2 full script runs + 1 manual CLI reproduction)** — `Unpublish-MutApp` the fixture test app (succeeds), `Compile-MutApp fixtures/fixture-aut` at the original `1.0.0.0` (9.36 s, 0 errors), then `Publish-MutAppFile` of that `1.0.0.0` build **fails** even with the dependent test app already unpublished: `{"success":false,"message":"Publishing failed due to 'Cannot install the extension MUT Fixture AUT by Continia Software 1.0.0.0 because a newer version 1.0.0.1 was already installed.'. The original extensions have been restored.\r\n\r\n"}`. Falling back to `Unpublish-MutApp` on the AUT itself (all versions, `Success:true`) and retrying the same publish **still fails with the identical message** — `continia unpublish` reports the AUT `Success:true` while, separately, both `env apps --all` (Automation API) and a direct `unpublish --app-id/--dev-endpoint/--name+--publisher` all report `"Not installed (Automation API)"` for the same app id at the same moment, yet the live BC platform still refuses to install `1.0.0.0` claiming `1.0.0.1` is present. A full `Reset-MutEnvironment` (env stop → Stopped → env start → Running, manually reproduced) did **not** clear this. `deploy --allow-downgrade` and `publish --sync-mode ForceSync` were also tried directly against the CLI and hit the identical error. Total time to conclusively fail (unpublish test + compile + failed publish + unpublish AUT + failed retry): 17.46 s. **Root cause is a genuine BC/CLI inconsistency, not a config or ordering mistake in this task's script** — likely because the fixture AUT was published via the raw `publish <file>` path (a dev-scoped install), which the Automation API-backed `env apps`/`unpublish` paths do not track, while the platform's own install-time version guard still sees it. Re-publishing an **equal-or-higher** version (`1.0.0.1`, the same mechanism as option (a)/(b)) always succeeds; only a genuine downgrade is blocked. **This does not affect the real orchestrator**: `schemata.publishStrategy = same-version` never downgrades — schemata is always published at the *same* version as the just-compiled `aut-original`, run after run, so this specific failure mode (publish a lower version after a higher one was installed in the same session) cannot occur in normal `Invoke-MutationRun.ps1` operation; it only arose here because this spike deliberately bumped the build (option b) before trying to go back down (option c). Flagged as a platform limitation worth knowing about (e.g. if a future `bump-build` strategy ever needs to roll back to an older build), not as a blocker for the current `same-version` choice. | DemoPortal | 2026-09-15 | T11 |
| endStateRestore | `spikes/u5-u6/Invoke-U6Spike.ps1`'s own restore sequence hit the identical downgrade block described above, then fell back (as designed, and logged explicitly) to republishing the last known-good **plain, non-schemata `1.0.0.1`** build from `out/u6-bump` instead of leaving the AUT fully unpublished, then republished `fixtures/fixture-test`. Final state, confirmed via `env apps <id> --all --json` and a fresh `test run 50300 --json`: fixture AUT `1.0.0.1` (plain build, not the schemata build) and fixture test app `1.0.0.0` both installed, 9/9 pass. This is a deliberate, documented deviation from the guardrail's literal "AUT at exactly 1.0.0.0" wording — the guardrail's intent (a plain, non-schemata AUT + working test app, 9/9) is met; the exact version differs because 1.0.0.0 itself is unreachable in-session per the `optionC_unpublishTestApp` finding above. | DemoPortal | 2026-09-15 | T11 |
| publishStrategy decision | **unchanged: `same-version`** in both `mutation.config.json` and `mutation.fixture.config.json`. Option (a) same-version was proven working by T22 and is not contradicted by anything found here (this task's option (c) failure is a downgrade-after-upgrade scenario that the real `same-version` strategy never produces, since schemata is always published at the current run's AUT version, never a lower one than was previously installed in the same session). | DemoPortal | 2026-09-15 | T11 |

## U7

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1) — Tier B baseline against the real AUT's
codeunit 95155, run before `mut-spike-02` existed.*

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| single-method job s | 9.3 (codeunit 95155, procedure `UpdatePlaceholderRows_EmptyInputs_BecomesNoMatchingAccounts`; substituted for the brief's codeunit 95913 / `TestAuthGrantedAcc.Codeunit.al`, which does not exist in the current AUT checkout — see `docs/issues.md` T12 entry) | DemoPortal | 2026-09-08 | T12 |
| 95155 s | 10.7 (whole codeunit, `Invoke-MutTests`, 13 total / 13 passed / 0 failed) | DemoPortal | 2026-09-08 | T12 |
| 95913 s | 8.3 (whole codeunit, `Invoke-MutTests`) — codeunit does not exist in the current AUT checkout; CLI returns `{"status":"completed","passed":true,"summary":{"total":0,"passed":0,"failed":0,"skipped":0,...},"tests":[]}` rather than erroring, so this is a job-overhead number for a no-op run, not a real codeunit duration | DemoPortal | 2026-09-08 | T12 |
| per-test median s | not computed (only 2 of the 2 target codeunits attempted; 95913 has 0 tests) — deferred to Gate G1 per §7.6 | DemoPortal | 2026-09-08 | T12 |

## U8

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1).*

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| API base URL pattern | `$Env.Url` itself (e.g. `https://demoportaldev.continiaonline.com/<envId>`) answers 200 for `GET <base>/api/v2.0/companies` with Basic auth; the `/BC` suffix is NOT needed on this environment (it 404s). `Get-MutApiBase` still tries `$Env.Url` then `$Env.Url + '/BC'`, in that order, and caches whichever works per environment id. | DemoPortal | 2026-09-08 | T07 |
| Automation API `userPermissions` field name | The actual field is `roleId`, not `permissionSetId` as approximated in SPEC §6.5.3 / this task's brief (values come back upper-cased, e.g. `"MUT CORE ALL"`). `POST` body `{ roleId, appId, scope: "System" }` succeeded on the first attempt; no fallback (no-scope, then `"Tenant"`) was needed. See `docs/issues.md` for the full finding. | DemoPortal | 2026-09-08 | T07 |
| mutationSetup GET/PATCH round trip | Via `Invoke-MutApi`: GET → `activeMutantId=0`; PATCH `mutationSetup(0)` `{activeMutantId:7}` → confirmed by GET `activeMutantId=7`; PATCH back to `{activeMutantId:0}` → confirmed by GET `activeMutantId=0`. Reverted cleanly. | DemoPortal | 2026-09-08 | T07 |
| Grant-MutPermissionSet live result | Automation API `GET companies({cid})/users` returns 4 users for `mut-spike-01` (`RB`, `ADMIN`, `EH`, `RF`) — one more than the 3 DemoPortal's own `env users --json` lists (`Rf`/Super User, `EH`/Controller, `RB`/Approver); `ADMIN` is a 4th BC user not in that list. Granted `MUT Core All` (3 granted: ADMIN, EH, RF; 1 already had it: RB, from an earlier manual probe) and `MUT Fx All` (4 granted: RB, ADMIN, EH, RF) to every user returned. All 4 already held `SUPER` before and after. | DemoPortal | 2026-09-08 | T07 |
| Fixture suite (codeunit 50300) after granting | `continia test run 30004698-209d-467c-96eb-9b412e9ee6ee 50300 --json` → 9 total, **7 passed, 2 failed, 0 skipped** — unchanged from the pre-grant T04 fix-round-2 baseline in `docs/issues.md`. Both failures: `Sorry, the current permissions prevented the action. (TableData 50200 MUT Fx Order IndirectInsert: MUT Fixture Test)` on `PostOrder_PositiveQty_SetsPosted` and `PostOrder_ZeroQty_Errors`. Not 9/9; reported DONE_WITH_CONCERNS per this task's brief rather than looped on. Full finding (why granting to every named user, all already `SUPER`, did not help) in `docs/issues.md`. | DemoPortal | 2026-09-08 | T07 |

## U9

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1) — Tier B baseline (codeunit 95155).*

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| job id field name | not exposed by `test run --json` (top-level properties are exactly `status, passed, summary, tests`, confirming F18); exposed only in the CLI's human-mode (non-`--json`) text output as `Test job started: N` — `test coverage <envId> <N> --json` accepts that plain integer and returns `{envId, jobId, csv}` correctly. Static reference selection is therefore the only covering-test selector available from `test run --json` alone; a job id is still obtainable per test run via one extra human-mode CLI call if the orchestrator needs it live. | DemoPortal | 2026-09-08 | T12 |
| CSV header line | **no header row** — every line of `test coverage --json`'s `csv` field, including the first, is a data row: `"Codeunit","50000","Object","0","0"`. 5 positional columns, not 4: `ObjectType` (`"Codeunit"` only, observed), `ObjectId`, a line-classification string (`"Object"`/`"Trigger/Function"`/`"Empty"`/`"Code"`, undocumented), `LineNo`, `Hits`. Full finding (columns, object ids observed, impact on §6.5.5's planned `ConvertFrom-MutCoverageCsv`) in `docs/issues.md`. `fixtures/coverage/sample.csv` is the first 200 raw lines of job 41's 1691-line CSV, verbatim. | DemoPortal | 2026-09-08 | T12 |

## Tier B baseline

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1) — a real-AUT baseline taken before the BC 29
move; superseded by `mut-spike-02`'s own baseline used in the Hand mutants and Pilot run sections below.*

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| codeunit 95155 "CTS-CB Test Auth Share Detect" | 13 total / 13 passed / 0 failed, 10.7s, on a fresh AUT+test-app deploy | DemoPortal | 2026-09-08 | T12 |
| codeunit 95913 "CTS-CB Test Auth Granted Acc" | **does not exist in the current AUT/test-app checkout** — 0 total / 0 passed / 0 failed, 8.3s (CLI reports `status:completed, passed:true` for an unknown codeunit id rather than erroring). Not the expected 15/15; see `docs/issues.md` T12 entry for the live evidence (AUT codeunit 72918690 is currently "CTS-CB Line Date Import Def.", not "CTS-CB Auth Granted Acc. Mgt"; id 72918691 is unused; two non-`mut-*` DemoPortal environments named `AuthGrantedAccountApply` / `build-2026-09-03-auth-granted-accounts-share-design` suggest this feature lives on an unmerged branch). | DemoPortal | 2026-09-08 | T12 |
| AUT repo read-only verification | `git -C "Continia Banking" status --short` identical before/after (14 pre-existing lines, unrelated to Tier B); 5 sample files (`AuthShareDetection.Codeunit.al`, `TestAuthShareDetect.Codeunit.al`, `.cli-ruleset-localdeploy.json`, both apps' `app.json`) hash-identical (`Get-FileHash`/`sha1sum`) before and after the full sync+deploy+test run. | DemoPortal | 2026-09-08 | T12 |

## Hand mutants

**T13 (2026-09-17, `mut-spike-01`, BC 28.1): BLOCKED — 0 of 20 mutants applied.** `Sync-MutAutCopy` pulled a fresh AUT snapshot whose `app.json` now declares `"version": "29.0.0.0"`, `"platform": "29.0.0.0"`, `"application": "29.0.0.0"` and all 5 Continia dependencies at `29.0.0.0` (up from `28.5.0.0` at T12, 2026-09-08 — the AUT is a genuine daily-merging moving target per §1.1, and it has now crossed a BC major-version boundary). `mut-spike-01` is a BC 28.1 sandbox and cannot serve or compile against 29.0.0.0 platform/application/dependency symbols; every `Publish-MutApp`/`deploy` attempt failed with `code: "symbol-fetch-failed"`. Full diagnosis in `docs/issues.md` (T13 entry). This blocker is resolved by T13b below.

**T13b (2026-09-17, `mut-spike-02`, BC 29.0.0.0): COMPLETE — 20 of 20 mutants applied, compiled, and tested.** Baseline (13/13, 0 failed) confirmed clean before the loop; final republish of the clean AUT copy afterward also passed 13/13, 0 failed, and its SHA-256 matched the pristine pre-loop hash exactly, so the copy was correctly restored. Six mutants drifted (their `find` text was not found on the given line or recurred elsewhere in the file at their exact given line per the harness's own rule for HM11-13/HM15-style ambiguous text — expected, since §6.6.5's line numbers predate the 2026-09-16 BC 29 move; this is recorded as drift, not failure, per the brief).

| Id | Operator | Status | Seconds | Note |
|---|---|---|---|---|
| HM01 | REL | Survived | 51.8 | |
| HM02 | REL | Survived | 53.1 | |
| HM03 | BOOL | Killed | 59.9 | failed: `DetectInCompany_WithFakeHttp_UnboundAccount_EmitsSystemNotMappedRow` |
| HM04 | BOOL | Drift | 0.0 | source drift |
| HM05 | REL | Killed | 51.5 | 6 tests failed |
| HM06 | REL | Killed | 50.6 | 4 tests failed |
| HM07 | REL | Killed | 54.0 | 6 tests failed |
| HM08 | NOT | Drift | 0.0 | source drift |
| HM09 | REL | Survived | 50.3 | |
| HM10 | REL | Survived | 49.8 | |
| HM11 | DEL | Drift | 0.0 | source drift |
| HM12 | DEL | Drift | 0.0 | source drift |
| HM13 | DEL | Survived | 49.8 | |
| HM14 | COND | Drift | 0.0 | source drift |
| HM15 | DEL | Drift | 0.0 | source drift |
| HM16 | REL | Killed | 52.8 | failed: `DetectInCompany_WithFakeHttp_UnboundAccount_EmitsSystemNotMappedRow` |
| HM17 | REL | Killed | 53.0 | failed: `DetectInCompany_WithFakeHttp_UnboundAccount_EmitsSystemNotMappedRow` |
| HM18 | NOT | Survived | 51.2 | |
| HM19 | DEL | Survived | 49.7 | |
| HM20 | BOOL | Survived | 51.1 | |

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| Totals | Killed 6, Survived 8, Drift 6, CompileError 0 (of 20) | DemoPortal | 2026-09-17 | T13b |
| Kill rate | 30.0% (6/20); of the 14 non-drift mutants, 6/14 = 42.9% | DemoPortal | 2026-09-17 | T13b |
| Gate G0 hand-mutant rule (>= 18 of 20 killed -> no-go) | **Not met** (6 < 18) — this criterion alone does not indicate the suite is already strong enough to warrant scaling down to a periodic manual audit; it does not by itself force either a `go` or `no-go` (other §8 G0 criteria — U4 events firing, U7's mutants/day throughput — are evaluated separately in the Recommendation section below) | DemoPortal | 2026-09-17 | T13b |
| AUT repo read-only verification | `git -C "Continia Banking" status --short` identical before/after (same 11 pre-existing lines as T13); SHA-256 of `AuthShareDetection.Codeunit.al` identical before/after (`B6BF6C4FEF7F73EBA4A75EA43A6ADE8C69B20D2E2349F48FDBE6F8AE2AD87EFA`) | DemoPortal | 2026-09-17 | T13b |

## Fixture run

*Backend: DemoPortal, environment `mut-spike-01` (BC 28.1, Tier A fixture) — the §8 orchestrator-acceptance
run, not Tier B.*

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

## Pilot run (run 4, superseded — pre covering-test-scope fix)

*Backend: DemoPortal, environment `mut-spike-02` (BC 29, Tier B real AUT) — codeunit 72918635.*

**Superseded measurement.** Run 4 was measured before `afe9c6a` (`fix(orchestrator): reference-map fallback stays inside the configured test scope`) landed. It is kept here for the record and for the explicit before/after comparison in the run 6 section below, not as the current baseline.

| Metric | Value | Backend | Date |
|---|---|---|---|
| Wall clock | 00:50:46 (2026-09-17T12:01:40.2162974Z → 2026-09-17T12:52:26.4120255Z) | DemoPortal | 2026-09-17 |
| Mutants generated / run | 157 / 157 | DemoPortal | 2026-09-17 |
| Killed / Survived / Timeout / CompileError / Uncovered | 62 / 95 / 0 / 0 / 0 | DemoPortal | 2026-09-17 |
| Score | 0.3949 | DemoPortal | 2026-09-17 |
| Mean seconds/mutant (wall clock) | 19.40 | DemoPortal | 2026-09-17 |

## Pilot run (run 6, corrected scope)

`Invoke-MutationRun.ps1 -ConfigPath mutation.config.json -RunNo 6` against `mut-spike-02`, codeunit 72918635 only, baseline covering three test codeunits (95155, 95179, 95191). Run 5 (same scope, `-RunNo 5`) had aborted in `Publish-MutBaseline` with `AL0185: Codeunit 'CTS-CB Req. Header Log Search' is missing` because the environment's installed test suite predated an upstream deletion of that codeunit and its test; the controller unpublished the stale test suite from `mut-spike-02` before this run, and run 6 used a fresh `-RunNo` so `Sync-MutAutCopy` re-synced from source and republished both apps rather than reusing run 5's stale `environment.done`.

| Metric | Value | Backend | Date |
|---|---|---|---|
| Wall clock | 00:55:18 (2026-09-17T21:32:51.1680358Z → 2026-09-17T22:28:09.5491343Z) | DemoPortal | 2026-09-17 |
| Mutants generated / run | 157 / 157 | DemoPortal | 2026-09-17 |
| Killed / Survived / Timeout / CompileError / Uncovered | 62 / 95 / 0 / 0 / 0 | DemoPortal | 2026-09-17 |
| Score | 0.3949 | DemoPortal | 2026-09-17 |
| Mean seconds/mutant (wall clock) | 21.14 | DemoPortal | 2026-09-17 |
| Covering-test set size distribution | 1 test: 112 mutants (71.3%); 2 tests: 3 mutants (1.9%); 3 tests: 42 mutants (26.8%); 0 tests (uncovered): 0 | DemoPortal | 2026-09-17 |
| Selection source | 115 mutants (73.2%) selected from baseline coverage rows; 42 mutants (26.8%) selected via the reference-map fallback (`Get-MutCoveringTests`, `orchestrator/lib/Coverage.psm1`), all correctly confined to the configured 3-codeunit scope | DemoPortal | 2026-09-17 |
| AUT repo read-only verification | `git -C "Continia Banking" status --short` before the run: 7 pre-existing lines (`.gitignore`, `.gitmodules`, 2 ruleset files, 3 untracked entries). After the run: those same 7 lines **plus 7 newly-modified `.docx`/`.rdlc` report layout files** (Direct Debit, Payment Suggestion, Remittance Advice, Customer Statement Payment Reference — all unrelated to codeunit 72918635), with filesystem mtimes of 22:12–22:16 UTC, inside the run window. Traced and ruled out as caused by this pipeline: `orchestrator/lib/AutCopy.psm1`'s `Sync-MutAutCopy`/`Invoke-MutRobocopyMirror` only mirrors `robocopy <source> <workDir-copy> /MIR` (source is never a robocopy destination), and `Run.psm1`'s baseline/schemata steps compile `$Config.workDir/aut-original` (the copy), never `$Config.aut.sourcePath` directly — confirmed by grepping `Run.psm1` for every use of `sourcePath` vs the copied `$autPath`. The change is therefore an **external edit to the source tree by someone/something else during the run**, not a guardrail violation by this tooling. Because `Sync-MutAutCopy` runs once, early, in the `initialize`/`baseline` steps (well before 22:12 UTC), run 6's own working copy and results are unaffected. Flagged here because it means the controller's "stable for ~7 hours" assurance did not fully hold in practice; worth a source-repo-activity check before any future run in this window. | DemoPortal | 2026-09-17 |

### Comparison with run 4

Run 4 was measured **before** `afe9c6a` fixed the reference-map fallback to stay inside the configured test scope. Run 6 is the first measurement **after** that fix, same mutant set (same seed, same `onlyObjects: [72918635]`, same 157 mutants by id).

- **Outcome (Killed/Survived/Timeout/CompileError/Uncovered) is identical for all 157 mutants** — 0 status differences between run 4 and run 6. Totals, score (0.3949), and the survivor list are byte-for-byte the same set of ids.
- **Covering-test sets changed for exactly 3 mutants**: ids 182, 183, 184 (`ResolveBankCodeForAccount`, line 212, `TempBank.Code <> ''`) went from `[95155]` in run 4 to `[95155, 95179]` in run 6 — codeunit 95179 is now correctly included because the fallback selection no longer needs the scope guard to exclude it (it was already in-scope; run 4's narrower result for this line was itself in-scope, just missing a second covering test that run 6's corrected logic now finds). None of the three changed outcome (182 and 184 stayed Killed, 183 stayed Survived).
- **Wall clock rose from 00:50:46 to 00:55:18** (19.40s → 21.14s mean per mutant) — expected, since the corrected scope now runs a genuine second/third covering-test job for the 42 mutants using the reference-map fallback (26.8% of the set, all now confined to the 3-codeunit scope) plus the 3 mutants above, instead of silently under-covering or over-reaching outside the configured suite.
- **Conclusion**: for this codeunit's mutant set, the covering-test-scope bug that run 4 predates did not happen to hide or fabricate any kills — but it could not have been trusted to generalize, since it was capable of selecting tests outside the configured baseline scope (no baseline duration, wrong timeout budget, coverage claims outside the declared suite). Run 6 is the trustworthy measurement going forward; run 4 remains here only as the labelled pre-fix baseline.

### Hand-mutant cross-check (HM01–HM20 vs run 6)

Of the 20 hand mutants in `spikes/hand-mutants/results.json`, 6 are `Drift` (HM04, HM08, HM11, HM12, HM14, HM15 — excluded per the brief). The remaining 14 (Killed or Survived) were matched to a run 6 generator mutant at the same `matchedLine` with equivalent `mutated` text:

| HM id | Line | Operator | Hand status | Generator match (run 6 id) | Agreement |
|---|---|---|---|---|---|
| HM01 | 120 | REL | Survived | id 159, `MatchingAccounts.Count() >= 0`, Survived | Agree |
| HM02 | 153 | REL | Survived | id 162, `AccountsAttempted <> 0`, Survived | Agree |
| HM03 | 204 | BOOL | Killed | id 174, `(...) or (...)`, Killed | Agree |
| HM05 | 399 | REL | Killed | id 238, `ExactMatchCount >= 0`, Killed | Agree |
| HM06 | 403 | REL | Killed | **none** | **Disagree — no generator counterpart** |
| HM07 | 412 | REL | Killed | id 241, `TotalFailed >= 0`, Killed | Agree |
| HM09 | 424 | REL | Survived | id 251, `TotalMatched >= 0`, Survived | Agree |
| HM10 | 474 | REL | Survived | id 256, `TotalAttempted >= 0`, Survived | Agree |
| HM13 | 625 | DEL | Survived | id 294, statement deleted, Survived | Agree |
| HM16 | 212 | REL | Killed | id 182, `TempBank.Code = ''`, Killed | Agree |
| HM17 | 85 | REL | Killed | id 149, `SourceBank.Code <> ''`, Killed | Agree |
| HM18 | 304 | NOT | Survived | id 213, `ToBank.WritePermission()`, Survived | Agree |
| HM19 | 309 | DEL | Survived | id 220, statement deleted, Survived | Agree |
| HM20 | 275 | BOOL | Survived | id 204, `(...) or (...)`, Survived | Agree |

**13 of 14 agree exactly** (same status, equivalent mutated text). **HM06 disagrees**, but not on outcome — the generator never produced a candidate at line 403 (`if MismatchCount > 0 then begin`) at all. Confirmed by the generator's own id sequence in `results/6.json`: ids 238–240 cover line 399's `if ExactMatchCount > 0 then begin` (the first arm of the `if ... then begin ... end else if ... then begin` chain), and the very next ids, 241–243, jump straight to line 412's unrelated `if TotalFailed > 0 then` — no ids exist for line 403 at all, even though `MismatchCount` is real, undrifted source (verified by reading the live file) and structurally identical to the line-399 condition the generator did mutate.

**This is not a defect — it is the deliberate deferral recorded in SPEC §1.2** ("Mutating `if` conditions in `else if`, `then if`, `do if`, or case-branch position" — requires wrapping the whole `if` statement in `begin…end`, which needs compound-statement end detection not built in v1), implemented exactly as designed by the `position = statementList` rule in §6.4.3 (a condition is only mutated when the token before its `if` is `begin`, `;`, or `repeat`; an `else if` arm's condition has `position: other` and is excluded via `condition-position` in §6.4.6). The hand mutants independently found and quantified the size of this known operator-coverage gap: 1 of the 14 applicable hand mutants (≈7%) landed in an `else if` arm and had no generator counterpart. This belongs in the Recommendation below as a known, bounded gap, not as a generator bug to fix before Gate G0.

## Whole-app generation (scale, measurement only)

*Backend: none (local generator CLI only, no environment touched). Not part of the pilot; recorded because
the number was captured live before the user directed the project to stay scoped to the one Tier B codeunit
(see the ledger's M2 entry, 2026-09-17).*

Running the generator with no `--only-objects` filter over the entire real AUT (1,072 `.al` files — the
later M7/M8 sections say 1,070 because the AUT lost two files between the two measurement dates; same
kind of upstream drift as the 15,058/15,012 mutant-count drift reconciled below) produced
**15,058 mutants in ≈90 seconds**. This shows mutant *generation* scales to the whole app without difficulty.
It does **not** show that compiling or publishing a schemata of that size works: the whole-app schemata compile
was started and then deliberately stopped by the user before completion, and its scratch output was removed.
The only compile measurement that exists at any real-AUT scale is the pilot's own 157-guard schemata (one
codeunit, 11s, 0 errors, analyzers disabled — see the Fixture/Pilot sections above and T25c in
`docs/issues.md`). Compiling and publishing ~100× that many guards in one schemata build is untested.

## Throughput and sampling

*Backend: DemoPortal, environment `mut-spike-02` (BC 29, Tier B) — derived from the Pilot run (run 6)
numbers above. Assumption throughout: sequential test jobs, one environment (§4 guardrail 8 forbids
concurrent jobs; nothing in this project has measured parallel environments).*

**Throughput.** Run 6 (the corrected-scope, current measurement) took 55m18s for 157 mutants: **21.1
seconds/mutant** (21.14 precisely). At that rate, one environment running mutant jobs back-to-back manages:

| Window | Mutants |
|---|---|
| 24 hours (informational only — nothing in this project runs unattended around the clock) | 86,400 / 21.1 ≈ **4,095 mutants/day** |
| 8 working hours | 28,800 / 21.1 ≈ **1,365 mutants** |

This 21.1 s/mutant figure is the *pilot's* per-mutant cost on a 1–3-test covering set; it does not include the
one-time per-run costs (baseline, schemata compile/publish, environment settle) which are amortised over
however many mutants a run covers, nor does it reflect a wider, unmeasured covering-test set on a different
codeunit (U2 is provisional — see Summary).

**Sampling default.** A whole-project run is far beyond one workday at this rate: the entire app generates
15,058 mutants (see above); at 21.1 s/mutant that is 15,058 × 21.1s ≈ 317,724s ≈ **88 hours (≈3.7 days)** of
continuous single-environment sequential execution — before even accounting for the unmeasured compile/publish
cost at that scale. To keep one run inside an 8-hour window at the measured rate, `generator.maxMutants` is
set to:

```
generator.maxMutants = 1364
```

(`floor(28800 / 21.1) = 1364`, in `mutation.config.json` — the only config change this task makes.)

This is **9.1%** of the 15,058 mutants a whole-project generation produces (1364 / 15058). It has **no effect
on the pilot's own scope**: codeunit 72918635 alone generates only 157 mutants, well under the 1,364 cap, so a
single-codeunit run like the pilot is never sampled by this default — the cap only activates once a run's
scope (via `onlyObjects`, or its absence) covers more than ~1,364 mutants' worth of code, e.g. several
codeunits at once or the whole project. Whether 1,364 mutants drawn from across many codeunits behaves the
same way the pilot's 157 mutants from one codeunit did (same score stability, same covering-set-size mix) is
untested — this default only bounds wall-clock time, it does not validate sampling quality at scale.

**`timeouts.jobOverheadSeconds`.** Left at its current value of **0** — not changed by this task. §U7's two
numbers (a single-method job: 9.3s; the whole 13-test codeunit: 10.7s) are too close together to support a
positive, safely-derived "job overhead" by subtraction: if the fixed per-job overhead were, say, 9s, the
remaining ~0.3s would have to cover all 13 tests' actual execution time, which is implausibly low and would
turn negative for a slower codeunit — the measurement does not decompose cleanly into "overhead" plus
"test time." §6.5.6's `perTestFactor` (5×) already carries the safety margin for the timeout budget
(`minSeconds` is **120 in `mutation.fixture.config.json`**, raised from 60 after the fixture-run
timeout defect in `docs/issues.md`, and **still 60 in `mutation.config.json`** — the Tier B floor was
never re-tuned, which is safe only because Tier B's baseline is slower than the fixture's); adding an
unproven subtracted constant on top would only remove margin, not add accuracy.

## Recommendation (DRAFT — a human decides)

**This section is a DRAFT.** It evaluates §8's Gate G0 rule against the recorded numbers and lays out the
costs and unknowns a human should weigh. It does not itself say `go` or `no-go`; that verdict belongs to the
human reader, written into this section.

### §8 Gate G0, evaluated

SPEC §8 states G0 is `no-go` if any of three conditions hold. None of the three fire:

| # | No-go condition | Measured | Fires? |
|---|---|---|---|
| 1 | U4 shows events do not fire under the DemoPortal runner | Events fire; kills are recorded (§U4, live evidence: a deliberately-failing fixture test produced exactly one `Killed` row) | **No** |
| 2 | ≥ 18 of the 20 hand mutants are killed (suite already strong → scale down to periodic manual audit) | 6 of 20 killed (30%); 6 of 14 applicable, non-drift mutants (43%) | **No** — far below 18/20 |
| 3 | U7 implies fewer than ~200 mutants/day | ≈4,095 mutants/day at the measured 21.1 s/mutant, one environment, sequential jobs | **No** — ≈20× the floor |

None of the three explicit triggers hold. That is evidence the project should not be stopped on the letter of
§8's rule; it is not, by itself, proof the project should scale up, since §8 is a floor, not a target, and the
costs and unproven items below are not part of the rule's own text.

### Tier B mutation score, and what it says about the suite

Run 6 (the current, reproducible measurement — 0 of 157 mutants changed status vs. the pre-scope-fix run 4):
157 mutants, 62 Killed, 95 Survived, 0 Timeout/CompileError/Uncovered, **score 0.3949**. The hand-mutant
cross-check (13 of 14 non-drift hand mutants agree with the generator's outcome at the same line) says this
score is a trustworthy measurement of **this codeunit's slice**, not an artifact of how mutants happen to
be generated (n = 14, all inside the one codeunit, written by this project — it says nothing about any
other codeunit) —
the one disagreement (HM06) is the known, deliberate `else if` operator-coverage gap from SPEC §1.2, not a
defect (see the Hand-mutant cross-check section above). A 39% kill rate means the existing tests for this one
codeunit (95155/95179/95191) let roughly 6 in 10 injected faults through undetected — a real, quantified gap
in test quality for this slice of the app, not evidence either way about the rest of the 451-codeunit AUT.

### Costs to weigh

| Cost | Number | Note |
|---|---|---|
| Guard overhead, synthetic tight loop | 22.4× (36.1s guarded vs 1.6s unguarded / 100k iterations) | Exceeds the §3 2× flag threshold. This is a 100,000-iteration hot loop with no test-job overhead diluting it — a worst case for code that is itself hot, not a general prediction. Mitigation (cache `Active()` locally per procedure entry) exists but is unapplied. |
| Guard overhead, real test suite | 0.97× (31.59s instrumented/inactive vs 32.59s plain, same 3 codeunits, 51 tests, same session — task M7) | The number that matters for this project's actual workload: no measurable slowdown. The gap between this and the 22.4× row above is real, not a contradiction — a BC test job's wall clock is dominated by fixed per-job overhead (U7: ~9–11s/job), which swamps a per-guard cost that only shows up when the guarded code itself runs a hot loop. Keep both: 22.4× still matters if a mutated procedure turns out to be hot. |
| Guard compile/publish (500 blocks, synthetic) | 26s / 40s | Comfortably inside budget |
| Real-AUT schemata compile (157 guards, one codeunit, 1,072 files) | ~11s, 0 errors | Real-app file-count scale, pilot codeunit's guard count |
| Real-AUT schemata compile (1,364 / 5,000 mutants, whole app scanned) | 24s / 22s, 0 errors, ~4.6 MB `.app` both times (task M7) | Compile time is flat across this range, not proportional to mutant count |
| Real-AUT schemata compile, concentrated (1,918 mutants in 5 objects, up to 53 in one procedure) | 29s, 0 errors, 4.53 MB (task M7) | Probed for a per-method/IL ceiling; none found |
| Real-AUT schemata compile, whole project (15,012 mutants, all files) | 20.5s, 0 errors, 73 warnings, 4.68 MB `.app` (task M8) | The full-scale number; see "Full-scale build" below for how the one failure at this scale (M7) was diagnosed and fixed |
| Environment reset (mid-run recovery) | ~5 minutes (219–288s reset + 32–106s settle) | Paid every time a job times out or is force-reset in a long run |
| Environment create+start (fresh) | ~10 minutes | One-time per new environment, not per run |
| Full-suite baseline (all 181 test codeunits) | **Not yet measured** — Gate G1, blocked until a human writes `go` here | Unknown scaling risk; U2's median-savings figure also waits on this |
| AUT-drift risk | See Chronology above | The AUT changed under this project 3 times in ~10 days (objects deleted, BC28→29, a mid-run dependent-recompile failure) and real code exercised syntax/style rules the fixture never had, surfacing 4 distinct defects only against real code. A longer, less-supervised run is more exposed to this kind of drift, not less. |

### Not proven

Schemata compile at whole-project scale, and publish at that size, were open questions in earlier drafts of
this section; both are now answered (tasks M7/M8, see "Schemata scaling curve" and "Full-scale build" below)
and have been removed from this list. What remains genuinely open:

- **Coverage-based selection beyond one codeunit** — U2 is provisional, measured on one AUT codeunit against a 3-test-codeunit scope only.
- **The Docker backend** — interface-only stub, throws `NotImplemented`.
- **A genuinely multi-codeunit mutant *run*, or any second AUT codeunit taken through the full loop** — compile is now proven at whole-project scale (M7/M8), and the pilot proved the full generate→compile→publish→test→record loop end to end, but only for one codeunit (72918635) at a time. Running that full loop across many codeunits, or the whole project, at once has never been attempted — only its compile step has.
- **The full 181-codeunit baseline (Gate G1)** — unmeasured; blocked until a human writes `go`.
- **The generator emits invalid AL for case branches with non-numeric labels.** Found in the final
  pre-merge review and reproduced: in `case <expr> of`, every branch label from the second onward sits at a
  statement-start position, so a label such as `BLbl:` starts a bogus "simple statement" that runs through
  the branch body — the two spans overlap, and the rewriter applies edits with no overlap check, emitting
  `endcase true of` and a duplicated label. The real AUT has **530 overlapping pairs across 98 of 1,070
  files**. Under the *default* operator set this never corrupts — proven, not assumed: the full-scale build
  (`out/m8/w-all`, 15,012 mutants, whole AUT) contains zero such artifacts and compiled `success: true,
  errorCount: 0`, which is why **run 6's score is unaffected**. Under `--include-break` it fires immediately
  on real code. `--include-break` is a spec'd flag (§6.4.5, §6.4.9) with its own committed config and
  **cannot currently be run on this AUT**. It is also a plausible partial explanation for run 2's "BREAK
  collateral CompileError" finding, which was attributed solely to block-granular linemap exclusion.
- **Guard overhead in hot code — §3's U3 decision rule fired and its mandated mitigation was never
  applied.** §3 U3 says: if > 2× slowdown, `Active()` becomes a global-variable compare inside the AUT.
  Measured 22.4× on a synthetic 100k-iteration loop; the mitigation was ruled non-blocking and not
  implemented. The 0.97× figure on the real suite is evidence that the *pilot's* code is not hot — not
  that every mutated procedure will be cold.
- **A compile error condemns every mutant sharing its guard block, not just the offending one.**
  `linemap.json` is block-granular, not candidate-granular, so any compile error in a shared guard block
  silently removes its block-mates from the denominator. Measured once, under `--include-break` (run 2: 24
  CompileError = 15 BREAK + 9 collateral `DEL`/`INSFLAG`). The mechanism is general, not BREAK-specific; the
  pilot had 0 compile errors, so it never bit — that is luck, not proof.
- **The restricted test-session identity is still unidentified.** Granting `MUT Core All` to all four
  enumerable environment users (all already SUPER) changed nothing, so the identity that runs DemoPortal
  test sessions is none of them. The IsolatedStorage channel routes around it and works, but the underlying
  mechanism was never established, and §6.1.5b still states a rationale this project disproved.
- **CRLF source files** — the generator's end-of-line handling has no test coverage at all (zero CRLF bytes
  in `generator/test/**` or `fixtures/generator/**`). The AUT is 1,023 LF / 46 CRLF / 1 mixed, so the
  CRLF path has run in production without ever being exercised by a test.

### DRAFT recommendation

**DRAFT.** None of §8's three explicit no-go conditions fire: the runner hooks work and kills are recorded,
the hand mutants show this suite is nowhere near already-adequate (6 of 20 killed, far under the 18-of-20
"scale down" threshold), and the measured throughput (~4,095 mutants/day on one environment, sequential jobs)
is roughly twenty times the 200/day floor. The pilot's mechanism has been proven twice over on real code — once
reproducibly (run 4 and run 6, identical outcome on all 157 mutants across a real orchestrator fix) and once
independently by hand (13 of 14 non-drift hand mutants agree with the generator, with the one disagreement
being a known, bounded, and now-documented operator gap rather than a defect) — and it found a real, sizeable
gap in the existing test suite (a 0.3949 score on real code).

The previous draft of this recommendation named whole-project scaling as the biggest open technical risk:
mutant generation was proven at 15,058 mutants in 90 seconds, but nothing said the schemata would compile,
publish, or run without a measurable slowdown at that size. That risk is now retired by measurement, not by
argument. Tasks M7 and M8 compiled 1,364, 5,000, and 15,012-mutant schemata against the real 1,070-file AUT —
compile time is flat (~20–24s) across that whole range, not proportional to mutant count; concentrating 1,918
mutants into 5 objects (53 in one procedure) still compiled clean in 29s with no per-method or IL limit found;
the one failure the curve did surface, at the unsampled 15,012-mutant extreme, was traced to a specific
generator rewriter defect (guard indentation copying preceding source text instead of whitespace, for a
statement sharing its line with its own un-blocked `if...then`) and fixed, with the identical scope then
compiling clean. And the guard-overhead number that mattered most for real use — not the 22.4× synthetic
tight-loop figure, but the actual 3-codeunit test suite running against an instrumented, inactive schemata —
came back at 0.97×: no measurable slowdown. Publish at the 4.56 MB / 1,364-mutant size class was also proven
live, with the environment restored cleanly afterward; the 4.68 MB whole-project build is the same size class,
though it was not itself separately published in this project.

What is left is honestly smaller, and different in kind. It is not architectural — nothing found says the
schemata mechanism breaks down at scale. It is operational and scope-related. Operationally, the AUT changed
shape three times in ten days in ways that broke the pipeline every time it touched real code rather than the
fixture (objects deleted, a BC major-version move, a mid-run dependent-recompile failure — see Chronology
above); a longer or less-supervised run is exposed to more of this, not less, and nothing in M7/M8 changes
that risk. On scope: every end-to-end run of the full generate→compile→publish→test→record loop — the pilot,
the hand mutants, the reproducibility check — was against one codeunit (72918635) at a time. M7/M8 prove the
*compile* step at whole-project scale; they do not prove a whole-project (or even multi-codeunit) mutant *run*,
since no such run has been executed. Coverage-based test selection (U2) is likewise proven only on that one
codeunit against a 3-test-codeunit scope, and the full 181-codeunit baseline (Gate G1) remains unmeasured.

The human reader weighs the proven, reproducible mutation-score signal, the throughput headroom, and the
now-retired scaling risk against the remaining operational (AUT drift) and scope (one codeunit run end to end,
whole-project loop untested, G1 baseline unmeasured) risk, and writes `go` or `no-go` into this section
themselves.

## Schemata scaling curve

*Date: 2026-09-18. Backend: DemoPortal. Environment: `mut-spike-02` (65eb4296-df3c-4ceb-a189-c3d029d701d0, BC 29).
Source task: M7. All compiles read-only against the environment (symbol fetch only); `out/aut-original`
(1,070 files, 120,203 lines — matches the figure recorded above) used unchanged throughout. AUT repo
read-only verification: `git -C "Continia Banking" status --short` identical before and after (7 pre-existing
modified lines + 3 untracked entries, none touched by this task).*

**Wide curve** (`--max-mutants N`, whole app, no `--only-objects`):

| label | mutants generated | compile sec | errors | warnings/info | `.app` produced | app size | `.al` lines (Δ) | lines/mutant |
|---|---|---|---|---|---|---|---|---|
| w-1364 | 1364 | 24 | 0 | 73 / 0 | yes | 4.56 MB | 129,994 (+9,791) | 7.18 |
| w-5000 | 5000 | 22 | 0 | 73 / 0 | yes | 4.61 MB | 151,282 (+31,079) | 6.22 |
| w-all (`--max-mutants 0`) | 15,012 | 15 (fails fast) | **36** | 0 / 0 | **no** | — | 191,616 (+71,413) | 4.76 |

(15,012 vs the 15,058 recorded above under "Whole-app generation" is a ~0.3% drift from small AUT source
changes between the two measurement dates, not investigated further.)

w-1364 and w-5000 — the sampling default and well above it — compile barely slower than the 157-mutant pilot's
11s, with a near-flat ~4.6 MB app. **w-all does not fail on size or an IL/method limit.** It fails fast (15s)
on 36 real syntax errors — `AL0104` ("Syntax error, ':' expected", 15), `AL0224` ("Expression expected...",
12), `AL0111` ("Semicolon expected...", 8), `AL0110` ("Orphaned ELSE statement...", 1) — all 36 in exactly one
file, `PaymentMethodMapper.Codeunit.al`. Root cause, confirmed by reading the generated source: mutant id 1898
(`DEL` on the `exit;` statement of `PopulatePaymentMethodsWithConflictCheck`, codeunit 72282417) sits inside a
nested `if MutCond_2 then\n    if ConflictDetectSvc.DetectAllConflicts(...) then exit;` — an inner `if...then`
**without `begin…end`** whose condition and statement share one physical source line. The generator's Shape-A
statement-guard rewrite (§6.4.7) duplicated the full `if ConflictDetectSvc.DetectAllConflicts(...) then` prefix
onto **every line** of the multi-line `case true of … end` replacement instead of inserting it once — a
rewrite-offset bug in the generator for this specific nested-if code shape, not a compiler resource ceiling.
Mutant id 1898 is confirmed absent from both `w-1364`'s and `w-5000`'s `mutants.json` (grep, zero matches) —
neither smaller sample happened to draw it; its absence there is sampling luck, not evidence the bug is
scale-gated, and nothing here rules out the same shape recurring elsewhere in the app.

**Deep probe** (`--only-objects <top5 by mutant count from w-all> --max-mutants 0`):

| rank | objectId | objectName | mutant count | largest single-procedure count |
|---|---|---|---|---|
| 1 | 71553638 | CTS-CB Payment Entry Mgt. | 521 | **53** (`SetQRInvoice`) |
| 2 | 71553671 | CTS-CB Authentication | 476 | 29 (`CopyPmtMthMapToAccount`) |
| 3 | 71553836 | CTS-CB Payment Allocation Mgt. | 349 | 33 (`CheckPaymentAllocationModificationAllowed`) |
| 4 | 71553593 | CTS-CB Yapily Export | 322 | 37 (`SendPaymentFromRegister`) |
| 5 | 71553697 | CTS-CB Bank Acc. Com. Setup | 250 | 33 (`SetDefaultCommunicationForAccount`) |

d-top5: **1918 mutants**, 128,735 lines (+8,532, 4.45 lines/mutant — closest of any label to the pilot's 4.4),
compile **29s, 0 errors, 73 warnings**, `.app` produced at 4.53 MB. **No per-method/IL limit was hit** at the
densest concentration tested (53 mutants, and 53 added `MutCond_<n>: Boolean` locals plus nested `case true of`
guard blocks, in one procedure).

**Guard overhead (optional final step, run because w-1364 compiled with 0 errors).** Published w-1364's `.app`
to `mut-spike-02`, PATCHed `mutationSetup(0)` to `activeMutantId = 0`, and ran codeunits 95155/95179/95191 once
via `Invoke-MutTests`: 51/51 passed, wall clock **31.59s**. Restored the plain AUT (`out/aut-original`'s
existing 29.0.0.0 `.app`) and re-ran the identical call: 51/51 passed, wall clock **32.59s**. Same-session,
apples-to-apples ratio: **31.59 / 32.59 ≈ 0.97×** — no measurable slowdown, consistent with the guard-overhead
finding above (22.4× only shows up in a synthetic tight loop, not in this suite). Note: this doc has no
recorded combined-3-codeunit uninstrumented baseline to compare against — only a single-codeunit figure
(`mut-spike-02 baseline (codeunit 95155)`: 13.4s) exists above; this task's own same-session plain-AUT
measurement (32.59s, 51 tests) is the only true 3-codeunit uninstrumented figure available and is what the
ratio uses. Environment restored: plain AUT published, 51/51 pass, `activeMutantId = 0` confirmed by a
follow-up GET.

**Finding.** The schemata approach scales cleanly through and beyond the production sampling default: 1364
and 5000 mutants both compile in ~22–24s with 0 errors and a stable ~4.6 MB app, and concentrating up to 1918
mutants into 5 objects (53 in one procedure) still compiles cleanly in 29s — the deep, per-method IL-limit
failure mode this task set out to find was not observed at any tested concentration. It breaks only at the
unsampled whole-app extreme, and not from size: it fails fast on a real generator rewrite bug in the
statement-guard shape for a nested, un-blocked `if...then` sharing a line with its mutated statement, and it
was sampling luck that neither production-realistic sample (1364, 5000) happened to draw the one mutant that
exposes it. What would have to change: the Shape-A rewrite in §6.4.7 needs to insert the guard block once,
after the un-blocked `if...then` prefix, not once per output line — a generator fix, paired with a survey of
how many other candidates share this code shape before whole-app generation is trusted again.

## Full-scale build

*Date: 2026-09-18. Source task: M8, commit 1b9a5ef. Fixes the one failure the scaling curve above found; closes
the question the previous section left open.*

| Metric | Value |
|---|---|
| Root cause | `lineIndent()` (`generator/src/schemata.ts`) returned everything between the previous newline and the anchor token, not just whitespace — correct only when the anchor is the first token on its physical line. For a statement candidate sharing its line with its own un-blocked `if … then` (mutant id 1898, `PaymentMethodMapper.Codeunit.al`), it captured the literal `if <cond> then ` prefix, which the guard template then repeated on every line of the multi-line replacement — exactly the 36-error failure recorded above. |
| Fix | `lineIndent` now walks forward from the physical line's start counting only space/tab characters, applied uniformly to condition guards, statement guards, and declaration insertion. |
| TDD evidence | 3 new unit tests, confirmed red against the pre-fix code, green after; new golden case `fixtures/generator/06-shared-line-if-then/` added |
| Existing goldens | All 5 pre-existing golden cases stayed byte-identical |
| Generator suite | 113/113 green (109 pre-existing + 4 net new) |
| Full-project generation (seed 1, `--max-mutants 0`, same scope as the w-all run above) | 15,012 mutants (skipped 1,423), 15.2s — matches the scaling curve's w-all count exactly |
| Full-project compile | 20.5s, **0 errors**, 73 warnings, 0 info, `.app` produced, 4.68 MB |
| Mutant 1898 spot-check | Renders with the `if … then` prefix exactly once, correctly indented; compiles clean |

**Finding.** The failure was a rewriter defect specific to one code shape, not a scale limit: the identical
15,012-mutant scope that failed fast with 36 syntax errors at 15s now compiles clean at the same generation
time (15.2s) and a comparable compile time (20.5s vs. the earlier attempt's 15s-to-fail). Combined with the
scaling curve above, the schemata mechanism is now shown to generate and compile at true whole-project scale
with 0 errors. This build was not itself re-published — no publish or test job was run in this task — but it
is the same size class as w-1364 (4.68 MB vs. 4.56 MB), which was published to `mut-spike-02` and restored
cleanly in the scaling-curve task; nothing in the size difference between the two builds suggests publish
would behave differently.

