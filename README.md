# al-mutation

Mutation testing for Business Central AL apps. This project mechanically generates mutants for one
App Under Test (the Continia Banking base application), compiles them all into a single "schemata"
build guarded by `MutationCore.Active(<id>)`, and runs the covering tests once per mutant to produce
a mutation score and a survivor list. It is proven end to end on a small fixture app (Tier A) and a
one-codeunit slice of the real AUT (Tier B) — codeunit 72918635, exercised by test codeunits
95155/95179/95191 — before any full run.

## Start here

- [`docs/SPEC.md`](docs/SPEC.md) — the source of truth for this project.
- [`docs/tasks.json`](docs/tasks.json) — the task decomposition of the spec.

## Configuration

`mutation.config.json` records the **pilot** configuration, not a general default. Before any other run,
replace the absolute `sourcePath` values, `environmentName` (`mut-spike-02` is one person's sandbox) and
`demoPortal.profileId`, and review `generator.onlyObjects`.

Any `path`/`sourcePath` may use `%VAR%` environment-variable references, so a config need not hard-code one
person's drive layout:

```json
"aut": { "sourcePath": "%AUT_ROOT%/base-application", "appId": "...", "version": "29.0.0.0" }
```

A referenced variable that is not set fails at config load, naming the variable, rather than surfacing much
later as a confusing "path not found".

`generator.onlyObjects` no longer scopes a run silently: `Get-MutConfig` warns at load time with the count and
the object ids, because a score means nothing without the scope it was computed over. Set it to `[]` to run
the whole AUT.

`demoPortal.settleProbe` targets Mutation Core's own test app (codeunit 50400 / `HookErrorIsEmpty`), published
by `coreAppTest` in pipeline step 3 immediately after Mutation Core and before the AUT. That target depends
only on Mutation Core, so it survives the AUT test app being unpublished and republished around the schemata
swap, and it does not move when the AUT's own test suite changes. It previously pointed at the AUT's test
codeunit 95155, which does not exist until the AUT is deployed — see `docs/issues.md` for the residual case
(a first-ever run on a brand-new environment still probes before step 3, so that one check stays non-fatal).

`testTransport` picks how the per-mutant loop runs tests. `"cli"` is the default when the key is missing, but every
shipped config (and so mutant-fixer, which uses `mutation.config.json` as its template) sets `"soap"`. `"cli"` runs
one `continia test run` job per mutant; `"soap"` runs batches of mutants through Mutation Core's `MUTRunner` SOAP service (SPEC
§6.10). Test time inside the runner is about 0.2-1.0 s per mutant; the loop's wall clock is
about 2 s per mutant in runs 16/17, against about 14 s per mutant end to end for the CLI run 15. `soap.batchSize` (a positive integer, default 50)
caps the mutants per SOAP call. `"soap"` needs Mutation Core 1.1.1.0 or later on the environment (the configs'
`coreApp.version`, published in pipeline step 3); the run checks that the service answers and stops if it does
not. Only the mutant loop moves to SOAP;
the baseline, coverage, the settle probe and fix verification still use the CLI.

`baseline.repeats` (a positive integer, default 3, set explicitly in every shipped config) is the number of
baseline passes (SPEC §6.11.2). Pass 1 is the coverage run; passes 2 and later run the tests again without
coverage. A test that fails in every pass aborts the run, as before. A test that fails in some passes only is
**flaky**: it is warned about and listed in `baseline.json` (`repeats`, `flakyTests`) and in the summary's
"Flaky baseline tests" table. `1` turns the repeats off and gives the old single baseline. Each `Killed` row in
`results/<RunNo>.json` carries a `reason`, the first line of the killing test's error message. When a mutant
is killed only by flaky tests, the row is `unreliable: true` and the killing test is the first failing test that
is not flaky when there is one (SPEC §6.11.3). `score` is unchanged. `strictScore` counts those unreliable kills
as survived, `totals.unreliableKills` counts them, and the summary lists them in an "Unreliable kills" table. With
`baseline.repeats` 1 there are no flaky tests, so `strictScore` equals `score`.

## Toolchain

| Tool | Version |
|---|---|
| `continia.exe` | 0.24.0 (`.tools/continia.exe`) |
| Node | 22.19 |
| npm | 11.10 |
| PowerShell | Windows PowerShell 5.1; PowerShell 7.4 on Linux |
| Pester | 5.9.1 (installed per user with `-MaximumVersion 5.99`; import with `Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99`; the preinstalled 3.4.0 is too old) |

## Headless use

