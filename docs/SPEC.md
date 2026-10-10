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
| Phase 4 triage page, Phase 5 incremental runs | After Gate G0. (Suggest-Test was pulled forward on 2026-10-01 as §6.7.) |

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
| F7 | DemoPortal runs one test codeunit per job (`continia test run <envId> <codeunitId> [functionName]`), jobs strictly sequential, no TestRunner codeunit id can be passed. | Targets are whole test codeunits (optionally one function). Never run two jobs concurrently. **Amended 2026-10-04:** this limits the CLI only. A SOAP codeunit on the environment can run test codeunits itself (§6.10), so the per-mutant loop may bypass test jobs. |
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
   Invoke-MutationRun.ps1, Export-MutFixBriefs.ps1, Test-MutFixReport.ps1   (§6.7), Invoke-MutFixVerify.ps1 (§6.8)
   /lib/*.psm1
   /backends/DemoPortal.psm1, Docker.psm1
   /tests/*.Tests.ps1
/spikes                   throwaway experiments U1–U9                (§6.6)
/docs                     SPEC.md, tasks.json, spike-baseline.md, issues.md, PLAN v2
/results                  committed run artifacts
/out                      ignored: AUT copies, schemata, build output
/.tools, /.continia       ignored
/.claude/skills/mutation-fix-suggest   skill for stage 2 of §6.7
/.claude/skills/mutation-fix-verify    skill for §6.8.3
mutation.config.json      Tier B config                              (§6.5.1)
mutation.fixture.config.json  Tier A config                          (§6.5.1)
```

`.gitignore` already contains `.tools/`, `.continia/`, `.alpackages/`, `out/`, `*.app`, `!fixtures/**/*.app`, `node_modules/`. Add `generator/dist/`.

### 6.0.1 Fixed identifiers

| App | App id | Publisher | Version | Id range |
|---|---|---|---|---|
| Mutation Core | `6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b` | Continia Software | 1.2.0.0 (1.0.0.0 before the SOAP runner; 1.1.0.0 before the runner's stop guard, §6.10.2; 1.1.1.0 before `Killing Error`, §6.11.1) | 50000–50199 |
| Mutation Core Test | `7a2e3d4b-9c5f-4e6a-8b7c-8d9e0f1a2b3c` | Continia Software | 1.0.0.0 | 50400–50499 |
| MUT Fixture AUT | `8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d` | Continia Software | 1.0.0.1 (bumped from 1.0.0.0 by the U6 spike, T11) | 50200–50299 |
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
PK `1 "Run No." Integer`, `2 "Mutant Id" Integer`; `3 Status Enum "MUT Mutant Status"`, `4 "Duration Ms" Integer`, `5 "Killing Test" Text[250]`, `6 "Recorded At" DateTime`, `7 "Killing Error" Text[250]` (§6.11.1).

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
// §6.11.1: capture GetLastErrorText() BEFORE ClearLastError() and set "Killing Error" from it on the insert
```
These signatures are copied from `TestRunnerMgt.Codeunit.al` in BCApps (lines 265 and 270) and MUST be used verbatim. `Test Method Line` and `TestPermissions` resolve from the Test Runner dependency (F14).

#### 6.1.5 Codeunit 50002 "MUT Install"
`Subtype = Install`. `OnInstallAppPerDatabase`: `if not EnvironmentInformation.IsSandbox() then Error(NotSandboxErr)` where `NotSandboxErr: Label 'Mutation Core can only be installed in a sandbox environment.'`. Then `Setup.GetOrCreate()`.

#### 6.1.5b PermissionSet 50000 "MUT Core All"
`Assignable = true; Caption = 'Mutation Core - all'`. Permissions: `tabledata` RIMD and `table` X for all five MUT tables (including 50004 "MUT Runner State", §6.10.2); `codeunit` X for all five codeunits (50000–50004); `page` X for all five API pages (50000–50004).
**Why (amended — the original rationale was disproved live, T07):** DemoPortal test sessions run under a restricted user (§6.1.4).
This set was specified on the theory that granting it to the environment users would let the hooks read the setup row. That theory is
**false**: granting `MUT Core All` to all four enumerable users (all already SUPER) changed nothing, so the identity running a
DemoPortal test session is none of the environment's own named BC users, and **what it actually is remains unidentified**. The hooks
instead read the active mutant from Isolated Storage (`DataScope::Module`), which is not subject to table permissions — that is the
mechanism that works (§6.1.4, U4). This permission set is retained for the API/table access used *outside* the test session; the
`HookErrorIsEmpty` test (§6.2) detects a hook that swallowed an error.

#### 6.1.6 Custom TestRunner (deferred)
A `SubType = TestRunner` codeunit that loops over mutants in one session would remove per-job overhead but cannot be used on DemoPortal (F7). Not built in v1; recorded in `docs/issues.md`.

**Runner-nesting spike (2026-09-30, `spikes/runner-nesting/`): no workaround exists on DemoPortal.** F7 rules out passing a TestRunner codeunit id to the CLI. The spike asked whether an *ordinary* test codeunit could loop mutants from inside a running test job. BC refuses both paths with the same platform error: `You cannot nest the execution of test codeunits. Test codeunit 50600 MUT Spike Victim was called from another test codeunit.` (a) `Codeunit.Run` on a test codeunit raises it at the call site, and the boolean return value does not capture it. (b) Building and running a suite through `Codeunit "Test Suite Mgt."` (`CreateTestSuite` / `SelectTestMethodsByRange` / `RunSelectedTests`) raises it too. In neither case did `MUT Test Hooks` record a result for the inner test. So the in-job mutant loop is reachable only if the CLI gains a TestRunner option, or on a backend where the test runner is under our control (the Docker backend, §6.5.3).

**Superseded 2026-10-04 by §6.10.** The refusal applies only when the caller is itself a test codeunit. A SOAP web-service call is not, so it can build and run a suite per mutant through `"Test Suite Mgt."`. That is the in-session mutant loop this section deferred; §6.10 specifies it. No `SubType = TestRunner` codeunit of our own is needed: the standard runner 130450 is used.

#### 6.1.7 API pages (`APIPublisher = 'mutation'`, `APIGroup = 'core'`, `APIVersion = 'v1.0'`, `DelayedInsert = true`, `ODataKeyFields` = the PK)

| Page | EntityName / EntitySetName | Source | Fields (API name → field) |
|---|---|---|---|
| 50000 "MUT Mutants API" | `mutant` / `mutants` | MUT Mutant | `id`, `stableKey`, `objectType`, `objectId`, `procedureName`, `lineNo`, `operator`, `originalText`, `mutatedText`, `status` |
| 50001 "MUT Mutation Runs API" | `mutationRun` / `mutationRuns` | MUT Mutation Run | `runNo`, `started`, `finished`, `commit`, `backend`, `total`, `killed`, `survived`, `score` |
| 50002 "MUT Mutant Results API" | `mutantResult` / `mutantResults` | MUT Mutant Result | `runNo`, `mutantId`, `status`, `durationMs`, `killingTest`, `recordedAt`, `killingError` (§6.11.1) |
| 50003 "MUT Mutation Setup API" | `mutationSetup` / `mutationSetup` | MUT Mutation Setup | `primaryKey` (Integer, always 0, `ODataKeyFields`), `activeMutantId`, `currentRunNo` |
| 50004 "MUT Sessions API" | `session` / `sessions` | Active Session (system table 2000000110) | `sessionId`, `userId`, `clientType`, `loginDateTime`, `serverInstanceId`, `isCurrentSession` (computed); read-only; bound action `Microsoft.NAV.stop` calls `StopSession` (refuses the calling session). Run 11, 2026-10-01: lets the orchestrator stop a runaway test session instead of restarting the environment. `Active Session` keeps rows for sessions killed by a container restart; such a stale row accepts `stop` and never disappears. |

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
For `if C then`: insert the block immediately before the `if` token (preceded by the same indentation as the `if` line) and replace `C` with `MutCond_<n>`. For `until C`: insert the block immediately before the `until` token; if the token before `until` is neither `;` nor `repeat`, insert `;` first; replace `C` with `MutCond_<n>`. "The same indentation as the … line" is normative: it is the leading *whitespace run* of that physical source line, never any non-whitespace text preceding the anchor token on that line — an inserted block starts at the anchor's own offset, so whatever precedes it (there is none for `if`/`until` positions, since only `statementList` conditions are mutated, §6.4.3) is unaffected either way.

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
A DEL branch is `begin end;`. The original terminator (`;` or none) stays after `end`. The replacement occupies exactly the original statement's span, so it is valid in every statement position, including `then`/`else` branches and case branches, without introducing a dangling `else` (`case … end` is one statement). The replacement's edit begins at the statement `S`'s own offset — never earlier — so when `S` is not the first token on its physical line (e.g. `if C then S;`, or `S` in an `else`/`do`/case-branch position sharing its line with that keyword), whatever precedes `S` on that line stays put and is emitted exactly once; every subsequent line of the block (each `MutationCore.Active(...)`/branch/`else`/`end` line) is indented by that physical line's own leading whitespace plus the usual per-level step, never by the preceding source text (M8: a statement-guard block naively indented from "everything before `S` on its line" duplicated an un-blocked `if … then` prefix onto every line of the replacement).

**Declarations.** For every procedure with at least one candidate, add to its `var` section (create `    var` before `begin` if absent):
`        MutationCore: Codeunit "MUT Mut";` and one `        MutCond_<n>: Boolean;` per condition block. Never add unused declarations (some rulesets treat an unused local as an error). `MutationCore` intentionally does not follow the type-suffix naming convention, and being appended after a procedure's existing locals means it isn't always in var-ordering position either; the schemata compile exempts every style analyzer entirely (not just these two shapes) instead of changing this template or downgrading rules one at a time (§6.5.1, §6.5.4 step 4).

