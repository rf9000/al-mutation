Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Backend-agnostic: no CLI or container-tool names in this module (see spec §4 item 6). This
# module never imports a backend module itself -- Invoke-MutApi and Reset-MutEnvironment are
# called as plain command names, resolved at runtime against whatever backend module the
# caller (Invoke-MutationRun.ps1, or a test) has already imported into the session (§6.5.6).
# The one genuine internal dependency is Coverage.psm1 (also backend-agnostic), for
# Get-MutCoveringTests.
Import-Module (Join-Path $PSScriptRoot 'Coverage.psm1') -Force

# Invoke-MutApi and Reset-MutEnvironment are backend interface functions (§6.5.3) this module
# calls unqualified and expects the caller to have already brought into the session by
# importing a backend module (§6.5.6: "the caller imports the backend module first"). If
# nothing has defined them yet (e.g. this module loaded first, or a unit test importing only
# MutantLoop.psm1), a placeholder matching the real §6.5.3 signature is registered here purely
# so the command exists for Pester's `Mock -ModuleName MutantLoop` to attach to -- Mock cannot
# create a mock for a command with no existing definition anywhere in the session, and without
# a matching parameter set the mock body would never see named values for $Method/$Path/$Body.
# Importing a real backend module (before or after this one) always wins: Import-Module
# overwrites an existing same-named function in the global function table.
if (-not (Get-Command -Name 'Invoke-MutApi' -ErrorAction SilentlyContinue)) {
    function global:Invoke-MutApi {
        param($Env, [string]$Method, [string]$Path, $Body)
        throw 'Invoke-MutApi: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Reset-MutEnvironment' -ErrorAction SilentlyContinue)) {
    function global:Reset-MutEnvironment {
        param($Env, $Config)
        throw 'Reset-MutEnvironment: no backend module has been imported into this session.'
    }
}
# FIX (T27 fix round 1, finding 2 -- task review): the controller's ruling put the backend
# CLI's own wedged-child-process force-kill in the BACKEND (as Stop-MutBackendChildProcesses
# -Env, with a matching stub on the container-based backend) rather than here, so this module --
# and every other lib/*.psm1 -- stays free of any backend-tool-specific name (§4 item 6).
# Called as a plain, unqualified command, same as Invoke-MutApi/Reset-MutEnvironment above.
if (-not (Get-Command -Name 'Stop-MutBackendChildProcesses' -ErrorAction SilentlyContinue)) {
    function global:Stop-MutBackendChildProcesses {
        param($Env)
        throw 'Stop-MutBackendChildProcesses: no backend module has been imported into this session.'
    }
}

function Get-MutTimeoutBudget {
    <#
        .SYNOPSIS
        Computes the per-mutant wall-clock budget in seconds (§6.5.6 step 2):
        max(minSeconds, ceil(perTestFactor * sum(baseline duration of covering codeunits, in
        seconds) + jobOverheadSeconds * count(covering codeunits))).

        .PARAMETER Config
        The run config; only .timeouts.perTestFactor / .minSeconds / .jobOverheadSeconds are
        read.

        .PARAMETER CoveringTests
        The covering test codeunit ids for one mutant (Get-MutCoveringTests' output).

        .PARAMETER Baseline
        `@{ Tests; DurationsByCodeunit = @{ '<id>' = <ms> } }` (baseline test run summary). A
        covering id absent from DurationsByCodeunit contributes 0.

        .OUTPUTS
        [int] seconds.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [int[]]$CoveringTests,
        [Parameter(Mandatory = $true)]
        $Baseline
    )

    $sumMs = 0
    foreach ($id in $CoveringTests) {
        $key = "$id"
        if ($Baseline.DurationsByCodeunit.ContainsKey($key)) {
            $sumMs += [double]$Baseline.DurationsByCodeunit[$key]
        }
    }
    $sumSeconds = $sumMs / 1000.0

    $raw = ([double]$Config.timeouts.perTestFactor * $sumSeconds) + ([double]$Config.timeouts.jobOverheadSeconds * $CoveringTests.Count)
    $ceilRaw = [math]::Ceiling($raw)

    return [int]([math]::Max([double]$Config.timeouts.minSeconds, $ceilRaw))
}

