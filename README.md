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
