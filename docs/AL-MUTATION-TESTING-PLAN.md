# AL Mutation Testing for Business Central — Execution Plan (v2)

Plan for Claude Code. Work phase by phase. Do not start a phase before the previous phase's acceptance criteria pass. Each phase ends with a commit.

## Changes from v1

| # | Change | Reason |
|---|--------|--------|
| C1 | Two execution backends: **Docker** (BcContainerHelper) and **DemoPortal** (Continia CLI `continia.exe`). One orchestrator, one backend interface (§6.1). | The AUT is developed against DemoPortal cloud sandboxes; BcContainerHelper 6.1.15 and Docker are also installed locally. |
| C2 | Mutation Core no longer relies on a custom `TestRunner` codeunit. It subscribes to the standard Test Runner events instead (§5). | DemoPortal cannot take a TestRunner codeunit id. The Docker runner uses Microsoft's standard runner by default. One code path serves both. |
| C3 | Phase 0 hand mutants run only the test codeunits that reference the mutated object, not the full suite. | 181 test codeunits run as sequential jobs on DemoPortal; 20 × full suite is days, not half a day. |
| C4 | Sampling (`--max-mutants`) and coverage-based selection are **mandatory** in v1. | Estimated 10k–30k mutants; per-job overhead on DemoPortal caps throughput at roughly 1–2k mutants/day. |
| C5 | Phase 0 gains three spikes: runner events (U4), timeout cancellation (U5), publish-over-dependents (U6). | Facts F5, F7, F9 were verified for BcContainerHelper only. |
| C6 | Facts F7–F9 rephrased backend-neutrally. Guardrail "container name starts with `mut-`" now covers container names **and** DemoPortal environment descriptions; shared environments are never targets. | C1. |
| C7 | Repository layout flattened: the plan's `/mutation` root **is** the repo root. `.tools/` and `.continia/` are ignored. | Single repo for core-app, generator, orchestrator. |
| C8 | Mutation Core object ids 50000–50199, prefix `MUT`. | AUT uses 71553575+ and 72xxxxxx ranges; test app uses 94999–95999. |

## 0. Context and constraints

**Goal:** measure test-suite quality for one Business Central AL app (the App Under Test, "AUT") by generating mutants mechanically, compiling them into a single "schemata" app, and running the covering tests per mutant. Report a mutation score and a survivor list.

**AUT for v1:** Continia Banking base application (`base-application`, app id `83461f48-dd16-49ea-b00c-e656830c640f`, target Cloud, runtime 17.0, platform 28). Test app: `base-application-test` (app id `02b81fad-90fa-4cdc-a414-5bda25e96db0`). Both live in the `Continia Banking` repo, which the generator never edits.

**AUT size (measured 2026-09-07):** 1,065 AL files, 451 codeunits, ~5,500 `if … then` lines, ~700 conditions containing `and`/`or`/`until`. Test app: 181 test codeunits, ~2,144 `[Test]` methods.

**Non-goals for v1:** expression-level mutants inside assignments or arguments, per-commit runs, AI-generated mutants, a general-purpose AL parser, a custom TestRunner codeunit (optional Docker-only optimization, see §5.3).

### Verified language and platform facts — design must respect all of these

