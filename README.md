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
`demoPortal.profileId`, and review `generator.onlyObjects` — it silently scopes a run to codeunit 72918635,
so a second user would get 157 mutants with no signal that the other 450 codeunits were excluded by config.

Known hazard: `demoPortal.settleProbe` points at the AUT's own test codeunit 95155, which does not exist
until the AUT is deployed — on a brand-new environment this fails after ~10 minutes of probing. See
`docs/issues.md`.

## Toolchain

| Tool | Version |
|---|---|
| `continia.exe` | 0.24.0 (`.tools/continia.exe`) |
| Node | 22.19 |
| npm | 11.10 |
| PowerShell | Windows PowerShell 5.1 |
| Pester | 5.9.1 (installed per user with `-MaximumVersion 5.99`; import with `Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99`; the preinstalled 3.4.0 is too old) |