`rewriteFile` computes all edits as `{start, end, text}` on the original source, sorts by `start` descending, and applies them, so offsets stay valid. Two candidates must never overlap. A statement candidate and a condition candidate cannot share a span because conditions are not statements — but two *statement* candidates can, and did: in `case <expr> of`, every branch label from the second onward sits at a statement-start position, so a non-numeric label (`BLbl:`, `Rec."Date Format Type"::Day:`) started a bogus simple statement running through the branch body. `findSimpleStatements` MUST therefore reject a candidate whose tokens reach a bare `:` (not `:=`, not `::`) at paren-depth 0 before any `;`. **This invariant MUST be enforced, not assumed:** `rewriteFile` MUST throw on an overlapping edit, and MUST re-tokenize each rewritten file and refuse to emit one that no longer tokenizes; `generate` records either failure as a `skipped.json` entry for that file and continues. Before this was enforced the rewriter silently emitted `endcase true of` and reported success (exit 0, lint clean) — `lint` is line-regex only and cannot see it. `lineMap` records, for each guard block in the **output**, `{ mutantIds: number[], startLine, endLine }`.

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
  "coreAppTest": { "path": "./core-app-test", "appId": "7a2e3d4b-9c5f-4e6a-8b7c-8d9e0f1a2b3c" },
  "permissionSets": [ { "id": "MUT Core All", "appId": "6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b" } ],
  "workDir": "./out",
  "generator": { "maxMutants": 0, "onlyObjects": [72918635], "seed": 1, "operators": ["REL", "BOOL", "NOT", "COND", "DEL", "INSFLAG"], "includeBreak": false },
  "schemata": { "publishStrategy": "same-version" },
  "timeouts": { "perTestFactor": 5, "minSeconds": 60, "jobOverheadSeconds": 0 },
  "demoPortal": { "profileId": "cc557829-71df-40ee-9516-98ca954d4b2f", "activationAppId": "c3755ece-dab0-4d16-987d-040661f18522", "cliPath": "./.tools/continia.exe", "settleProbe": { "codeunitId": 50400, "functionName": "HookErrorIsEmpty" } }
}
```
`demoPortal.settleProbe` (T11b, spike U5) names the codeunit/function `Wait-MutEnvironmentSettled`'s test-readiness probe runs after a real Start-/Reset-MutEnvironment transition; `Get-MutConfig` requires it (`codeunitId` an integer, `functionName` a non-empty string) whenever `backend` is `DemoPortal`.
`coreAppTest` is OPTIONAL (`path`, `appId`; both required when the key is present). When configured, `Publish-MutBaseline` (§6.5.4 step 3) publishes Mutation Core's own test app immediately after Mutation Core and BEFORE the AUT, so `settleProbe` can target a codeunit that exists independently of the AUT: it depends only on Mutation Core and the Microsoft test libraries, so it survives the AUT test app being unpublished and republished around the schemata swap (§6.5.4 step 4) and does not move when the AUT's own test suite changes. The probe function must be side-effect-free — codeunit 50400's `HookErrorIsEmpty` is, while its sibling tests call `SetActive`/`Reset` and would clobber the active mutant. Residual: `Ensure-MutEnvironment` (step 2) still runs before step 3, so on a first-ever run against a brand-new environment the probe target does not yet exist and that one check stays non-fatal (`-RequireProbe $false`); the complete fix is to publish Mutation Core in step 2, recorded as an open item in `docs/issues.md`.
Any `path`/`sourcePath` value may contain `%VAR%` environment-variable references, expanded by `Resolve-MutConfigPath` before the relative/absolute decision. A reference to an unset variable throws at config load naming the variable, rather than leaving the literal `%VAR%` text to fail later as a path-not-found.
`Get-MutConfig` WARNS when `generator.onlyObjects` is non-empty, naming the count and the ids: the shipped configs carry pilot values, and a score reported without the scope it was computed over is misleading (§7.5).
`mutation.fixture.config.json` (Tier A) differs in: `aut.sourcePath = "./fixtures/fixture-aut"`, `aut.appId = "8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d"`, `aut.version = "1.0.0.1"` (bumped from the fixture's original `1.0.0.0` once BC refused to reinstall the lower build over an in-session higher one, T11), `testApp.sourcePath = "./fixtures/fixture-test"`, `testApp.appId = "9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e"`, `testApp.testCodeunits = [50300]`, `rulesets = null`, `timeouts.minSeconds = 120` (raised from 60 after the fixture-run timeout defect, `docs/issues.md` T27; `mutation.config.json` is still 60), `generator.onlyObjects = []`, `demoPortal.settleProbe = { "codeunitId": 50300, "functionName": "IsLargeOrder_Twelve_IsTrue" }`, and `permissionSets` additionally contains `{ "id": "MUT Fx All", "appId": "8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d" }`.
`schemata.publishStrategy` ∈ `same-version | bump-build | unpublish-test-app` (set after U6). `Get-MutConfig -Path` loads, validates required keys, resolves relative paths against the repo root, and throws on `environmentName` not matching `^mut-`. The schemata compile (§6.5.4 step 4) always writes an empty `al.codeAnalyzers` list into the generated tree's `.vscode/settings.json`, so no style analyzer ever gates it, regardless of `rulesets`; when `rulesets` is also set, a generated sibling ruleset that includes `rulesets.file` is written and passed too, as a harmless second line of defence.

#### 6.5.2 AUT copy (`lib/AutCopy.psm1`)
`Sync-MutAutCopy -Config` mirrors `aut.sourcePath` → `<workDir>/aut-original`, `testApp.sourcePath` → `<workDir>/test-app`, and `rulesets.sourcePath` → `<workDir>/rulesets` using `robocopy <src> <dst> /MIR /XD .alpackages .snapshots .git /XF *.app /NFL /NDL /NJH /NJS` (robocopy exit codes 0–7 are success). Returns the three paths. This is the only function that reads the AUT repo, and it never writes there.

#### 6.5.3 Backend interface (`backends/<Name>.psm1`)
Every backend module exports exactly these functions. `$Env` is the handle returned by `New-MutEnvironment`/`Get-MutEnvironment`: `[pscustomobject]@{ Id; Name; Url; Backend; Shared }`. Every function that receives `$Env` first calls `Assert-MutEnvironmentAllowed $Env` (throws unless `Name -match '^mut-'` and `-not Shared`).

| Function | Returns | DemoPortal implementation |
|---|---|---|
| `Get-MutEnvironment -Name -Config` | handle or `$null` | `env list --json`; match `description -eq Name`. Handle also carries `Status` (Draft/Starting/Running/Stopped) and `CliPath`. |
| `Start-MutEnvironment -Env -Config [-RequireProbe]` | handle (Status Running) | idempotent: if `Status -ne 'Running'`: `env start <id>` (no `--json`; stdout empty, message on stderr) → poll `env get <id> --json` every 10 s until `Running` (max 10 min; a response without a `status` property counts as "not yet", never as an error). Then, **on every call, regardless of whether a start just happened** (F3, finding I6 — a `Running` status alone is not proof the environment is serving: run 8 fired 46 test jobs in a row at an environment that reported `Running` but was not, and every one silently came back "no tests discovered" because this settle-and-probe used to run only inside the `Status -ne 'Running'` branch): **settle**: poll `env apps <id> --all --json` until non-empty (10 s, max 12), then 30 s (a test job issued right after Running returned 0 tests, spike T09), then a **test-readiness probe** (T11b, spike U5): `test run <id> <settleProbe.codeunitId> <settleProbe.functionName> --json --timeout 120` up to 10 times 30 s apart until `summary.total -gt 0` → `deps install-by-id <id> <activationAppId> --json` → `env use <id>`. `-RequireProbe` (`[bool]`, default `$true`) controls what happens when the probe never reports `total -gt 0`: `$true` throws (the pre-F3b behaviour, still used by every post-baseline caller — the mutant loop's `Confirm-MutEnvironmentServing`, §6.5.6 — since an unconfirmed environment must not silently continue there); `$false` (F3b IMPORTANT 2; passed by `New-MutEnvironment` and `Ensure-MutEnvironment`, §6.5.4 step 2, since both can run before the probe's target test codeunit exists) warns instead and returns with `ProbeConfirmed = $false`. Records `StartDurationSec` (0 when no start was needed), `SettleDurationSec`, `SettleProbeAttempts`, `ProbeConfirmed` (always from a real settle-and-probe call), `ActivationInstallDurationSec`. |
| `New-MutEnvironment -Name -Config` | handle | refuse if Name !~ `^mut-`; `env create --name <Name> --profile <profileId> --json` → poll `env get <id> --json` until it returns an object with `status` (max 60 s) → `Start-MutEnvironment`. Records `CreateDurationSec`. |

`Invoke-Continia -Arguments [-ExpectJson]` (private): `env start`, `env stop`, `env delete`, `env use` and `launch add` have no `--json` output; call them with `-ExpectJson:$false`, which returns `@{ ExitCode; StdOut; StdErr }` and throws when `ExitCode -ne 0` (message includes StdErr). With `-ExpectJson` (default) an empty stdout is an error whose message includes StdErr; it never returns `$null` silently.
| `Remove-MutEnvironment -Env` | none | `env delete <id>` (or `env stop` when `keepEnvironment`) |
| `Reset-MutEnvironment -Env [-Config]` | `@{ DurationSec; SettleDurationSec; SettleProbeAttempts }` | `env stop <id>`; poll to `Stopped`; `env start <id>`; poll to `Running`; then the same settle (apps poll + 30 s) and, when `-Config` is given, test-readiness probe as `Start-MutEnvironment` (T11b, spike U5); without `-Config` the probe is skipped with a warning rather than assumed ready. |
| `Install-MutDependencies -Env -AppPath` | JSON object | `deps install <id> <AppPath> --json` |
| `Compile-MutApp -Env -Path [-Ruleset] [-TimeoutSec]` | `@{ Success; Diagnostics; AppFile; DurationSec; Code; ErrorMessage }` | `compile <Path> --json [--ruleset <Ruleset>] --no-raw-output`; `Diagnostics` = `[{Severity; Code; File; Line; Column; Message}]`; `AppFile` = newest `*.app` in `<Path>`. `TimeoutSec` default 900 (the real AUT compiles in ~70 s; the default Invoke-Continia timeout was too short, T12). **(M6)** `compile`/`deploy`/`publish` can also return a single run-level failure object instead of the normal per-app row when the command cannot reach the per-app loop at all: `{"success": false, "error": {"code": "...", "message": "..."}}`. `Compile-MutApp`, `Publish-MutApp` and `Publish-MutAppFile` all detect this shape (a `success = false` object whose `error` is itself an object, not a string) and map it to `Code`/`ErrorMessage` directly, instead of reading an absent array's first row and reporting `Success = $false` with an empty `Diagnostics` list and no code (the defect behind three live investigations, docs/issues.md T13). On the normal row shape, the row's own `code` and free-prose `error` string (e.g. a BC-side `Extension compilation failed ... error AL0185: ...` dependent-recompile failure) are always carried into `Code`/`ErrorMessage` too, since `diagnostics[]` can be empty even though the row failed. |
| `Publish-MutApp -Env -Path [-Ruleset] [-AllowDowngrade] [-SyncMode] [-TimeoutSec]` | `@{ Success; Code; Diagnostics; DurationSec; ErrorMessage }` | `deploy <id> <Path> --json [--ruleset] [--allow-downgrade] [--sync-mode]`; `TimeoutSec` default 900. Both response shapes handled per the Compile-MutApp row above; `Code` and `ErrorMessage` are always surfaced on failure. |
| `Publish-MutAppFile -Env -AppFile [-SyncMode]` | `@{ Success; DurationSec; Code; ErrorMessage }` | `publish <id> <AppFile> --json`. Both response shapes handled per the Compile-MutApp row above; `Code` and `ErrorMessage` are always surfaced on failure. |
| `Unpublish-MutApp -Env -AppId [-Version]` | `@{ Success }` | `unpublish <id> --app-id <AppId> [--app-version <Version>] --json` |
| `Invoke-MutTests -Env -Targets -TimeoutSec [-Coverage]` | `@{ Passed; Failed; Tests; DurationMs; JobIds }` | one `test run <id> <CodeunitId> [<Function>] --timeout <TimeoutSec>` per distinct target, sequential; `Tests` = `[{Codeunit; Function; Result ('Pass'/'Fail'/'Skip'); DurationMs; Error}]`. Without `-Coverage`: `--json`, `JobIds = @()`. **With `-Coverage` (U9 answered 2026-09-08): `--json` does not expose the job id, so run with `--raw` via `-ExpectJson:$false`**: stdout is the line `Test job started: <N>` followed by xUnit XML (`<assemblies><assembly><collection><test name method time result>` with `<failure><message>` on failed tests); parse `N` into `JobIds` and the XML into `Tests`. |
| `Get-MutCoverageRaw -Env -JobIds` | `[string[]]` raw CSV documents | `test coverage <id> <jobId> --json` per job; returns each `csv` string |
| `Get-MutCoverage -Env -JobIds` | `[{ObjectType; ObjectId; LineNo; Hits}]` | `Get-MutCoverageRaw` then `ConvertFrom-MutCoverageCsv` (§6.5.5) per document; merge by summing `Hits` |
| `Get-MutApiBase -Env` | string | U8: derive from `Url`; verify `GET <base>/api/v2.0/companies` returns 200 |
| `Get-MutCompanyId -Env` | GUID string | first company from `/api/v2.0/companies` |
| `Grant-MutPermissionSet -Env -PermissionSetId -AppId` | `@{ Granted = [users]; AlreadyHad = [users] }` | Automation API: `GET <apiBase>/api/microsoft/automation/v2.0/companies({companyId})/users` → for every user, `GET users({userSecurityId})/userPermissions`; if no row has that `permissionSetId`, `POST users({userSecurityId})/userPermissions` with `{ "roleId": <id>, "appId": <AppId>, "scope": "System" }` (the Automation API field is `roleId`; verified live 2026-09-08). Idempotent. Used by `Publish-Baseline` for every entry of config `permissionSets`. |
| `Invoke-MutApi -Env -Method -Path [-Body]` | parsed JSON | `Invoke-RestMethod` with Basic auth from `env users <id> --json` (cache credentials in the module for the session; never log them), `If-Match: *` on PATCH, path relative to `<apiBase>/api/mutation/core/v1.0/companies(<companyId>)/` |

The SOAP-runner functions `Get-MutCompanyName`, `Get-MutRunnerState`, `Stop-MutRunnerBatch`, `Invoke-MutMutantBatch` and `Test-MutSoapRunner` are part of this interface too (§6.10.3).

`Targets` is `@([pscustomobject]@{ CodeunitId = 95155; Function = $null })`. All CLI calls go through one private function `Invoke-Continia -Arguments <string[]> -TimeoutSec` in `DemoPortal.psm1` that runs `cliPath`, captures stdout, parses JSON, and is the single Pester mock point. `Docker.psm1` exports the same names and each throws `[System.NotImplementedException]'Docker backend is not implemented in v1'`.

#### 6.5.4 Steps (`Invoke-MutationRun.ps1 -ConfigPath <file> [-RunNo N] [-SkipEnvironment] [-SkipBaseline]`)
Each step is a function in `lib/*.psm1`; the script is idempotent per run number (a step that finds its output for this run skips itself).

1. `Initialize-MutRun` — load config (§6.5.1), compute `RunNo` (next after highest in `results/`), create `<workDir>/runs/<RunNo>/`.
2. `Ensure-MutEnvironment` — `Get-MutEnvironment` or `New-MutEnvironment` (`-SkipEnvironment` requires an existing one), else (an environment was found) a best-effort PATCH `activeMutantId = 0` (F3c: this branch can reach an environment Mutation Core is already installed on, from an earlier attempt at this or an earlier run; `activeMutantId` lives in the environment's own isolated storage and survives a crash, and the probe below runs a real test job, so a stale active mutant plus a failing probe test would misattribute a false `Killed` to it under the same `RunNo` — see §6.5.6's identical hazard) then `Start-MutEnvironment` unconditionally (F3, finding I6 — not only when not already `Running`, since a `Running` status is not proof of serving). Both `New-MutEnvironment` and this call pass `-RequireProbe $false` (F3b IMPORTANT 2): the settle-and-probe's target is the AUT's own test codeunit, which does not exist until step 3 installs it, so an unconfirmed probe here is a warning, not fatal. `Sync-MutAutCopy`.
3. `Publish-Baseline` — `Install-MutDependencies` for `aut-original` and for `test-app`; `Publish-MutApp` for Mutation Core, then `aut-original`, then `test-app` (with ruleset and `-AllowDowngrade`); then `Grant-MutPermissionSet` for every entry of config `permissionSets` (§6.1.5b). `Invoke-MutTests` over `testApp.testCodeunits` with `-Coverage`, then `baseline.repeats − 1` more passes without coverage (§6.11.2). **Abort if any test fails in every pass**; a test that fails in some passes only is flagged flaky (§6.11.2). Save `baseline.json` (`{ tests[], durationsByCodeunit, repeats, flakyTests[] }`), `coverage.json` (§7.2) when job ids exist, and `references.json` (§6.5.5).
4. `Build-Schemata` — run the generator (§6.4.9) with config flags into `<workDir>/runs/<RunNo>/gen/`. On every iteration (the generator recreates the whole tree each time), before compiling, write `gen/aut-schemata/.vscode/settings.json` (BOM-less UTF-8) containing exactly `{ "al.codeAnalyzers": [] }`: the schemata app is generated, compiled once, never read by a human and never shipped, so **no style analyzer runs against it at all** — only genuine compiler errors can fail the compile. (Four consecutive attempts to instead downgrade one CodeCop rule at a time — `AA0072` naming, `AA0137` unused-variable, `AA0021` var-ordering, plus a defective generated ruleset missing `name` — each passed unit tests and then failed against the real 1,072-file AUT on a different rule; disabling analyzers entirely ended that whack-a-mole.) When `rulesets` is also configured, still write `<rulesets dir>/.cli-ruleset-schemata.json` (BOM-less UTF-8, regenerated every run): `includedRuleSets` = one entry `{ "action": "Default", "path": "./<rulesets.file>" }` (mirrors F12's own relative-include style), `rules` downgrades `AA0072` and `AA0137` to `Info` (the generator's injected `MutationCore`/`MutCond_<n>` declarations, §6.4.7, do not follow the AUT's own naming/unused-variable rules by design), and pass it to `Compile-MutApp` via `-Ruleset` — this remains a harmless second line of defence, not the mechanism that suppresses the diagnostics. `Compile-MutApp` on `gen/aut-schemata` uses this generated ruleset (not the configured one directly) when `rulesets` is set, else no `-Ruleset` at all. On errors: for each diagnostic with a `file`/`line`, find the `linemap.json` block containing that line → collect mutant ids → mark them `CompileError` in `results` → append their stable keys to `gen/exclude.json` → regenerate with `--exclude-stable-keys gen/exclude.json` → recompile. Cap at 10 iterations, then throw. Diagnostics without a mapped block are fatal.
5. `Publish-Schemata` — per `schemata.publishStrategy`: `same-version`: `Publish-MutAppFile` schemata `.app`; `bump-build`: generator was called with `--aut-version <version with build+1>`, then `Publish-MutAppFile`; `unpublish-test-app`: `Unpublish-MutApp testApp` → `Publish-MutAppFile` schemata → `Publish-MutApp test-app`. Then PATCH setup `activeMutantId = 0` and rerun `Invoke-MutTests` over `testApp.testCodeunits`. **Abort if any failure** (the schemata must be behaviour-preserving when inactive).
6. `Push-Manifest` — PATCH setup `currentRunNo = RunNo`; POST each mutant of `mutants.json` to `mutants` (skip ids already present, `status = Pending`).
7. `Get-CoveringTests` — §6.5.5. Mutants with no covering test get `Status = Uncovered` without running.
8. `Invoke-MutantLoop` — §6.5.6. Re-invoking `Invoke-MutationRun.ps1` with the same `-RunNo` after this step has started (e.g. after a crash, **or the environment-recovery cap below aborting the run**) continues where the loop stopped, rather than re-running every mutant from scratch (§6.5.6). **If the loop aborts on its environment-recovery cap (F3b IMPORTANT 3), step 9 still runs** (against whatever the loop completed before aborting) rather than being skipped: `mutant-loop.done` is not written, so a later, genuinely complete re-invocation for this `RunNo` still runs this step for real.
9. `Export-Results` — GET all `mutantResults` for `RunNo`, merge with `mutants.json` → `results/<RunNo>.json` (§7.3) and `results/<RunNo>-summary.md` (§7.5). `Remove-MutEnvironment` unless `keepEnvironment`. **On the step-8 cap-abort path (F3b): still writes `results/<RunNo>.json`/summary (every mutant without a row renders as `Pending`, §7.3; `aborted: true`, F3c) and Write-Warnings how many of how many mutants finished (the same denominator `totals.total` uses, F3c — mutants plus compile-error-excluded ones), but does not write `export.done` and does not call `Remove-MutEnvironment` regardless of `keepEnvironment` — then the run still throws (never reports success) after this partial export lands on disk. Any mutant recorded `Error` before the abort is also named in its own warning (F3c): a resume skips a mutant with ANY recorded status, including `Error`, so those are not retried and stay excluded from the score denominator (§7.3) unless their rows are deleted first.**

#### 6.5.5 Covering-test selection (`lib/References.psm1`, `lib/Coverage.psm1`)
- `Get-MutReferenceMap -AutPath -TestAppPath` → `references.json`: `{ "<autObjectId>": [<testCodeunitId>, …] }`. Build a name→id map from every AUT `.al` file: strip `//` and `/* … */` comments (block-comment state tracked across lines), then skip the recognised **file preamble** — blank lines, `#` compiler directives, and `namespace`/`using` declarations — and test the **first remaining line** against `^(codeunit|table|page|report|enum|interface|query|xmlport)\s+(\d+)\s+("[^"]+"|\S+)`. If that line does not match, the file yields **no entry**, and the implementation MUST emit a warning naming the file.

  The map MUST be keyed by **(object type, name)**, never by name alone. AL ids are per type, so a name may be claimed by a codeunit and a page at once; a name-only map silently overwrites, then resolves the name to an id owned by a *different* type. On the real AUT this is not hypothetical: **55 names are claimed by more than one object, 36 AUT codeunits lose their map slot entirely, and 391 of 812 entries resolve to an id that is also some other codeunit's id**. It was live on the Tier B slice itself — `page 72918635 "CTS-CB JPMorgan Assist Setup"` overwrote `codeunit 72918654` of the same name, and because that page's id equals the pilot codeunit `72918635 "CTS-CB Auth Share Detection"`, test codeunits 95179 and 95191 were attributed to the pilot object although neither mentions it anywhere. Reference sites carry the type (`Codeunit "…"`, `Record "…"`, `Page "…"`, `Database::"…"`, …), so resolve each reference with its own type: `Record`/`Database` → `table`, `Codeunit` → `codeunit`, `Page` → `page`, and so on. A collision *within* one type is a genuine ambiguity and MUST warn.

  References MUST be collected from **trivia-stripped** content, on the same terms as the header: a commented-out `Codeunit::"X"` must not bind a test to X.

  **Why first-remaining-line rather than scanning forward for any matching line** (this reverses an earlier amendment, which was wrong): scanning forward attaches a *wrong* id — a realistic `permissionset` whose `Permissions` list contains `table 50100 = X` yields `table 50100` named `=`, and header-shaped text inside a string literal does the same. A wrong id is worse than none: the real object never enters the map, every reference to it is discarded, and its mutants fall through to `Uncovered`, deflating the score. Stopping at the first non-preamble line cannot do that. Its own risk — an unanticipated leading construct silently dropping an object — is why the warning is mandatory: the preamble set above is closed for AL today (comments, directives, `namespace`, `using`), and anything outside it must be visible rather than silent. Both failure modes were live: `#pragma`/`#if` files were dropped before any of this, and 306 AUT files carry a commented-out `//namespace` one uncomment away from being dropped by a preamble set that omits it. then for each test codeunit file (`Subtype = Test`) collect quoted object names in `Codeunit "…"`, `Record "…"`, `Page "…"`, `Enum "…"`, `Codeunit::"…"`, `Page::"…"`, `Database::"…"` and map them to ids.
