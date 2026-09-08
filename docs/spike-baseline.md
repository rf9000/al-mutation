# Spike baseline

Numbers recorded by each spike task, per §7.6 of `docs/SPEC.md`.

## Environment

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| Environment Id | 30004698-209d-467c-96eb-9b412e9ee6ee | DemoPortal | 2026-09-07 | T03 |
| CreateDurationSec | n/a (created in attempt 2 at 2026-09-07 13:42:53 UTC; started manually) | DemoPortal | 2026-09-07 | T03 |
| StartDurationSec | 0 | DemoPortal | 2026-09-07 | T03 |
| ActivationInstallDurationSec | 2.0046002 | DemoPortal | 2026-09-07 | T03 |

## U1/U3

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|

## U4

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
| eventsFire | yes — `OnBeforeTestMethodRun`/`OnAfterTestMethodRun` on codeunit 130454 fire under the DemoPortal test job; runner chain seen in a live stack trace: `"Test Runner - Isol. Codeunit"(130450).OnRun` → `"Test Runner - Mgt"(130454).RunTests` → `"Test Suite Mgt."(130456)` → `"Command Line Test Tool"(130455)`. | DemoPortal | 2026-09-08 | T04b |
| tableReadInTestSession | no — `Setup.Get(0)` inside `MUT Test Hooks` (declared `Permissions = tabledata "MUT Mutation Setup" = R`) is denied even for a SUPER user granted permission set "MUT Core All": `Sorry, the current permissions prevented the action. (TableData 50000 MUT Mutation Setup IndirectRead: Mutation Core)`. An API session as the same user reads/writes the table fine — only the DemoPortal test job's runtime is restricted. | DemoPortal | 2026-09-08 | T04b |
| experimentA_disabledMode | pass — with `TestPermissions = Disabled;` added to codeunit 50400 "MUT Mut Tests", `test run <env> 50400 --json` → 4 total, 4 passed, 0 failed; `HookErrorIsEmpty` passes (empty `LastHookError`). Confirms the restriction is TestPermissions-mode-specific, not a deeper platform limitation. Property reverted and core-app-test redeployed afterward (control only; not shipped). | DemoPortal | 2026-09-08 | T04b |
| experimentB_isolatedStorage | pass — table 50000 gained `OnInsert`/`OnModify` triggers calling `MirrorToIsolatedStorage()` (`IsolatedStorage.Set('ActiveMutantId'/'CurrentRunNo', Format(<field>, 0, 9), DataScope::Module)`); `MUT Test Hooks`' `TryReadActiveMutant` now reads `IsolatedStorage.Get(..., DataScope::Module, Value)` + `Evaluate(..., Value, 9)` instead of `Setup.Get(0)`, defaulting to 0 on a missing key. Under the DEFAULT (restrictive) TestPermissions mode, after PATCHing `mutationSetup(0)` once to write the mirror: `test run <env> 50400 --json` → 4 total, 4 passed, 0 failed; `HookErrorIsEmpty` passes. IsolatedStorage reads are not subject to table permissions, so this channel survives the restricted test session. | DemoPortal | 2026-09-08 | T04b |
| killedRowWrittenByHooks | yes — PATCHed `activeMutantId = 999, currentRunNo = 1`; `test run <env> 50301 --json` → 2 total, 1 passed (`U4_Passing`), 1 failed (`U4_Failing`, `errorMessage: "deliberate U4 failure"`); GET `mutantResults` returned exactly one row `{runNo:1, mutantId:999, status:"Killed", killingTest:"MUT Fx U4 Spike Tests:U4_Failing"}`. The brief expected this insert to probably fail (table-permission denial on `MUT Mutant Result`), but it succeeded live — the hooks codeunit's own `Permissions = tabledata "MUT Mutant Result" = RI` is sufficient for a direct `Insert()` executed inside the same codeunit (unlike the read, which failed only because of `GetOrCreate()`/table-method indirection in earlier rounds, see T04/T04-fix-round-2 in `docs/issues.md`). A follow-up run of codeunit 50400 (`HookErrorIsEmpty`) with `activeMutantId` still 999 confirmed no swallowed error (4/4 pass, `LastHookError` empty). Setup PATCHed back to `activeMutantId = 0, currentRunNo = 0` and confirmed via GET. | DemoPortal | 2026-09-08 | T04b |

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

## Tier B baseline

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|

## Hand mutants

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|

## Recommendation

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|
