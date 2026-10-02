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

## Toolchain

| Tool | Version |
|---|---|
| `continia.exe` | 0.24.0 (`.tools/continia.exe`) |
| Node | 22.19 |
| npm | 11.10 |
| PowerShell | Windows PowerShell 5.1 |
| Pester | 5.9.1 (installed per user with `-MaximumVersion 5.99`; import with `Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99`; the preinstalled 3.4.0 is too old) |

## Headless use

Another program can call al-mutation with no human in the loop. The call sequence is in
[`docs/SPEC.md`](docs/SPEC.md) §6.9.1. Every call runs with the repository root as working directory, and the config
file may live anywhere.

The two skills run unattended when the prompt contains `HEADLESS RUN`. The prompt must also contain the line
`Config file: <cfg>`. `mutation-fix-verify` also gets the fix ids to verify. The skills never ask questions in this
mode (SPEC §6.9.6).

`Invoke-MutationRun.ps1` and `Invoke-MutFixVerify.ps1` hold the lock file `<workDir>/.environment.lock` while they
run. The lock is an open file handle, so Windows deletes the file when the holder ends, even when it is killed. A
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