| # | Fact | Consequence |
|---|------|-------------|
| F1 | AL `and` / `or` / `xor` have **no documented short-circuit guarantee** (MS docs, confirmed by Microsoft BCQuality knowledge article `boolean-operators-do-not-short-circuit`). | Never write `Mut.Active(id) and <expr>`. Inactive mutants would still evaluate, throwing errors (div by zero, out of range) or reading unloaded records, contaminating every result. |
| F2 | AL has **no conditional expression** (no ternary). `if…then…else` is a statement only. | Mutants must be lifted to statement level. |
| F3 | Procedure arguments are evaluated eagerly (pass by value). | `Mut.Pick(id, a, b)` evaluates both `a` and `b`. Not allowed. |
| F4 | `case` statement: **the first matching value set executes** (MS docs). Guarantee is across value sets, not within one comma-separated list. | `case true of` is the only documented lazy construct. Use it for all condition mutants. |
| F5 | `OnBeforeTestRun` / `OnAfterTestRun` on a TestRunner codeunit **always run in their own transaction**, regardless of TestIsolation / TransactionModel / test outcome. `FunctionName` is empty when called for the whole codeunit. Microsoft's standard runner (codeunit 130450 "Test Runner - Mgt") raises `OnBeforeTestMethodRun` / `OnAfterTestMethodRun` from these triggers. | Set the active mutant and record results in subscribers to these events. Do not write results from inside tests. Whether the subscriber inherits the own-transaction behaviour is **U4** — verify in Phase 0. |
| F6 | SingleInstance codeunit state persists **until the company is closed**, i.e. across test methods in a session. | Set the active id explicitly in the before-method subscriber every time; never lazy-load it. |
| F7 | Both backends can run a named test codeunit, optionally a named function, and return per-test pass/fail with error text. Docker: `Run-TestsInBcContainer -testCodeunit -testFunction -XUnitResultFileName`. DemoPortal: `continia test run <envId> <codeunitId> [functionName] --json`, **one codeunit per job, jobs strictly sequential**. Neither backend is given a TestRunner codeunit id. | The backend interface (§6.1) exposes `Invoke-MutTests` over a list of targets and normalizes results. |
| F8 | Both backends can return line coverage for a run. Docker: Code Coverage virtual table 2000000049 (via `Run-TestsInBcContainer -CodeCoverageTrackingType`). DemoPortal: `continia test coverage <envId> <jobId>` returns CSV **per job**. | Build mutant → covering-tests map from a normalized coverage file; DemoPortal merges one CSV per test-codeunit job. |
| F9 | No per-test timeout exists in the platform or either backend. BcContainerHelper `-ReRun` only restarts on infrastructure errors; `continia test run --timeout` is a client-side wait. | Wall-clock kill must live in the orchestrator. Whether the DemoPortal job can be cancelled server-side is **U5**. |
| F10 | Dependency direction: the mutated AUT calls `Mut.Active()`, so **mutated AUT depends on Mutation Core**, test app depends on both. | Mutation Core is a separate app that never ships to customers. It never depends on the AUT. |
| F11 | Environments: DemoPortal envs are created from a profile (`continia env create --name --profile`), take 1–3 min to start, run BC 28.1 today, and need the Continia Core Internal Activation App installed before agents can use them. The AUT's own dependencies (Continia System Application, Core, Approval, Connector App, Banking Permission Sets) are installed with `continia deps install`. | `New-MutEnvironment` for DemoPortal includes these steps. |
| F12 | `continia compile` / `continia deploy` wrap the AL extension's `alc.exe`, refresh symbols from the target env, and return structured `diagnostics[]` (file, line, column, message). The repo ships `Banking Rulesets/.cli-ruleset-localdeploy.json` which excludes AppSourceCop and downgrades rules that fail on pre-existing code. | Compile-error → mutant-id mapping reads `diagnostics[]`. Schemata compiles with the local-deploy ruleset. |

### Unverified — spike before relying on them

- U1: Whether the AL compiler accepts / optimizes large numbers of duplicated blocks, and the publish-time cost of a schemata app with thousands of guards.
- U2: Whether coverage-based test selection saves meaningful time on this suite (BC tests are integration-heavy). **Most important number**: it decides whether v1 is feasible at all on DemoPortal.
- U3: Whether `case true of` with a `Mut.Active()` call in each value set has measurable overhead in hot loops.
- U4: Whether `OnBeforeTestMethodRun` / `OnAfterTestMethodRun` fire under both backends' default runners, and whether a subscriber's writes commit independently of the test outcome (F5 carried over).
- U5: Whether a DemoPortal test job can be stopped once started, and how long `env stop` + `env start` takes as the recovery path.
- U6: How to replace the installed AUT with the schemata build while the test app depends on it: same id + same version (CLI auto-unpublish is refused by BC when dependents exist?), same id + bumped build number (upgrade path), or unpublish test app → publish schemata → republish test app.
- U7: Per-job fixed overhead on DemoPortal (`test run` of a one-method codeunit) and full-suite wall-clock (181 sequential jobs).

