# al-mutation Linux port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run every orchestrator script under PowerShell 7 on Ubuntu 24.04 (the mutant-fixer container), with Windows PowerShell 5.1 still working. Add configurable work, results and CLI paths, a DemoPortal profile derived from `app.json`, and two environment-cleanup scripts.

**Architecture:** Platform differences live in a small number of helpers in `lib/Config.psm1` (`Test-MutIsWindows`, `Get-MutPathComparison`, `Get-MutResultsDir`, `Write-MutTextFile`). Other modules call these helpers and do not branch on the OS themselves. Environment-variable overrides (`MUT_WORK_DIR`, `MUT_RESULTS_DIR`, `MUT_CLI_PATH`) are applied once, in `Get-MutConfig` and `Get-MutResultsDir`. New DemoPortal calls go into `backends/DemoPortal.psm1`. Entry scripts never name the CLI (§4 item 6).

**Tech Stack:** Windows PowerShell 5.1 and pwsh 7.4, Pester 5.x, continia CLI (`continia.exe` / `continia-linux`).

**Spec:** `C:\GeneralDev\DevOpsPullers\mutant-fixer\docs\handover\al-mutation-headless.md`, tasks 7–11. Background: mutant-fixer `docs/superpowers/specs/2026-10-02-vm-deployment-design.md`. Exploration showed that tasks 1–6 are already met on `main` (external config, negative verify run number, exit codes, stable output files, `EnvLock.psm1`, headless skill sections). This plan does not redo them; Task 9 documents them.

## Global Constraints
- 5.1-compatible syntax only: no `?:`, `??`, `?.`, `&&`/`||`, `ForEach-Object -Parallel`. Feature-test .NET APIs (`ResolveLinkTarget`, `$IsWindows`) before calling them.
- The Windows run keeps working: the Pester suite stays green under `powershell` 5.1 on Windows after every task.
- Under pwsh 7 in WSL Ubuntu the suite turns green during this plan. A Windows-only test is skipped with `-Skip:(-not (Test-MutIsWindows))` and gets a Linux counterpart where the behaviour exists on Linux.
- Never rename `results/<N>-fixes.json`, `-fixes.md`, `-verified.json`, `-tests.patch` or their fields.
- Environment names must match `^mut-`; never touch a `Shared` environment.
- Env var names exactly: `MUT_WORK_DIR`, `MUT_RESULTS_DIR`, `MUT_CLI_PATH`.

## Review Focus
1. `MUT_RESULTS_DIR` set: every reader and writer (run, briefs, report check, verify, delivery, skills) uses the same dir. A missed site makes the next step fail with "file not found".
2. Paths that differ only in case on Linux: the workDir-in-sources check and the fix target file match must not treat `Foo.al` and `foo.al` as the same file.
3. pwsh 7 web errors (`HttpResponseException`, `HttpRequestException`, `TaskCanceledException`) classify as outage, timeout or HTTP status in the same way 5.1 `WebException` does. Otherwise the outage retry logic aborts runs on Linux.
4. 5.1 reading a BOM-less UTF-8 file without `-Encoding` decodes it as ANSI. Non-ASCII AL names (æ, ø, å) must survive a round trip.
5. `Remove-MutOrphanEnvironments` with an empty or non-`mut-` prefix, or a prefix that matches a `Shared` environment, deletes nothing.

---

### Task 0: Branch, baseline, Linux test environment
- [ ] `git switch -c linux-port` in `C:\GeneralDev\AL\al-mutation`.
- [ ] Windows baseline: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99; Invoke-Pester orchestrator/tests -Output Normal"`. Expected: all pass. Record the counts.
- [ ] WSL Ubuntu: install `powershell` (Microsoft apt repo for 24.04), Pester 5.x (`Install-Module Pester -MaximumVersion 5.99 -Scope CurrentUser`), plus `git` and `nodejs` if missing.
- [ ] Linux baseline: `wsl -d Ubuntu -- pwsh -NoProfile -Command "cd /mnt/c/GeneralDev/AL/al-mutation; Import-Module Pester -MaximumVersion 5.99; Invoke-Pester orchestrator/tests -Output Normal"`. Expected: failures. Save the list to the workspace; it is the worklist for Tasks 1–6.
- [ ] Add `orchestrator/tests/Invoke-Tests.ps1` (runs Pester 5 on the current host) so both runs use one command.

