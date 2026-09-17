# AL Mutation Testing for Business Central — Specification (v3)

This document is the source of truth for the `al-mutation` project. `docs/tasks.json` decomposes it into
tasks that a single implementing agent (Claude Sonnet 5) executes one at a time, reading only its task and
the spec sections the task cites. Anything an implementer needs must therefore be **in this document or in
the task**; nothing lives only in chat history. `docs/AL-MUTATION-TESTING-PLAN.md` (v2) is superseded by
this spec; keep it for history, do not update it.

Conventions in this document: "MUST" is a hard requirement checked by acceptance criteria. "SHOULD" is
the default unless a task says otherwise. "Deferred" means out of scope for this task list; open an issue
in `docs/issues.md` instead of building it.

---

## 1. Goal and scope

**Goal.** Measure test-suite quality for one Business Central AL app (the App Under Test, "AUT") by
generating mutants mechanically, compiling all of them into one "schemata" build of the AUT in which
each mutant is guarded by `MutationCore.Active(<id>)`, and running the covering tests once per mutant.
Output: a mutation score and a survivor list, exported as files in `results/`.

**AUT.** Continia Banking base application. Test app: Continia Banking base-application test suite.

| Item | Value |
|---|---|
| AUT source (read-only) | `C:\GeneralDev\AL\Continia Banking Master\Continia Banking\base-application` |
| AUT app id / version | `83461f48-dd16-49ea-b00c-e656830c640f` / `29.0.0.0` (was `28.5.0.0` on 2026-09-07) |
| AUT id ranges | 71553575–71553874, 72282325–72282424, 72282525–72282574, 72918625–72918824 |
| AUT runtime / platform / target | `18.0` / `29.0.0.0` / `Cloud` (was `17.0` / `28.0.0.0`; the AUT moved to BC 29 around 2026-09-16, which forced a second environment — see §1.1) |
| Test app source (read-only) | `C:\GeneralDev\AL\Continia Banking Master\Continia Banking\base-application-test` |
| Test app id / id range | `02b81fad-90fa-4cdc-a414-5bda25e96db0` / 94999–95999 |
| Rulesets (read-only) | `C:\GeneralDev\AL\Continia Banking Master\Continia Banking\Banking Rulesets\` — use `.cli-ruleset-localdeploy.json` |
| AUT size | 1,065 AL files, 451 codeunits, ~5,500 `if` lines. Test app: 181 test codeunits, ~2,144 `[Test]` methods |

### 1.1 POC slice (this task list)

The full suite is **not** run in this task list. Everything is proven on two tiers first:

**Tier A — fixture apps.** A tiny AUT (`fixtures/fixture-aut`) and test app (`fixtures/fixture-test`)
written for this project. Used to prove the whole mechanism end to end (§6.3) and as the acceptance
fixture for generator and orchestrator.

**Tier B — real AUT slice.** One AUT codeunit and the test codeunit that exercises it:

| AUT codeunit | Id | File (relative to AUT root) | Covered by test codeunit |
|---|---|---|---|
| CTS-CB Auth Share Detection | 72918635 | `Authentication\Codeunit\AuthShareDetection.Codeunit.al` | 95155 "CTS-CB Test Auth Share Detect" (13 tests) |

Test codeunit file: `Authentication\TestAuthShareDetect.Codeunit.al` (relative to the test app root). Test 95155 also
references `CTS-CB Upgrade To 28xxx` and `CTS-CB Http Factory`; coverage rows for those objects are filtered out, not an error.
**The AUT repo is a moving target** (the owning team merges daily; on 2026-09-08 the previously planned objects 72918690 /
72918691 and test codeunit 95913 were no longer present, and by 2026-09-16 the whole app had moved from BC 28 to BC 29).
`Sync-MutAutCopy` snapshots the working tree at run time; every live task re-verifies that its target objects exist in the
copy before using them, checks that `app.json`'s `platform`/`application` still match the target environment's BC version,
and records drift in `docs/issues.md`.

**Two environments (2026-09-17).** `mut-spike-01` is a BC 28.1 sandbox and stays the Tier A (fixture) environment — the
fixture apps and the §8 acceptance run live there. Tier B needs a BC 29 environment (`mut-spike-02`, profile
`ff24b00b-ea9b-4311-8191-81b8370f0a0a`, build 29.0.54011.54239) because BC refuses an app whose `platform`/`application`
is newer than the server. `mutation.fixture.config.json` points at `mut-spike-01`, `mutation.config.json` at `mut-spike-02`.
Mutation Core (platform 28.0.0.0, runtime 17.0) installs on both: BC accepts an app built against an older platform, and its
Microsoft "Test Runner" 28.0.0.0 dependency is satisfied by the 29.x runner.

**Gate G1 — full baseline.** Running all 181 test codeunits (baseline + coverage) is required before
the first full mutation run, but only after the go decision at Gate G0 (§8). It is the last task in the list
and is blocked until a human writes "go" into `docs/spike-baseline.md`.

### 1.2 Non-goals and deferred items

Not in v1 at all: expression-level mutants inside assignments or arguments; per-commit runs; AI-generated
mutants; a general AL parser; a custom `TestRunner` codeunit (see §6.1.6); Docker backend implementation
(interface is defined, module is a stub that throws `NotImplemented`).

Deferred from the v2 plan into `docs/issues.md`, with the reason:

| Item | Reason |
|---|---|
| Operators GUARDCOLLAPSE, GUARDSPLIT | Need compound-statement end detection (nested `if` with dangling `else`). v1 detects simple statements and conditions only. |
| Mutating `while` conditions | Requires body rewriting (`while true do begin … break`). v1 mutates `if` and `until` conditions only. |
| Mutating `if` conditions in `else if`, `then if`, `do if`, or case-branch position | Requires wrapping the whole `if` statement in `begin…end`, which needs compound-statement end detection. |
| Objects other than codeunits (table/page triggers) | Same tokenizer would work; cut for POC size. |
| Phase 4 triage page, Phase 5 incremental runs, Suggest-Test | After Gate G0. |

---

## 2. Verified facts (design MUST respect all)

| # | Fact | Consequence |
|---|---|---|
| F1 | AL `and`/`or`/`xor` have **no short-circuit guarantee** (Microsoft docs; BCQuality article `boolean-operators-do-not-short-circuit`). | Never emit `MutationCore.Active(id) and <expr>` or `… or <expr>`. The lint in §6.4.10 fails the build if found. |
| F2 | AL **does** have a conditional (ternary) expression on current runtimes (`cond ? a : b`; confirmed live in the AUT on runtime 18, e.g. `TemplateValues.Codeunit.al`) — the tokenizer must lex `?` as an operator (§6.4.1). v1 still mutates at statement level regardless: F1 (no short-circuit guarantee) and F3 (eager argument evaluation) are the binding reasons, independent of whether a ternary exists. | The tokenizer lexes `?`; no operator behaviour changes and mutants are still lifted to statement level. |
| F3 | Procedure arguments are evaluated eagerly. | Never pass a mutated expression as an argument to select it. |
| F4 | `case` executes **the first matching value set** (Microsoft docs). | `case true of` is the only documented lazy construct. It is the **only guard template** used (§6.4.7). |
| F5 | Test runner before/after hooks run in their own transaction. Microsoft's runner commits before raising `OnAfterTestMethodRun`. | Set the active id and write results from event subscribers, never from inside tests. Whether a subscriber's write survives a failed test is U4. |
| F6 | SingleInstance codeunit state persists until the company is closed. | Set the active id explicitly in the before-method subscriber every time. |
| F7 | DemoPortal runs one test codeunit per job (`continia test run <envId> <codeunitId> [functionName]`), jobs strictly sequential, no TestRunner codeunit id can be passed. | Targets are whole test codeunits (optionally one function). Never run two jobs concurrently. |
| F8 | DemoPortal returns coverage per job: `continia test coverage <envId> <jobId>` (CSV, or `--json` envelope `{ envId, jobId, csv }`). | Coverage granularity is per test codeunit. Format is observed in U9 and pinned as `fixtures/coverage/sample.csv`. |
| F9 | No per-test timeout exists in the platform or the CLI; `--timeout` is a client-side wait. | Wall-clock kill lives in the orchestrator (§6.5.6). Server-side cancel is U5. |
| F10 | The mutated AUT calls `MutationCore.Active()`, so schemata AUT depends on Mutation Core; the test app depends on the AUT. | Mutation Core never depends on the AUT and never ships to customers. |
| F11 | DemoPortal environments are created from a profile, start in 1–3 min, run BC 28.1, and need the Continia Core Internal Activation App (`c3755ece-dab0-4d16-987d-040661f18522`) before agents can use them. The AUT's dependencies are installed with `continia deps install <envId> <appPath>`. | `New-MutEnvironment` performs these steps (§6.5.3). |
| F12 | `continia compile`/`deploy` wrap `alc.exe`, refresh symbols from the target env into `<appPath>/.alpackages`, and return `diagnostics[] {severity, code, file, line, column, message}` with `file` relative to the app path. `.cli-ruleset-localdeploy.json` includes `./.cli-ruleset.json` by relative path. | Copy the whole `Banking Rulesets` folder; compile-error → mutant mapping reads `diagnostics[]`. |
| F13 | The standard runner is **codeunit 130454 "Test Runner - Mgt"** (Microsoft "Test Runner" app `23de40a6-dfe8-4f80-80db-d70f83ce8caf`), namespace `System.TestTools.TestRunner`. The v2 plan's "130450" was wrong. Exact publishers: see §6.1.4. | Subscribe by name: `Codeunit::"Test Runner - Mgt"`. |
| F14 | A non-namespaced app can reference objects from namespaced apps without `using` when the name is unambiguous (the Banking test app does `Assert: Codeunit Assert;` with no `using`). | Mutation Core and fixtures use **no namespace**. |
| F15 | Toolchain: `continia.exe` 0.24.0 at `.tools/continia.exe`, auth via API token (already configured); Node 22.19, npm 11.10; Windows PowerShell 5.1 is the shell; Pester 3.4.0 is preinstalled (too old). | Orchestrator targets PowerShell 5.1 (no `&&`, no ternary, `ConvertFrom-Json` returns PSCustomObject). Tests use Pester 5 installed per user (§9). Generator uses TypeScript compiled with `tsc`, tests with `node --test`. |
| F16 | BC 28.1 profile "BASE Business Central 28.1": id `cc557829-71df-40ee-9516-98ca954d4b2f`, build `28.1.49838.50268`. Test Runner symbol version on that build: `28.1.49838.50268`. | Config default `demoPortal.profileId`. |
| F17 | `continia deploy` compiles in place: it writes `.alpackages/` and the built `.app` under the app path it is given. | **Never point the CLI at the real AUT or test app folders.** Build only from copies under `out/` (§4, §6.5.2). |
| F18 | `continia test run --json` returns `{ status, passed, summary {total, passed, failed, skipped, durationSeconds, codeunitName}, tests[] {name, fullName, result, durationSeconds, errorMessage, stackTrace} }`; exit code 1 when tests fail; a job id field is not documented. | `Invoke-MutTests` must not rely on exit code. Whether a job id is exposed is U9. |

---

## 3. Unknowns and the spike that resolves each

Every spike records its numbers in `docs/spike-baseline.md` (template §7.6) together with the backend
name and the date.

| # | Question | Spike (task) | Decision rule |
|---|---|---|---|
| U1 | Does `alc.exe` accept ~500 `case true of MutationCore.Active(n)` blocks in one codeunit, and what do compile and publish cost? | `spikes/u1-guard-bench` | If compile > 10 min or publish fails: chunk schemata generation per object folder (`--only-objects`). |
| U2 | How much does covering-test selection save on this suite? Measured as (tests covering an object) / (all tests) for the Tier B objects, plus median over all AUT codeunits at Gate G1. | Tier B baseline; Gate G1 | Provisional in POC. Sets `--max-mutants` default. |
| U3 | Overhead of a `case true of MutationCore.Active(n)` guard in a 100k-iteration loop. | `spikes/u1-guard-bench` | If > 2× slowdown, `Active()` becomes a global-variable compare inside the AUT (id copied once per test). |
| U4 | Do `OnBeforeTestMethodRun`/`OnAfterTestMethodRun` on codeunit 130454 fire under the DemoPortal test job, and does the after-subscriber's insert survive a failed test? | `spikes/u4-runner-events` | **Answered 2026-09-08 (spike U4b):** events fire (runner chain "Test Runner - Isol. Codeunit" 130450 → "Test Runner - Mgt" 130454); the test session cannot read Mutation Core tables (even indirect read is denied for SUPER users), so the hooks read the active id from Isolated Storage (§6.1.2, §6.1.4); the Killed row inserted by the after-hook for a failed test IS persisted (`{runNo 1, mutantId 999, Killed, 'MUT Fx U4 Spike Tests:U4_Failing'}`). §5 step 5 remains as a fallback. |
| U5 | Can a running DemoPortal test job be stopped? How long does `env stop` + `env start` take? | `spikes/u5-u6` | Sets `Reset-MutEnvironment` implementation and the timeout budget. |
| U6 | How to replace the installed AUT with the schemata build while the test app depends on it. Options: (a) `continia publish` same id + same version (CLI auto-unpublishes; BC may refuse with dependents), (b) same id + bumped build number `28.5.0.1`, (c) unpublish test app → publish schemata → republish test app. | `spikes/u5-u6` on fixture apps | Sets `schemata.publishStrategy` in config. |
| U7 | Fixed cost of one DemoPortal job (single-method test) and duration of test codeunits 95155 and 95913. | Tier B baseline | Sets `timeouts.jobOverheadSeconds` and the sampling default. |
| U8 | The BC API base URL and credentials for a DemoPortal environment. `env get --json` returns a portal `url`; the API root is expected at `<url>/api/v2.0/companies` with Basic auth from `continia env users <envId> --json`. | `Invoke-MutApi` task | If 404: inspect `continia --help` for an API/URL command and `env get` output for a web-service URL; record the working pattern in `docs/spike-baseline.md`. |
| U9 | Does `test run --json` expose the job id needed by `test coverage`? What are the CSV columns? | Tier B baseline | **Answered 2026-09-08:** `--json` does not expose it; `--raw` prints `Test job started: <N>` before the xUnit XML (§6.5.3 Invoke-MutTests). CSV: no header, five positional columns ObjectType, ObjectId, LineType, LineNo, Hits (§6.5.5, `fixtures/coverage/sample.csv`). |

---

## 4. Guardrails (apply to every task)

1. **The AUT repo is read-only.** Nothing under `C:\GeneralDev\AL\Continia Banking Master\Continia Banking` may be created, modified, deleted, compiled in place, or used as a CLI target. Read/Grep/Glob only. All builds run against copies under `out/` produced by `Sync-MutAutCopy` (§6.5.2). Hand mutants are applied to the copy.
2. **Environment names.** Every DemoPortal environment this project creates or targets MUST have a description starting with `mut-`. Every backend function that takes an environment MUST refuse (throw) if the description does not match `^mut-` or if `shared` is `true`. Never target an environment created by someone else.
3. **No short-circuit guards.** Never emit `MutationCore.Active(<id>)` on either side of `and`/`or`/`xor`, nor as a procedure argument (F1, F3). `generator lint` enforces this; it runs in the generator test suite and in `Build-Schemata`.
4. **Do not invent AL syntax.** If a construct is not documented under `learn.microsoft.com/…/dev-itpro/developer/`, do not emit it. The only emitted constructs are: `case true of … else … end;`, `begin end;`, local variable declarations, and copies of existing statements/conditions.
5. **History lives in files.** Every run exports `results/<run>.json` and `results/<run>-summary.md`. BC tables are a cache.
6. **Backend isolation.** `orchestrator/Invoke-MutationRun.ps1` and `orchestrator/lib/*.psm1` MUST NOT contain the strings `continia`, `BcContainerHelper`, or `docker`. Only `orchestrator/backends/*.psm1` may. One exemption: the line in `lib/Config.psm1` that defines the allowed backend names carries the marker comment `# isolation-lint: allow`, and the isolation test (§8 item 3) skips lines with that marker.
7. **Mutation Core never depends on the AUT** and errors on install unless `EnvironmentInformation.IsSandbox()` is true (§6.1.5).
8. **Sequential test jobs.** Never start a DemoPortal test job while another is running.
9. **Diagnostic, not a gate.** The mutation score is reported; it is never wired into CI as a pass/fail gate in v1.
10. **Commit discipline.** Each task ends with one commit whose message is given in the task. Never commit `out/`, `.alpackages/`, `*.app` (except under `fixtures/`), `node_modules/`, `.tools/`, `.continia/`.

---

## 5. Runtime handoff (how a mutant is activated and a kill recorded)

1. Orchestrator PATCHes `mutationSetup` via the Mutation Core API: `activeMutantId = <id>`, `currentRunNo = <run>`.
2. Orchestrator calls `Invoke-MutTests` for the mutant's covering test codeunits (§6.5.5).
3. The standard runner raises `OnBeforeTestMethodRun` before every test method → `MUT Test Hooks` reads `MUT Mutation Setup` and calls `MutationCore.SetActive(activeMutantId)`.
4. The standard runner raises `OnAfterTestMethodRun` after every method → if `IsSuccess = false`, `activeMutantId <> 0`, and no `MUT Mutant Result` exists for (run, mutant), the hook inserts one with `Status = Killed`, `Killing Test = CodeunitName + ':' + FunctionName`.
5. Orchestrator reads the normalized test result. If any test failed and GET `mutantResults` has no row for (run, mutant), the orchestrator POSTs the row itself (fallback if U4 shows subscriber writes roll back). If all tests passed, the orchestrator POSTs `Survived`.
6. Baseline runs use `activeMutantId = 0`; hooks then do nothing except `SetActive(0)`.

---

## 6. Component specifications

### 6.0 Repository layout

```
/core-app                 AL app "Mutation Core"                     (§6.1)
/core-app-test            AL test app for Mutation Core              (§6.2)
/fixtures/fixture-aut     AL fixture AUT                             (§6.3)
/fixtures/fixture-test    AL fixture test app                        (§6.3)
/fixtures/expected-results.json                                      (§7.4)
/fixtures/tokenizer       tokenizer golden files                     (§6.4.1)
/fixtures/generator       generator golden cases                     (§6.4.11)
/fixtures/coverage        sample.csv from U9                         (§6.5.5)
/generator                TypeScript generator                       (§6.4)
/orchestrator             PowerShell orchestrator                    (§6.5)
   Invoke-MutationRun.ps1
   /lib/*.psm1
   /backends/DemoPortal.psm1, Docker.psm1
   /tests/*.Tests.ps1
/spikes                   throwaway experiments U1–U9                (§6.6)
/docs                     SPEC.md, tasks.json, spike-baseline.md, issues.md, PLAN v2
/results                  committed run artifacts
/out                      ignored: AUT copies, schemata, build output
/.tools, /.continia       ignored
mutation.config.json      Tier B config                              (§6.5.1)
mutation.fixture.config.json  Tier A config                          (§6.5.1)
```

`.gitignore` already contains `.tools/`, `.continia/`, `.alpackages/`, `out/`, `*.app`, `!fixtures/**/*.app`, `node_modules/`. Add `generator/dist/`.

### 6.0.1 Fixed identifiers

| App | App id | Publisher | Version | Id range |
|---|---|---|---|---|
| Mutation Core | `6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b` | Continia Software | 1.0.0.0 | 50000–50199 |
| Mutation Core Test | `7a2e3d4b-9c5f-4e6a-8b7c-8d9e0f1a2b3c` | Continia Software | 1.0.0.0 | 50400–50499 |
| MUT Fixture AUT | `8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d` | Continia Software | 1.0.0.0 | 50200–50299 |
| MUT Fixture Test | `9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e` | Continia Software | 1.0.0.0 | 50300–50399 |
| MUT Guard Bench (spike U1/U3) | `ad5b6a7e-cf8c-4b9d-9eaf-1a2b3c4d5e6f` | Continia Software | 1.0.0.0 | 50500–50599 |

All apps: `runtime "17.0"`, `platform "28.0.0.0"`, `application "28.0.0.0"`, `target "Cloud"`, features `["NoImplicitWith"]`, no namespace. Microsoft dependency versions are `28.0.0.0`. Object prefix `MUT`.

### 6.1 Mutation Core app (`core-app/`)

`app.json` dependencies: exactly one — Microsoft "Test Runner" `23de40a6-dfe8-4f80-80db-d70f83ce8caf` version `28.0.0.0`. `idRanges` 50000–50199.

#### 6.1.1 Enum 50000 "MUT Mutant Status"
Values: `0 Pending`, `1 Killed`, `2 Survived`, `3 Equivalent`, `4 Timeout`, `5 CompileError`, `6 Uncovered`. `Extensible = false`.

#### 6.1.2 Tables

**Table 50000 "MUT Mutation Setup"** (single record, `DataPerCompany = false`):
`1 "Primary Key" Integer` (PK, always `0`), `2 "Active Mutant Id" Integer`, `3 "Current Run No." Integer`.
Procedure `GetOrCreate()` does `if not Get(0) then begin Init(); "Primary Key" := 0; Insert(); end;`. The API
URL for PATCH is therefore `mutationSetup(0)`.
Triggers `OnInsert` and `OnModify` call `MirrorToIsolatedStorage()`: `IsolatedStorage.Set('ActiveMutantId', Format("Active Mutant Id", 0, 9), DataScope::Module)` and the same for `'CurrentRunNo'`. This mirror is the channel the hooks read (§6.1.4): Isolated Storage in module scope needs no table permission, unlike the table itself, which is unreadable inside the restricted test session (verified 2026-09-08, spike U4b).

**Table 50001 "MUT Mutant"** (`DataPerCompany = false`):
`1 Id Integer` (PK), `2 "Stable Key" Text[50]` (secondary unique key), `3 "Object Type" Option Codeunit,Table,Page,Report,Enum` (only Codeunit is used in v1), `4 "Object Id" Integer`, `5 "Procedure Name" Text[128]`, `6 "Line No." Integer`, `7 Operator Code[20]`, `8 "Original Text" Text[250]`, `9 "Mutated Text" Text[250]`, `10 Status Enum "MUT Mutant Status"`.

**Table 50002 "MUT Mutation Run"** (`DataPerCompany = false`):
`1 "Run No." Integer` (PK), `2 Started DateTime`, `3 Finished DateTime`, `4 Commit Text[50]`, `5 Backend Code[20]`, `6 Total Integer`, `7 Killed Integer`, `8 Survived Integer`, `9 Score Decimal`.

**Table 50003 "MUT Mutant Result"** (`DataPerCompany = false`):
PK `1 "Run No." Integer`, `2 "Mutant Id" Integer`; `3 Status Enum "MUT Mutant Status"`, `4 "Duration Ms" Integer`, `5 "Killing Test" Text[250]`, `6 "Recorded At" DateTime`.

#### 6.1.3 Codeunit 50000 "MUT Mut"
`SingleInstance = true`, `Access = Public`. Global `ActiveId: Integer`.
```al
procedure SetActive(Id: Integer)          // ActiveId := Id
procedure Active(Id: Integer): Boolean    // exit(Id = ActiveId)  — MUST NOT touch the database (U3)
procedure Reset()                         // ActiveId := 0; LastHookError := ''
procedure GetActive(): Integer            // exit(ActiveId)
procedure SetLastHookError(ErrorText: Text)   // diagnostics: the hooks store the last swallowed error here
procedure GetLastHookError(): Text            // read by the diagnostic test in the same session (F6)
```

#### 6.1.4 Codeunit 50001 "MUT Test Hooks"
`Access = Internal`. `Permissions = tabledata "MUT Mutation Setup" = R, tabledata "MUT Mutant Result" = RI;`
**DemoPortal test sessions run under a restricted user, not SUPER.** Every table access in the hooks must be executed by
code inside this codeunit (Get/Insert on record variables declared here) so the `Permissions` property applies. A table
method such as `GetOrCreate()` runs in the table object, is denied, and the resulting error in `OnBeforeTestMethodRun`
makes the runner skip every test (observed 2026-09-08). `GetOrCreate()` is for `MUT Install` only.

```al
[EventSubscriber(ObjectType::Codeunit, Codeunit::"Test Runner - Mgt", OnBeforeTestMethodRun, '', false, false)]
local procedure OnBeforeTestMethodRun(var CurrentTestMethodLine: Record "Test Method Line"; CodeunitID: Integer; CodeunitName: Text[30]; FunctionName: Text[128]; FunctionTestPermissions: TestPermissions; var Skip: Boolean)
// ClearLastError(); if TryReadActiveMutant(Id, RunNo) then MutationCore.SetActive(Id)
// else begin MutationCore.SetActive(0); MutationCore.SetLastHookError('Before ' + FunctionName + ': ' + GetLastErrorText()); end;
// TryReadActiveMutant is a [TryFunction] that reads IsolatedStorage.Get('ActiveMutantId', DataScope::Module, Value) and
// 'CurrentRunNo' (missing key → 0), Evaluate(…, Value, 9). It does NOT read the table: inside the restricted test session the
// table is unreadable even for SUPER users, while Isolated Storage (module scope) works (spike U4b, 2026-09-08).
// The hooks MUST never raise an error: an error in OnBeforeTestMethodRun makes the platform skip the test.