## 1. Repository layout

The repo root is the folder currently named `Mutation-Core` (rename to `al-mutation` between sessions; the running session locks the directory).

```
/core-app            AL app "Mutation Core" (tables, Mut codeunit, event subscribers, API pages)
/generator           TypeScript: tokenizer, operators, schemata writer, manifest
/orchestrator        PowerShell: Invoke-MutationRun.ps1 + /backends/Docker.psm1 + /backends/DemoPortal.psm1
/fixtures            small AL samples + expected mutants (golden files) + fixture AUT/test app
/spikes              throwaway experiments for U1–U7
/docs                this plan, operator catalog, result schema, spike-baseline.md
/results             exported run artifacts (committed; the environment is disposable)
/.tools              continia.exe (ignored)
/.continia           CLI workspace state (ignored)
mutation.config.json backend selection + paths (see §6.2)
```

`.gitignore`: `.tools/`, `.continia/`, `.alpackages/`, `out/`, `node_modules/`, `*.app` except under `fixtures/`.

## 2. Phase 0 — Spike before building (1–2 days)

Purpose: answer U1–U7 and the value question before investing. Runs on the **DemoPortal** backend (what is configured today); every number in `spike-baseline.md` records which backend produced it. Docker numbers are added when Docker Desktop is switched to Windows containers.

Tasks:
1. Scaffold the repo per §1, `git init`, copy this plan to `/docs`. Commit.
2. Create environment `mut-spike-01` on the BC 28.1 profile. Install activation app and AUT dependencies. Deploy AUT and test app with the local-deploy ruleset. Record: environment creation time, deploy times, whether the test app compiles cleanly.
3. **Baseline + U2 + U7.** Run the full suite once: 181 test codeunits as sequential jobs, coverage on. Record per-codeunit duration, pass/fail, and the merged coverage file. Compute for each AUT codeunit the fraction of test methods that cover it; record the median. Also record the fixed cost of one single-method job. **Abort the plan if the suite does not pass 100 % on a fresh environment** until the owning team fixes it — a failing baseline makes every mutant result meaningless.
4. **U4 runner spike.** Deploy a stub Mutation Core (one table, one SingleInstance codeunit, two subscribers to `OnBeforeTestMethodRun` / `OnAfterTestMethodRun` that insert a marker row keyed by codeunit + function + outcome). Run one test codeunit containing one passing and one deliberately failing test. Confirm both markers exist afterwards, including for the failed test.
5. **U1 + U3.** Write a throwaway AL codeunit with ~500 `case true of Mut.Active(n): … else …` blocks. Compile, publish, time both. Run a tight loop calling one guarded block 100k times with and without the guard. Record numbers.
6. **Hand mutants (C3).** Pick 20 mutants by hand in the AUT (mix of relational, `and`↔`or`, statement deletion). For each: apply it in a scratch copy of the AUT, deploy, run only the test codeunits whose source references the mutated object (grep), record kill/survive and wall-clock. Revert.
7. **U5 + U6.** Start a test job that loops forever (stub codeunit) and try to stop it; time `env stop`/`env start`. Try the three publish-over-dependents options and record which one works and how long it takes.
8. Write `/docs/spike-baseline.md`: all numbers, backend used, go / no-go recommendation, and the sampling default (`--max-mutants`) implied by U7 and U2.

Acceptance: `/docs/spike-baseline.md` has every number above and a go / no-go. If ≥ 18/20 hand mutants die, propose scaling the project down to a periodic manual audit and stop. If U4 fails on DemoPortal, stop and redesign §5 before Phase 1.

## 3. Phase 1 — Mutation Core app (AL)

App id: new GUID. Publisher "Continia Software", name "Mutation Core", id range 50000–50199, object prefix `MUT`, runtime 17.0, platform/application 28.0.0.0, target Cloud. Dependencies: Microsoft "Test Runner" (23de40a6-dfe8-4f80-80db-d70f83ce8caf) for the event publishers, nothing else. **No dependency on the AUT (F10).**