### Task 1: Platform helpers and portable tests
**Files:** `lib/Config.psm1`, `tests/Config.Tests.ps1`, test files that spawn shells (`EnvLock.Tests.ps1`, `EnvLock.Scripts.Tests.ps1`, `FixBriefs.Tests.ps1`, `DemoPortal.Environment.Tests.ps1`, `DemoPortal.Tests.Tests.ps1`), `Isolation.Tests.ps1`, `FixVerify.Tests.ps1`, `Run.Tests.ps1`.
- [ ] Tests first: `Test-MutIsWindows` (matches `[Environment]::OSVersion.Platform -eq 'Win32NT'`), `Get-MutPathComparison` (`OrdinalIgnoreCase` on Windows, `Ordinal` elsewhere), and `Get-MutShellPath` (`(Get-Process -Id $PID).Path`, the host running now). Run them and watch them fail.
- [ ] Implement the three helpers and export them.
- [ ] Test plumbing:
  - Replace `powershell`/`powershell.exe` child processes and the `cmd.exe /c` fake CLIs with `Get-MutShellPath` running a fake-CLI `.ps1` in `TestDrive:`.
  - Replace `$env:TEMP` with `TestDrive:`.
  - Build the backslash test paths with `Join-Path`.
  - Make `Run.Tests.ps1:249` compare with `Join-Path 'results' '1.json'`.
  - Mark junction, drive-root, `$env:WINDIR` and `X:\` data tests `-Skip:(-not (Test-MutIsWindows))`.
- [ ] Windows suite green. Commit `test: portable test plumbing and platform helpers`.

### Task 2: Paths
**Files:** `lib/Config.psm1` (`Resolve-MutFinalPath` :233-272, workDir check :301-324), `lib/FixVerify.psm1` (:60, :87, :140, :563, :689-693, :868), `lib/FixBriefs.psm1:208`, `lib/Schemata.psm1:5`, `lib/Run.psm1:1066`, `backends/DemoPortal.psm1:5,9`.
- [ ] Failing tests, written first:
  - `Resolve-MutFinalPath '/'` returns `/`.
  - On Linux a symlinked dir resolves to its target. The test creates the link with `New-Item -ItemType SymbolicLink` and is skipped on Windows when the process lacks symlink rights.
  - On Linux, a workDir under `aut.sourcePath` with different case is not treated as inside it.
  - On Linux, the FixVerify target-file match is case-sensitive.
  - `FixVerify` file mapping (:140) produces a path that `Test-Path` finds on both platforms.
- [ ] Implement:
  - Use the P/Invoke only when `Test-MutIsWindows`. Otherwise use `[IO.Directory]::ResolveLinkTarget($p,$true)` / `[IO.File]::...` per path segment when the method exists, with the literal path as the fallback.
  - `TrimEnd` must keep the root.
  - Comparisons use `Get-MutPathComparison`.
  - `-replace '/', '\'` becomes `[IO.Path]::DirectorySeparatorChar`.
  - Backslash literals in `Join-Path` become `/`.
- [ ] Both suites: the tests touched here pass. Commit `fix: portable path resolution and comparisons`.

### Task 3: AUT copy without robocopy, and child-process cleanup
**Files:** `lib/AutCopy.psm1:40-52`, `backends/DemoPortal.psm1:1650-1670`, `tests/AutCopy.Tests.ps1`, `tests/DemoPortal.Environment.Tests.ps1`.
- [ ] Failing tests, written first, against a new function `Copy-MutMirror -Source -Destination -ExcludeName @('.git')`:
  - It mirrors files and subdirectories.
  - It deletes destination files that are not in the source.
  - It excludes `.git` as both a file and a directory.
  - It keeps non-ASCII file names.
  - It throws on a missing source.
  - These tests run on both platforms.
- [ ] Implement `Copy-MutMirror` in pure PowerShell (`Get-ChildItem -Force -Recurse`, `Copy-Item`, deleting extra files). `Sync-MutAutCopy` uses robocopy on Windows (unchanged) and `Copy-MutMirror` elsewhere. Robocopy tests are Windows-only.
- [ ] `Stop-MutBackendChildProcesses`:
  - On Windows, keep CIM. The process name is derived from the leaf of `$script:CliPath`.
  - On Linux, read `/proc/<pid>/stat` field 4 (`ppid`) for every numeric `/proc` entry and match on `$PID`.
  - The CIM mock tests become Windows-only. Add a Linux test that starts a real child (`sleep 60` via `Start-Process`) and checks that it gets stopped.
- [ ] Both suites: the tests touched here pass. Commit `fix: portable AUT mirror and backend child cleanup`.