[EventSubscriber(ObjectType::Codeunit, Codeunit::"Test Runner - Mgt", OnAfterTestMethodRun, '', false, false)]
local procedure OnAfterTestMethodRun(var CurrentTestMethodLine: Record "Test Method Line"; CodeunitID: Integer; CodeunitName: Text[30]; FunctionName: Text[128]; FunctionTestPermissions: TestPermissions; IsSuccess: Boolean)
// if IsSuccess then exit; if FunctionName = '' then exit;
// ClearLastError(); if not TryReadActiveMutant(Id, RunNo) then begin MutationCore.SetLastHookError('After ' + FunctionName + ': ' + GetLastErrorText()); exit; end;
// if Id = 0 then exit;
// if MutantResult.Get(Setup."Current Run No.", Setup."Active Mutant Id") then exit;
// insert MutantResult: Status Killed, "Killing Test" = CopyStr(CodeunitName + ':' + FunctionName, 1, 250), "Recorded At" = CurrentDateTime()
```
These signatures are copied from `TestRunnerMgt.Codeunit.al` in BCApps (lines 265 and 270) and MUST be used verbatim. `Test Method Line` and `TestPermissions` resolve from the Test Runner dependency (F14).

#### 6.1.5 Codeunit 50002 "MUT Install"
`Subtype = Install`. `OnInstallAppPerDatabase`: `if not EnvironmentInformation.IsSandbox() then Error(NotSandboxErr)` where `NotSandboxErr: Label 'Mutation Core can only be installed in a sandbox environment.'`. Then `Setup.GetOrCreate()`.

#### 6.1.5b PermissionSet 50000 "MUT Core All"
`Assignable = true; Caption = 'Mutation Core - all'`. Permissions: `tabledata` RIMD and `table` X for all four MUT tables; `codeunit` X for the three codeunits; `page` X for the four API pages.
**Why:** DemoPortal test sessions run under a restricted user (§6.1.4). A codeunit's `Permissions` property only elevates
permissions the user already holds indirectly, so the environment users MUST be granted this set (via `Grant-MutPermissionSet`,
§6.5.3) before the hooks can read the setup row. Without it the hooks swallow a permission error and every mutant looks inactive;
the `HookErrorIsEmpty` test (§6.2) detects that state.

#### 6.1.6 Custom TestRunner (deferred)
A `SubType = TestRunner` codeunit that loops over mutants in one session would remove per-job overhead but cannot be used on DemoPortal (F7). Not built in v1; recorded in `docs/issues.md`.

#### 6.1.7 API pages (`APIPublisher = 'mutation'`, `APIGroup = 'core'`, `APIVersion = 'v1.0'`, `DelayedInsert = true`, `ODataKeyFields` = the PK)

| Page | EntityName / EntitySetName | Source | Fields (API name → field) |
|---|---|---|---|
| 50000 "MUT Mutants API" | `mutant` / `mutants` | MUT Mutant | `id`, `stableKey`, `objectType`, `objectId`, `procedureName`, `lineNo`, `operator`, `originalText`, `mutatedText`, `status` |
| 50001 "MUT Mutation Runs API" | `mutationRun` / `mutationRuns` | MUT Mutation Run | `runNo`, `started`, `finished`, `commit`, `backend`, `total`, `killed`, `survived`, `score` |
| 50002 "MUT Mutant Results API" | `mutantResult` / `mutantResults` | MUT Mutant Result | `runNo`, `mutantId`, `status`, `durationMs`, `killingTest`, `recordedAt` |
| 50003 "MUT Mutation Setup API" | `mutationSetup` / `mutationSetup` | MUT Mutation Setup | `primaryKey` (Integer, always 0, `ODataKeyFields`), `activeMutantId`, `currentRunNo` |

All pages: `PageType = API`, `Editable = true` (PATCH must work on setup and mutants), `Extensible = false`.
URL pattern: `<apiBase>/api/mutation/core/v1.0/companies(<companyId>)/<entitySet>`.

#### 6.1.8 Acceptance
- `continia compile core-app --json` → zero errors with the ruleset in §9.3.
- `core-app-test` codeunit 50400 passes on `mut-spike-01`.
- U4 spike (§6.6.3) shows exactly one `mutantResults` row for the failing test.

### 6.2 Mutation Core test app (`core-app-test/`)
Dependencies: Mutation Core, Microsoft "Library Assert" `dd0be2ea-f733-4d65-bb34-a28f4624fb14`, Microsoft "Test Runner". Id range 50400–50499.

Codeunit 50400 "MUT Mut Tests", `Subtype = Test`:
- `SetActive_ThenActiveMatchesOnlyThatId`: `SetActive(5)`; `Active(5)` true; `Active(6)` false.
- `Reset_ClearsActive`: `SetActive(5)`; `Reset()`; `Active(5)` false; `GetActive()` = 0.
- `Active_ZeroWhenNothingSet`: fresh `Reset()`; `Active(0)` true (documented: id 0 means "no mutant").
- `HookErrorIsEmpty` (diagnostic, MUST be the last test in the codeunit so the hooks have run for the earlier tests): `Assert.AreEqual('', MutationCore.GetLastHookError(), 'MUT Test Hooks swallowed an error')`. When the hooks cannot read the setup row, this test fails and its message carries the real error text, which the CLI otherwise never shows.

### 6.3 Fixture apps

#### 6.3.1 `fixtures/fixture-aut` — "MUT Fixture AUT" (no dependencies)

**Table 50200 "MUT Fx Order"**: `1 "Entry No." Integer` (PK), `2 Quantity Integer`, `3 Amount Decimal`, `4 Posted Boolean`.

**PermissionSet 50200 "MUT Fx All"**: `Assignable = true`; `tabledata "MUT Fx Order" = RIMD`, `table "MUT Fx Order" = X`, `codeunit "MUT Fx Order Mgt" = X`. Granted to the environment users by the fixture configuration (§6.5.1 `permissionSets`) so the fixture tests can write the table under the restricted test session (§6.1.5b).

**Codeunit 50200 "MUT Fx Order Mgt"**, `Access = Public`. The bodies below are normative; the generator's expected results (§7.4) are derived from them, so implement them **exactly** (whitespace may differ, tokens may not).

```al
procedure IsLargeOrder(Quantity: Integer): Boolean
begin
    if Quantity >= 10 then
        exit(true);
    exit(false);