- `ConvertFrom-MutCoverageCsv -Csv` → `[{ObjectType; ObjectId; LineType; LineNo; Hits}]`. **Format pinned by `fixtures/coverage/sample.csv` (U9, 2026-09-08): no header row; five quoted positional columns** `"ObjectType","ObjectId","LineType","LineNo","Hits"` where LineType ∈ `Object | Trigger/Function | Empty | Code`, e.g. `"Codeunit","50000","Code","12","1"`. The parser MUST validate exactly five columns per row and a known ObjectType, and MUST throw otherwise. Only `LineType = Code` rows carry meaningful `Hits`; selection uses those rows.
- `Get-CoveringTests -Mutant -Coverage -References -TestCodeunits` → `[int[]]` of test codeunit ids: if `Coverage` has rows for `(ObjectId, LineNo)` with `Hits > 0`, the test codeunits whose jobs produced them; else `References[ObjectId]` **intersected with `TestCodeunits`** (order preserved from the reference map); else `@()`. The intersection matters because the reference map is built from AL source (§6.5.5 above) and can name test codeunits that are not in the configured scope; without it, those codeunits would run un-baselined (§6.5.4 step 3 only baselines `TestCodeunits`, so `Get-MutTimeoutBudget`, §6.5.6, would fall back to `minSeconds` for them) and reported coverage would describe tests the run never claimed to include. If the intersection is empty the mutant is `Uncovered` — the honest outcome when the configured suite does not reach it.

#### 6.5.6 Mutant loop and timeout (`lib/MutantLoop.psm1`)
**Resumable (M3):** before the per-mutant loop starts, `Invoke-MutMutantLoop` loads already-recorded results for this `RunNo` and skips those mutants entirely (no covering-test lookup, no PATCH, no test run, no POST) — each still appears in the returned rows, from the recorded data, so the export remains complete. The Mutation Core API (GET `mutantResults?$filter=runNo eq <RunNo>`, the same source `Export-MutResults` reads) is preferred as the source of truth; `<workDir>/runs/<RunNo>/results.jsonl` (written by this same loop, possibly by an earlier, crashed attempt at this exact run) is used only when the API reports no rows at all for the run. This is what makes re-invoking the loop for the same `RunNo` after a crash (§6.5.4 step 8) continue where it stopped instead of re-running, and re-POSTing, every mutant from scratch.

For each remaining mutant, in id order:
1. PATCH setup `activeMutantId = <id>`.
2. Budget: `max(minSeconds, perTestFactor × baseline duration of the covering codeunits + jobOverheadSeconds × count)`.
3. Run `Invoke-MutTests` on a background runspace under the budget (§6.5.6 implementation note: a runspace, not `Start-Job` — see the FIX comment on `Invoke-MutTestsWithBudget`). On timeout: PATCH `activeMutantId = 0` **before** the reset (F3b BLOCKER 1 — see below), then `Reset-MutEnvironment`, record `Timeout`, continue.
4. On completion: if `Failed > 0`: GET `mutantResults?$filter=runNo eq <RunNo> and mutantId eq <id>`; if empty, POST `{ runNo, mutantId, status: 'Killed', killingTest: '<codeunit>:<function>' of the first failed test that is not flaky (else the first failed test, §6.11.3), killingError (§6.11.1), durationMs }`. If `Failed = 0`: GET the same filter and, if empty, POST `Survived` — idempotent the same way as `Killed`, so a duplicate-key response from a resumed run's already-existing row is never POSTed again; a duplicate-key failure that does still occur (e.g. a race) is swallowed, never aborting the loop. Also write each result to `<workDir>/runs/<RunNo>/results.jsonl` immediately (crash safety): the append is retried up to 5 times with a short back-off, and a still-failing write is logged and skipped rather than thrown, since the API already holds the authoritative result.
5. PATCH `activeMutantId = 0` after every mutant.
6. Each mutant's entire body (steps 1–5) is wrapped so an unexpected error of any kind — not just a timeout or a `Failed`/`Passed` outcome — records `Status = 'Error'` with the exception message and moves on to the next mutant, **with one deliberate exception (F3b BLOCKER 2, amending F3): the environment-recovery-cap abort below is re-thrown, not swallowed into a per-mutant `Error`.** The loop reports how many mutants ended in `Error` when it finishes.

**Environment recovery (F3, run 8, finding I6; hardened F3b).** A result of `Passed + Failed = 0` (empty) or a job-level `ErrorMessage` — either can mean the environment died mid-run rather than that the mutant's covering tests genuinely produced nothing — is retried once (as already described for the empty case) but, before that retry, the loop confirms the environment itself is not the cause: PATCH `activeMutantId = 0` (a real test job is about to run while nothing must be misattributed to this mutant — see below), re-check status (`Get-MutEnvironment`), then call `Start-MutEnvironment` regardless of the reported status — idempotent, and (per its own §6.5.3 amendment) it now always runs the settle-and-probe, which is what actually confirms serving rather than merely `Running`. On success, PATCH `activeMutantId = <id>` again and retry the mutant with whatever handle `Start-MutEnvironment` returned (Reset-MutEnvironment on the timeout path costs no PATCH cycle since it never retries the same mutant). A `Timeout`'s `Reset-MutEnvironment` is deactivated-around the same way and spends from the same budget, so a dead environment presenting as repeated timeouts cannot reset forever uncounted.

**Why the deactivate/reactivate matters:** the probe/reset above runs a REAL test job. Mutation Core's `OnAfterTestMethodRun` records a `Killed` row for *any* failing test while `activeMutantId <> 0`, with no check that the failing test covers that mutant — probing or resetting with the wrong mutant still active can misattribute a false kill to it, the same misattribution class §6.5.5's reference-map fix eliminated, one layer down. This is worse on resume, since `Get-MutRecordedResultsForRun` (above) prefers the API, which is exactly where the false row would have landed.