function Invoke-MutTestsWithBudget {
    <#
        .SYNOPSIS
        Private. Runs the backend's Invoke-MutTests on a background runspace (a PowerShell
        instance hosted on another thread of THIS SAME process) so a hung test run can be killed
        on the wall clock (§6.5.6 step 3), rather than blocking the orchestrator forever. Imports
        the backend module by path inside that runspace (a fresh runspace starts with no modules
        loaded) and calls Invoke-MutTests with $Env/$Targets/$TimeoutSec.

        FIX (T27, live DemoPortal run, 2026-09-08/09 -- see docs/issues.md): the original
        implementation ran this inside a `Start-Job` background job instead. Every live mutant
        activation against the real DemoPortal backend hung -- not merely slower, but
        unresponsive past 400+ seconds of wall clock, confirmed by direct reproduction outside
        the orchestrator -- the moment that job's own (separate-process) instance of PowerShell
        tried to spawn the backend's own CLI tool as a further child process via
        System.Diagnostics.Process (the backend module's private process-invocation helper),
        even though the exact same call, made directly from an interactive-context process,
        completed normally in ~37 seconds. A background runspace hosted in the SAME process (no
        additional OS-process boundary for that grandchild process to cross) reproduced the
        direct call's normal completion. `Invoke-MutMutantLoop` and the rest of this module are
        unchanged; only this function's transport mechanism was replaced, and its public
        signature/contract are identical to the previous `Start-Job`-based implementation.

        Exposed (not exported) so tests can either mock it wholesale (fast, deterministic unit
        tests of Invoke-MutMutantLoop) or call it directly via InModuleScope with a real, tiny
        fake backend module to prove the wall-clock kill actually happens.

        FIX (T27 fix round 1, finding 2 -- task review): a real hang inside the backend's own
        process-invocation helper is a synchronous Process.WaitForExit call PowerShell cannot
        preempt, so stopping the pipeline alone does not guarantee this runspace's thread
        actually returns at the budget -- a SYNCHRONOUS $powershell.Stop() (and, worse,
        .Dispose()/$runspace.Close(), which internally re-invoke Stop()) all BLOCK the calling
        thread until the pipeline's thread actually finishes, which for a truly wedged,
        non-cooperative child process (blocked in a .NET call PowerShell cannot preempt) can
        take arbitrarily long -- and (before this fix) a subsequent mutant's test job could
        start while the previous one's backend CLI child process was still running (spec §4
        item 8). Four changes close that gap:
        1. The caller (Invoke-MutMutantLoop) now passes a $TimeoutSec strictly less than
           $BudgetSec (max(30, BudgetSec - 30)), so the backend's OWN client-side timeout --
           plus its own +60s process-level margin -- fires (at BudgetSec + 30 at the latest)
           before a genuine hang would otherwise run past this wrapper's own budget with nothing
           on the inside ever trying to stop it.
        2. On budget expiry, `$powershell.BeginStop()` (async -- returns immediately, unlike the
           blocking `.Stop()`) requests a stop, then this function waits an additional
           -GraceSec (default 90s -- comfortably covers that BudgetSec + 30 inner kill) on the
           SAME AsyncWaitHandle (itself always bounded, signaled the moment the pipeline
           actually finishes, whichever comes first) for the runspace to actually finish.
        3. If the runspace STILL has not finished after the grace period (the backend's own
           process-invocation helper's WaitForExit call can genuinely never return on its own
           for a truly wedged child process), every backend CLI child process of this session is
           force-stopped via the backend's own Stop-MutBackendChildProcesses (called as a plain,
           unqualified command -- see the guard block near the top of this file -- keeping this
           module free of any backend-tool-specific name per §4 item 6), `ForcedKill = $true` is
           set on the returned object, and the runspace is torn down via the async
           `CloseAsync()` (moves it out of the 'Opened' state immediately; the actual teardown
           finishes on its own background thread) rather than a synchronous Close()/Dispose()
           that would block this call for exactly the same reason as step 2 -- $powershell
           itself is left for the finalizer/GC in this one already-exceptional branch, an
           accepted, documented cost.
        4. Every path is wrapped in try/catch and this function must never throw from the
           timeout path, whichever of the above it takes.

        .PARAMETER BudgetSec
        Wall-clock budget to wait for the background runspace to finish. May differ from
        $TimeoutSec (which is only the value forwarded to the backend's own -TimeoutSec) so a
        test can shrink the wrapper's patience independently of what is told to the backend.

        .PARAMETER GraceSec
        Extra wall-clock seconds to wait, after requesting a stop, for the background runspace
        to actually finish once -BudgetSec has already elapsed, before force-killing any backend
        CLI child process of this session (default 90). Exposed as a parameter so a test can
        shrink it independently of the real production grace.

        .OUTPUTS
        [pscustomobject]@{ TimedOut (bool); Result (backend Invoke-MutTests result, or $null);
        ErrorMessage (string, or $null); ForcedKill (bool) }.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [object[]]$Targets,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSec,
        [Parameter(Mandatory = $true)]
        [int]$BudgetSec,
        [Parameter(Mandatory = $true)]
        [string]$BackendModulePath,
        [int]$GraceSec = 90
    )

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [System.Management.Automation.PowerShell]::Create()
    $powershell.Runspace = $runspace

    [void]$powershell.AddScript({
            param($JobModulePath, $JobEnv, $JobTargets, $JobTimeoutSec)
            Import-Module $JobModulePath -Force
            Invoke-MutTests -Env $JobEnv -Targets $JobTargets -TimeoutSec $JobTimeoutSec
        })
    [void]$powershell.AddArgument($BackendModulePath)
    [void]$powershell.AddArgument($Env)
    [void]$powershell.AddArgument($Targets)
    [void]$powershell.AddArgument($TimeoutSec)

    $asyncResult = $powershell.BeginInvoke()
    $completed = $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($BudgetSec))

    if (-not $completed) {
        # FIX (T27 fix round 1, finding 2): $powershell.Stop()/.Dispose() and $runspace.Close()
        # are all BLOCKING calls that wait for the pipeline's underlying thread to actually
        # return -- fine for the cooperative case below (the thread responds to a stop request
        # quickly), but for a truly wedged, non-cooperative child (blocked in a synchronous .NET
        # call PowerShell cannot preempt) they would block THIS function for as long as that
        # thread keeps running, defeating the whole point of a bounded wall-clock kill.
        # BeginStop (async: returns immediately, requests the same stop) is used here instead of
        # Stop() for exactly that reason.
        try { $powershell.BeginStop($null, $null) | Out-Null } catch { }

        $finishedDuringGrace = $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($GraceSec))

        $forcedKill = $false
        if (-not $finishedDuringGrace) {
            try {
                Stop-MutBackendChildProcesses -Env $Env | Out-Null
            }
            catch { }
            $forcedKill = $true

            # The pipeline is, by definition, still not finished here (WaitOne just timed out) --
            # a synchronous Dispose()/Close() would block this call for as long as the wedged
            # thread keeps running. Runspace.CloseAsync() moves it out of the 'Opened' state
            # immediately and finishes the actual teardown on its own background thread;
            # $powershell itself is left for the finalizer/GC rather than risking the same block
            # inside its own Dispose() (which re-invokes Stop() internally) -- an accepted,
            # documented resource-leak cost specific to this already-exceptional path (the
            # underlying .NET thread may still be running; only this wrapper's own bounded
            # return is guaranteed).
            try { $runspace.CloseAsync() } catch { }

            return [pscustomobject]@{ TimedOut = $true; Result = $null; ErrorMessage = $null; ForcedKill = $forcedKill }
        }

        # The pipeline finished on its own during the grace period (the cooperative case, e.g.
        # a fake backend using Start-Sleep): safe to dispose/close synchronously here, since
        # AsyncWaitHandle already signaled that it is done.
        try { $powershell.Dispose() } catch { }
        try { $runspace.Close() } catch { }
        try { $runspace.Dispose() } catch { }

        return [pscustomobject]@{ TimedOut = $true; Result = $null; ErrorMessage = $null; ForcedKill = $forcedKill }
    }

    try {
        $resultCollection = $powershell.EndInvoke($asyncResult)

        if ($powershell.HadErrors -and @($powershell.Streams.Error).Count -gt 0) {
            $errorMessage = (@($powershell.Streams.Error) | ForEach-Object { $_.ToString() }) -join '; '
            $powershell.Dispose()
            $runspace.Close()
            $runspace.Dispose()
            return [pscustomobject]@{ TimedOut = $false; Result = $null; ErrorMessage = $errorMessage; ForcedKill = $false }
        }

        $result = @($resultCollection) | Select-Object -First 1
        $powershell.Dispose()
        $runspace.Close()
        $runspace.Dispose()
        return [pscustomobject]@{ TimedOut = $false; Result = $result; ErrorMessage = $null; ForcedKill = $false }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $powershell.Dispose()
        $runspace.Close()
        $runspace.Dispose()
        return [pscustomobject]@{ TimedOut = $false; Result = $null; ErrorMessage = $errorMessage; ForcedKill = $false }
    }
}