Objects:
- `table MUT Mutation Setup` — single record: `Active Mutant Id` (Integer), `Current Run No.` (Integer).
- `table MUT Mutant` — `Id` (PK, Integer), `Stable Key` (Text 250, unique: hash of object, procedure, normalized snippet, operator, occurrence), `Object Type`, `Object Id`, `Procedure Name`, `Line No.`, `Operator` (Code 30), `Original Text` (Text 250), `Mutated Text` (Text 250), `Status` (Enum: Pending, Killed, Survived, Equivalent, Timeout, CompileError).
- `table MUT Mutation Run` — `Run No.` (PK), `Started`, `Finished`, `Commit`, `Backend` (Code 20), `Total`, `Killed`, `Survived`, `Score` (Decimal).
- `table MUT Mutant Result` — PK (`Run No.`, `Mutant Id`): `Status`, `Duration Ms`, `Killing Test` (Text 250).
- `codeunit MUT Mut` — `SingleInstance = true`. Global `ActiveId: Integer`. Procedures: `SetActive(Id)`, `Active(Id): Boolean` (pure comparison, no DB access), `Reset()`.
- `codeunit MUT Test Hooks` — event subscribers on codeunit 130450 "Test Runner - Mgt":
  - `OnBeforeTestMethodRun`: read `MUT Mutation Setup."Active Mutant Id"`, call `Mut.SetActive()`. (F5, F6, U4)
  - `OnAfterTestMethodRun`: if `IsSuccess = false` and no result yet for this mutant/run, write `MUT Mutant Result` with Status=Killed and `Killing Test = CodeunitName + ':' + FunctionName`. (F5)
- API pages (APIPublisher `mutation`, group `core`, v1.0): `mutants`, `mutationRuns`, `mutantResults`, `mutationSetup`. Setup page must support PATCH.

Rules:
- `Mut.Active()` must not touch the database. (U3)
- Nothing in Mutation Core may have a dependency on the AUT. (F10)
- Add a guard procedure `AssertNotProduction()` called on install: error unless the environment is a sandbox (`EnvironmentInformation.IsSandbox()`) or on-prem container.

### 3.1 Optional: custom TestRunner (Docker only, not v1)

If U7 shows per-job overhead dominates, a `SubType = TestRunner` codeunit that loops over pending mutants inside one session (set active → `Codeunit.Run` covering tests → record) removes the per-job cost. It only works on Docker (`-TestRunnerCodeunitId`). Open an issue after Phase 3; do not build in v1.

Acceptance:
- Compiles with no warnings under the local-deploy ruleset.
- Unit test: `SetActive(5); Active(5)=true; Active(6)=false; Reset(); Active(5)=false`.
- Running a trivial test app with one deliberately failing test through the standard runner writes exactly one `MUT Mutant Result` row with the correct `Killing Test`. Verified on DemoPortal; re-verified on Docker when that backend lands.

## 4. Phase 2 — Generator (TypeScript)

### 4.1 Tokenizer
- Input: `.al` file. Output: token stream with kind (identifier, keyword, string, comment, number, operator, punctuation), text, line, column.
- Must correctly skip `//` and `/* */` comments and `'...'` strings including `''` escapes. Golden tests in `/fixtures/tokenizer/`.
- Track procedure boundaries (`procedure`/`trigger` … `begin` … matching `end;`) and `begin…end` nesting depth. A statement-level AST is not needed; a statement boundary detector is (semicolon at depth, `then`/`else`/`do` keywords).

### 4.2 Operator catalog (v1)

Statement-level only. Every mutant must be expressible with one of the two guard shapes in 4.3.