**Recovery cap.** Recovery attempts (the environment was not `Running`, its probe failed anyway, or a timeout's reset) are spent from a single per-run budget (3, a constant, not a config key) — once spent, the loop aborts instead of continuing to erode mutants one at a time. §6.5.4 step 8/9 describes what happens to the run when that abort fires.

**Environment outage wait (503 bisect, 2026-09-30).** The DemoPortal environment has a transient outage after roughly 45–60 minutes of continuous test jobs, independent of mutation (`spikes/503-bisect/`). During one, the API calls (`Invoke-MutApi`) fail with `(503) Server Unavailable` — including the step-1 PATCH, which runs before the empty-result retry above and so bypassed recovery entirely: runs 8 and 9 each recorded the last 46 mutants as `Error` in seconds. Now any throw inside a mutant's body (other than a `LimitsExceeded` abort) calls `Wait-MutOutageRecovery` and re-runs the **same** mutant, up to 2 times per mutant, before recording `Error`. The wait polls every 30 s: PATCH `activeMutantId = 0` first, and only when that succeeded run the readiness check `Start-MutEnvironment` (its probe is a real test job, so it must never run with the mutant still active — the F3b BLOCKER 1 hazard). It returns the handle once serving is confirmed. An optional `-BeforeProbe` step runs after a successful PATCH and before the readiness check; a throw from it skips that poll's probe (a `LimitsExceeded` throw propagates). The CLI loop passes none; the SOAP loop passes its orphan sweep (§6.10.4 step 1). If the environment does not serve again within 900 s, it throws `LimitsExceeded` and the run aborts with a partial export. A wait that ends in recovery is not charged against the recovery cap: it costs time, not score integrity. A mutant retried this way writes one `results.jsonl` line, not one per attempt.

**Consecutive-`Error` circuit breaker.** After each mutant, the loop counts consecutive `Error` rows; any other status resets the count. At 5 it throws `LimitsExceeded` with the rows so far attached (`TargetObject`), so the pipeline exports a partial result exactly as for the recovery cap. This is the backstop for failures that present *inside* a job while the environment looks healthy between jobs — run 9 lost 46 mutants that way, spent zero recovery slots, and published `aborted: false` with a score over 219 of 265.

**Non-terminating mutants (run 10, 2026-09-30).** `continia test run --timeout N` stops only the client after N seconds and returns exit code 1 with `status: failed`, `summary.total: 0`, no tests and an empty stderr; the BC session keeps running. So an empty result whose attempt took at least `ClientWaitExpiredFraction` (0.9) of the timeout handed to the backend is treated as `TimedOut`: it is never retried against the still-running session, and the Timeout branch resets the environment, which is what ends that session. `Timeout` counts as detected in the score (§7.3). A Timeout whose reset returns gives its recovery slot back — a non-terminating mutant is a verdict, not a lost environment; a reset that throws keeps the slot spent. 5 consecutive `Timeout` rows abort the run with a partial export, the same shape as the other aborts, because each costs a full stop/start and that many in a row points at the budget or the environment.

**Stopping the runaway session (run 11, 2026-10-01).** On a Timeout, the loop first stops the job's own test session instead of resetting the environment: it lists `sessions`, targets `Client Service` sessions on the current server instance (the highest `serverInstanceId` listed, which always includes the caller's own request session; stale rows from before the last restart sit on older instances and are never targeted), POSTs `stop` to each, and polls until they are gone (up to 120 s). Verified live: `StopSession` ends a session stuck in a non-terminating mutant's loop within ~10 s, although BC documents that it cannot always. With no target visible, a target that stays, or no sessions API (an older Mutation Core), it falls back to `Reset-MutEnvironment`. If that reset throws, the mutant is still recorded as `Timeout` (the verdict was reached) and is not re-run; the loop then waits for the environment with `Wait-MutOutageRecovery` before the next mutant. Neither a stopped session nor a successful reset spends a recovery slot; a failed reset does.

**Confirming a Timeout (run 14, 2026-10-01).** `Timeout` counts as detected (§7.3), so an environment hiccup that pushes an ordinary mutant past its budget is a false kill: run 14's mutant 159 (`MatchingAccounts.Count() > 0` → `>= 0`, which survived in 186 ms in run 13) hit its wall-clock budget with no runaway session behind it. After a Timeout's recovery (session stop or reset), the loop now re-runs the same mutant once — waiting for the environment first if the reset failed — and records `Timeout` only if the re-run times out too; otherwise the re-run's own result stands. A non-terminating mutant times out every time; a hiccup does not. Cost: one extra attempt per genuinely non-terminating mutant. An unconfirmed Timeout is never written as a row; if the run aborts before the re-run, that mutant stays `Pending`.

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

### 6.7 Fix suggestions (Suggest-Test)

**Goal.** Every `Survived` mutant of a run maps to one suggested AL change to the automated tests that would kill it, or to
a reasoned verdict that the mutant is equivalent. The output is a machine-readable report (`results/<RunNo>-fixes.json`,
§7.8) that a separate agent picks up to apply the changes in the test app. This feature **suggests only**: it never
compiles, publishes or runs a suggested fix, and it never writes into the AUT or test-app repositories (§4). Only
`Survived` mutants are in scope; `Timeout`, `Error`, `CompileError`, `Uncovered`, `Pending` and `Killed` rows are ignored.

The work is split in three stages. Stages 1 and 3 are deterministic PowerShell with Pester tests; stage 2 is a Claude
Code skill (an LLM), because writing a meaningful assertion needs judgement. No Anthropic API is called from PowerShell.

```
results/<N>.json + out/runs/<N>/gen/mutants.json + out/aut-original + out/test-app
   └─ stage 1  Export-MutFixBriefs   →  results/<N>-fix-briefs.json   (§7.7, deterministic)
        └─ stage 2  skill mutation-fix-suggest  →  results/<N>-fixes.json  (§7.8, LLM)
             └─ stage 3  Test-MutFixReport + Export-MutFixMarkdown  →  validation errors, results/<N>-fixes.md
```

#### 6.7.1 Test procedure index (`References.psm1`)
`Get-MutTestProcedureIndex -TestAppPath <string> [-CodeunitIds <int[]>]` → `[pscustomobject[]]`, one per test codeunit
(files where `Test-MutIsTestCodeunit` is true), sorted by `CodeunitId`:
`{ CodeunitId; CodeunitName; File; Procedures }`. `File` is relative to `-TestAppPath` with forward slashes. `Procedures`
is `[{ Name; StartLine; EndLine }]` in file order, one per test method. With `-CodeunitIds`, only those codeunits are
returned (an id with no file is simply absent).

- Header: reuse `Get-MutObjectHeader` (id and name). A file without a header is skipped, with its existing warning.
- A **test method** is a `procedure` declaration (optionally `local`/`internal`) whose preceding attribute block (the
  consecutive lines starting with `[` directly above it; comment-only lines inside the block are skipped, not treated as its end, so a commented line between `[Test]` and `procedure` never drops a test) contains `[Test]` (case-insensitive). Handler methods
  (`[ConfirmHandler]`, `[MessageHandler]`, …) and helpers are not test methods.
- Line numbers are 1-based lines of the **original file** (comments must not shift them; strip comments per line, or
  use a stripping that preserves newlines). `StartLine` is the first line of the attribute block. `EndLine` is the last
  line that starts with `end;` (after leading whitespace) before the next `procedure` declaration's attribute block, or
  before the object's closing `}` for the last procedure.

#### 6.7.2 Stage 1 — fix briefs (`orchestrator/lib/FixBriefs.psm1`)
Exports exactly: `Get-MutOperatorHint`, `New-MutFixBriefs`, `Export-MutFixBriefs`, `Test-MutFixReport`,
`Export-MutFixMarkdown`.

`Get-MutOperatorHint -Operator <string>` → `[string]`. Fixed texts (MUST be these, verbatim):

| Operator | Hint |
|---|---|
| REL | `A relational operator was changed. Kill it with a test whose input sits exactly on the boundary of the comparison (equal values, zero, empty string), and assert the outcome that differs between the original and the mutated operator.` |
| BOOL | `and/or was swapped. Kill it with a test where exactly one of the operands is true, and assert the outcome that differs.` |
| NOT | `A not was added or removed, so the branch inverts. Assert the observable effect of the branch for an input that takes it (returned value, record written, error raised).` |
| COND | `The condition was forced to a constant. Add a test where the condition evaluates to the other value, and assert the effect of the branch it guards.` |
| DEL | `A statement was deleted. Assert the effect of that statement: the field value it set, the record it inserted, modified or deleted, the error it raised, or the value it returned.` |
| INSFLAG | `A flag argument was inverted (e.g. Insert(true) to Insert(false)). Assert the side effect the flag controls, such as trigger logic run by the call.` |
| BREAK | `A break was inserted. Assert the result of loop iterations after the first one.` |

Any other operator throws `Unknown operator '<op>'`.

`New-MutFixBriefs -RunNo <int> -Mutants <object[]> -Results <object> -AutPath <string> -TestIndex <object[]>
[-ContextLines <int> = 15]` → the §7.7 object (`autPath`/`testAppPath`/source-path fields are added by the caller).
`-Mutants` are §7.1 entries; `-Results` is the parsed `results/<N>.json` (§7.3). For every row with `status = Survived`,
in ascending `id` order:

1. Join with the `mutants.json` entry of the same `id` for `objectType`, `objectName`, `file`. A survivor without a
   `mutants.json` entry throws `Survivor <id> missing from mutants.json`.
2. **Locate the line.** Read `<AutPath>/<file>`. If line `line` contains `original` (ordinal, exact substring),
   `resolvedLine = line`, `sourceDrift = false`. Otherwise search the whole file: exactly one line containing `original`
   → `resolvedLine` = that line, `sourceDrift = true`; zero or several → `resolvedLine = null`, `sourceDrift = true`.
   A missing or empty file gives `resolvedLine = null`, `sourceDrift = true` and `context = null`. (Why: `out/aut-original` is
   re-synced on every run and the AUT is a moving target, §1.1.) For DEL the `original` is the deleted statement and
   the check is the same.
3. **Context.** Lines `max(1, c − ContextLines)` … `min(lineCount, c + ContextLines)` where `c = resolvedLine ?? min(line, lineCount)`,
   rendered as one string, lines joined by `\n`, each formatted as `{marker}{lineNo,5}: {text}` where `marker` is `>`
   on line `c` and a space otherwise (PowerShell: `'{0}{1,5}: {2}' -f $marker, $n, $text`). Trailing `\r` is removed.
4. **Covering tests.** For each id in the row's `coveringTests`, the `-TestIndex` entry with that `CodeunitId` gives
   `{ codeunitId, codeunitName, file, procedures: [{ name, startLine, endLine }] }`. An id not in the index gives
   `codeunitName = null`, `file = null`, `procedures = []` and a `Write-Warning`; it is never dropped.
5. `operatorHint = Get-MutOperatorHint <operator>`.

`Export-MutFixBriefs -RunNo <int> -Config <object> [-RepoRoot <string>]` reads `results/<N>.json`,
`<workDir>/runs/<N>/gen/mutants.json`, builds the index over `<workDir>/test-app` restricted to all `coveringTests` ids
of the survivors, calls `New-MutFixBriefs` with `-AutPath <workDir>/aut-original`, sets `autPath`/`testAppPath` (repo
relative, forward slashes) and `autSourcePath`/`testAppSourcePath` (from `Config.aut.sourcePath`/`Config.testApp.sourcePath`),
writes `results/<N>-fix-briefs.json` (`ConvertTo-Json -Depth 10`, UTF-8) and returns its path. A run with zero survivors
writes a brief with `survivors: []`. A missing `results/<N>.json` or `mutants.json` throws, naming the path.

Script `orchestrator/Export-MutFixBriefs.ps1 -ConfigPath <file> -RunNo <int>` loads the config (`Config.psm1`),
imports `References.psm1` and `FixBriefs.psm1`, calls `Export-MutFixBriefs` and prints the path. It works on any past
run without touching an environment.

**Pipeline hook.** `Invoke-MutRunPipeline` (`Run.psm1`) calls `Export-MutFixBriefs` after `Export-MutResultsStep` on a
complete (non-partial) export. A failure there is caught and reported with `Write-Warning`; it MUST NOT fail the run or
change any other output. No `.done` marker: the brief is cheap and re-generated every time.

#### 6.7.3 Stage 2 — skill `mutation-fix-suggest` (`.claude/skills/mutation-fix-suggest/SKILL.md`)
Invoked as `/mutation-fix-suggest <RunNo>` in this repo. Input: `results/<N>-fix-briefs.json`. Output:
`results/<N>-fixes.json` (§7.8). Procedure the skill MUST prescribe:

1. Read the brief. Group survivors by covering test codeunit (first `coveringTests` entry). For each group, read the
   test file under `testAppPath` once, and the AUT file around each `context` as needed (under `autPath`).