end;

procedure RequiresApproval(Amount: Decimal; IsTrusted: Boolean): Boolean
begin
    if (Amount > 1000) and (not IsTrusted) then
        exit(true);
    exit(false);
end;

procedure PostOrder(var FxOrder: Record "MUT Fx Order")
var
    QtyErr: Label 'Quantity must be positive.';
begin
    if FxOrder.Quantity <= 0 then
        Error(QtyErr);
    FxOrder.Posted := true;
    FxOrder.Modify(true);
end;

procedure CountBatches(Total: Integer; BatchSize: Integer): Integer
var
    Remaining: Integer;
    Batches: Integer;
begin
    Remaining := Total;
    Batches := 0;
    repeat
        Remaining -= BatchSize;
        Batches += 1;
    until Remaining <= 0;
    exit(Batches);
end;

procedure FirstMultipleAbove(Base: Integer; Threshold: Integer): Integer
var
    Candidate: Integer;
begin
    Candidate := 0;
    while true do begin
        Candidate += Base;
        if Candidate > Threshold then
            exit(Candidate);
    end;
end;
```

#### 6.3.2 `fixtures/fixture-test` — "MUT Fixture Test"
Dependencies: MUT Fixture AUT, Microsoft "Library Assert", Microsoft "Test Runner". Id range 50300–50399.

**Codeunit 50300 "MUT Fx Order Tests"** (`Subtype = Test`, `TestPermissions = Disabled;` — the restricted default mode denies table access to the fixture's own table even with `Permissions = tabledata "MUT Fx Order" = RIMD` declared and permission sets granted (spike U4b); 52 of the Continia test codeunits use the same setting. Keep the `Permissions` line too.) — the baseline suite. Codeunits 50301 and 50302 also set `TestPermissions = Disabled`. Tests, all MUST pass on the unmutated fixture:

| Test | Calls | Asserts |
|---|---|---|
| `IsLargeOrder_Twelve_IsTrue` | `IsLargeOrder(12)` | true |
| `IsLargeOrder_Three_IsFalse` | `IsLargeOrder(3)` | false |
| `RequiresApproval_LargeUntrusted_IsTrue` | `RequiresApproval(5000, false)` | true |
| `RequiresApproval_SmallUntrusted_IsFalse` | `RequiresApproval(100, false)` | false |
| `PostOrder_PositiveQty_SetsPosted` | insert order Qty 5, `PostOrder`, `Get` again | `Posted` true |
| `PostOrder_ZeroQty_Errors` | insert order Qty 0, `asserterror PostOrder` | error text = 'Quantity must be positive.' |
| `CountBatches_TenByThree_IsFour` | `CountBatches(10, 3)` | 4 |
| `CountBatches_NineByThree_IsThree` | `CountBatches(9, 3)` | 3 |
| `FirstMultipleAbove_Base3_Threshold9_IsTwelve` | `FirstMultipleAbove(3, 9)` | 12 |

Deliberately missing (so mutants survive): boundary `IsLargeOrder(10)`, boundary `RequiresApproval(1000, false)`, any trusted case for `RequiresApproval`.

**Codeunit 50301 "MUT Fx U4 Spike Tests"** (`Subtype = Test`, not part of the baseline): `U4_Passing` (asserts true) and `U4_Failing` (`Error('deliberate U4 failure')`).

**Codeunit 50302 "MUT Fx U5 Spike Tests"** (`Subtype = Test`, not part of the baseline): `U5_InfiniteLoop`: `while true do Sleep(1000);`.

#### 6.3.3 Expected mutation outcomes on the fixture (design-derived; see §7.4 for the file format)

| Procedure | Operator | Original → Mutated | Expected | Why |
|---|---|---|---|---|
| IsLargeOrder | REL | `Quantity >= 10` → `Quantity > 10` | Survived | no boundary test |
| IsLargeOrder | COND | → `true` | Killed | Three_IsFalse |
| IsLargeOrder | COND | → `false` | Killed | Twelve_IsTrue |
| IsLargeOrder | DEL | `exit(true)` removed | Killed | Twelve_IsTrue |
| IsLargeOrder | DEL | `exit(false)` removed | Survived | equivalent (default return is false) |
| RequiresApproval | REL | `Amount > 1000` → `>=` | Survived | no boundary test |
| RequiresApproval | BOOL | `and` → `or` | Killed | SmallUntrusted_IsFalse |
| RequiresApproval | NOT | `not IsTrusted` → `IsTrusted` | Killed | LargeUntrusted_IsTrue |
| RequiresApproval | COND | → `true` | Killed | SmallUntrusted_IsFalse |
| RequiresApproval | COND | → `false` | Killed | LargeUntrusted_IsTrue |
| RequiresApproval | DEL | `exit(true)` | Killed | LargeUntrusted_IsTrue |
| RequiresApproval | DEL | `exit(false)` | Survived | equivalent |
| PostOrder | REL | `Quantity <= 0` → `<` | Killed | ZeroQty_Errors |
| PostOrder | COND | → `true` | Killed | PositiveQty_SetsPosted |
| PostOrder | COND | → `false` | Killed | ZeroQty_Errors |
| PostOrder | DEL | `Error(QtyErr)` | Killed | ZeroQty_Errors |
| PostOrder | DEL | `FxOrder.Modify(true)` | Killed | PositiveQty_SetsPosted |
| PostOrder | INSFLAG | `Modify(true)` → `Modify(false)` | Survived | table has no OnModify logic |
| CountBatches | REL | `Remaining <= 0` → `<` | Killed | NineByThree_IsThree |
| CountBatches | COND | → `true` | Killed | TenByThree_IsFour |
| CountBatches | COND | → `false` | Timeout | loop never ends |
| CountBatches | DEL | `exit(Batches)` | Killed | both CountBatches tests |
| FirstMultipleAbove | REL | `Candidate > Threshold` → `>=` | Killed | Threshold9_IsTwelve (returns 9) |
| FirstMultipleAbove | COND | → `true` | Killed | returns 3 |
| FirstMultipleAbove | COND | → `false` | Timeout | never exits |
| FirstMultipleAbove | DEL | `exit(Candidate)` | Timeout | never exits |

The `while true do` condition is **not** mutated (deferred). Total expected: 26 mutants, 18 Killed, 5 Survived, 3 Timeout
(score per §7.3 = (18 + 3) / 26 = 0.8077).
With `--include-break` one extra `BREAK` mutant per simple statement is generated and expected `CompileError` (§6.4.5).

### 6.4 Generator (`generator/`, TypeScript)

Toolchain: `package.json` with `"type": "module"`, devDependencies `typescript@^5.6` and `@types/node`, scripts `build: tsc -p .`, `test: npm run build && node --test dist/test/*.test.js` (Node 22 on Windows rejects a bare directory argument). `tsconfig.json`: `target ES2022`, `module NodeNext`, `strict true`, `rootDir .`, `outDir dist`, `include ["src", "test"]`. No runtime dependencies. Node's built-in `node:test`, `node:assert/strict`, `node:crypto`, `node:fs`, `node:path` only.

Source files and their single responsibility:

| File | Exports |
|---|---|
| `src/tokenizer.ts` | `tokenize(source: string): Token[]` |
| `src/procedures.ts` | `findProcedures(tokens: Token[]): ProcedureSpan[]`, `findObjectHeader(tokens): ObjectHeader \| null` |
| `src/statements.ts` | `findSimpleStatements(tokens, span): SimpleStatement[]`, `findConditions(tokens, span): Condition[]` |
| `src/operators/rel.ts`, `bool.ts`, `not.ts`, `cond.ts`, `del.ts`, `insflag.ts`, `break.ts` | each: `export const <NAME>: Operator` |
| `src/operators/index.ts` | `OPERATORS: Record<OperatorName, Operator>`, `OPERATOR_ORDER` |
| `src/exclusions.ts` | `isExcludedFile(relPath, source): string \| null`, `isExcludedRegion(tokens, startIdx, endIdx): string \| null`, `isExcludedCondition(tokens, cond): string \| null` |
| `src/schemata.ts` | `rewriteFile(source: string, candidates: MutantCandidate[]): { output: string; lineMap: LineMapEntry[] }` |
| `src/manifest.ts` | `assignIds(candidates): Mutant[]`, `stableKey(c): string`, `sample(mutants, n, seed): Mutant[]` |
| `src/generate.ts` | `generate(options: GenerateOptions): GenerateResult` (whole pipeline, pure except file I/O via injected fs) |
| `src/lint.ts` | `lintSchemata(dir): LintFinding[]` |
| `src/cli.ts` | `generate` and `lint` subcommands |

#### 6.4.1 Tokenizer
```ts
type TokenKind = 'identifier' | 'quotedIdentifier' | 'keyword' | 'string' | 'number' | 'comment' | 'preprocessor' | 'operator' | 'punct';
interface Token { kind: TokenKind; text: string; start: number; end: number; line: number; column: number; }
```
Rules: `//` to end of line and `/* … */` are single `comment` tokens. `'…'` strings with `''` escape are one `string` token. `"…"` is one `quotedIdentifier`. A line starting (after whitespace) with `#` is one `preprocessor` token. Operators (longest match first): `:=` `<>` `<=` `>=` `::` `..` `+=` `-=` `*=` `/=` `<` `>` `=` `+` `-` `*` `/` `.` `|` `?` — `|` appears in AL filter expressions (e.g. `filter("A" | "B")`) and `?` is the AL conditional (ternary) operator (e.g. `cond ? a : b`); both are single-character operators, lexed as `operator` tokens and nothing else changes. Punct: `;` `:` `,` `(` `)` `[` `]` `{` `}` (braces delimit object bodies and property blocks; §6.4.2 depends on them). Numbers: digits with optional `.` fraction. Identifiers: `[A-Za-z_][A-Za-z0-9_]*`; a token whose lower-cased text is in the keyword list is `keyword`: `procedure trigger var begin end if then else while do repeat until case of for to downto foreach in exit not and or xor div mod true false local internal protected`. Lines are 1-based, columns 1-based. Whitespace is not tokenized; `start`/`end` are offsets into the source so text between tokens is preserved on rewrite.

