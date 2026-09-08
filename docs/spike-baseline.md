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

## U5

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|

## U6

| Metric | Value | Backend | Date | Source task |
|---|---|---|---|---|

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