function Start-MutPostResetSettle {
    <#
        .SYNOPSIS
        Private. Waits a short settle period after Reset-MutEnvironment (§6.5.6 step 3), before
        the loop's next test run.

        FIX (T27, live DemoPortal run, 2026-09-09 -- see docs/issues.md): observed live, twice,
        immediately after Reset-MutEnvironment's poll reported the environment back to Running:
        the very next mutant's test run returned instantly (0 ms) with Failed = 0 and no tests
        actually executed, which the loop then recorded as a false Survived (or, for the mutant
        that was itself supposed to genuinely time out, a false non-Timeout) rather than the
        correct outcome -- the backend's own "Running" status evidently does not yet guarantee
        the test-execution service is ready to accept a job. A fixed settle delay after every
        reset is a coarse, minimal mitigation (not a guarantee for a slower environment) chosen
        over a more invasive change (e.g. retrying on an empty result, or teaching this
        backend-agnostic module a backend-specific readiness probe) to keep this fix narrowly
        scoped. Exposed (not exported) so a test can mock it away instead of genuinely sleeping.
    #>
    param([int]$Seconds = 45)

    Start-Sleep -Seconds $Seconds
}

function Write-MutResultsJsonLine {
    <#
        .SYNOPSIS
        Appends one mutant's result row as a single JSON line to <RunDir>/results.jsonl,
        immediately (crash safety, §6.5.6 step 4).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunDir,
        [Parameter(Mandatory = $true)]
        $Row
    )

    $jsonlPath = Join-Path $RunDir 'results.jsonl'
    ($Row | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $jsonlPath
}