Golden tests: `fixtures/tokenizer/<name>.al` + `<name>.tokens.json` (array of `{kind,text,line,column}`). Minimum cases: comments containing quotes, strings containing `//`, `''` escape, `<>` vs `<` `>`, `#if`/`#endif`, quoted identifier with spaces.

#### 6.4.2 Object header and procedure spans
```ts
interface ObjectHeader { objectType: string; objectId: number; objectName: string; }   // from the first tokens: keyword-like identifier `codeunit`, number, quotedIdentifier|identifier
interface ProcedureSpan { name: string; kind: 'procedure' | 'trigger'; headerStart: number; varKeywordIdx: number | null; beginIdx: number; endIdx: number; }
```
`findProcedures`: scan for `procedure`/`trigger` keywords at brace-depth 1 of the object (the object body is `{ … }`; note `{`/`}` are only used for object bodies and property blocks and are emitted as `punct`; track them). Name is the next token. Header continues to the first `var` or `begin` keyword outside parentheses. Body: from `begin`, depth += 1 on `begin` or `case`, depth −= 1 on `end`; `endIdx` is the `end` that returns depth to 0. The object-level `var` section is not a procedure.

#### 6.4.3 Simple statements and conditions
```ts
interface SimpleStatement { startIdx: number; endIdx: number; /* last token before the terminator */ terminator: 'semicolon' | 'none'; }
interface Condition { kind: 'if' | 'until'; keywordIdx: number; startIdx: number; endIdx: number; /* tokens of the condition */ terminatorIdx: number; /* the `then` or the `;`/`end`/`else`/`until` token after an until-condition */ position: 'statementList' | 'other'; }
```
Statement-start positions inside a body: the token after `begin`, `;`, `repeat`, `then`, `else`, `do`, and after `:` of a case branch (a `:` at paren-depth 0 inside a `case … of` block). A **simple statement** starts at such a position with an `identifier`/`quotedIdentifier`/`exit` token and is not a compound keyword (`if while repeat case for foreach begin with`). It ends at the first `;` at paren-depth 0 (`terminator: 'semicolon'`) or at `end`/`else`/`until` at depth 0 (`terminator: 'none'`). Assignments (`:=`, `+=` …) are simple statements too (needed for BREAK; DEL only targets the call list in §6.4.5).