| Operator | Original | Mutated | Guard shape |
|----------|----------|---------|-------------|
| REL | `>` `>=` `<` `<=` `=` `<>` in an `if`/`while`/`repeat…until` condition | swapped neighbour (`>`↔`>=`, `<`↔`<=`, `=`↔`<>`) | B |
| BOOL | `and` ↔ `or` in a condition | swapped | B |
| NOT | `not X` in a condition | `X` | B |
| COND | whole condition | `true` / `false` | B |
| DEL | statement `X.Insert(…)`, `X.Modify(…)`, `X.Delete(…)`, `X.Validate(…)`, `Error(…)`, `Commit()`, `exit(…)`, `Message(…)` | removed | A |
| INSFLAG | `Insert(true)`↔`Insert(false)`, same for `Modify`, `Delete` | flipped | A |
| GUARDCOLLAPSE | `if A then if B then S` (nested guard, no else) | `if A and B then S` | A over the outer `if`. Exposes shape-2 silent bugs (F1). |
| GUARDSPLIT | `if A and B then S` | `if A then if B then S` | A. Detects tests that depend on `B`'s side effects. |

Exclusions (hard-coded skip): anything inside `Evaluate(...)`, `SetRange`/`SetFilter` argument lists, `case` labels, field/property declarations, `var` sections, `#if` regions, test codeunits, `Obsolete Objects/` folder, and any line with a `// mutation:ignore` comment.

### 4.3 Guard shapes

**Shape A — statement replacement/deletion**
```al
if Mut.Active(<id>) then <mutated statement> else <original statement>;
```
For DEL, mutated statement is empty: `if not Mut.Active(<id>) then <original statement>;`

**Shape B — condition mutants (F1, F2, F4)**
All mutants on the same condition are grouped into one block. Introduce a local `MutCond_<n>: Boolean` in the procedure's `var` section.
```al
case true of
    Mut.Active(<id1>): MutCond_1 := <mutated cond 1>;
    Mut.Active(<id2>): MutCond_1 := <mutated cond 2>;
    else MutCond_1 := <original cond>;
end;
if MutCond_1 then ...
```
For `while` and `until` conditions, the `case` block goes inside the loop immediately before the condition is consumed; for `while` this means rewriting to `repeat … until not MutCond_n` is not allowed — instead use `while true do begin case…end; if not MutCond_n then break; …` only if the body has no `break` already; otherwise skip the mutant.

Never emit `Mut.Active(id) and …`, `Mut.Active(id) or …`, or pass a mutated expression as a procedure argument. (F1, F3)

`Mut` is referenced as `MutationCore: Codeunit "MUT Mut"` declared in each mutated procedure's `var` section (or once as a global per object).

### 4.4 Output
- Writes mutated copy of the AUT to `<out>/aut-schemata/` with `app.json` patched: same app id as the AUT, version per the U6 result (same or bumped build number), plus dependency on Mutation Core.
- Writes `mutants.json`: array of `{ id, stableKey, objectType, objectId, procedure, line, operator, original, mutated }`.
- Deterministic: same input → byte-identical output and ids. Golden tests in `/fixtures/generator/`.
- Flags `--max-mutants N` (random sample, seeded) and `--only-objects <ids>` for sampling. **Default `--max-mutants` is set from the U7/U2 numbers in `spike-baseline.md`.**

Acceptance:
- All golden tests pass.
- Generated schemata for the fixture app compiles with `alc.exe` (via `continia compile` or directly) with zero errors.
- A grep of the output for `Mut.Active(` followed by ` and ` or ` or ` returns nothing (lint step in CI).

## 5. Runner integration (both backends)

Neither backend is given a custom TestRunner (F7). Mutation Core's `MUT Test Hooks` subscribers (Phase 1) do the work under Microsoft's standard runner:

1. Orchestrator PATCHes `mutationSetup.activeMutantId` via API.
2. Orchestrator calls `Invoke-MutTests` for the mutant's covering targets.
3. Standard runner fires `OnBeforeTestMethodRun` → hooks set `Mut.SetActive(id)` before every method.
4. Standard runner fires `OnAfterTestMethodRun` → on failure, hooks write the `Killed` result with the killing test.
5. Orchestrator reads the normalized result; if failures exist but no result row was written (U4 fallback), it writes the result via API itself.

If U4 shows the subscriber writes are rolled back with a failed test, step 5 is the only writer and the hooks only set the active id.

## 6. Phase 3 — Orchestrator (PowerShell)