2. Per survivor decide the verdict:
   - `fix` — an existing test method already drives execution through the mutated line but does not assert the
     difference; add assertions to it (`add-assert`) or rewrite it (`modify-test`).
   - `new-test` — no existing method reaches the line with an input that distinguishes original from mutant; write a
     new `[Test]` procedure in a covering codeunit, following that codeunit's own style (GIVEN/WHEN/THEN comments,
     its library codeunits, its fakes, its handler functions, its `Assert` variable).
   - `equivalent` — no test can observe the difference (state the reason concretely, e.g. "`Count() > 0` and
     `Count() >= 1` are identical for integers"). Use it only with a concrete reason.
3. Mutants that the same change kills share one fix entry (`mutantIds` with several ids). Every survivor appears in
   exactly one entry.
4. `alCode` uses only identifiers that exist in the test codeunit or that the change itself declares (new local
   variables are declared in the code given). For `add-assert` it is the lines to insert; for `modify-test` and
   `new-test` it is a complete procedure including its attribute lines.
5. Write the file, then run `orchestrator/Test-MutFixReport.ps1 -RunNo <N>` and correct every reported error until it
   prints `ok`.

The skill may fan out one subagent per test codeunit group and merge their entries; fix ids are assigned after the
merge. It writes only `results/<N>-fixes.json` and `results/<N>-fixes.md`, and never edits AUT or test-app files.

#### 6.7.4 Stage 3 — validation and rendering
`Test-MutFixReport -BriefsPath <string> -FixesPath <string> [-TestIndex <object[]>]` → `[string[]]` errors, empty when
valid. Without `-TestIndex`, it builds one from the brief's `testAppPath` (resolved against the repo root). Rules, each
violation one error string that starts with the `fixId` (or `report` for file-level errors):

1. The file parses and has `runNo` equal to the brief's `runNo`, and a `fixes` array.
2. `fixId` is present and unique; `verdict` ∈ {`fix`, `new-test`, `equivalent`}; `confidence` ∈ {`high`, `medium`,
   `low`}; `rationale` is non-empty; `mutantIds` is a non-empty array.
3. Every survivor id of the brief is in exactly one entry's `mutantIds`; no entry names an id that is not a survivor
   of the brief.
4. `equivalent`: `target`, `change` and `anchor` are null and `alCode` is the empty string.
5. `fix`: `change` ∈ {`add-assert`, `modify-test`}; `target.isNewProcedure = false`; `target.procedure` is a procedure
   of `target.codeunitId` in the index, and `target.file` equals that codeunit's `File`. `add-assert` needs
   `anchor.afterLine` within that procedure's `[StartLine, EndLine]`; `modify-test` needs `anchor = null`. `alCode` and
   `expectedEffect` are non-empty.
6. `new-test`: `change = new-test`; `target.isNewProcedure = true`; `target.procedure` is NOT already a procedure of that
   codeunit and is unique among new-test entries of that codeunit; `anchor = null`; `alCode` contains `[Test]` and
   `procedure <target.procedure>(` (case-insensitive); `expectedEffect` is non-empty.
7. For `fix` and `new-test`, `target.codeunitId` is a covering test codeunit of every mutant in `mutantIds`.

`Export-MutFixMarkdown -BriefsPath <string> -FixesPath <string> -OutPath <string>` writes `results/<N>-fixes.md`: a header
(run no, survivor count, counts per verdict and per confidence), then one section per target test codeunit (equivalent
entries last, under "Equivalent mutants"), and per entry: fix id, mutant ids with `original → mutated` and AUT
`file:line`, verdict, change, target procedure, anchor, confidence, rationale, expected effect, and `alCode` in an
` ```al ` fence. Ordering: codeunit id, then fix id.

Script `orchestrator/Test-MutFixReport.ps1 -RunNo <int>`: runs `Test-MutFixReport` on `results/<N>-fix-briefs.json` and
`results/<N>-fixes.json`; on errors prints each one and exits 1; on success writes `results/<N>-fixes.md` with
`Export-MutFixMarkdown`, prints `ok` and exits 0.

#### 6.7.5 Consuming the report (for the downstream agent)
The downstream agent reads `results/<N>-fixes.json`, never the markdown. Line numbers (`anchor.afterLine`, procedure
ranges) refer to the `out/test-app` snapshot taken at brief time. The real test-app source is at `testAppSourcePath`
of the brief and may have moved on: locate the target procedure by **name**, treat lines as advisory, and apply
several `add-assert` entries in one file bottom-up. It then compiles, runs the covering test codeunit on the original
AUT (must pass) and, when a mutation run is available, re-runs the mutant (must be `Killed`).

### 6.8 Fix verification (apply, verify, repair)

**Goal.** Close the loop that §6.7 opens. Apply the suggested fixes of `results/<N>-fixes.json` to a copy of the test
app, prove each one on the environment, let an agent repair the failures, and hand the owning team a patch that holds
only verified fixes. A fix is **verified** when three things hold:
- the patched test app compiles;
- the changed test passes on the unmutated AUT;
- every mutant the entry names is killed by that test.

The pilot `spikes/fix-pilot/` (2026-10-01) showed the mechanics on 8 entries of run 15: 7 verified (23 of 23 mutants
killed), and 1 failed on the original AUT. About 10 s per test job, about 80 s per test-app publish.

Rules, in addition to §4:
- Never write the real test-app repository (`testApp.sourcePath`). All edits go to `out/fix-verify/<N>/`.
- Strictly one test job at a time (F7).
- `activeMutantId` is reset to `0` in a `finally` after every mutant, and confirmed `0` at the end.
- The step always ends by republishing the unpatched `<workDir>/test-app`, so the environment is left as the mutation
  run left it.
- `equivalent` entries are never applied. Their verdict is `skipped-equivalent`.

#### 6.8.1 Apply (`orchestrator/lib/FixVerify.psm1`, pure, no environment)
`Invoke-MutFixApply -SourcePath <string> -DestinationPath <string> -Fixes <object[]>` → `[pscustomobject[]]`, one per
applied entry: `{ fixId; file; insertedStartLine; insertedEndLine }` (lines in the **patched** file).

1. Mirror `-SourcePath` to `-DestinationPath`, deleting anything already there, then apply in place.
2. Group entries by `target.file`. Locate procedures by **name** with `Get-MutTestProcedureIndex` on the unpatched copy.
   A target procedure that is not found throws `Fix <fixId>: procedure '<name>' not found in <file>`.
3. Per file, apply all `add-assert` and `modify-test` edits **bottom-up** by their position:
   - `add-assert` inserts the `alCode` lines after `anchor.afterLine`.
   - `modify-test` replaces lines `StartLine..EndLine` of the target procedure.

   Then append each `new-test` procedure before the codeunit's final closing `}`, preceded by one blank line, in fixId
   order.
4. Two `add-assert` entries with the same anchor go in fixId order. A `modify-test` and any other edit in the same
   procedure throws `Fix <a> and <b> both change procedure '<name>'`. The caller resolves the clash, see §6.8.3.
5. Keep each file's line ending (LF or CRLF, decided by its first line break) and its BOM presence. `alCode` is split
   on `\n` and has any `\r` removed before insertion.

`New-MutTestPatch -OriginalPath <string> -PatchedPath <string> -OutPath <string>` writes a unified diff with
`git diff --no-index --no-color` between the two folders. Paths in the diff are relative to the test-app root:
`a/<file>` and `b/<file>`, with no `out/...` prefix. The diff applies with `git apply -p1` in the test-app root. Exit
code 1 from `git diff` means "differences found" and is not an error. An empty diff writes an empty file.

#### 6.8.2 Verify (`Invoke-MutFixVerify`, live)
`Invoke-MutFixVerify -Config <object> -RunNo <int> [-FixIds <string[]>] [-RepoRoot <string>]` → the §7.9 object, also
written to `results/<N>-verified.json`. `orchestrator/Invoke-MutFixVerify.ps1 -ConfigPath <file> -RunNo <int>
[-FixIds <csv>]` wraps it. **Use the config the mutation run used**, so the environment and the settle probe match.

1. Select the entries: all entries of `fixes.json`, or only `-FixIds`. `equivalent` entries become
   `skipped-equivalent` and drop out of the set.
2. `Get-MutEnvironment` / `Start-MutEnvironment` as the mutant loop does. Then GET `mutationSetup(0)` and PATCH
   `activeMutantId = 0` if it is not.
3. **Compile and publish.** `Invoke-MutFixApply` into `out/fix-verify/<N>/test-app`, then `Publish-MutApp` with the
   ruleset and `-AllowDowngrade`, exactly as `Publish-MutBaseline` publishes the test app.
   - On failure, map each diagnostic (file + line) to the entry whose inserted range contains it.
   - Mark those entries `compile-failed`, keep the diagnostic text, drop them, and apply again from scratch.
   - At most 3 publish rounds.
   - A diagnostic that maps to no entry is recorded under `unmappedDiagnostics`. If a round's failure maps to no entry
     at all, every remaining entry becomes `compile-failed` with that text, and the step goes on to restore.
4. **Original.** With `activeMutantId = 0`, run each remaining entry's target test function (`Invoke-MutTests`, one
   target = codeunit + function, timeout 120 s). Fail → `fails-on-original`, with the error text.
5. **Mutants.** For each mutant id of each entry that passed step 4:
   - PATCH `{ activeMutantId = <id>, currentRunNo = -N }`. Verification records its `Killed` rows under the negative
     run number, so they can never be read as rows of a real run (real run numbers are always positive, §6.9.3);
   - run that entry's target function, timeout 120 s;
   - PATCH `activeMutantId = 0` in a `finally`.

   The test failing = `killed` (its error is the evidence). Passing = `survived`. A client timeout = `timeout`, which
   counts as killed, as in §7.3. The verdict comes from the test result, never from `mutantResults` rows.

   Entry verdict:
   - every mutant killed or timeout → `verified`;
   - otherwise `not-killed`, with the per-mutant list.
6. **Environment errors.** A 503 or an empty result during step 4 or 5: wait and retry the same job, as
   `Wait-MutOutageRecovery` does (up to 2 retries). Still failing → `env-error` for that entry, and go on.
7. **Restore.** Republish the unpatched `<workDir>/test-app`, then confirm `activeMutantId = 0`. A restore failure is
   reported as a thrown error **after** `verified.json` is written.
8. **Merge.** When `results/<N>-verified.json` already exists, entries in this run replace the same fixIds there.
   Others stay unchanged. Each entry carries the `revision` of the fix it verified (absent = 0).

#### 6.8.3 Repair and deliver (skill `mutation-fix-verify`, `.claude/skills/mutation-fix-verify/SKILL.md`)
Invoked as `/mutation-fix-verify <RunNo>`. Procedure the skill MUST prescribe:

1. Run `Invoke-MutFixVerify.ps1` on all entries.
2. **Repair rounds (at most 2).** For each entry with verdict `compile-failed`, `fails-on-original` or `not-killed`, an
   agent gets:
   - the entry;
   - its brief;
   - the exact evidence (compile diagnostics, the test error, or the surviving mutant ids);
   - the "Mutation runtime facts" of `mutation-fix-suggest`.

   The agent rewrites the entry in `fixes.json`. It keeps the `fixId`, increments `revision`, and adds the evidence it
   answered to the `rationale`. It may also give up: it sets the verdict to `equivalent` (with proof, as §6.7.3 asks),
   or leaves the entry and says why. Then run `Test-MutFixReport.ps1` until `ok`, and `Invoke-MutFixVerify.ps1
   -FixIds <the repaired ids>`. `env-error` entries are simply re-run, not rewritten.
3. **Combined check.** Run `Invoke-MutFixVerify.ps1 -FixIds <all verified ids>` once more on the whole verified set.
   This catches clashes between entries that were verified apart. An entry that fails here goes back into the repair
   loop if rounds are left; otherwise it is marked by this run's verdict.
4. **Deliver.** `Export-MutFixDelivery -RunNo <N>` applies only the `verified` entries to
   `out/fix-verify/<N>/delivery/test-app`, writes `results/<N>-tests.patch` with `New-MutTestPatch` against `out/test-app`,
   and writes `results/<N>-verified.md`. The markdown has:
   - counts per verdict;
   - one line per entry: fixId, mutants killed out of total, revision;
   - every failure with its evidence;
   - how to apply: `git apply -p1 <patch>` in the test-app root, and the reminder that line numbers came from the
     `out/test-app` snapshot (§6.7.5).
5. The skill never commits to, or writes into, the test-app repository.

### 6.9 Headless use (external callers)

**Goal.** Let a program call al-mutation with no human in the loop. The first caller is mutant-fixer
(`C:\GeneralDev\DevOpsPullers\mutant-fixer`), which runs one targeted mutation run per matching draft pull request.

#### 6.9.1 Call sequence
Every call runs with the repository root as working directory. `<cfg>` is an absolute path, usually outside the
repository. `<N>` is chosen by the caller.

1. `powershell -NoProfile -File orchestrator/Invoke-MutationRun.ps1 -ConfigPath <cfg> -RunNo <N>`
2. `powershell -NoProfile -File orchestrator/Export-MutFixBriefs.ps1 -ConfigPath <cfg> -RunNo <N>`
3. An agent session runs `/mutation-fix-suggest <N>` with a headless prompt (§6.9.6).
4. `powershell -NoProfile -File orchestrator/Test-MutFixReport.ps1 -RunNo <N>` prints `ok`.
5. An agent session runs `/mutation-fix-verify <N>` with a headless prompt and a list of fix ids.
6. The caller reads `results/<N>-fixes.json`, `results/<N>-fixes.md`, `results/<N>-verified.json` and
   `results/<N>-tests.patch`.

#### 6.9.2 External config and sources
- The config file may live anywhere. Relative paths inside it still resolve against the repository root (§6.5.1), so
  an external config should use absolute paths.
- `aut.sourcePath`, `testApp.sourcePath` and `rulesets.sourcePath` may point into a `git worktree`. In a worktree,
  `.git` is a file, not a folder. The AUT copy (§6.5.2) excludes `.git` both as a folder and as a file.
- `Export-MutFixDelivery` loads a config given as a path through `Get-MutConfig`, so `%VAR%` references and relative
  paths resolve exactly as they do for the run.

#### 6.9.3 Run numbers
- Run numbers are positive integers with no upper bound and no padding. Every file and folder name uses the plain
  decimal number.
- Fix verification (§6.8.2) uses `-N` as `currentRunNo`, so it cannot collide with any real run.
- A caller that picks its own numbers must not reuse a number that already has `results/<N>.json`.

#### 6.9.4 Exit codes
| Script | 0 | 1 |
|---|---|---|
| `Invoke-MutationRun.ps1` | Run completed, survivors or not | Config, environment or pipeline error; aborted run (`aborted: true` is still written); environment lock held |
| `Export-MutFixBriefs.ps1` | Briefs written | Any error |
| `Test-MutFixReport.ps1` | Prints `ok` | Validation errors (one per line) or any other error |
| `Invoke-MutFixVerify.ps1` | Verify completed, whatever the per-fix verdicts | Config or environment error, restore failure, environment lock held |

#### 6.9.5 Environment lock (`orchestrator/lib/EnvLock.psm1`)
`Invoke-MutationRun.ps1` and `Invoke-MutFixVerify.ps1` hold `<workDir>/.environment.lock` while they run. Every
config that targets one environment must use the same `workDir`; the lock does not protect two work directories.
- The lock is an **open file handle**, not a pid check. `Enter-MutEnvLock -WorkDir <string> -RunNo <int> -Owner
  <string>` creates the file with `FileMode.CreateNew`, `FileShare.Read` and `FileOptions.DeleteOnClose`, writes
  `{ pid, runNo, owner, startedUtc }`, flushes, and keeps the stream open in module scope. When the process ends for any
  reason, Windows closes the handle and deletes the file. A reused pid can therefore never hold a lock.
- When the file exists, it tries to open it exclusively (`FileShare.None`). That fails while a holder has it open:
  read the content (open for read with `FileShare.ReadWrite, Delete`) and throw
  `environment locked by <owner> run <runNo> (pid <pid>) since <startedUtc>: <path>`. Unreadable content gives
  `environment locked by unknown holder: <path>`.
- When the exclusive open succeeds, nobody holds the file: it is a stale leftover (crash before close, or older code).
  Delete it through that exclusive handle (`DeleteOnClose`), warn naming the old holder, and create the lock again with
  `CreateNew`. A loser of that race gets the "locked" error, never a double hold.
- `Exit-MutEnvLock -WorkDir <string>` closes the module's stream for that path, which deletes the file. No error when
  this process holds no lock. Both scripts call it in a `finally`.
- `runNo` is the `-RunNo` given; `0` means "auto-numbered".

#### 6.9.6 Headless skill runs
A prompt that contains `HEADLESS RUN` makes both skills run unattended:
- never ask the user anything; decide and continue;
- take the config path from the prompt (`Config file: <cfg>`) and use it for every `-ConfigPath` and `-Config`;
- `mutation-fix-suggest` finishes only when `Test-MutFixReport.ps1` prints `ok`;
- `mutation-fix-verify` runs step 1 of §6.8.3 with `-FixIds <the given ids>` and repairs only those ids;
- an environment-lock error stops the skill with a report; it does not wait or retry;
- every hard rule of §6.7.3 and §6.8 still applies.

#### 6.9.7 Stable outputs
External callers depend on the file names and fields of §7.8 and §7.9 (`results/<N>-fixes.json`,
`results/<N>-fixes.md`, `results/<N>-verified.json`, `results/<N>-tests.patch`). Paths in `results/<N>-tests.patch`
are relative to the test-app root (`testApp.sourcePath`), as `a/<file>` and `b/<file>`: apply it with
`git apply -p1 results/<N>-tests.patch` run in the test-app root, or with `git apply -p1 --directory=<test-app folder>`
from the repository root that contains the test app (§6.8.1). Renaming a file or a field is a breaking change: tell the callers
first. Optional fields may be added.

#### 6.9.8 Linux, environment overrides and cleanup
The orchestrator runs under PowerShell 7 on Linux as well as Windows PowerShell 5.1 (platform helpers in
`lib/Config.psm1`: `Test-MutIsWindows`, `Get-MutPathComparison`, `Read-MutTextFile`, `Write-MutTextFile`).
- `MUT_WORK_DIR` replaces `workDir` and `MUT_CLI_PATH` replaces `demoPortal.cliPath` (`Set-MutConfigOverrides`, applied
  by `Get-MutConfig` before validation). `MUT_RESULTS_DIR` replaces `<repo>/results` for every reader and writer
  (`Get-MutResultsDir`). Relative values resolve against the repo root.
- `demoPortal.profileId` is optional; without it the backend derives the profile from the apps' `app.json`
  (`Resolve-MutProfileId`). `demoPortal.localization` (default `base`) picks the localization.
- `Remove-MutRunEnvironment.ps1 -ConfigPath <cfg>` deletes the config's environment regardless of
  `keepEnvironment`; exit 0 also when it is already gone. `Remove-MutOrphanEnvironments.ps1 -Prefix <p> [-Keep <n>]`
  deletes every non-Shared environment named `<p>*` (case-sensitive, `<p>` starts with `mut-` and is longer than it);
  exit 1 only when the prefix is refused or listing fails.

### 6.10 SOAP test transport (mutant loop without DemoPortal test jobs)

**Why.** A `continia test run` job costs a median of 10.5 s, while the tests one mutant needs run in a median of
188 ms inside BC (run 15). The SOAP-runner spike (2026-10-04, `spikes/soap-runner/`, `docs/spike-baseline.md`
"SOAP-runner spike") ran test codeunits from a SOAP web-service session through the standard runner chain.
- **Speed:** 630 ms per call against 10.7 s per job.
- **Batch:** all 157 mutants of 72918635 ran in one call at 285 ms each.
- **Parity:** all 157 outcomes matched run 15, and `MUT Test Hooks` behaved the same.

This section moves the **per-mutant loop** onto that route. Baseline, coverage, the settle probe and fix
verification stay on `continia test run` (§6.5.3), because they run once per run, not once per mutant.

#### 6.10.1 Facts the design rests on (spike, mut-spike-02)
| # | Fact | Consequence |
|---|---|---|
| S1 | A SOAP call that runs `"Test Suite Mgt."` (`CreateTestSuite`, `SelectTestMethodsByRange`, `RunAllTests`) is not nested inside a test codeunit. It runs runner 130450 → `"Test Runner - Mgt"` (130454), including `StartStopPermissionMock`. | `MUT Test Hooks` (§6.1.4) work unchanged. The §6.1.6 nesting refusal does not apply. |
| S2 | `"Test Suite Mgt.".RunAllTests` reads `"Test Suite"` from the record, not from the filter. | Call `FindFirst()` on the filtered `Test Method Line` first. |
| S3 | `MUT Mutation Setup` mirrors to Isolated Storage only in its triggers. | The runner sets the mutant with `Modify(true)`. |
| S4 | A SOAP session that hangs in a non-terminating mutant is **not listed in `Active Session`**, so `MUT Sessions API` cannot see or stop it. Inside the call, `SessionId()` returns an ordinary id, and `StopSession(<that id>)` from another SOAP call ends it within 5 s. | The runner records its own session id and current mutant, committed, before each mutant (§6.10.2). The client stops the session by id. |
| S5 | A hung runner keeps its test transaction open. Other test runs then fail on its locks: `... a record in table 'Bank' is being updated in a transaction done by another session.` | A hung runner must be stopped before the next call. One runner at a time (§6.10.5). |
| S6 | A timed-out SOAP call returns nothing to the client. In one probe the connection dropped by itself after 276 s; nothing may depend on that. | Each mutant's result is committed by the runner as it finishes, so a timed-out batch loses at most the hung mutant. |
| S7 | `/WS/<company>/Codeunit/<service>` uses the same Basic credentials and base URL as the API (`Get-MutApiBase`). The company **name** goes in the path. | The backend resolves the company name once and caches it. |

#### 6.10.2 Mutation Core additions (`core-app/`, version `1.1.1.0`; `1.2.0.0` since §6.11.1)
The configs' `coreApp.version` and §6.0.1 become `1.1.1.0` (`1.1.0.0` added the runner; `1.1.1.0` added the
`Stop Requested` guard below). The schemata AUT's dependency on Mutation Core `1.0.0.0` is a minimum version, so
it stays valid. New objects:
- table 50004 "MUT Runner State"
- codeunit 50003 "MUT Runner"
- codeunit 50004 "MUT Upgrade" (`Subtype = Upgrade`)

All three are added to `MUT Core All` (§6.1.5b).

**Table 50004 "MUT Runner State"** (`DataPerCompany = false`, `Access = Public`): `1 "Session Id" Integer`,
`2 "Batch Id" Text[50]` (PK: `"Batch Id"`), `3 "Run No." Integer`, `4 "Mutant Id" Integer` (0 = not inside a mutant),
`5 "Mutant Started At" DateTime`, `6 "Mutants Done" Integer`, `7 Finished Boolean`, `8 "Stop Requested" Boolean`
(set by `StopRunner`; a confirmed `StopSession` does not prove the session ended, so the runner checks it itself).

**Codeunit 50003 "MUT Runner"** (`Access = Public`) is published as the SOAP service `MUTRunner`. Registration:
`"Web Service Management".CreateTenantWebService(TenantWebService."Object Type"::Codeunit, Codeunit::"MUT Runner",
'MUTRunner', true)`, called from `MUT Install`'s `OnInstallAppPerDatabase` (after the sandbox check) and from
`MUT Upgrade`'s `OnUpgradePerDatabase` (for environments that already have 1.0.0.0).

The codeunit's `Permissions` cover `AL Test Suite`, `Test Method Line`, `MUT Mutation Setup`, `MUT Mutant Result` and
`MUT Runner State`. Each call builds its own test suite named `CopyStr('MR' + Format(Abs(SessionId()), 0, 9), 1, 10)`.
It deletes the suite (if present) before building it and again when the call ends. Every procedure below that sets
the active mutant does so with `Modify(true)` on `MUT Mutation Setup` (S3) followed by `Commit()`.

| Procedure | Behaviour |
|---|---|
| `RunMutants(BatchId: Text; CodeunitIds: Text; MutantIds: Text; RunNo: Integer): Text` | `BatchId` is a client GUID. `CodeunitIds` is a `SelectTestMethodsByRange` filter such as `95155\|95110` (the mutant's covering set). First insert the state row (`Batch Id`, `Session Id` = `SessionId()`, `Run No.`, `Mutant Id` = 0) and commit. Then build the suite and commit. **Stop guard:** before each mutant, after the suite run, before incrementing `Mutants Done` and before setting `Finished`, the runner re-reads its row (`Get`, which also makes the following `Modify` work on the current version); if `Stop Requested` is set, or the row is gone, it returns the entries so far at once, writing nothing (no result row, no state change, no active-mutant change, no suite deletion). For each id in the comma list `MutantIds`, in order: (1) set the state row's `Mutant Id` and `Mutant Started At` = now, and commit; (2) set the active mutant (id, RunNo) and commit; (3) filter the suite, `FindFirst()` (S2), `RunAllTests`, timing the call for `Duration Ms`; (4) read the suite's `Function` lines with `Run = true`. `passed`/`failed` count `Result::Success`/`Result::Failure`. (5) If `passed + failed = 0`, insert no row; the entry's `status` is `Empty`. Otherwise, if no `MUT Mutant Result` exists for (RunNo, mutant), insert one: `Killed` when `failed > 0`, with `Killing Test` = `CopyStr(CopyStr(<Name of the suite's Codeunit line with the same "Test Codeunit">, 1, 30) + ':' + <"Function">, 1, 250)` of the first failed line in `"Line No."` order (the name is cut to 30 characters because the hook receives `CodeunitName: Text[30]`, §6.1.4), else `Survived`. Set `Duration Ms` and `Recorded At`. The entry's `status`/`killingTest` are those of the persisted row after this step, so a row the hook wrote first wins; `status` is the enum value **name** (`Killed`, `Survived`, ...), not its caption. (6) Increment `Mutants Done` and commit. After the loop: set the active mutant to 0 and commit; set the state row's `Mutant Id` = 0 and `Finished` = true; delete the suite; commit. Returns `[ { mutantId, status, killingTest, killingError, failures, durationMs, passed, failed } ]` (`killingError`, `failures` and the `"Killing Error"` value on an inserted `Killed` row: §6.11.1). |
| `RunTests(CodeunitIds: Text): Text` | **First** sets the active mutant to 0 and `Current Run No.` to 0, and commits. Then it runs the suite as above, with no state row and no result rows. Returns `{ passed, failed, durationMs, tests: [ { codeunit, name, result, durationMs, error } ] }`. |
| `GetRunnerState(): Text` | Returns `{ serverNowUtc, rows: [ { batchId, sessionId, runNo, mutantId, mutantStartedAt, mutantsDone, finished, stopRequested } ] }`, with datetimes as ISO-8601 UTC strings (`Format(<DateTime>, 0, 9)`). |
| `StopRunner(BatchId: Text): Text` | Refuses (`Error`) unless a row with that `Batch Id` exists with `Finished = false` and a `Session Id` other than `SessionId()`. Otherwise sets the row's `Stop Requested` and commits (it calls `LockTable()` on the state table before reading the row, so a runner that commits its own row change at the same moment cannot make the `Modify` fail), **then** calls `StopSession(<row's Session Id>, '<reason>')` inside a `[TryFunction]`, so a session that already ended (for example after a fault) does not raise an error. Returns `stopped`, or `not stopped: <error text>`. It does not delete the row. |
| `DeleteRunnerState(BatchId: Text): Text` | Deletes that row and the suite named after its session. Called by the client only after a confirmed stop or a `Finished` row. |

The runner inserts the result row itself because, unlike the test session, it runs outside the restricted test
session and may write Mutation Core's tables. The killing-test format is the hook's (§6.1.4), so export and resume
read the same text whichever of the two wrote the row.

#### 6.10.3 Backend functions (`backends/DemoPortal.psm1`; `Docker.psm1` stubs throw `NotImplemented`)
§6.5.3's list of exported functions is extended by these. The SOAP envelope, namespace
`urn:microsoft-dynamics-schemas/codeunit/MUTRunner`, camelCase parameter names (`batchId`, `codeunitIds`, …),
`return_value` XPath and `[uri]::EscapeDataString(<company name>)` are those of `spikes/soap-runner/Invoke-SoapRunnerSpike.ps1`.

| Function | Returns | Implementation |
|---|---|---|
| `Get-MutCompanyName -Env` | string | The first company's `name` from `/api/v2.0/companies`, cached per environment id. `Get-MutCompanyId` is cached the same way. |
| `Invoke-MutSoap -Env -Operation -Arguments [-TimeoutSec]` | `@{ Ok; Value; Fault; TimedOut; Dropped; DurationMs; HttpStatus }` | Private, and the single Pester mock point for SOAP. `POST <apiBase>/WS/<escaped company name>/Codeunit/MUTRunner` with `SOAPAction: <namespace>:<Operation>`, Basic auth and XML-escaped arguments. BC SOAP binds parameters by **sequence**, so `-Arguments` is an `[ordered]` dictionary in the AL parameter order, sent in that order. `Value` is the `return_value` text. On a SOAP fault, `Fault` is the `faultstring`. A client timeout sets `TimedOut`. A connection closed before a response, or a 5xx without a `faultstring` (a gateway), sets `Dropped`. `HttpStatus` is the HTTP status of a failed response (404 when the service is missing), `$null` on success or when no response arrived. Throws on HTTP 503, DNS or connect failure (no connection at all), so §6.5.6's outage wait handles those (the exception carries `Data['MutSoapOutage']`); on HTTP 401/403 (credentials or permissions); and on an exception that is not a web error. |
| `Get-MutRunnerState -Env` | `@{ ServerNowUtc; Rows }` | `GetRunnerState`, parsed. Throws when no value is returned. |
| `Stop-MutRunnerBatch -Env -BatchId -CodeunitIds` | `@{ Confirmed; Attempts }` | Calls `StopRunner`, reads the batch row's (`Mutant Id`, `Mutants Done`), then polls every 5 s for up to 120 s. Each poll runs `RunTests` of a **health codeunit**: the first id of `-CodeunitIds`, which is the batch's covering set (for an orphan found at loop start, whose covering set is unknown, the loop passes `testApp.testCodeunits`). `Confirmed` is true when that `RunTests` returns `failed = 0` and `passed > 0` within 30 s **and** the row's (`Mutant Id`, `Mutants Done`) read after it equals the previous read (a runner still writing moves it; a move restarts the comparison; an unreadable state confirms nothing). `RunTests` clears the active mutant first. On confirmation it calls `DeleteRunnerState`. `Attempts` counts the health calls. |
| `Remove-MutRunnerState -Env -BatchId` | string | `DeleteRunnerState` for that batch (`deleted` or `not found`); throws when no value is returned. |
| `Invoke-MutMutantBatch -Env -CodeunitIds -MutantIds -RunNo -MutantBudgetSec` | `@{ Results; HungMutantId; FaultMutantId; Fault; Stopped }` | Generates a `BatchId` and starts `RunMutants` on a background runspace (the §6.5.6 runspace pattern), with client timeout `MutantIds.Count × MutantBudgetSec + 60`. It polls `Get-MutRunnerState` every 5 s; the poll interval is injectable for tests. Two rules declare a **hang**: (1) the row for this `BatchId` has a non-zero `Mutant Id` for more than `MutantBudgetSec` on the server clock (`ServerNowUtc − MutantStartedAt`); (2) no row appears within 60 s, or the batch exceeds its client timeout. On a hang it calls `Stop-MutRunnerBatch`; an unconfirmed stop throws `RunnerStopFailed`. **The batch has ended only when its row shows `Finished = true` or its stop was confirmed.** A `TimedOut` or `Dropped` call is not an outage: polling continues until one of those holds. A `Fault` with the row still unfinished and its `Mutant Id` not advancing for 10 s is treated like a hang, but reported as `FaultMutantId`. `Results` come from the return value when the call finished, otherwise from GET `mutantResults` for the batch's mutant ids (rows committed before the hang, S6). **`HungMutantId`/`FaultMutantId` are never included in `Results`**; whether a row already exists for them is reported in `Results` only through the loop's own GET (§6.10.4). A batch whose row was seen `Finished` and whose return value arrived deletes its row (`DeleteRunnerState`, best effort). |
| `Test-MutSoapRunner -Env` | `$true`/`$false` | `GetRunnerState` answers without a fault. False when Mutation Core is older than 1.1.0.0 or the service is missing (it cannot tell 1.1.0.0 from the required 1.1.1.0). Uses the 30 s state-call timeout. |

`GetRunnerState`, `StopRunner` and `DeleteRunnerState` use a 30 s client timeout (`RunMutants` uses the batch's client
timeout, `RunTests` the health timeout).

#### 6.10.4 Loop changes (`lib/MutantLoop.psm1`) and config
Config key `testTransport`: `"cli"` (default when the key is missing) or `"soap"`. Since 2026-10-06 (after runs 16 and 17) every shipped config sets `"soap"`, so mutant-fixer, which uses `mutation.config.json` as its template, runs on SOAP too. `Get-MutConfig` validates it. Optional
`soap.batchSize`, a positive integer with default 50. When `testTransport` is `"soap"`, `Test-MutSoapRunner` is
checked right after `Publish-Baseline` (§6.5.4 step 3) and again at loop start; false throws before any further work.

With `"soap"`:
1. **Orphans first.** At loop start, before reading recorded results: run `Get-MutRunnerState`. For every row with
   `Finished = false`, run `Stop-MutRunnerBatch`; such a row counts as a row of this loop (§6.10.5). Then PATCH
   `activeMutantId = 0`. A confirmed stop deletes its row (`Stop-MutRunnerBatch`). Finished rows the sweep finds stay:
   they are keyed by a unique `BatchId`, and nothing reads them (a batch deletes its own once its result is in). An
   orphan whose stop is not confirmed goes to the recovery path in step 5. The sweep runs again inside **every**
   outage wait, after the wait's PATCH 0 and **before** its readiness probe (`-BeforeProbe`, §6.5.6), because a runner
   from the interrupted call may still be alive and re-sets the active mutant per mutant, and the probe is a real test
   job; and before the next batch after any batch call that ended in an outage. A sweep that completes resets the
   PATCH-0 outage counter (mutant 0), so outages in separate sweeps do not add up over the run; it does **not** reset
   it while an outer retry for mutant 0 is still running (a sweep nested inside that retry's outage wait), so the
   per-mutant cap still bounds that retry. A row listed as stale (step 5) is deleted by the sweep, not stopped.
2. **Batches.** Take the pending mutants (resume rules unchanged), in id order. Group runs of consecutive mutants with
   the same covering set (§6.5.5) into batches. "Same" means set equality: the grouping key is the sorted ids, while
   `CodeunitIds` keeps the §6.5.5 order, so the health codeunit is the first covering codeunit. A batch holds at most `batchSize` mutants, and is capped further so
   that the sum of their covering sets' baseline durations stays ≤ 120 s. `Uncovered` handling is unchanged.
   `MutantBudgetSec` is the §6.5.6 budget for one mutant of that covering set.
3. **Results.** Each entry of `Results` is appended to `results.jsonl`; the runner already wrote the API row, so
   nothing is POSTed. An entry with `status = Empty` is the CLI's empty result: one retry, alone, after
   `Confirm-MutEnvironmentServing` (§6.5.6 environment recovery, with the PATCH to 0 first), then `Error`.
4. **Hang.** For `HungMutantId` X, GET `mutantResults` for (RunNo, X):
   - If a row exists (the hook recorded a failing test before the hang), it stands.
   - Otherwise apply the run-14 confirmation (§6.5.6 "Confirming a Timeout"): re-run X alone. If it hangs again,
     POST `{ status: 'Timeout' }` for X, so resume skips it. Otherwise the re-run's result stands.

   The mutants after X continue as a new batch. 5 consecutive `Timeout` mutants abort the run, as today.
5. **Fault, or a stop that fails.**
   - **Fault:** `FaultMutantId` is the culprit. Mutants before it keep their rows. The culprit is re-run alone under
     §6.5.6's per-mutant rules (the outage wait, up to 2 re-runs, then `Error`, which is not POSTed). The mutants
     after it continue as a new batch. A batch head whose outage retries are spent is recorded from its API row when
     the runner wrote one (best-effort GET), otherwise as `Error`.
   - **`RunnerStopFailed`:** PATCH 0, then `Reset-MutEnvironment` under the §6.5.6 recovery cap. A failed reset keeps
     its slot spent. A confirmed stop spends no slot. After a successful reset the batch's row, still unfinished, is
     deleted (`Remove-MutRunnerState`), so no later sweep stops its session id. The delete is best effort: if it fails,
     the batch id is remembered as stale and the next sweep deletes the row instead of stopping it; the failure never
     changes the culprit's verdict. The culprit is treated as in §6.5.6 for the CLI: after a
     successful reset it goes through the step-4 hang handling (existing row stands, otherwise a re-run alone). After a
     failed reset it is recorded as `Timeout`, POSTed once the environment serves again, and not re-run. The
     consecutive-`Error` breaker counts per mutant.
   - **Re-run counts:** "up to 2 re-runs" means the §6.5.6 outage rule: a mutant whose attempt **throws** is re-run
     after the outage wait, at most twice. A culprit whose re-run faults again without throwing is recorded as
     `Error` after that one re-run. A hang re-run that returns `Empty` goes through step 3.
   - **Outage waits apply everywhere:** every Mutation Core API call the loop makes for a mutant (PATCH, GET, the
     `Timeout` POST, `Confirm-MutEnvironmentServing`) is covered by the same outage wait and per-mutant retry as the
     CLI body. A `Timeout` verdict already reached retries its POST after the wait instead of becoming `Error`.
6. **No per-mutant PATCH.** The PATCH of `mutationSetup` around each mutant is gone: the runner sets and clears the
   mutant itself. The loop still PATCHes `activeMutantId = 0` before any probe, reset or outage wait (F3b BLOCKER 1).

`Invoke-MutationRun.ps1` and `lib/*.psm1` stay free of backend names (guardrail 6): the loop calls only the
functions of §6.10.3.

#### 6.10.5 Guardrails
- One runner at a time per environment, as for test jobs (guardrail 8). The environment lock (§6.9.5) serializes
  runs. A batch never starts while a runner row from an earlier batch is unfinished (S5).
- `StopRunner` takes a `BatchId`, never a raw session id. AL refuses only finished rows and the calling session, so
  an **unfinished** row left from before a restart could still point at a session id the server has reused. The loop
  therefore deletes the row of a batch whose runner a reset ended (§6.10.4 step 5).
- Any exit of `RunMutants` that does not reach `Finished = true` leaves the row unfinished, for the client to stop
  and clean up. The active mutant is cleared by `RunTests`, by the loop's PATCH before any probe, or by the next
  `RunMutants`. Clearing happens before anything else runs tests.

#### 6.10.6 Acceptance
1. Pester, with `Invoke-MutSoap` mocked, covering each path:
   - a finished batch
   - a hang mid-batch with partial results
   - a hung mutant that already has a row (no re-run)
   - a re-run that hangs again (`Timeout` POSTed)
   - a re-run that passes
   - `Empty` handling
   - a fault mid-batch (culprit isolated, the rest continue)
   - a `Dropped` call that later shows `Finished`
   - an orphan at loop start
   - `RunnerStopFailed` going to a reset
   - resume after a crash
2. Live, on `mut-spike-02` with `mutation.u2.config.json` and `testTransport = "soap"`: every one of the 265 mutants
   has the same status as run 15, including the 3 `Timeout` mutants of 72918630. Record the wall-clock time and the
   seconds per mutant in `docs/spike-baseline.md`.
3. With `testTransport = "cli"`, the Pester suite and behaviour are unchanged.

### 6.11 Kill reasons and flaky baseline tests (issues.md, run 1015)
Run 1015 scored 408/409, and two tests made 81 % of the kills. One of them killed mutants far outside its
scenario, including the time code. A timing-dependent test fails on its own, and every mutant active at that
moment is scored as killed. The run could not show this, because `reason` was `null` on every `Killed` row.
This section adds two things: the failure message of each kill, and a repeated baseline that flags unstable tests.

#### 6.11.1 Kill reason
- **Format.** The kill reason is the first non-blank line of the first killing test's error message (leading CR,
  LF and whitespace are skipped, then the text is cut at the next CR or LF), trimmed, cut to 250 characters. One
  procedure implements it, `"MUT Mut".FormatKillReason(ErrorText: Text): Text[250]`, and the orchestrator uses
  the same rule. A message with no non-blank line gives `''` in AL and `null` in the results.
- **Table.** `MUT Mutant Result` (§6.1.2) gains `7 "Killing Error" Text[250]`. The API page `mutantResults`
  gains `killingError`. Mutation Core becomes version `1.2.0.0` (§6.0.1 and every shipped config's
  `coreApp.version`). The field is additive, so no upgrade code is needed.
- **Hook (§6.1.4).** `OnAfterTestMethodRun` reads `GetLastErrorText()` into a local **before** its
  `ClearLastError()` call. When it inserts the `Killed` row it sets `"Killing Error"` from that text, using the format
  above. If BC no longer holds the test's error at that point (verify live), the hook uses
  `CurrentTestMethodLine."Error Message Preview"` instead. The hook still never raises an error.
- **SOAP runner (§6.10.2).** `RunSuite` already reads `"Error Message Preview"` per line. `RunMutants` sets
  `"Killing Error"` on a `Killed` row it inserts, from the first failed line. Each entry gains `killingError`
  (the persisted row's value, so a hook-written row wins, as for `killingTest`). Each entry also gains
  `failures`: `[ { test, error } ]` for every failed line in `"Line No."` order, at most 10. `test` uses the
  `killingTest` format, and `error` uses the reason format.
- **CLI loop (§6.5.6 step 4).** The `Killed` POST adds `killingError` from the chosen killing test's `Error`.
- **Loop rows.** Every loop row (CLI, SOAP, and rows rebuilt from the API or `results.jsonl` on resume) carries
  `KillingError`. On the SOAP path a row also carries `Failures`, and on the CLI path it carries the failing tests
  of the result. Neither is persisted to the API.
- **Export (§7.3).** `reason` is set for `Killed` rows from `KillingError`, in addition to `Error` rows.

#### 6.11.2 Repeated baseline
- **Config.** Optional `baseline.repeats` is a positive integer, default 3. `Get-MutConfig` validates it, and 1
  turns the repeats off. The shipped configs set it explicitly.
- **Step 3 (§6.5.4).** The first pass is today's coverage run, one `Invoke-MutTests -Coverage` per codeunit.
  Passes 2..`repeats` run `Invoke-MutTests` per codeunit **without** `-Coverage`. Durations and coverage come from
  pass 1 only. A zero-test result in any pass aborts, as today.
- **Verdict per test** (key `<Codeunit>:<Function>` with the codeunit name cut to 30 characters, so it matches
  `killingTest` from every writer):
  - It passes in every pass: stable.
  - It fails in every pass: a real baseline failure, and the run aborts as today, listing every such test.
  - It fails in at least one pass but not all: **flaky**. A warning names each flaky test with its pass/fail
    count and its first error.
- **Output.** `baseline.json` gains `repeats` (the number of passes) and `flakyTests`: `[ { test, passed, failed,
  error } ]`, sorted by `test`. `Get-MutSkippedBaselineResult` (resume) reads both, and an older file without them
  means `repeats = 1` and no flaky tests.
- The step 5 rerun (§6.5.4) is unchanged: it runs once, and a flaky failure there still aborts.

#### 6.11.3 Unreliable kills
- **Choosing the killing test.** When the loop knows the failing tests of a mutant (the CLI result, or the SOAP
  entry's `failures`), `killingTest` and `killingError` come from the first failing test that is **not** flaky. They
  come from the first failing test only when every failing test is flaky. On the SOAP path the runner already wrote
  the row with the first failed line, so the loop overrides only its own row values. The API row stays as written.
- **Flag.** A `Killed` row is `unreliable: true` when every known failing test is flaky. The loop computes the flag
  when it builds the row and stores it in `results.jsonl` and `loop-results.json` (neither stores the failing-test
  lists). A row rebuilt from the API knows only `killingTest`, so it is judged on that one test, and so is a
  `results.jsonl` row without a stored flag. Every other row is `unreliable: false`.
- **Score (§7.3).** `score` is unchanged. A new `strictScore` counts unreliable kills as survived:
  `(killed − unreliableKills + timeout) / (the same denominator)`, rounded and `null` on the same terms as `score`.
  `totals` gains `unreliableKills`. It is a subset of `killed`, not a tenth bucket, so the nine buckets still sum
  to `total`.
- **Summary (§7.5).** The score section shows both scores. A **"Flaky baseline tests"** table lists `flakyTests`.
  An **"Unreliable kills"** table lists id, object, procedure, line, operator, killing test and reason. Both
  sections are omitted when they are empty.

#### 6.11.4 Acceptance
1. Pester: the reason format (multi-line, empty, over-long); the CLI `Killed` POST carries `killingError`; the SOAP
   entry's `killingError`/`failures` reach the row; resume rows carry `KillingError`; export writes `reason` for
   `Killed`; flaky verdicts across 3 passes (stable, all-fail abort, mixed); `baseline.json` round-trip and an older
   file without the new keys; choosing the killing test (one flaky + one stable failing, all flaky);
   `strictScore`/`unreliableKills`; and summary sections present and omitted.
2. AL: `core-app` and `core-app-test` compile with 0 errors. The reason format is one public procedure,
   `"MUT Mut".FormatKillReason(ErrorText: Text): Text[250]`, which the hook and the runner both call. A
   `core-app-test` test covers it with multi-line, empty and over-long input. A test cannot observe its own
   `OnAfterTestMethodRun`, so item 3 proves the hook path live.
3. Live, on `mut-spike-02` only, with the owner's go-ahead: a short targeted run where every `Killed` row has a
   non-null `reason` on both the hook-written and the runner-written path, and `baseline.json` carries `repeats` 3.

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
  "totals": { "total": 26, "killed": 17, "survived": 6, "timeout": 3, "compileError": 0, "uncovered": 0, "equivalent": 0, "error": 0, "pending": 0, "unreliableKills": 0 },
  "score": 0.7692,
  "strictScore": 0.7692,
  "aborted": false,
  "mutants": [{ "id": 1, "stableKey": "…", "objectId": 50200, "procedure": "IsLargeOrder", "line": 4, "operator": "REL",
                "original": "…", "mutated": "…", "status": "Survived", "killingTest": null, "durationMs": 4200,
                "coveringTests": [50300], "reason": null, "unreliable": false }] }
```
`reason` is the error text of an `Error` row and the kill reason of a `Killed` row (§6.11.1), else `null`. `unreliable` is `true` only on a `Killed` row whose every known failing test is flaky (§6.11.3). `strictScore` and `totals.unreliableKills` are defined in §6.11.3; `unreliableKills` is a subset of `killed` and is not one of the nine buckets that sum to `total`.
`score = (killed + timeout) / (total − equivalent − compileError − error − pending)`, rounded to 4 decimals. `Uncovered` counts as survived in the denominator — the suite genuinely did not reach it. When the denominator is **zero or negative** (e.g. every mutant errored), `score` is **`null`**, not `0` — `0` is indistinguishable in JSON from “the suite killed nothing”, which is the opposite of what a collapsed run means. `Error` and `Pending` are **excluded** from the denominator: an infrastructure failure (a failed job, a zero-test result, an unhandled exception) is not evidence about the test suite, and leaving it in silently scored every such mutant as a survivor. The totals buckets MUST sum to `total`, and `<RunNo>-summary.md` (§7.5) MUST render an Errors section alongside Survivors/Timeouts/Compile errors/Uncovered. `aborted` (F3c) is `true` only for the partial export §6.5.4 step 9 writes when the mutant loop stopped on its environment-recovery cap rather than completing every mutant (§6.5.6) — `false` on every normal, complete run. It exists so a consumer never has to infer partial-ness from `totals.pending -gt 0`, an implicit artifact of how an unrun mutant happens to render rather than a deliberate marker.

### 7.4 `fixtures/expected-results.json`
```json
[{ "procedure": "IsLargeOrder", "operator": "REL", "mutated": "Quantity > 10", "expected": "Survived" }, …]
```
One entry per row of §6.3.3 (26 entries). Matching key: `(procedure, operator, mutated)`; for DEL, `mutated` is `""` and `original` is added to the key.

### 7.5 `results/<RunNo>-summary.md`
Sections: header table (run no, backend, environment, AUT version, started/finished, wall-clock), totals table, score, "Survivors" table (id, object, procedure, line, operator, original → mutated, covering tests), "Timeouts" table, "Compile errors" table, **"Errors" table** (mutants whose run failed for infrastructure reasons — a failed job, a zero-test result, an unhandled exception — with the reason), "Uncovered" count, and a **Pending** count when any mutant was never reached. The totals table carries all nine buckets of §7.3 and they MUST sum to `total`. When non-empty, a **"Flaky baseline tests"** table and an **"Unreliable kills"** table follow, and the score section shows `strictScore` next to `score` (§6.11.3).

### 7.6 `docs/spike-baseline.md` template
Sections in this order, each a table with columns `Metric | Value | Backend | Date | Source task`: Environment (create s, start s, activation-app install s, deps install s, AUT deploy s, test app deploy s); U1/U3; U4; U5; U6; U7 (single-method job s, 95155 s, 95913 s, per-test median s); U8 (API base URL pattern); U9 (job id field name, CSV header line); Tier B baseline (pass/fail per codeunit); Hand mutants (20 rows + kill count); Recommendation (`go` / `no-go`, `--max-mutants` default, `timeouts.jobOverheadSeconds`, `schemata.publishStrategy`).

### 7.7 `results/<RunNo>-fix-briefs.json`
```json
{ "runNo": 15, "generatedUtc": "2026-10-01T12:00:00Z",
  "autPath": "out/aut-original", "testAppPath": "out/test-app",
  "autSourcePath": "C:/GeneralDev/AL/…/base-application", "testAppSourcePath": "C:/GeneralDev/AL/…/base-application-test",
  "survivors": [{
    "mutantId": 140, "stableKey": "…", "objectType": "codeunit", "objectId": 72918635,
    "objectName": "CTS-CB Auth Share Detection", "procedure": "DetectInCompany",
    "file": "Authentication/Codeunit/AuthShareDetection.Codeunit.al", "line": 119, "resolvedLine": 119, "sourceDrift": false,
    "operator": "REL", "original": "MatchingAccounts.Count() > 0", "mutated": "MatchingAccounts.Count() >= 0",
    "operatorHint": "A relational operator was changed. …",
    "context": { "startLine": 104, "endLine": 134, "text": "    104:     …\n>  119:         if MatchingAccounts.Count() > 0 then\n…" },
    "coveringTests": [{ "codeunitId": 95155, "codeunitName": "CTS-CB Test Auth Share Detect",
                        "file": "Authentication/TestAuthShareDetect.Codeunit.al",
                        "procedures": [{ "name": "DetectInCompany_…", "startLine": 40, "endLine": 71 }] }] }] }
```
Field rules are in §6.7.2. `survivors` is sorted by `mutantId`. `context` is `null` only when the AUT file is missing.

### 7.8 `results/<RunNo>-fixes.json`
```json
{ "runNo": 15, "generatedUtc": "2026-10-01T12:30:00Z",
  "fixes": [{
    "fixId": "F001", "mutantIds": [140, 141], "verdict": "fix",
    "target": { "codeunitId": 95155, "codeunitName": "CTS-CB Test Auth Share Detect",
                "file": "Authentication/TestAuthShareDetect.Codeunit.al",
                "procedure": "DetectInCompany_NoMatchingAccounts_EmitsNothing", "isNewProcedure": false },
    "change": "add-assert", "anchor": { "afterLine": 68 },
    "alCode": "        Assert.RecordIsEmpty(TempAuthShareTarget);",
    "rationale": "The test reaches line 119 with zero matching accounts but never checks the result buffer.",
    "expectedEffect": "Fails on mutants 140/141 (the buffer gets a row for Count() = 0); passes on the original.",
    "confidence": "high" }] }
```
| Field | Values |
|---|---|
| `fixId` | `F` + 3-digit sequence, unique |
| `verdict` | `fix` \| `new-test` \| `equivalent` |
| `change` | `add-assert` (alCode = lines inserted after `anchor.afterLine`) \| `modify-test` (alCode = full replacement procedure, `anchor` null) \| `new-test` (alCode = full new procedure, `anchor` null) \| `null` for `equivalent` |
| `target` | object as above; `null` for `equivalent` |
| `alCode` | AL source, lines joined by `\n`, 4-space indentation matching the target file; `""` for `equivalent` |
| `confidence` | `high` \| `medium` \| `low` |

Validation rules are in §6.7.4.

### 7.9 `results/<RunNo>-verified.json`
```json
{ "runNo": 15, "verifyRunNo": -15, "updatedUtc": "2026-10-02T10:00:00Z", "environmentName": "mut-spike-02",
  "entries": [{
    "fixId": "F033", "revision": 0, "verdict": "verified", "verifiedUtc": "2026-10-02T09:58:00Z",
    "compile": { "ok": true, "diagnostics": [] },
    "original": { "result": "Pass", "error": null, "durationMs": 9800 },
    "mutants": [{ "mutantId": 271, "outcome": "killed", "error": "Assert.AreEqual failed. Expected:<Other Bank A> Actual:<OTHERBANKA>", "durationMs": 10100 }] }],
  "unmappedDiagnostics": [] }
```
| Field | Values |
|---|---|
| `verdict` | `verified` \| `compile-failed` \| `fails-on-original` \| `not-killed` \| `env-error` \| `skipped-equivalent` |
| `original.result` | `Pass` \| `Fail` \| `null` (not reached) |
| `mutants[].outcome` | `killed` \| `survived` \| `timeout` \| `not-run` |

`entries` is sorted by `fixId`. Fields of a stage that was not reached are `null` (`original`) or `[]` (`mutants`).

`results/<RunNo>-fixes.json` (§7.8) gains one optional field: `revision` (integer, default 0). Only §6.8.3 increments
it. `Test-MutFixReport` ignores it.

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

**Tier B acceptance:** `Invoke-MutationRun.ps1 -ConfigPath mutation.config.json` completes on the Tier B slice (§1.1: AUT codeunit 72918635, covered by test codeunits 95155/95179/95191) and `results/<n>-summary.md` lists survivors; the hand-mutant outcomes (HM01–HM20) agree with the generator-run outcomes for the same lines where both exist.

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