A **condition** is: for `if`, the tokens between `if` and its matching `then` (paren-depth 0); for `until`, the tokens between `until` and the first `;`/`end`/`else`/`until` at depth 0. `position` is `statementList` when the token before `if` is `begin`, `;`, or `repeat` (for `until` always `statementList`). Only `statementList` conditions are mutated (§1.2).

#### 6.4.4 Operator interface and candidates
```ts
type OperatorName = 'REL' | 'BOOL' | 'NOT' | 'COND' | 'DEL' | 'INSFLAG' | 'BREAK';
interface MutantCandidate {
  id?: number;                         // assigned by manifest.assignIds (§6.4.8); required by schemata.rewriteFile
  operator: OperatorName; objectType: string; objectId: number; objectName: string; procedureName: string;
  line: number;                        // 1-based line of the first token of the original span
  target: { kind: 'condition'; cond: Condition } | { kind: 'statement'; stmt: SimpleStatement };
  original: string;                    // original condition or statement text (tokens joined with original spacing)
  mutated: string;                     // replacement text; '' for DEL
  occurrence: number;                  // 0-based index among candidates with the same (procedure, operator, original, mutated)
}
interface Operator { name: OperatorName; kind: 'condition' | 'statement'; apply(ctx: { tokens: Token[]; span: ProcedureSpan; header: ObjectHeader; source: string }, target: Condition | SimpleStatement): MutantCandidate[]; }
// `source` is the original file text; `original`/`mutated` are built from source slices by token offsets so spacing is preserved.
// Operators emit occurrence = 0; the pipeline calls assignOccurrences(candidatesOfOneProcedure) (src/operators/types.ts),
// which fills `occurrence` per (operator|original|mutated) group in order.
```
`OPERATOR_ORDER = ['REL','BOOL','NOT','COND','DEL','INSFLAG','BREAK']`.

#### 6.4.5 Operator catalog (v1)

| Name | Kind | Rule |
|---|---|---|
| REL | condition | For each `operator` token in the condition with text in `< <= > >= = <>`: one candidate replacing that token: `>`↔`>=`, `<`↔`<=`, `=`↔`<>`. |
| BOOL | condition | For each `and`/`or` keyword in the condition: swap. |
| NOT | condition | For each `not` keyword: remove it (and one following space). |
| COND | condition | Two candidates: whole condition → `true` and → `false`. Skip when the condition is a single `true`/`false` token. |
| DEL | statement | Only when the statement matches `^(<ident>(\.<ident>)*\.)?(Insert\|Modify\|Delete\|DeleteAll\|ModifyAll\|Validate\|Error\|Commit\|Message\|exit)\s*(\(.*\))?$` case-insensitively on its text (i.e. a call to one of those, or bare `exit`). Mutated text `''`. |
| INSFLAG | statement | Statement text matches `\.(Insert\|Modify\|Delete)\((true\|false)\)$`: flip the literal. |
| BREAK | statement | Only with `--include-break`. Every simple statement → `MutBreak_ThisDoesNotCompile();`. Used to test compile-error handling. |

#### 6.4.6 Exclusions (record every skip in `skipped.json` with a reason string)
- File: first object keyword is not `codeunit` → `not-a-codeunit`; path contains `Obsolete Objects` → `obsolete-folder`; object has `Subtype = Test` → `test-codeunit`; file name ends with `.Test.al` → `test-codeunit`; the per-file step (tokenize plus everything derived from it) throws for any reason → `tokenize-error: <message>` (§6.4.9) — generation continues with the remaining files instead of aborting the run.
- Region: any candidate whose span lies between a `#if`/`#ifdef`/`#ifndef` preprocessor token and its `#endif` → `preprocessor-region`; any candidate whose first token's line contains a comment token with text containing `mutation:ignore` → `ignore-comment`.
- Condition: an `until` condition containing an identifier `Next` followed by `(` → `until-next-loop` (would only produce infinite loops); a condition whose `position` is `other` → `condition-position`.
- Statement: a statement whose tokens include `Evaluate` → `evaluate`; inside a `SetRange`/`SetFilter` argument list (the statement itself is a SetRange/SetFilter call) → not a DEL target anyway.

#### 6.4.7 The single guard template

**Condition guard** (Shape B). For a condition `C` with candidates `m1..mk` in a procedure where this is the n-th mutated condition (n starts at 1 per procedure):
```al
case true of
    MutationCore.Active(<id_m1>):
        MutCond_<n> := <mutated_1>;
    MutationCore.Active(<id_m2>):
        MutCond_<n> := <mutated_2>;
    else
        MutCond_<n> := <C>;
end;
```
For `if C then`: insert the block immediately before the `if` token (preceded by the same indentation as the `if` line) and replace `C` with `MutCond_<n>`. For `until C`: insert the block immediately before the `until` token; if the token before `until` is neither `;` nor `repeat`, insert `;` first; replace `C` with `MutCond_<n>`.

**Statement guard** (Shape A). For a simple statement `S` (text without its terminator) with candidates `m1..mk`:
```al
case true of
    MutationCore.Active(<id_m1>):
        begin
        end;
    MutationCore.Active(<id_m2>):
        <mutated_2>;
    else
        <S>;
end
```
A DEL branch is `begin end;`. The original terminator (`;` or none) stays after `end`. The replacement occupies exactly the original statement's span, so it is valid in every statement position, including `then`/`else` branches and case branches, without introducing a dangling `else` (`case … end` is one statement).

**Declarations.** For every procedure with at least one candidate, add to its `var` section (create `    var` before `begin` if absent):
`        MutationCore: Codeunit "MUT Mut";` and one `        MutCond_<n>: Boolean;` per condition block. Never add unused declarations (AA0137 is an error under the strict ruleset).

`rewriteFile` computes all edits as `{start, end, text}` on the original source, sorts by `start` descending, and applies them, so offsets stay valid. Two candidates never overlap: a statement candidate and a condition candidate cannot share a span because conditions are not statements. `lineMap` records, for each guard block in the **output**, `{ mutantIds: number[], startLine, endLine }`.

#### 6.4.8 Ids, stable keys, ordering, sampling
Enumerate candidates over files sorted by relative path (ordinal), procedures in source order, targets by `start` offset, operators by `OPERATOR_ORDER`, variants in generation order. Ids are `1..N` in that order over the **full** enumeration (before sampling), so an id identifies the same mutant in every run over identical input.
`stableKey = sha256(objectType|objectId|procedureName|operator|normalize(original)|normalize(mutated)|occurrence).slice(0,16)` where `normalize` collapses whitespace runs to one space and lower-cases keywords only. `sample(mutants, n, seed)`: mulberry32 PRNG seeded with `seed`, Fisher–Yates shuffle, take `n`, re-sort by id. `n = 0` means all.
`--exclude-stable-keys <file>` removes mutants whose stableKey is listed (`{ "stableKeys": [] }`), before sampling. Excluded ids are still reserved (ids never shift).

#### 6.4.9 Output and CLI
```
node generator/dist/src/cli.js generate --aut <dir> --out <dir> --core-app-id <guid> --core-app-version <ver>
    [--aut-version <ver>] [--max-mutants N] [--seed S] [--only-objects 1,2] [--operators REL,BOOL,...]
    [--include-break] [--exclude-stable-keys <file>]
node generator/dist/src/cli.js lint --schemata <dir>
```
`generate` writes: `<out>/aut-schemata/**` (every file of `--aut` copied byte-for-byte except `.alpackages/`, `*.app`, `.snapshots/`; mutated files rewritten; `app.json` patched: `version` = `--aut-version` if given, `dependencies` += `{ id, name: "Mutation Core", publisher: "Continia Software", version }`), `<out>/mutants.json` (§7.1), `<out>/skipped.json` (`[{file, line, reason}]`), `<out>/linemap.json` (`{ "<relPath>": LineMapEntry[] }`). Exit 0 on success, 2 on usage error, 1 on failure. Output is deterministic: same input and flags → byte-identical files.