### 6.1 Backend interface

`orchestrator/backends/<Name>.psm1` exports exactly these functions. `Invoke-MutationRun.ps1` calls nothing backend-specific outside them.

| Function | Docker (BcContainerHelper) | DemoPortal (continia.exe) |
|----------|----------------------------|---------------------------|
| `New-MutEnvironment -Name -Config` → env handle | `New-BcContainer` with `mut-` name; refuse otherwise | `env create --name mut-… --profile`, poll to Running, install activation app, `deps install` for AUT; refuse if name lacks `mut-` |
| `Remove-MutEnvironment` | `Remove-BcContainer` | `env delete` (or `env stop` if `keepEnvironment`) |
| `Publish-MutApp -Path/-AppFile [-SyncMode]` | `Publish-BcContainerApp -Install -Sync` | `continia publish` / `continia deploy --allow-downgrade --ruleset <local-deploy>` |
| `Unpublish-MutApp -AppId [-Version]` | `UnPublish-BcContainerApp` | `continia unpublish --app-id` |
| `Compile-MutApp -Path -Out -Ruleset` → diagnostics[] | shared: `alc.exe` with symbols from `Download-BcContainerSymbols` | shared `alc.exe` via `continia compile --json`; parse `diagnostics[]` |
| `Invoke-MutTests -Targets @([pscustomobject]@{CodeunitId; Function}) -TimeoutSec -Coverage` → `{ passed, failed, tests[] {codeunit, function, result, durationMs, error}, durationMs, jobIds[] }` | one `Run-TestsInBcContainer` call, `-XUnitResultFileName`, `-CodeCoverageTrackingType` | one `test run --json` per distinct codeunit, sequential; merge |
| `Get-MutCoverage -RunHandle` → `[{objectType, objectId, lineNo, hits}]` | export table 2000000049 / coverage output path | `test coverage <jobId>` per job, merge CSVs |
| `Reset-MutEnvironment` (timeout recovery) | restart service tier in container | `env stop` + `env start`, poll; record duration |
| `Invoke-MutApi -Method -Path -Body` | `http://<container>:7048/BC/api/mutation/core/v1.0/…` with container credentials | `<env url>/api/mutation/core/v1.0/…` with `env users` credentials |

### 6.2 `mutation.config.json`

```json
{
  "backend": "DemoPortal" | "Docker",
  "environmentName": "mut-nightly",
  "keepEnvironment": false,
  "aut": { "path": "…/base-application", "appId": "83461f48-…", "ruleset": "…/.cli-ruleset-localdeploy.json" },
  "testApp": { "path": "…/base-application-test", "appId": "02b81fad-…" },
  "coreApp": { "path": "./core-app" },
  "generator": { "maxMutants": 0, "onlyObjects": [], "seed": 1 },
  "timeouts": { "perTestFactor": 5, "minSeconds": 60 },
  "docker": { "artifactUrl": "…", "licenseFile": "…" },
  "demoPortal": { "profileId": "…", "bcVersion": "28.1.0.0" }
}
```

### 6.3 Steps

Steps, in order. Each step is a function; the script is idempotent per run number.

1. `New-MutEnvironment` — fresh environment via the backend. Refuse if name does not match `^mut-`. Refuse shared DemoPortal environments.
2. `Publish-Baseline` — publish Mutation Core, original AUT, test app. Run full suite (`Invoke-MutTests` over all test codeunits, coverage on). Abort if any failure. `Get-MutCoverage` → `coverage.json`. (F8)
3. `Build-Schemata` — call generator; `Compile-MutApp`. On compile error: parse `diagnostics[]` line → map to mutant id → mark `CompileError` in manifest → remove that mutant → recompile. Cap at 10 iterations, then fail loudly.
4. `Publish-Schemata` — replace the original AUT with the schemata AUT per the U6 recipe. Rerun full suite with no mutant active. Abort if any failure (schemata must be behaviour-preserving when inactive).
5. `Push-Manifest` — POST `mutants.json` to `/api/mutation/core/v1.0/mutants`. Skip stable keys listed in `equivalent.json` (Phase 4).
6. `Get-CoveringTests` — for each mutant, intersect its `(objectId, line)` with `coverage.json` → list of test codeunit/function pairs. Mutants with no covering test are marked `Survived` with `Killing Test = '<uncovered>'` without running.
7. `Invoke-Mutant` (loop) — for each Pending mutant:
   - PATCH setup `Active Mutant Id`.
   - `Invoke-MutTests` for the covering targets wrapped in a `Start-Job` with wall-clock timeout (default `perTestFactor` × the baseline duration of those tests, min `minSeconds`). (F9)
   - On timeout: `Stop-Job`, `Reset-MutEnvironment`, mark `Timeout`.
   - Read the normalized result; if any failure and no `Mutant Result` written by the hooks, write it via API.
   - If all pass, write `Survived`.