function Invoke-MutMutantLoop {
    <#
        .SYNOPSIS
        Runs the mutant loop (§6.5.6): for each mutant in id order, selects covering tests,
        activates the mutant, runs its covering tests under a wall-clock budget, records the
        outcome via the Mutation Core API, and always deactivates the mutant afterward -- even
        on a timeout or a job error. Never aborts the loop because one mutant failed or errored.

        .PARAMETER Config
        The run config (needs .testApp.testCodeunits and .timeouts.*).

        .PARAMETER Env
        The environment handle, passed through to Invoke-MutApi / the job's Invoke-MutTests /
        Reset-MutEnvironment.

        .PARAMETER Mutants
        mutants.json entries (§7.1): at minimum id, objectId, line.

        .PARAMETER Baseline
        `@{ Tests; DurationsByCodeunit }`, used by Get-MutTimeoutBudget.

        .PARAMETER Coverage
        `@{ byTestCodeunit = @{...} }` (§7.2), passed to Get-MutCoveringTests.

        .PARAMETER References
        objectId -> int[] testCodeunitIds, passed to Get-MutCoveringTests.

        .PARAMETER RunNo
        The current run number.

        .PARAMETER RunDir
        Directory results.jsonl is appended to.

        .PARAMETER BackendModulePath
        Path to the backend module the Start-Job wrapper imports to call Invoke-MutTests.

        .OUTPUTS
        [pscustomobject[]] one row per mutant, in id order: {Id; Status; KillingTest;
        DurationMs; CoveringTests}. A row with Status 'Error' additionally carries an `Error`
        property with the job's exception message.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [object[]]$Mutants,
        [Parameter(Mandatory = $true)]
        $Baseline,
        [Parameter(Mandatory = $true)]
        $Coverage,
        [Parameter(Mandatory = $true)]
        $References,
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [string]$RunDir,
        [Parameter(Mandatory = $true)]
        [string]$BackendModulePath
    )

    $testCodeunits = [int[]]@($Config.testApp.testCodeunits)
    $orderedMutants = $Mutants | Sort-Object -Property id

    $rows = @()

    foreach ($mutant in $orderedMutants) {
        $covering = Get-MutCoveringTests -Mutant $mutant -Coverage $Coverage -References $References -TestCodeunits $testCodeunits

        if (@($covering).Count -eq 0) {
            $row = [pscustomobject]@{
                Id            = $mutant.id
                Status        = 'Uncovered'
                KillingTest   = $null
                DurationMs    = $null
                CoveringTests = @($covering)
            }
            Write-MutResultsJsonLine -RunDir $RunDir -Row $row
            $rows += $row
            continue
        }

        Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = $mutant.id; currentRunNo = $RunNo } | Out-Null

        $budget = Get-MutTimeoutBudget -Config $Config -CoveringTests $covering -Baseline $Baseline
        # FIX (T27 fix round 1, finding 2 -- task review): the timeout handed to the backend
        # (and, inside it, to its own +60s process margin) must be strictly less
        # than $budget -- otherwise a genuine hang would never be killed by the backend's own
        # client-side timeout before Invoke-MutTestsWithBudget's own wall-clock budget already
        # gave up waiting on it. max(30, budget - 30) leaves the backend's own timeout plus its
        # +60s margin firing at budget + 30 at the latest, comfortably inside
        # Invoke-MutTestsWithBudget's own (default 90s) post-budget grace period.
        $innerTimeoutSec = [math]::Max(30, $budget - 30)
        $targets = @($covering | ForEach-Object { [pscustomobject]@{ CodeunitId = $_; Function = $null } })

        # FIX (T27, live run, 2026-09-09 -- see docs/issues.md): observed live, twice, that the
        # very next test run after Reset-MutEnvironment (§6.5.6 step 3, immediately below) came
        # back as a clean completion (no timeout, no error) reporting ZERO tests actually
        # executed (Passed = 0, Failed = 0) rather than genuinely running the covering
        # codeunit's suite -- silently recorded as a false Survived. A fixed post-reset settle
        # delay (Start-MutPostResetSettle, below) alone was not sufficient to prevent this on
        # its own (confirmed live: the same empty-result pattern recurred even after it). Instead
        # of guessing at a longer delay, this retries the SAME test invocation once when it
        # completes with zero total tests -- directly targeting the observed symptom (an
        # apparently-transient "not yet truly ready" response) rather than a specific wait
        # duration this environment has not confirmed is ever long enough.
        $attempt = 0
        $maxAttempts = 2
        do {
            $attempt++
            $outcome = Invoke-MutTestsWithBudget -Env $Env -Targets $targets -TimeoutSec $innerTimeoutSec -BudgetSec $budget -BackendModulePath $BackendModulePath
            $isEmptyResult = (-not $outcome.TimedOut) -and (-not $outcome.ErrorMessage) -and ($null -ne $outcome.Result) -and
                (([int]$outcome.Result.Passed + [int]$outcome.Result.Failed) -eq 0)
        } while ($isEmptyResult -and $attempt -lt $maxAttempts)

        $status = $null
        $killingTest = $null
        $durationMs = $null
        $errorMessage = $null

        if ($outcome.TimedOut) {
            Reset-MutEnvironment -Env $Env -Config $Config | Out-Null
            Start-MutPostResetSettle
            $status = 'Timeout'
        }
        elseif ($outcome.ErrorMessage) {
            $status = 'Error'
            $errorMessage = $outcome.ErrorMessage
        }
        else {
            $result = $outcome.Result
            $durationMs = $result.DurationMs

            if (@($result.Tests).Count -eq 0) {
                # FIX (T27 fix round 1, finding 4b -- spike T09): a test job issued too soon
                # after a DemoPortal environment (re)start can complete cleanly (no timeout, no
                # error) with ZERO tests actually discovered/run for a codeunit that DOES have
                # covering tests -- indistinguishable from a genuinely passing suite by
                # Passed/Failed alone, and would otherwise be recorded as a false Survived (the
                # mutant was never actually exercised). The retry above already tries once more
                # when Passed + Failed = 0; if the result is STILL empty here, this is recorded
                # as Error (never Survived) so it is visible and excluded from the score rather
                # than silently counted as a kill-suppressing pass.
                $status = 'Error'
                $errorMessage = 'no tests discovered'
            }
            elseif ($result.Failed -gt 0) {
                $status = 'Killed'

                $firstFail = @($result.Tests) | Where-Object { $_.Result -eq 'Fail' } | Select-Object -First 1
                if ($firstFail) {
                    $killingTest = '{0}:{1}' -f $firstFail.Codeunit, $firstFail.Function
                }

                $filterPath = 'mutantResults?$filter=runNo eq {0} and mutantId eq {1}' -f $RunNo, $mutant.id
                $existing = Invoke-MutApi -Env $Env -Method 'GET' -Path $filterPath

                if (@($existing.value).Count -eq 0) {
                    Invoke-MutApi -Env $Env -Method 'POST' -Path 'mutantResults' -Body @{
                        runNo       = $RunNo
                        mutantId    = $mutant.id
                        status      = 'Killed'
                        killingTest = $killingTest
                        durationMs  = $durationMs
                    } | Out-Null
                }
            }
            else {
                $status = 'Survived'
                # FIX (T27, live run, 2026-09-09 -- see docs/issues.md): unlike the Killed branch
                # above (which GETs first and only POSTs when no row exists yet), this always
                # POSTed unconditionally -- fine on a genuinely fresh run, but a run resumed at
                # this step for the same RunNo (a step earlier in the pipeline was re-run after
                # a crash, or, live, this loop was re-run to pick up a fix) re-processes a
                # mutant that already has a Survived row from the earlier attempt, and the POST
                # then fails with the table's (runNo, mutantId) key already existing --
                # previously an unhandled, run-ending error. Swallowed here as an idempotent
                # no-op (matching the Killed branch's own idempotency), while any other POST
                # failure still propagates normally.
                try {
                    Invoke-MutApi -Env $Env -Method 'POST' -Path 'mutantResults' -Body @{
                        runNo      = $RunNo
                        mutantId   = $mutant.id
                        status     = 'Survived'
                        durationMs = $durationMs
                    } | Out-Null
                }
                catch {
                    $duplicateKeyText = ''
                    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                        $duplicateKeyText = $_.ErrorDetails.Message
                    }
                    if (-not $duplicateKeyText) {
                        $duplicateKeyText = $_.Exception.Message
                    }
                    if ($duplicateKeyText -notmatch 'EntityWithSameKeyExists') {
                        throw
                    }
                }
            }
        }

        Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = $RunNo } | Out-Null

        $row = [pscustomobject]@{
            Id            = $mutant.id
            Status        = $status
            KillingTest   = $killingTest
            DurationMs    = $durationMs
            CoveringTests = @($covering)
        }
        if ($status -eq 'Error') {
            $row | Add-Member -NotePropertyName 'Error' -NotePropertyValue $errorMessage
        }

        Write-MutResultsJsonLine -RunDir $RunDir -Row $row
        $rows += $row
    }

    return , $rows
}

Export-ModuleMember -Function Get-MutTimeoutBudget, Invoke-MutMutantLoop