**Per-file robustness.** The candidate-generation step (tokenize → find header/procedures/conditions/statements → apply operators) for one `.al` file is wrapped in a per-file try/catch: on any error, the file contributes zero candidates and one `skipped.json` entry `{ file, line: 0, reason: "tokenize-error: <message>" }`, and generation continues with the remaining files — a single unparseable file (e.g. AL constructs the tokenizer does not yet handle) never aborts the whole run. Any error that does escape a per-file step (e.g. while writing `aut-schemata`, a stage that only runs after a file's candidates were already generated successfully) is re-thrown naming the relative file path.

#### 6.4.10 Lint
`lintSchemata(dir)` scans every `.al` under `dir` and reports any line where `MutationCore.Active(` is preceded or followed (same line, ignoring whitespace) by the keyword `and`, `or`, or `xor`, or appears inside a parenthesised argument list of another call. Any finding → exit 1. `generate` runs lint on its own output and fails if it finds anything.

#### 6.4.11 Golden cases (`fixtures/generator/<case>/`)
`input/` (an `app.json` + `.al` files), `expected/aut-schemata/**`, `expected/mutants.json`. Cases: `01-if-rel-bool-not-cond`, `02-until-and-next-exclusion`, `03-del-insflag-positions` (statements in `then`, `else`, case-branch, and last-in-block-without-semicolon positions), `04-exclusions` (test codeunit, `#if` region, `mutation:ignore`, non-codeunit object), `05-fixture-aut` (input = `fixtures/fixture-aut`; expected mutants match §6.3.3). A test runs `generate` on each `input/` into a temp dir and compares byte-for-byte.

### 6.5 Orchestrator (`orchestrator/`, Windows PowerShell 5.1)

#### 6.5.1 Configuration
`mutation.config.json` (Tier B):
```json
{
  "backend": "DemoPortal",
  "environmentName": "mut-spike-01",
  "keepEnvironment": true,
  "aut": { "sourcePath": "C:/GeneralDev/AL/Continia Banking Master/Continia Banking/base-application", "appId": "83461f48-dd16-49ea-b00c-e656830c640f", "version": "28.5.0.0" },
  "testApp": { "sourcePath": "C:/GeneralDev/AL/Continia Banking Master/Continia Banking/base-application-test", "appId": "02b81fad-90fa-4cdc-a414-5bda25e96db0", "testCodeunits": [95155, 95913] },
  "rulesets": { "sourcePath": "C:/GeneralDev/AL/Continia Banking Master/Continia Banking/Banking Rulesets", "file": ".cli-ruleset-localdeploy.json" },
  "coreApp": { "path": "./core-app", "appId": "6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b", "version": "1.0.0.0" },
  "permissionSets": [ { "id": "MUT Core All", "appId": "6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b" } ],
  "workDir": "./out",
  "generator": { "maxMutants": 0, "onlyObjects": [72918635, 72918690, 72918691], "seed": 1, "operators": ["REL", "BOOL", "NOT", "COND", "DEL", "INSFLAG"], "includeBreak": false },
  "schemata": { "publishStrategy": "same-version" },
  "timeouts": { "perTestFactor": 5, "minSeconds": 60, "jobOverheadSeconds": 0 },
  "demoPortal": { "profileId": "cc557829-71df-40ee-9516-98ca954d4b2f", "activationAppId": "c3755ece-dab0-4d16-987d-040661f18522", "cliPath": "./.tools/continia.exe", "settleProbe": { "codeunitId": 95155, "functionName": "UpdatePlaceholderRows_EmptyInputs_BecomesNoMatchingAccounts" } }
}
```
`demoPortal.settleProbe` (T11b, spike U5) names the codeunit/function `Wait-MutEnvironmentSettled`'s test-readiness probe runs after a real Start-/Reset-MutEnvironment transition; `Get-MutConfig` requires it (`codeunitId` an integer, `functionName` a non-empty string) whenever `backend` is `DemoPortal`.
`mutation.fixture.config.json` (Tier A) differs in: `aut.sourcePath = "./fixtures/fixture-aut"`, `aut.appId = "8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d"`, `aut.version = "1.0.0.1"` (bumped from the fixture's original `1.0.0.0` once BC refused to reinstall the lower build over an in-session higher one, T11), `testApp.sourcePath = "./fixtures/fixture-test"`, `testApp.appId = "9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e"`, `testApp.testCodeunits = [50300]`, `rulesets = null`, `generator.onlyObjects = []`, `demoPortal.settleProbe = { "codeunitId": 50300, "functionName": "IsLargeOrder_Twelve_IsTrue" }`, and `permissionSets` additionally contains `{ "id": "MUT Fx All", "appId": "8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d" }`.
`schemata.publishStrategy` ∈ `same-version | bump-build | unpublish-test-app` (set after U6). `Get-MutConfig -Path` loads, validates required keys, resolves relative paths against the repo root, and throws on `environmentName` not matching `^mut-`.

#### 6.5.2 AUT copy (`lib/AutCopy.psm1`)
`Sync-MutAutCopy -Config` mirrors `aut.sourcePath` → `<workDir>/aut-original`, `testApp.sourcePath` → `<workDir>/test-app`, and `rulesets.sourcePath` → `<workDir>/rulesets` using `robocopy <src> <dst> /MIR /XD .alpackages .snapshots .git /XF *.app /NFL /NDL /NJH /NJS` (robocopy exit codes 0–7 are success). Returns the three paths. This is the only function that reads the AUT repo, and it never writes there.

#### 6.5.3 Backend interface (`backends/<Name>.psm1`)
Every backend module exports exactly these functions. `$Env` is the handle returned by `New-MutEnvironment`/`Get-MutEnvironment`: `[pscustomobject]@{ Id; Name; Url; Backend; Shared }`. Every function that receives `$Env` first calls `Assert-MutEnvironmentAllowed $Env` (throws unless `Name -match '^mut-'` and `-not Shared`).

| Function | Returns | DemoPortal implementation |
|---|---|---|
| `Get-MutEnvironment -Name -Config` | handle or `$null` | `env list --json`; match `description -eq Name`. Handle also carries `Status` (Draft/Starting/Running/Stopped) and `CliPath`. |
| `Start-MutEnvironment -Env -Config` | handle (Status Running) | idempotent: if `Status -ne 'Running'`: `env start <id>` (no `--json`; stdout empty, message on stderr) → poll `env get <id> --json` every 10 s until `Running` (max 10 min; a response without a `status` property counts as "not yet", never as an error) → **settle**: poll `env apps <id> --all --json` until non-empty (10 s, max 12), then 30 s (a test job issued right after Running returned 0 tests, spike T09), then a **test-readiness probe** (T11b, spike U5): `test run <id> <settleProbe.codeunitId> <settleProbe.functionName> --json --timeout 120` up to 10 times 30 s apart until `summary.total -gt 0`, throwing if it never does (the apps-poll settle alone was still observed live to leave `test run` discovering 0 tests) → `deps install-by-id <id> <activationAppId> --json` → `env use <id>`. Records `StartDurationSec`, `SettleDurationSec`, `SettleProbeAttempts`, `ActivationInstallDurationSec`. |
| `New-MutEnvironment -Name -Config` | handle | refuse if Name !~ `^mut-`; `env create --name <Name> --profile <profileId> --json` → poll `env get <id> --json` until it returns an object with `status` (max 60 s) → `Start-MutEnvironment`. Records `CreateDurationSec`. |

`Invoke-Continia -Arguments [-ExpectJson]` (private): `env start`, `env stop`, `env delete`, `env use` and `launch add` have no `--json` output; call them with `-ExpectJson:$false`, which returns `@{ ExitCode; StdOut; StdErr }` and throws when `ExitCode -ne 0` (message includes StdErr). With `-ExpectJson` (default) an empty stdout is an error whose message includes StdErr; it never returns `$null` silently.
| `Remove-MutEnvironment -Env` | none | `env delete <id>` (or `env stop` when `keepEnvironment`) |
| `Reset-MutEnvironment -Env [-Config]` | `@{ DurationSec; SettleDurationSec; SettleProbeAttempts }` | `env stop <id>`; poll to `Stopped`; `env start <id>`; poll to `Running`; then the same settle (apps poll + 30 s) and, when `-Config` is given, test-readiness probe as `Start-MutEnvironment` (T11b, spike U5); without `-Config` the probe is skipped with a warning rather than assumed ready. |
| `Install-MutDependencies -Env -AppPath` | JSON object | `deps install <id> <AppPath> --json` |
| `Compile-MutApp -Env -Path [-Ruleset] [-TimeoutSec]` | `@{ Success; Diagnostics; AppFile; DurationSec }` | `compile <Path> --json [--ruleset <Ruleset>] --no-raw-output`; `Diagnostics` = `[{Severity; Code; File; Line; Column; Message}]`; `AppFile` = newest `*.app` in `<Path>`. `TimeoutSec` default 900 (the real AUT compiles in ~70 s; the default Invoke-Continia timeout was too short, T12). |
| `Publish-MutApp -Env -Path [-Ruleset] [-AllowDowngrade] [-SyncMode] [-TimeoutSec]` | `@{ Success; Code; Diagnostics; DurationSec }` | `deploy <id> <Path> --json [--ruleset] [--allow-downgrade] [--sync-mode]`; `TimeoutSec` default 900 |
| `Publish-MutAppFile -Env -AppFile [-SyncMode]` | `@{ Success; DurationSec }` | `publish <id> <AppFile> --json` |
| `Unpublish-MutApp -Env -AppId [-Version]` | `@{ Success }` | `unpublish <id> --app-id <AppId> [--app-version <Version>] --json` |
| `Invoke-MutTests -Env -Targets -TimeoutSec [-Coverage]` | `@{ Passed; Failed; Tests; DurationMs; JobIds }` | one `test run <id> <CodeunitId> [<Function>] --timeout <TimeoutSec>` per distinct target, sequential; `Tests` = `[{Codeunit; Function; Result ('Pass'/'Fail'/'Skip'); DurationMs; Error}]`. Without `-Coverage`: `--json`, `JobIds = @()`. **With `-Coverage` (U9 answered 2026-09-08): `--json` does not expose the job id, so run with `--raw` via `-ExpectJson:$false`**: stdout is the line `Test job started: <N>` followed by xUnit XML (`<assemblies><assembly><collection><test name method time result>` with `<failure><message>` on failed tests); parse `N` into `JobIds` and the XML into `Tests`. |
| `Get-MutCoverageRaw -Env -JobIds` | `[string[]]` raw CSV documents | `test coverage <id> <jobId> --json` per job; returns each `csv` string |
| `Get-MutCoverage -Env -JobIds` | `[{ObjectType; ObjectId; LineNo; Hits}]` | `Get-MutCoverageRaw` then `ConvertFrom-MutCoverageCsv` (§6.5.5) per document; merge by summing `Hits` |
| `Get-MutApiBase -Env` | string | U8: derive from `Url`; verify `GET <base>/api/v2.0/companies` returns 200 |
| `Get-MutCompanyId -Env` | GUID string | first company from `/api/v2.0/companies` |
| `Grant-MutPermissionSet -Env -PermissionSetId -AppId` | `@{ Granted = [users]; AlreadyHad = [users] }` | Automation API: `GET <apiBase>/api/microsoft/automation/v2.0/companies({companyId})/users` → for every user, `GET users({userSecurityId})/userPermissions`; if no row has that `permissionSetId`, `POST users({userSecurityId})/userPermissions` with `{ "roleId": <id>, "appId": <AppId>, "scope": "System" }` (the Automation API field is `roleId`; verified live 2026-09-08). Idempotent. Used by `Publish-Baseline` for every entry of config `permissionSets`. |
| `Invoke-MutApi -Env -Method -Path [-Body]` | parsed JSON | `Invoke-RestMethod` with Basic auth from `env users <id> --json` (cache credentials in the module for the session; never log them), `If-Match: *` on PATCH, path relative to `<apiBase>/api/mutation/core/v1.0/companies(<companyId>)/` |

`Targets` is `@([pscustomobject]@{ CodeunitId = 95155; Function = $null })`. All CLI calls go through one private function `Invoke-Continia -Arguments <string[]> -TimeoutSec` in `DemoPortal.psm1` that runs `cliPath`, captures stdout, parses JSON, and is the single Pester mock point. `Docker.psm1` exports the same names and each throws `[System.NotImplementedException]'Docker backend is not implemented in v1'`.

#### 6.5.4 Steps (`Invoke-MutationRun.ps1 -ConfigPath <file> [-RunNo N] [-SkipEnvironment] [-SkipBaseline]`)
Each step is a function in `lib/*.psm1`; the script is idempotent per run number (a step that finds its output for this run skips itself).

1. `Initialize-MutRun` — load config (§6.5.1), compute `RunNo` (next after highest in `results/`), create `<workDir>/runs/<RunNo>/`.
2. `Ensure-MutEnvironment` — `Get-MutEnvironment` or `New-MutEnvironment` (`-SkipEnvironment` requires an existing one). `Sync-MutAutCopy`.
3. `Publish-Baseline` — `Install-MutDependencies` for `aut-original` and for `test-app`; `Publish-MutApp` for Mutation Core, then `aut-original`, then `test-app` (with ruleset and `-AllowDowngrade`); then `Grant-MutPermissionSet` for every entry of config `permissionSets` (§6.1.5b). `Invoke-MutTests` over `testApp.testCodeunits` with `-Coverage`. **Abort if any failure.** Save `baseline.json` (`{ tests[], durationsByCodeunit }`), `coverage.json` (§7.2) when job ids exist, and `references.json` (§6.5.5).
4. `Build-Schemata` — run the generator (§6.4.9) with config flags into `<workDir>/runs/<RunNo>/gen/`; `Compile-MutApp` on `gen/aut-schemata`. On errors: for each diagnostic with a `file`/`line`, find the `linemap.json` block containing that line → collect mutant ids → mark them `CompileError` in `results` → append their stable keys to `gen/exclude.json` → regenerate with `--exclude-stable-keys gen/exclude.json` → recompile. Cap at 10 iterations, then throw. Diagnostics without a mapped block are fatal.
5. `Publish-Schemata` — per `schemata.publishStrategy`: `same-version`: `Publish-MutAppFile` schemata `.app`; `bump-build`: generator was called with `--aut-version <version with build+1>`, then `Publish-MutAppFile`; `unpublish-test-app`: `Unpublish-MutApp testApp` → `Publish-MutAppFile` schemata → `Publish-MutApp test-app`. Then PATCH setup `activeMutantId = 0` and rerun `Invoke-MutTests` over `testApp.testCodeunits`. **Abort if any failure** (the schemata must be behaviour-preserving when inactive).
6. `Push-Manifest` — PATCH setup `currentRunNo = RunNo`; POST each mutant of `mutants.json` to `mutants` (skip ids already present, `status = Pending`).
7. `Get-CoveringTests` — §6.5.5. Mutants with no covering test get `Status = Uncovered` without running.
8. `Invoke-MutantLoop` — §6.5.6.
9. `Export-Results` — GET all `mutantResults` for `RunNo`, merge with `mutants.json` → `results/<RunNo>.json` (§7.3) and `results/<RunNo>-summary.md` (§7.5). `Remove-MutEnvironment` unless `keepEnvironment`.

#### 6.5.5 Covering-test selection (`lib/References.psm1`, `lib/Coverage.psm1`)
- `Get-MutReferenceMap -AutPath -TestAppPath` → `references.json`: `{ "<autObjectId>": [<testCodeunitId>, …] }`. Build a name→id map from every AUT `.al` file's first line (`^(codeunit|table|page|report|enum|interface|query|xmlport)\s+(\d+)\s+("[^"]+"|\S+)`), then for each test codeunit file (`Subtype = Test`) collect quoted object names in `Codeunit "…"`, `Record "…"`, `Page "…"`, `Enum "…"`, `Codeunit::"…"`, `Page::"…"`, `Database::"…"` and map them to ids.
- `ConvertFrom-MutCoverageCsv -Csv` → `[{ObjectType; ObjectId; LineType; LineNo; Hits}]`. **Format pinned by `fixtures/coverage/sample.csv` (U9, 2026-09-08): no header row; five quoted positional columns** `"ObjectType","ObjectId","LineType","LineNo","Hits"` where LineType ∈ `Object | Trigger/Function | Empty | Code`, e.g. `"Codeunit","50000","Code","12","1"`. The parser MUST validate exactly five columns per row and a known ObjectType, and MUST throw otherwise. Only `LineType = Code` rows carry meaningful `Hits`; selection uses those rows.
- `Get-CoveringTests -Mutant -Coverage -References -TestCodeunits` → `[int[]]` of test codeunit ids: if `Coverage` has rows for `(ObjectId, LineNo)` with `Hits > 0`, the test codeunits whose jobs produced them; else `References[ObjectId]`; else `@()`.

#### 6.5.6 Mutant loop and timeout (`lib/MutantLoop.psm1`)
For each mutant with `Status = Pending`, in id order:
1. PATCH setup `activeMutantId = <id>`.
2. Budget: `max(minSeconds, perTestFactor × baseline duration of the covering codeunits + jobOverheadSeconds × count)`.
3. Run `Invoke-MutTests` inside `Start-Job` (the job imports the backend module and receives `$Env`, `$Targets`, config path); `Wait-Job -Timeout <budget>`. On timeout: `Stop-Job`, `Remove-Job`, `Reset-MutEnvironment`, record `Timeout`, PATCH `activeMutantId = 0`, continue.
4. On completion: if `Failed > 0`: GET `mutantResults?$filter=runNo eq <RunNo> and mutantId eq <id>`; if empty, POST `{ runNo, mutantId, status: 'Killed', killingTest: '<codeunit>:<function>' of the first failed test, durationMs }`. If `Failed = 0`: POST `Survived`. Also write each result to `<workDir>/runs/<RunNo>/results.jsonl` immediately (crash safety).
5. PATCH `activeMutantId = 0` after every mutant.

### 6.6 Spikes (`spikes/`)

#### 6.6.1 `spikes/Start-SpikeEnvironment.ps1`
Imports `orchestrator/backends/DemoPortal.psm1`, `Get-MutEnvironment 'mut-spike-01'` or `New-MutEnvironment`, prints the handle and timings, appends them to `docs/spike-baseline.md` §Environment.

#### 6.6.2 `spikes/u1-guard-bench/` (U1, U3)
`New-GuardBenchApp.ps1` generates app "MUT Guard Bench" (§6.0.1): codeunit 50500 "MUT Guard Bench" with a procedure `Guarded(Value: Integer): Integer` containing 500 sequential blocks
```al
case true of
    MutationCore.Active(<n>):
        Result := Value + <n>;
    else
        Result := Value;
end;
```
(n = 1..500, `Result` reassigned each block) and `Unguarded(Value: Integer): Integer` with 500 `Result := Value;` lines; test codeunit 50501 "MUT Guard Bench Tests" with `Guarded_100k` and `Unguarded_100k` each looping 100,000 times over the respective procedure. Deploy, record compile seconds, publish seconds, and both test durations from `test run --json`.

#### 6.6.3 `spikes/u4-runner-events/Invoke-U4Spike.ps1` (U4)
Preconditions: Mutation Core, fixture AUT, fixture test deployed. PATCH setup `activeMutantId = 999`, `currentRunNo = 1`. `Invoke-MutTests` on codeunit 50301. Then GET `mutantResults`. Expected: exactly one row `{ runNo 1, mutantId 999, status Killed, killingTest 'MUT Fx U4 Spike Tests:U4_Failing' }`. Record: events fired (yes/no), row present after failed test (yes/no). Reset setup to 0.

#### 6.6.4 `spikes/u5-u6/` (U5, U6)
`Invoke-U5Spike.ps1`: start `test run <env> 50302 --timeout 30` as a child process (`Start-Process` with redirected output; `Start-Job` + stderr redirection trips NativeCommandError under PS 5.1); after the client timeout, check `continia env sessions <id> --json` for the session; try `env stop` and time `Reset-MutEnvironment`. Record whether the job was cancelled and the reset duration.
`Invoke-U6Spike.ps1`: with fixture AUT + fixture test installed, try in order and record success/duration per option: (a) `Publish-MutAppFile` of a rebuilt fixture AUT with the same version; (b) same with version `1.0.0.1`; (c) `Unpublish-MutApp` fixture test → publish → `Publish-MutApp` fixture test. After each, run codeunit 50300 to confirm the test app still works.

#### 6.6.5 `spikes/hand-mutants/` (Tier B kill-rate sample)
`mutants.json`: the 20 mutants below. `Invoke-HandMutants.ps1 -Config mutation.config.json`: `Sync-MutAutCopy`; baseline run of 95155 and 95913 must pass; then for each mutant: read `file` in `aut-original`, assert that line `line` contains `find` exactly once (else abort with "source drift"), replace with `replace`, `Publish-MutApp aut-original` (ruleset, `-AllowDowngrade`), `Invoke-MutTests` on `testCodeunits`, record `Killed` (any failure) / `Survived` and wall-clock seconds, restore the original line. Write `spikes/hand-mutants/results.json` and the table into `docs/spike-baseline.md`.

Paths are relative to the AUT root; line numbers refer to the AUT at commit of 2026-09-07 (the script verifies by text, not by line alone).

| # | File | Line | find | replace | Op | Tests |
|---|---|---|---|---|---|---|
| HM01 | `Authentication\Codeunit\AuthShareDetection.Codeunit.al` | 119 | `MatchingAccounts.Count() > 0` | `MatchingAccounts.Count() >= 0` | REL | 95155 |
| HM02 | same | 152 | `AccountsAttempted = 0` | `AccountsAttempted <> 0` | REL | 95155 |
| HM03 | same | 203 | `(BankAccount.IBAN = '') and (BankAccount."Bank Branch No." = '')` | `(BankAccount.IBAN = '') or (BankAccount."Bank Branch No." = '')` | BOOL | 95155 |
| HM04 | same | 231 | `(BankCode = '') or (SourceBankSystemCode = '')` | `(BankCode = '') and (SourceBankSystemCode = '')` | BOOL | 95155 |
| HM05 | same | 418 | `if ExactMatchCount > 0 then begin` | `if ExactMatchCount >= 0 then begin` | REL | 95155 |
| HM06 | same | 422 | `if MismatchCount > 0 then begin` | `if MismatchCount >= 0 then begin` | REL | 95155 |
| HM07 | same | 431 | `if TotalFailed > 0 then` | `if TotalFailed >= 0 then` | REL | 95155 |
| HM08 | same | 434 | `if not PlaceholderConsumed then begin` | `if PlaceholderConsumed then begin` | NOT | 95155 |
| HM09 | same | 443 | `if TotalMatched > 0 then` | `if TotalMatched >= 0 then` | REL | 95155 |
| HM10 | same | 493 | `if TotalAttempted > 0 then` | `if TotalAttempted >= 0 then` | REL | 95155 |
| HM11 | same | 460 | `TempAuthShareTarget.Modify();` | `;` | DEL | 95155 |
| HM12 | same | 526 | `TempAuthShareTarget.Insert();` | `;` | DEL | 95155 |
| HM13 | same | 644 | `TempAuthShareTarget.DeleteAll();` | `;` | DEL | 95155 |
| HM14 | same | 401 | `if TempAuthShareTarget.FindLast() then` | `if false then` | COND | 95155 |
| HM15 | same | 577 | `exit;` | `;` | DEL | 95155 |
| HM16 | same | 211 | `if TempBank.Code <> '' then` | `if TempBank.Code = '' then` | REL | 95155 |
| HM17 | same | 84 | `if SourceBank.Code = '' then` | `if SourceBank.Code <> '' then` | REL | 95155 |
| HM18 | same | 323 | `if not ToBank.WritePermission() then` | `if ToBank.WritePermission() then` | NOT | 95155 |
| HM19 | same | 328 | `ToBank.Insert(true);` | `;` | DEL | 95155 |
| HM20 | same | 274 | `(CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` | `(CurrentCompany <> PreferredCompany) or TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` | BOOL | 95155 |

All 20 mutants live in `AuthShareDetection.Codeunit.al` (the other planned objects disappeared from the checkout on 2026-09-08, §1.1).
**Locating a mutant:** `line` is advisory. The script first checks the given line; if the `find` text is not there, it searches
the whole file and requires exactly one occurrence, else aborts with `source drift: <id>`. HM11–HM13 and HM15 have `find` texts
that occur several times in the file, so their `line` MUST match (the script reports drift otherwise); HM15's `exit;` is the
one inside `EmitSystemNotMappedRow` after `PlaceholderConsumed := true;`.

---

## 7. Data schemas

### 7.1 `mutants.json`
```json
[{ "id": 1, "stableKey": "9f2c…", "objectType": "codeunit", "objectId": 50200, "objectName": "MUT Fx Order Mgt",
   "procedure": "IsLargeOrder", "line": 4, "operator": "REL", "original": "Quantity >= 10", "mutated": "Quantity > 10",
   "file": "src/FxOrderMgt.Codeunit.al" }]
```

### 7.2 `coverage.json`
```json
{ "byTestCodeunit": { "95155": [{ "objectType": "Codeunit", "objectId": 72918635, "lineNo": 119, "hits": 3 }] } }
```

### 7.3 `results/<RunNo>.json`
```json
{ "runNo": 1, "backend": "DemoPortal", "environmentName": "mut-spike-01", "startedUtc": "…", "finishedUtc": "…",
  "autAppId": "…", "autVersion": "…", "coreAppVersion": "1.0.0.0",
  "generator": { "seed": 1, "maxMutants": 0, "onlyObjects": [], "operators": [] },
  "totals": { "total": 26, "killed": 17, "survived": 6, "timeout": 3, "compileError": 0, "uncovered": 0, "equivalent": 0 },
  "score": 0.7692,
  "mutants": [{ "id": 1, "stableKey": "…", "objectId": 50200, "procedure": "IsLargeOrder", "line": 4, "operator": "REL",
                "original": "…", "mutated": "…", "status": "Survived", "killingTest": null, "durationMs": 4200,
                "coveringTests": [50300] }] }
```
`score = (killed + timeout) / (total − equivalent − compileError)`, rounded to 4 decimals. `Uncovered` counts as survived in the denominator.

### 7.4 `fixtures/expected-results.json`
```json
[{ "procedure": "IsLargeOrder", "operator": "REL", "mutated": "Quantity > 10", "expected": "Survived" }, …]
```
One entry per row of §6.3.3 (26 entries). Matching key: `(procedure, operator, mutated)`; for DEL, `mutated` is `""` and `original` is added to the key.

### 7.5 `results/<RunNo>-summary.md`
Sections: header table (run no, backend, environment, AUT version, started/finished, wall-clock), totals table, score, "Survivors" table (id, object, procedure, line, operator, original → mutated, covering tests), "Timeouts" table, "Compile errors" table, "Uncovered" count.

### 7.6 `docs/spike-baseline.md` template
Sections in this order, each a table with columns `Metric | Value | Backend | Date | Source task`: Environment (create s, start s, activation-app install s, deps install s, AUT deploy s, test app deploy s); U1/U3; U4; U5; U6; U7 (single-method job s, 95155 s, 95913 s, per-test median s); U8 (API base URL pattern); U9 (job id field name, CSV header line); Tier B baseline (pass/fail per codeunit); Hand mutants (20 rows + kill count); Recommendation (`go` / `no-go`, `--max-mutants` default, `timeouts.jobOverheadSeconds`, `schemata.publishStrategy`).

---

## 8. Gates and acceptance

**Phase acceptance** is listed per component (§6.1.8, §6.4.11, and below). **Gates:**

- **G0 — go/no-go** after Tier A and Tier B spikes. Written by a human into `docs/spike-baseline.md` → Recommendation. `no-go` if: U4 shows events do not fire under the DemoPortal runner; or ≥ 18 of the 20 hand mutants are killed (suite already strong → scale down to a periodic manual audit); or U7 implies fewer than ~200 mutants/day.
- **G1 — full baseline** (last task): all 181 test codeunits pass on a fresh `mut-` environment with coverage recorded; U2 median computed. Only after `go`.

**Orchestrator acceptance (on the fixture, DemoPortal):**
1. `Invoke-MutationRun.ps1 -ConfigPath mutation.fixture.config.json` produces `results/<n>.json` whose statuses match `fixtures/expected-results.json` for all 26 entries (Timeout entries may instead be `Killed` if U5 shows the job fails fast; record which).
2. With `generator.includeBreak = true`, all BREAK mutants end as `CompileError` and the run completes.
3. `Select-String -Path orchestrator/Invoke-MutationRun.ps1, orchestrator/lib/*.psm1 -Pattern 'continia|BcContainerHelper|docker' -CaseSensitive:$false` returns nothing.
4. A run with `activeMutantId = 0` on the schemata passes the full fixture suite (zero false kills).

**Tier B acceptance:** `Invoke-MutationRun.ps1 -ConfigPath mutation.config.json` completes on the three target codeunits and `results/<n>-summary.md` lists survivors; the hand-mutant outcomes (HM01–HM20) agree with the generator-run outcomes for the same lines where both exist.

---

## 9. Engineering standards for implementing agents

### 9.1 Process
- TDD: write the failing test first, run it, watch it fail, implement, run it, watch it pass, commit. Golden files are written **by hand from the spec**, never by copying the program's output (the exception is `fixtures/coverage/sample.csv`, which is observed data).
- One task = one commit with the message given in the task. Do not amend earlier commits.
- Never run two `continia test run` calls concurrently. Never target an environment not named `mut-*`.
- If a spec statement turns out to be wrong (e.g. an AL construct does not compile), do not guess: record the finding in `docs/issues.md` with the exact compiler message, stop the task, and report.

### 9.2 AL
- Prefix `MUT`, ids in the ranges of §6.0.1, no namespace, `Access` explicit on every object except API pages (AL0124 forbids it there), labels for all user text. Every test codeunit declares `Permissions = tabledata <table> = RIMD` for each table it reads or writes, and codeunits that touch tables from event subscribers declare `Permissions` and perform the Get/Insert in their own code (DemoPortal test sessions are not SUPER), no unused variables (AA0137), `NoImplicitWith`, one statement per line, 4-space indent.
- Compile with the strict ruleset for our own apps: `continia compile <app> --json` uses `<app>/.vscode/settings.json` `al.codeAnalyzers: ["${CodeCop}", "${UICop}"]` (no AppSourceCop, no PerTenantExtensionCop). Zero errors required; warnings are reported in the task result.
- AUT copies compile with `--ruleset <workDir>/rulesets/.cli-ruleset-localdeploy.json`.

### 9.3 PowerShell
- Windows PowerShell 5.1 compatible: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, no `&&`/`||`, no ternary, `[pscustomobject]` for records, `ConvertTo-Json -Depth 10`.
- Tests: Pester 5 (`Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.5 -MaximumVersion 5.99`; `Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99` (Pester 6 is not used; its breaking changes are unverified)). Test files `orchestrator/tests/<Module>.Tests.ps1`, run with `Invoke-Pester orchestrator/tests -Output Detailed`. Mock `Invoke-Continia` with `Mock -ModuleName DemoPortal Invoke-Continia -MockWith { … }`; never call the real CLI from unit tests.
- Module files export only the functions listed in this spec (`Export-ModuleMember`).

### 9.4 TypeScript
- `strict`, no `any`, no runtime dependencies, ESM, Node 22 built-ins only. Relative imports in `.ts` files use the `.js` extension (`import { tokenize } from './tokenizer.js'`) as `module: NodeNext` requires. Tests in `generator/test/*.test.ts` using `node:test` + `node:assert/strict`; run `npm test` from `generator/`.
- Never mutate input arrays; return new objects. Deterministic ordering everywhere (explicit sorts, no `Object.keys` order reliance).

### 9.5 Reporting a task done
Include in the final report: commands run with their exit codes, test counts (passed/failed), the commit hash, every deviation from the spec, and anything appended to `docs/issues.md` or `docs/spike-baseline.md`.