### Task 4: pwsh 7 web failures
**Files:** `backends/DemoPortal.psm1` (`Get-MutWebFailure` :1732-1771, :1843-1885), `tests/DemoPortal.Soap.Tests.ps1` (or the file that holds the `Get-MutWebFailure` tests).
- [ ] Failing tests that build pwsh 7 exceptions:
  - `Microsoft.PowerShell.Commands.HttpResponseException` with status 503, 401 and 500
  - `System.Net.Http.HttpRequestException` (connect refused, DNS)
  - `System.Threading.Tasks.TaskCanceledException` (timeout)

  Each must map to the same classification as its 5.1 `WebException` twin. Mark them `-Skip:($PSVersionTable.PSVersion.Major -lt 6)`, because those types don't exist in 5.1.
- [ ] Implement a type check by full name (`$ex.GetType().FullName`), so that 5.1 does not need the types to load. Walk `InnerException`. Read the status from `$ex.Response.StatusCode`.
- [ ] Linux suite: these tests pass; the 5.1 tests still pass on Windows. Commit `fix: classify pwsh 7 web errors like 5.1 WebException`.

### Task 5: Encoding
**Files:** `lib/Config.psm1` (new `Write-MutTextFile`, `Read-MutTextFile`), every `Get-Content -Raw` and `Set-Content -Encoding UTF8` site listed in the audit (Config, FixBriefs, FixVerify, References, Results, MutantLoop, Run, Schemata).
- [ ] Failing tests, written first:
  - A string with `æøå` written by `Write-MutTextFile` reads back identical through `Read-MutTextFile`, on both hosts.
  - The written file has no BOM.
  - `Read-MutTextFile` reads a file that has a BOM (written by older runs) without a leading `U+FEFF`.
- [ ] Implement. `Write-MutTextFile` uses `[IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding $false))`. `Read-MutTextFile` uses `[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)`, which strips the BOM. Replace the listed reads and writes. Line endings stay as they are today.
- [ ] Both suites green: the full suite, not just this task's tests. Commit `fix: explicit UTF-8 reads and BOM-less writes`.

### Task 6: `MUT_WORK_DIR`, `MUT_RESULTS_DIR`, `MUT_CLI_PATH`
**Files:** `lib/Config.psm1` (`Get-MutConfig`, new `Get-MutResultsDir`), `lib/Run.psm1:252,997`, `lib/FixBriefs.psm1:227,262,362-365`, `lib/FixVerify.psm1:565-572,877-887`, `orchestrator/Test-MutFixReport.ps1:21-23`, `orchestrator/Invoke-MutFixVerify.ps1:79`, both SKILL.md files, `tests/Config.Tests.ps1`, `tests/Run.Tests.ps1`, `tests/FixBriefs.Tests.ps1`, `tests/FixVerify.Tests.ps1`.
- [ ] Failing tests, written first:
  - `MUT_WORK_DIR` set replaces `workDir`, and the outside-sources check sees the override.
  - `MUT_CLI_PATH` set replaces `demoPortal.cliPath`.
  - `Get-MutResultsDir` returns `MUT_RESULTS_DIR` when set and `<repo>/results` otherwise.
  - The run, briefs, report check, verify and delivery steps all write to and read from `MUT_RESULTS_DIR` when it is set.
  - The `Export-MutFixDelivery` raw-JSON fallback also applies `MUT_WORK_DIR`.
  - Each test sets the variables in `BeforeEach` and clears them in `AfterEach`.
- [ ] Implement. Relative env values resolve against the repo root, the same as config paths.
- [ ] Update both skills:
  - Results dir = `$env:MUT_RESULTS_DIR` when set, else `results/`.
  - Commands use `pwsh` on Linux and `powershell` on Windows.
  - Keep the headless sections.
- [ ] Both suites green. Commit `feat: MUT_WORK_DIR, MUT_RESULTS_DIR and MUT_CLI_PATH overrides`.

### Task 7: Profile from `app.json`
**Files:** `lib/Config.psm1` (`demoPortal.profileId` optional, new optional `demoPortal.localization`, default `base`), `backends/DemoPortal.psm1` (new `Resolve-MutProfileId`, used by `New-MutEnvironment`), `mutation.config.json`, `tests/Config.Tests.ps1`, `tests/DemoPortal.Environment.Tests.ps1`.
- [ ] Failing tests, written first, against the fake CLI:
  - The required version is the maximum of `application` and `platform` over the `app.json` files under `aut.sourcePath` and `testApp.sourcePath`.
  - `env profiles versions --json` (an array or `{versions:[]}`) picks the lowest version ≥ required.
  - `env profiles list --bc-version <v> --json` (an array or `{profiles:[]}`) is filtered on `isEnabled -ne $false` and on localization (case-insensitive), and the lowest `id` wins.
  - It throws when no version ≥ required exists, or when no localization matches.
  - A set `profileId` skips all of this.
  - It throws when no `app.json` declares a version and no `profileId` is set.