8. `Export-Results` — GET all `mutantResults` for the run → `results/<run>.json` (includes backend name); compute score; write `summary.md`; publish both as pipeline artifacts. **The environment is disposable; the artifact is the record.**

### 6.4 Backend delivery order

DemoPortal first (configured today). Docker second, after Docker Desktop is switched to Windows containers. Phase 3 acceptance runs on DemoPortal first; the Docker acceptance run is a separate commit and may land after Phase 4.

Acceptance:
- End-to-end run on the fixture app produces `results/<run>.json` with the expected kill/survive pattern from `/fixtures/expected-results.json`, on DemoPortal. Same result on Docker when that backend lands.
- Deliberately inject an infinite-loop mutant into a fixture; confirm it is recorded as `Timeout` and the run continues.
- Inject a compile-breaking mutant; confirm it is dropped and the run continues.
- `Invoke-MutationRun.ps1` contains no reference to `continia`, `BcContainerHelper`, or `docker` outside `backends/`.

## 7. Phase 4 — Triage

- Page `MUT Mutant Survivors` in Mutation Core: filter Status=Survived, show original/mutated text, action `Mark Equivalent` (writes `Equivalent`, persists into the exported artifact via `stableKey` so it survives environment recreation).
- Orchestrator reads `equivalent.json` from the repo at step 5 and skips those stable keys.
- Optional `Suggest-Test` script: for each survivor, send object snippet + mutant + covering tests to the Claude API and ask for one test that would kill it or a one-line reason it is equivalent. Output to `survivors-triage.md`. Never auto-commit generated tests.

## 8. Phase 5 — Incremental runs

- Cache `results/<commit>.json`. On the next run, a mutant with the same `stableKey` whose object's source hash and covering tests' source hashes are unchanged inherits its previous result.
- Measure how many mutants actually inherit on a real week of commits before promising this to anyone.

## 9. Guardrails for Claude Code

- Do not invent AL syntax. If a construct is not in `learn.microsoft.com/…/dev-itpro/developer/`, do not emit it.
- Never emit a mutated expression on the right of `and`/`or`/`xor` or as a procedure argument (F1, F3). CI greps for this.
- Never publish to a container or DemoPortal environment whose name/description does not start with `mut-`. Never target a shared DemoPortal environment.
- Never edit files in the real AUT repo; the generator writes to `<out>/` only. Phase 0 hand mutants are applied in a scratch copy.
- Never store history only in BC tables; every run exports to `results/`.
- No backend-specific calls outside `orchestrator/backends/`.
- Do not add expression-level mutants (arithmetic in assignments/arguments) to v1. Open an issue instead.
- Do not build the custom TestRunner (§3.1) in v1. Open an issue instead.
- Treat the mutation score as a diagnostic. Do not wire it into a gate until survivors have been triaged for at least three runs.

## 10. Definition of done (v1)

- One AUT, nightly or weekly pipeline on the DemoPortal backend, produces `summary.md` with score, survivor list, timeouts, compile-errors, wall-clock time, and backend name.
- Docker backend passes the same fixture-app acceptance run.
- Zero false kills: a run with no mutant active passes the full suite (§6.3 step 4).
- Spike numbers (U1–U7) recorded and reflected in the operator catalog and sampling defaults.