Another program can call al-mutation with no human in the loop. The call sequence is in
[`docs/SPEC.md`](docs/SPEC.md) §6.9.1. Every call runs with the repository root as working directory, and the config
file may live anywhere.

The skills run unattended when the prompt contains `HEADLESS RUN`. The prompt must also contain the line
`Config file: <cfg>`. `mutation-fix-verify` also gets the fix ids to verify, and `mutation-fix-repair` the fix ids to
repair (it only edits `fixes.json` and never touches the environment; the caller re-verifies). The skills never ask questions in this
mode (SPEC §6.9.6).

`Invoke-MutationRun.ps1` and `Invoke-MutFixVerify.ps1` hold the lock file `<workDir>/.environment.lock` while they
run. The lock is an open file handle, so Windows deletes the file when the holder ends, even when it is killed (Linux leaves it; see below). A
second script on the same work directory fails with `environment locked by ...`. A leftover file that nobody holds is
replaced with a warning. Every config for one environment must use the same `workDir`.

`Invoke-MutFixVerify.ps1` writes its rows under run number `-N`, so it cannot collide with a real run. Run numbers are
any positive integer.

`results/<N>-tests.patch` holds paths relative to the test-app root (`a/<file>`, `b/<file>`). Apply it with
`git apply -p1 <patch>` in the test-app folder, or with `git apply -p1 --directory=<test-app folder> <patch>` from the
root of the repository that contains it.

### Exit codes

| Script | 0 | 1 |
|---|---|---|
| `Invoke-MutationRun.ps1` | Run completed, with or without survivors | Config, environment or pipeline error; aborted run; lock held |
| `Export-MutFixBriefs.ps1` | Briefs written | Any error |
| `Test-MutFixReport.ps1` | Prints `ok` | Validation errors or any other error |
| `Invoke-MutFixVerify.ps1` | Verify completed, whatever the verdicts | Config or environment error; restore failure; lock held |
| `Remove-MutRunEnvironment.ps1` | Environment deleted, or already gone | Refused (`^mut-` name, Shared) or any error |
| `Remove-MutOrphanEnvironments.ps1` | Sweep ran (a failed single delete is only a warning) | Prefix refused or environments could not be listed |

### Environment cleanup

A caller that creates one environment per job (mutant-fixer: `mut-pr-<prId>-<sha7>` with `keepEnvironment: true`)
removes it with `Remove-MutRunEnvironment.ps1 -ConfigPath <cfg>`, which deletes the config's environment even though
`keepEnvironment` is set. `Remove-MutOrphanEnvironments.ps1 -Prefix mut-pr- [-Keep <name>] [-ConfigPath <cfg>]`
deletes every non-Shared environment whose name starts with the prefix. The prefix must start with `mut-` and be
longer than it, so a sweep never reaches the `mut-spike-*` environments. `-ConfigPath` only supplies the backend and
CLI path and defaults to `mutation.config.json`.

### DemoPortal profile

`demoPortal.profileId` is optional. Without it, the environment is created on the profile that fits the apps: the
highest `application`/`platform` version in the `app.json` files under `aut.sourcePath` and `testApp.sourcePath`, the
lowest published profile version at least that high, and the enabled profile of that version in
`demoPortal.localization` (default `base`) with the lowest id. Set `profileId` only to pin a profile on purpose.

## Linux and containers

Every orchestrator script runs under PowerShell 7 on Linux (`pwsh -NoProfile -File orchestrator/<script>.ps1`) as well
as under Windows PowerShell 5.1. Three environment variables move what a container must keep outside the repo folder:

| Variable | Replaces | Example (mutant-fixer image) |
|---|---|---|
| `MUT_WORK_DIR` | config `workDir` | `/data/al-mutation/out` |
| `MUT_RESULTS_DIR` | `<repo>/results` for every `results/<N>*` file | `/data/al-mutation/results` |
| `MUT_CLI_PATH` | config `demoPortal.cliPath` | `/usr/local/bin/continia` (the `continia-linux` build) |

Relative values resolve against the repo root. On Linux the AUT copy uses `rsync` instead of robocopy (install it: the built-in
PowerShell fallback copies one file at a time and takes minutes for a full app). The CLI's `compile` and `deploy`
get `--workspace-root` set to the app folder's parent, because the CLI only accepts app paths under it. And
a killed lock holder leaves its lock file behind; the next script replaces it with a warning. The tests run on both
hosts: `powershell -NoProfile -File orchestrator/tests/Invoke-Tests.ps1` and
`pwsh -NoProfile -File orchestrator/tests/Invoke-Tests.ps1` (Pester 5).