- [ ] Implement, following DevOpsCoder `src/pipeline/stages/env-provision.ts:29-131` and `src/utils/bc-version.ts:63-76`.
- [ ] Remove `profileId` from `mutation.config.json`, which mutant-fixer uses as its template on the VM. The fixture configs keep their pinned profile.
- [ ] Both suites green. Commit `feat: derive DemoPortal profile from app.json`.

### Task 8: Environment cleanup scripts
**Files:** `backends/DemoPortal.psm1` (new `Get-MutEnvironments -Prefix`, new `Remove-MutEnvironment -Force` path that deletes even when `keepEnvironment` is set), new `orchestrator/Remove-MutRunEnvironment.ps1`, new `orchestrator/Remove-MutOrphanEnvironments.ps1`, new `tests/RemoveEnvironments.Scripts.Tests.ps1`.
- [ ] Failing tests, written first, against the fake CLI:
  - **`Remove-MutRunEnvironment.ps1 -ConfigPath <cfg>`:**
    - deletes the config's environment and exits 0
    - exits 0 when the environment is already gone
    - refuses a `Shared` environment or a non-`^mut-` name, with a non-zero exit
  - **`Remove-MutOrphanEnvironments.ps1 -Prefix mut-pr- [-Keep <name>] [-ConfigPath <cfg>]`:**
    - deletes every non-shared environment whose name starts with the prefix, except `-Keep`
    - prints one line per deleted environment
    - refuses a prefix that does not start with `mut-` (non-zero exit)
    - exits non-zero only when listing fails, so a single failed delete is printed and skipped
  - `-ConfigPath` defaults to `<repo>/mutation.config.json`; it is used only for the CLI path, and `MUT_CLI_PATH` overrides it.
- [ ] Implement. Both scripts load the backend from config like `Invoke-MutationRun.ps1` does. Neither script names the CLI.
- [ ] Both suites green. Commit `feat: Remove-MutRunEnvironment and Remove-MutOrphanEnvironments`.

### Task 9: Docs and the mutant-fixer side
- [ ] Add to the al-mutation `README.md`:
  - an "Exit codes" section (from the audit: 0 = success, including survivors; non-zero = failure or abort)
  - a "Linux / container" section: pwsh 7, `MUT_*` variables, `continia-linux` through `MUT_CLI_PATH`, profile derivation, cleanup scripts
  - the patch root (`a/`/`b/` relative to the test-app root, `git apply -p1`)
- [ ] Add a short SPEC §6.9 note for the env overrides and the cleanup scripts.
- [ ] mutant-fixer, in its own commit there:
  - `compose.snippet.yml`: add `MUT_CLI_PATH: /usr/local/bin/continia`, and remove the "names come from the Linux port" comment.
  - `docs/handover/al-mutation-headless.md`: mark tasks 1–11 done with the final names.
  - `docs/vm-bringup.md`: drop the pinned-profile step if one exists.
- [ ] Commit `docs: exit codes, Linux usage, cleanup scripts`.

### Task 10: Linux smoke checks (WSL)
- [ ] With `MUT_*` set to temp dirs, and a config in `/tmp` whose sources point at a `git worktree` of the Banking clone under `/mnt/c`, run `Get-MutConfig` and `Export-MutFixBriefs.ps1 -RunNo <an existing run copied into MUT_RESULTS_DIR>` under pwsh on Linux. Expected: exit 0, briefs written to `MUT_RESULTS_DIR`.
- [ ] `Test-MutFixReport.ps1` on the same run, under Linux. Expected: `ok`.
- [ ] If `continia-linux` and a `CONTINIA_API_TOKEN` are available in WSL: `Remove-MutOrphanEnvironments.ps1 -Prefix mut-pr-zzz-` (matches nothing). Expected: exit 0, no output. A full `Invoke-MutationRun -RunNo 1000` on Linux waits for VM bring-up (runbook phase G).

## Verification
- Both suites green: Windows 5.1 `orchestrator/tests/Invoke-Tests.ps1` and WSL pwsh 7 `orchestrator/tests/Invoke-Tests.ps1`.
- Task 10 smoke checks pass.
- Final whole-branch review, then merge `linux-port` into `main` only after the user agrees.
