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
# FIX (F3, run 8 -- finding I6): Get-MutEnvironment/Start-MutEnvironment are the two more
# backend interface functions (§6.5.3) Confirm-MutEnvironmentServing (below) needs to re-check
# and, if necessary, recover a non-serving environment. Same placeholder-for-Mock pattern as
# Invoke-MutApi/Reset-MutEnvironment/Stop-MutBackendChildProcesses above.
if (-not (Get-Command -Name 'Get-MutEnvironment' -ErrorAction SilentlyContinue)) {
    function global:Get-MutEnvironment {
        param([string]$Name, $Config)
        throw 'Get-MutEnvironment: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Start-MutEnvironment' -ErrorAction SilentlyContinue)) {
    function global:Start-MutEnvironment {
        param($Env, $Config)
        throw 'Start-MutEnvironment: no backend module has been imported into this session.'
    }
}

# T42 (§6.10.4): the SOAP test transport's backend functions (§6.10.3). Same placeholder-for-Mock
# pattern as above; importing a real backend module always wins.
if (-not (Get-Command -Name 'Invoke-MutMutantBatch' -ErrorAction SilentlyContinue)) {
    function global:Invoke-MutMutantBatch {
        param($Env, [int[]]$CodeunitIds, [int[]]$MutantIds, [int]$RunNo, [int]$MutantBudgetSec)
        throw 'Invoke-MutMutantBatch: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Get-MutRunnerState' -ErrorAction SilentlyContinue)) {
    function global:Get-MutRunnerState {
        param($Env)
        throw 'Get-MutRunnerState: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Stop-MutRunnerBatch' -ErrorAction SilentlyContinue)) {
    function global:Stop-MutRunnerBatch {
        param($Env, [string]$BatchId, [string]$CodeunitIds)
        throw 'Stop-MutRunnerBatch: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Test-MutSoapRunner' -ErrorAction SilentlyContinue)) {
    function global:Test-MutSoapRunner {
        param($Env)
        throw 'Test-MutSoapRunner: no backend module has been imported into this session.'
    }
}

# FIX (F3, run 8 -- finding I6): recovery-attempt cap (Confirm-MutEnvironmentServing, below).
# Reset to 0 at the top of every Invoke-MutMutantLoop call. A small constant per the task brief
# rather than a config key -- three lost environments in one run is a reason to stop, not a
# dial to tune per run.
$script:MaxEnvironmentRecoveries = 3
# FIX (F3b, Minors): a custom ErrorCategory ([System.Management.Automation.ErrorCategory]::
# LimitsExceeded) identifies the recovery-cap-exceeded throw, not string-matching a marker
# prefix in the exception message -- see Request-MutEnvironmentRecoveryBudget and the
# per-mutant catch in Invoke-MutMutantLoop. $script:MutEnvironmentRecoveryCapErrorId is only the
# ErrorRecord's ErrorId (cosmetic/diagnostic; never matched against).
$script:MutEnvironmentRecoveryCapErrorId = 'MutEnvironmentRecoveryCapExceeded'
# Initialized here (not lazily inside Invoke-MutMutantLoop only) because Set-StrictMode
# -Version Latest throws on a bare read of a $script: variable that was never assigned at all,
# as opposed to one that is $null -- same reasoning as DemoPortal.psm1's own module-scoped cache
# variables. Invoke-MutMutantLoop resets it to 0 at the start of every call.
$script:MutEnvironmentRecoveryCount = 0

# FIX (503 bisect, 2026-09-30): the environment has a transient outage after ~45-60 minutes of
# continuous test jobs, independent of mutation. Runs 8 and 9 each lost the last 46 of 265
# mutants to one: in run 9, 37 of them were `(503) Server Unavailable` thrown by the PATCH that
# activates each mutant, which sits BEFORE the empty-result retry, so every one fell straight
# into the per-mutant catch, was recorded as Error in seconds, and the loop burned through the
# rest of the run inside the outage window. A thrown call now waits for the environment to serve
# again (Wait-MutOutageRecovery) and retries the SAME mutant.
#   OutageWaitDeadlineSec     -- how long one outage may last before the run aborts. The bisect's
#                                outage lasted ~2-4 min; run 9's included 600 s stuck in Starting.
#   OutagePollIntervalSec     -- pause between readiness checks inside one wait.
#   MaxOutageRetriesPerMutant -- outage waits per mutant before it is recorded as Error, so a
#                                mutant whose own calls always throw cannot stall the run.
#   MaxConsecutiveErrors      -- the circuit breaker: this many Error rows in a row abort the run
#                                with a partial export. Run 9 recorded 46 in a row, spent zero
#                                recovery slots, and published `aborted: false` with a score.
$script:OutageWaitDeadlineSec = 900
$script:OutagePollIntervalSec = 30
$script:MaxOutageRetriesPerMutant = 2
$script:MaxConsecutiveErrors = 5

# FIX (run 10, 2026-09-30): non-terminating mutants. Mutants 4371/4373/4374 make
# BuildBatchDisplay's `repeat ... until false` loop never exit. The CLI's --timeout only stops the
# CLIENT waiting and then reports ZERO tests; the BC session keeps looping (two were still alive
# ~15 min later). The loop read that as an empty result ("no tests discovered"), retried it
# against the still-looping session, and never reached the Timeout branch -- the one that resets
# the environment and so kills the runaway session -- so every later job on that test codeunit
# came back empty too. That is what cost runs 8, 9 and 10 every mutant from execution position
# 219 on.
#   ClientWaitExpiredFraction -- an empty result whose attempt took at least this fraction of the
#                                timeout handed to the backend is the client wait expiring, and is
#                                treated as a Timeout. A genuinely empty result returns in seconds.
#   MaxConsecutiveTimeouts    -- see the consecutive-Timeout breaker in Invoke-MutMutantLoop.
$script:ClientWaitExpiredFraction = 0.9
$script:MaxConsecutiveTimeouts = 5

# FIX (run 11, 2026-10-01): the Timeout branch's full environment stop/start can fail outright --
# in run 11 the new container's database attach raced the old container ("Failed to move
# database ... Container marked as unhealthy"), and the run aborted. A Timeout now first stops
# just the runaway session through Mutation Core's sessions API (verified live: StopSession ends a
# session stuck in a non-terminating mutant's loop within ~10 s, despite BC documenting that it
# cannot always), and falls back to the reset only when it cannot (Stop-MutRunawayTestSessions).
#   Targets are 'Client Service' sessions on the CURRENT server instance. BC leaves STALE rows in
#   Active Session for sessions killed by a container restart; they accept a stop and never go
#   away. Their serverInstanceId is an older one (it increments per service start: live rows on
#   2026-10-01 were instance 12, stale ones 9, 10 and 11). A first version filtered on login time
#   instead and missed the runaway in run 12: DemoPortal reuses a long-lived test-runner session,
#   so the looping job's session had logged in minutes before the job started.
#   RunawaySessionWaitSec -- how long to wait for stopped sessions to disappear.
$script:RunawaySessionWaitSec = 120
$script:RunawaySessionPollSec = 10
$script:MutOutageWaitCount = 0

function Test-MutHasProperty {
    <#
        .SYNOPSIS
        Private. True when $Object is non-null and has a property named $Name. See the
        identical helper in Run.psm1/DemoPortal.psm1/etc. for why this guard exists under
        Set-StrictMode -Version Latest.
    #>
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-MutClockSeconds {
    <#
        .SYNOPSIS
        Private. A monotonic clock in seconds, used to time each test attempt (the
        client-wait-expired check in Invoke-MutMutantLoop). A function rather than an inline
        Stopwatch so tests can advance time without sleeping.
    #>
    return [System.Diagnostics.Stopwatch]::GetTimestamp() / [double][System.Diagnostics.Stopwatch]::Frequency
}

function Request-MutEnvironmentRecoveryBudget {
    <#
        .SYNOPSIS
        Private. Spends one recovery slot against $script:MaxEnvironmentRecoveries for the life
        of one Invoke-MutMutantLoop call (F3b IMPORTANT 1: shared by every way an environment
        loss can present -- an empty/erroring result recovered via Confirm-MutEnvironmentServing,
        below, AND a Timeout's Reset-MutEnvironment, in Invoke-MutMutantLoop itself -- a dead
        environment presenting as repeated Timeouts must not reset forever, uncounted).

        Throws (an ErrorRecord categorized LimitsExceeded, per F3b Minors -- callers match on
        that category, never on the exception's message text) instead of spending a slot once
        the cap is already spent, so the caller aborts the run rather than limping on. Otherwise
        increments the counter and Write-Warnings once, naming the mutant and why.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$MutantId,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($script:MutEnvironmentRecoveryCount -ge $script:MaxEnvironmentRecoveries) {
        $message = "Invoke-MutMutantLoop: mutant $MutantId -- $Context, after $($script:MutEnvironmentRecoveryCount) prior environment recoveries this run (cap $($script:MaxEnvironmentRecoveries)). A run that has lost its environment this many times is not producing a trustworthy score; aborting rather than continuing."
        $exception = [System.Exception]::new($message)
        throw [System.Management.Automation.ErrorRecord]::new($exception, $script:MutEnvironmentRecoveryCapErrorId, [System.Management.Automation.ErrorCategory]::LimitsExceeded, $null)
    }
    $script:MutEnvironmentRecoveryCount++
    Write-Warning "Invoke-MutMutantLoop: mutant $MutantId -- $Context; recovering (recovery $($script:MutEnvironmentRecoveryCount) of $($script:MaxEnvironmentRecoveries) this run)."
}

function Confirm-MutEnvironmentServing {
    <#
        .SYNOPSIS
        FIX (F3, run 8, 2026-09-22 -- finding I6): called by Invoke-MutMutantLoop when a test
        run comes back with a non-real result (zero total tests, or a job ErrorMessage -- F3b
        IMPORTANT 1), before the loop consumes its last retry. Run 8 fired 46 test jobs in a row
        at an environment that reported Running but was not actually serving, and every one of
        them was silently recorded as a legitimate result -- the loop never asked whether the
        environment was still alive.

        Re-checks status via Get-MutEnvironment, then ALWAYS calls Start-MutEnvironment -- it is
        idempotent (starts only when not already Running) but, as of the companion DemoPortal
        fix, now always probes test-readiness regardless of whether a real start happened, which
        is what actually confirms the environment is serving rather than merely reporting
        Running (the exact gap run 8 fell through).

        FIX (F3b BLOCKER 1): the CALLER must PATCH `activeMutantId = 0` before calling this and
        re-PATCH the real mutant id back afterward -- this function runs a REAL test job (the
        probe) and Mutation Core's OnAfterTestMethodRun records a Killed row for ANY failing
        test while a mutant is active, with no check that the failing test covers that mutant.
        Probing with the wrong mutant still active would misattribute a kill exactly like the
        reference-map defect this project already fixed once, one layer down. This function
        does not do that PATCHing itself, because it has no RunNo and must not assume one PATCH
        shape -- see Invoke-MutMutantLoop's own call sites.

        Recovery attempts (the environment was found NOT Running, or found Running but its
        probe then failed) are spent from $script:MaxEnvironmentRecoveries via
        Request-MutEnvironmentRecoveryBudget, above -- see its own doc comment for the cap
        throw. A confirmation of an already-Running, already-serving environment costs nothing
        against the cap.

        .OUTPUTS
        The environment handle Start-MutEnvironment returns once it has confirmed the
        environment is serving (F3b Minors: the caller must keep using THIS handle from here on,
        not the one it passed in -- Start-MutEnvironment re-fetches status and this is the
        freshest confirmed-serving handle available). Never returns without one --
        Start-MutEnvironment's own probe failure, or the recovery cap, propagates instead.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $MutantId
    )

    # FIX (F3b Minors): guarded the same way $recheck.Status already was -- $Env is always this
    # module's own handle shape in practice, but a bare $Env.Name read was the one inconsistent
    # unguarded property access under Set-StrictMode in this function.
    $envName = $null
    if (Test-MutHasProperty $Env 'Name') { $envName = $Env.Name }

    $recheck = Get-MutEnvironment -Name $envName -Config $Config
    $statusText = if (Test-MutHasProperty $recheck 'Status') { $recheck.Status } else { 'unknown' }
    $targetEnv = if ($null -ne $recheck) { $recheck } else { $Env }
    $wasRunning = ($statusText -eq 'Running')

    if (-not $wasRunning) {
        Request-MutEnvironmentRecoveryBudget -MutantId $MutantId -Context "got a non-real test result and the environment is not Running (status '$statusText')"
    }

    try {
        # Idempotent: starts only if $targetEnv is not already Running, but always probes
        # test-readiness now regardless (the companion DemoPortal fix) -- this call is what
        # actually confirms "serving", not the status check above.
        return (Start-MutEnvironment -Env $targetEnv -Config $Config)
    }
    catch {
        if ($wasRunning) {
            # The status check said Running, but the readiness probe itself failed -- also a
            # genuine environment-recovery event, counted the same way (F3b IMPORTANT 4: this
            # branch is exercised by its own dedicated test).
            Request-MutEnvironmentRecoveryBudget -MutantId $MutantId -Context "the environment reports Running but its readiness probe failed: $($_.Exception.Message)"
        }
        throw
    }
}

function Wait-MutOutageRecovery {
    <#
        .SYNOPSIS
        Private. FIX (503 bisect): called when a mutant's attempt threw -- typically an API call
        failing because the environment is mid-outage. Polls until the environment is serving
        again, bounded by $script:OutageWaitDeadlineSec, so the caller can retry the SAME mutant
        instead of recording Error and moving on.

        Each poll first PATCHes `activeMutantId = 0`, and runs the readiness check only when that
        succeeded. The readiness check (Start-MutEnvironment) runs a real probe test job, and
        Mutation Core's OnAfterTestMethodRun records a Killed row for ANY failing test while a
        mutant is active (the F3b BLOCKER 1 hazard). During an outage the caller's own
        best-effort deactivation may itself have failed, so this cannot assume it happened.

        Not charged against $script:MaxEnvironmentRecoveries: an outage that ends, followed by a
        retry of the same mutant, costs time but not score integrity. An outage that does not end
        within the deadline aborts the run instead.

        .OUTPUTS
        The environment handle Start-MutEnvironment returned once it confirmed serving. Throws
        an ErrorRecord categorized LimitsExceeded (the same category the recovery cap uses, so
        the caller aborts the run with a partial export) when the deadline passes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [int]$MutantId,
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    $script:MutOutageWaitCount++
    Write-Warning "Invoke-MutMutantLoop: mutant $MutantId -- an environment call failed ($Reason); waiting up to $($script:OutageWaitDeadlineSec) s for the environment to serve again, then retrying this mutant."

    $deadline = [datetime]::UtcNow.AddSeconds($script:OutageWaitDeadlineSec)
    $lastError = $Reason
    while ($true) {
        $deactivated = $false
        try {
            Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = $RunNo } | Out-Null
            $deactivated = $true
        }
        catch {
            $lastError = "deactivating the mutant failed: $($_.Exception.Message)"
        }

        if ($deactivated) {
            try {
                return (Start-MutEnvironment -Env $Env -Config $Config)
            }
            catch {
                $lastError = $_.Exception.Message
            }
        }

        if ([datetime]::UtcNow -ge $deadline) {
            $message = "Invoke-MutMutantLoop: mutant $MutantId -- the environment did not return to serving within $($script:OutageWaitDeadlineSec) s after an environment call failed ($Reason). Last readiness error: $lastError. Aborting rather than recording the rest of the run as Error."
            $exception = [System.Exception]::new($message)
            throw [System.Management.Automation.ErrorRecord]::new($exception, 'MutEnvironmentOutageTimeout', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $null)
        }
        Start-Sleep -Seconds $script:OutagePollIntervalSec
    }
}

function Stop-MutRunawayTestSessions {
    <#
        .SYNOPSIS
        Private. FIX (run 11): after a Timeout, stops the test session the timed-out job left
        running, through Mutation Core's sessions API (GET sessions; POST
        sessions(<id>)/Microsoft.NAV.stop), and waits for it to disappear.

        Targets: 'Client Service' sessions (the type DemoPortal test jobs run as) on the current
        server instance -- the highest serverInstanceId in the listing, which always includes the
        caller's own request session. That rule keeps STALE rows out: BC leaves sessions killed
        by a container restart in Active Session, on an older instance, and such a row accepts a
        stop but never disappears, so targeting it would force a needless full reset every time.
        DemoPortal reuses a long-lived test-runner session, so an idle one on the current instance
        is stopped too; the next job starts a fresh one.

        .OUTPUTS
        $true only when at least one target was found and every target disappeared within
        $script:RunawaySessionWaitSec. $false otherwise -- no target visible, a target that does
        not go away, or the sessions API missing (an older Mutation Core) -- and the caller then
        falls back to the full environment reset.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [int]$MutantId
    )

    try {
        $list = Invoke-MutApi -Env $Env -Method 'GET' -Path 'sessions'
    }
    catch {
        Write-Warning "Invoke-MutMutantLoop: mutant $MutantId -- could not list sessions ($($_.Exception.Message)); falling back to an environment reset."
        return $false
    }

    $rowsAll = @()
    if ((Test-MutHasProperty $list 'value') -and ($null -ne $list.value)) {
        $rowsAll = @(@($list.value) | Where-Object { (Test-MutHasProperty $_ 'sessionId') -and (Test-MutHasProperty $_ 'serverInstanceId') })
    }
    $targets = @()
    if ($rowsAll.Count -gt 0) {
        $currentInstance = (@($rowsAll | ForEach-Object { [int]$_.serverInstanceId }) | Measure-Object -Maximum).Maximum
        foreach ($session in $rowsAll) {
            if (-not (Test-MutHasProperty $session 'clientType') -or ([string]$session.clientType -ne 'Client Service')) { continue }
            if ((Test-MutHasProperty $session 'isCurrentSession') -and [bool]$session.isCurrentSession) { continue }
            if ([int]$session.serverInstanceId -ne $currentInstance) { continue }
            $targets += [int]$session.sessionId
        }
    }
    if ($targets.Count -eq 0) {
        Write-Warning "Invoke-MutMutantLoop: mutant $MutantId -- no test session from the timed-out job is visible; falling back to an environment reset."
        return $false
    }

    foreach ($id in $targets) {
        try {
            Invoke-MutApi -Env $Env -Method 'POST' -Path "sessions($id)/Microsoft.NAV.stop" -Body @{} | Out-Null
        }
        catch {
            # A session that ended between the listing and the stop is fine; the poll below
            # decides success either way.
        }
    }

    $deadline = (Get-MutClockSeconds) + $script:RunawaySessionWaitSec
    while ($true) {
        $alive = $targets
        try {
            $now = Invoke-MutApi -Env $Env -Method 'GET' -Path 'sessions'
            $liveIds = @()
            if ((Test-MutHasProperty $now 'value') -and ($null -ne $now.value)) {
                $liveIds = @(@($now.value) | ForEach-Object { [int]$_.sessionId })
            }
            $alive = @($targets | Where-Object { $liveIds -contains $_ })
        }
        catch {
            # Unknown this poll: keep waiting.
        }
        if (@($alive).Count -eq 0) {
            Write-Warning "Invoke-MutMutantLoop: mutant $MutantId -- stopped the runaway test session(s) $($targets -join ', ') left by the timed-out job."
            return $true
        }
        if ((Get-MutClockSeconds) -ge $deadline) {
            Write-Warning "Invoke-MutMutantLoop: mutant $MutantId -- test session(s) $(@($alive) -join ', ') still alive $($script:RunawaySessionWaitSec) s after a stop; falling back to an environment reset."
            return $false
        }
        Start-Sleep -Seconds $script:RunawaySessionPollSec
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

        FIX (M3, run 3 crash, 2026-09-1x -- see .superpowers/sdd/tasks.json/progress.md): the
        run that motivated this task crashed on `Add-Content` throwing a file-lock IOException
        (another process briefly had `results.jsonl` open) at mutant 145 of 157, aborting the
        entire run. `results.jsonl` is a post-mortem/audit trail and this loop's own resume
        fallback (`Get-MutRecordedResultsForRun`, below) only when the Mutation Core API itself
        holds nothing for the run -- the API is the authoritative record (§6.5.6, §7.3's
        Export-Results reads the API, not this file). Losing one line of it must never abort an
        hours-long run. The append is now retried up to 5 times with a short linear back-off; if
        it still fails, the failure is logged and swallowed rather than thrown.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunDir,
        [Parameter(Mandatory = $true)]
        $Row
    )

    $jsonlPath = Join-Path $RunDir 'results.jsonl'
    $line = ($Row | ConvertTo-Json -Depth 10 -Compress)

    $maxAttempts = 5
    $lastError = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $line | Add-Content -Path $jsonlPath
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Milliseconds (200 * $attempt)
            }
        }
    }

    Write-Warning "Invoke-MutMutantLoop: failed to append mutant $($Row.Id)'s result to results.jsonl after $maxAttempts attempts (the API already holds the authoritative result): $($lastError.Exception.Message)"
}

function Get-MutRecordedResultsForRun {
    <#
        .SYNOPSIS
        Private. Loads already-recorded mutant results for this run so Invoke-MutMutantLoop can
        resume after a crash (§6.5.6) instead of re-running -- and re-POSTing, hitting the
        `MUT Mutant Result` primary key (Run No., Mutant Id), §6.1.2 -- every mutant from
        scratch. Called once, at the top of the loop (not per mutant).

        The Mutation Core API (GET `mutantResults` filtered to this RunNo -- the same source
        `Export-MutResults` reads, §6.5.4 step 9) is preferred as the source of truth. Only when
        the API reports NO rows at all for the run (a fresh run, or a crash before any POST ever
        succeeded) does this fall back to `<RunDir>/results.jsonl`, written by this same loop --
        possibly by an earlier, crashed attempt at this exact RunNo/RunDir. The jsonl fallback is
        also the only source for `Uncovered`/`Timeout`/non-POSTed `Error` rows, since only
        `Killed`/`Survived` are ever POSTed to the API.

        .OUTPUTS
        `@{ <mutantId (int)> = [pscustomobject]@{ Status; KillingTest; DurationMs; CoveringTests;
        Error } }`
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [string]$RunDir
    )

    $recorded = @{}

    $apiRows = @()
    try {
        $filterPath = 'mutantResults?$filter=runNo eq {0}' -f $RunNo
        $response = Invoke-MutApi -Env $Env -Method 'GET' -Path $filterPath
        if ($response -and $response.value) {
            $apiRows = @($response.value)
        }
    }
    catch {
        # A resume-fetch failure (e.g. a transient API hiccup) must not abort the run -- it
        # just means this attempt falls back to results.jsonl (or, if that is also unavailable,
        # re-runs every mutant, which is exactly today's un-resumable behaviour, not a
        # regression).
        $apiRows = @()
    }

    if (@($apiRows).Count -gt 0) {
        # The `MUT Mutant Result` API row (runNo/mutantId/status/killingTest/durationMs, §6.1.2)
        # does not carry coveringTests at all, but the data is already on disk: Run.psm1's
        # Get-MutCoveringTestsStep (§6.5.4 step 7) wrote <RunDir>/covering.json (mutant id ->
        # covering test codeunit ids) before the loop ever ran. Read it here so a resumed run's
        # export does not lose coveringTests -- required by §7.3/§7.5 and the most useful column
        # when triaging survivors -- for every mutant this attempt only knows about via the API.
        $coveringByMutantId = @{}
        $coveringPath = Join-Path $RunDir 'covering.json'
        if (Test-Path -LiteralPath $coveringPath) {
            try {
                $coveringRaw = Get-Content -LiteralPath $coveringPath -Raw | ConvertFrom-Json
                if ($null -ne $coveringRaw) {
                    foreach ($property in $coveringRaw.PSObject.Properties) {
                        $coveringByMutantId[[int]$property.Name] = [int[]]@($property.Value)
                    }
                }
            }
            catch {
                # A missing/corrupt covering.json must not abort resume -- it only means the
                # API-sourced rows below fall back to an empty CoveringTests list, same as today.
                $coveringByMutantId = @{}
            }
        }

        foreach ($apiRow in $apiRows) {
            $mutantId = [int]$apiRow.mutantId
            $coveringTests = @()
            if ($coveringByMutantId.ContainsKey($mutantId)) {
                $coveringTests = $coveringByMutantId[$mutantId]
            }

            $recorded[$mutantId] = [pscustomobject]@{
                Status        = $apiRow.status
                KillingTest   = $apiRow.killingTest
                DurationMs    = $apiRow.durationMs
                CoveringTests = $coveringTests
                Error         = $null
            }
        }
        return $recorded
    }

    $jsonlPath = Join-Path $RunDir 'results.jsonl'
    if (Test-Path -LiteralPath $jsonlPath) {
        foreach ($line in @(Get-Content -LiteralPath $jsonlPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $parsed = $line | ConvertFrom-Json
            }
            catch {
                # A partial/corrupt last line (plausible after a mid-write crash) is skipped:
                # that mutant is simply treated as not-yet-recorded and re-run.
                continue
            }

            $errorText = $null
            if ($parsed.PSObject.Properties.Name -contains 'Error') {
                $errorText = $parsed.Error
            }

            $recorded[[int]$parsed.Id] = [pscustomobject]@{
                Status        = $parsed.Status
                KillingTest   = $parsed.KillingTest
                DurationMs    = $parsed.DurationMs
                CoveringTests = @($parsed.CoveringTests)
                Error         = $errorText
            }
        }
    }

    return $recorded
}

# ---------------------------------------------------------------------------------------------
# T42 (§6.10.4): the SOAP test transport. With config testTransport 'soap', Invoke-MutMutantLoop
# hands over to Invoke-MutSoapMutantLoop, which batches consecutive mutants that share a covering
# set and runs each batch through the backend's Invoke-MutMutantBatch (one SOAP call per batch,
# the runner writes the API rows itself, so nothing is POSTed except a confirmed Timeout).
# Only the backend functions of §6.10.3 are called (guardrail 6).
# ---------------------------------------------------------------------------------------------
$script:SoapDefaultBatchSize = 50
$script:SoapMaxBatchBaselineSec = 120

function Add-MutSoapRow {
    <#
        .SYNOPSIS
        Private. Records one final mutant row: results.jsonl, the context's row table, and the
        consecutive-Error / consecutive-Timeout breakers (same limits as the cli loop). A breaker
        throws a LimitsExceeded ErrorRecord; the soap loop's outer catch attaches the rows.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Ctx,
        [Parameter(Mandatory = $true)]
        $Row
    )

    Write-MutResultsJsonLine -RunDir $Ctx.RunDir -Row $Row
    $Ctx.Rows[[int]$Row.Id] = $Row

    if ($Row.Status -eq 'Error') { $Ctx.ConsecutiveErrors++ } else { $Ctx.ConsecutiveErrors = 0 }
    if ($Row.Status -eq 'Timeout') { $Ctx.ConsecutiveTimeouts++ } else { $Ctx.ConsecutiveTimeouts = 0 }

    if ($Ctx.ConsecutiveErrors -ge $script:MaxConsecutiveErrors) {
        $message = "Invoke-MutMutantLoop: $($Ctx.ConsecutiveErrors) consecutive mutants ended in Error (last: mutant $($Row.Id): $($Row.Error)). A run whose mutants keep failing to produce real results is not producing a trustworthy score; aborting with a partial export rather than continuing."
        throw [System.Management.Automation.ErrorRecord]::new([System.Exception]::new($message), 'MutConsecutiveErrorsExceeded', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $null)
    }
    if ($Ctx.ConsecutiveTimeouts -ge $script:MaxConsecutiveTimeouts) {
        $message = "Invoke-MutMutantLoop: $($Ctx.ConsecutiveTimeouts) consecutive mutants ended in Timeout (last: mutant $($Row.Id)). Every mutant timing out points at the per-mutant budget or the environment, not at that many non-terminating mutants in a row; aborting with a partial export rather than continuing."
        throw [System.Management.Automation.ErrorRecord]::new([System.Exception]::new($message), 'MutConsecutiveTimeoutsExceeded', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $null)
    }
}

function New-MutSoapRow {
    <# Private. A results row in the cli loop's shape (Id, Status, KillingTest, DurationMs, CoveringTests; Error on Error rows). #>
    param(
        [Parameter(Mandatory = $true)]
        $Item,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        $KillingTest = $null,
        $DurationMs = $null,
        [string]$ErrorText = $null
    )

    if (($null -ne $KillingTest) -and [string]::IsNullOrEmpty([string]$KillingTest)) { $KillingTest = $null }
    $row = [pscustomobject]@{
        Id            = $Item.Mutant.id
        Status        = $Status
        KillingTest   = $KillingTest
        DurationMs    = $DurationMs
        CoveringTests = @($Item.Covering)
    }
    if ($Status -eq 'Error') {
        $row | Add-Member -NotePropertyName 'Error' -NotePropertyValue $ErrorText
    }
    return $row
}

function Clear-MutSoapActiveMutant {
    <# Private. PATCH activeMutantId = 0, required before any probe, reset or outage wait (F3b BLOCKER 1). #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [int]$MutantId = 0
    )

    Invoke-MutSoapApiRetry -Ctx $Ctx -MutantId $MutantId -Action {
        Invoke-MutApi -Env $Ctx.Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = $Ctx.RunNo } | Out-Null
    } | Out-Null
}

function Invoke-MutSoapApiRetry {
    <#
        .SYNOPSIS
        Private. Runs $Action; a throw (an API call failing mid-outage) waits for the environment
        and retries, at most $script:MaxOutageRetriesPerMutant times per mutant (shared counter in
        the context), as the cli body does. LimitsExceeded is always rethrown. After the retries
        are spent the last error propagates.
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] [int]$MutantId,
        [Parameter(Mandatory = $true)] [scriptblock]$Action
    )

    while ($true) {
        try {
            return (& $Action)
        }
        catch {
            $caught = $_
            if ($caught.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
                throw $caught
            }
            $used = 0
            if ($Ctx.OutageRetries.ContainsKey($MutantId)) { $used = [int]$Ctx.OutageRetries[$MutantId] }
            if ($used -ge $script:MaxOutageRetriesPerMutant) {
                throw $caught
            }
            $Ctx.OutageRetries[$MutantId] = $used + 1
            Invoke-MutSoapOutageWait -Ctx $Ctx -MutantId $MutantId -Reason $caught.Exception.Message
        }
    }
}

function Send-MutSoapTimeout {
    <#
        .SYNOPSIS
        Private. POSTs the Timeout verdict (so resume skips the mutant) and records its row. The
        verdict is already reached, so a failing POST waits for the environment and retries the
        POST itself (bounded at 10 attempts); it never turns the verdict into Error. An existing
        API row (the hook wrote one meanwhile) stands instead.
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] $Item
    )

    $id = [int]$Item.Mutant.id
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $existing = Get-MutSoapExistingRow -Ctx $Ctx -MutantId $id
            if ($null -ne $existing) {
                Add-MutSoapApiRow -Ctx $Ctx -Item $Item -ApiRow $existing
                return
            }
            Invoke-MutApi -Env $Ctx.Env -Method 'POST' -Path 'mutantResults' -Body @{ runNo = $Ctx.RunNo; mutantId = $id; status = 'Timeout' } | Out-Null
            break
        }
        catch {
            $caught = $_
            if ($caught.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
                throw $caught
            }
            $text = ''
            if ($caught.ErrorDetails -and $caught.ErrorDetails.Message) { $text = $caught.ErrorDetails.Message }
            if (-not $text) { $text = $caught.Exception.Message }
            if ($text -match 'EntityWithSameKeyExists') { break }
            if ($attempt -ge 10) { throw $caught }
            Invoke-MutSoapOutageWait -Ctx $Ctx -MutantId $id -Reason $text
        }
    }
    Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status 'Timeout')
}

function Invoke-MutSoapOutageWait {
    <# Private. Wait-MutOutageRecovery, keeping the refreshed environment handle in the context. #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] [int]$MutantId,
        [Parameter(Mandatory = $true)] [string]$Reason
    )

    # A runner from the interrupted call may still be alive: the orphan sweep must run before the
    # next batch (§6.10.4 step 1, §6.10.5).
    $Ctx.SweepPending = $true
    $Ctx.Env = Wait-MutOutageRecovery -Env $Ctx.Env -Config $Ctx.Config -MutantId $MutantId -RunNo $Ctx.RunNo -Reason $Reason
}

function Invoke-MutSoapStopFailedRecovery {
    <#
        .SYNOPSIS
        Private. A runner stop that was not confirmed (RunnerStopFailed, or an orphan whose stop
        is unconfirmed): PATCH 0, then Reset-MutEnvironment under the §6.5.6 recovery cap. A
        reset that returns gives its slot back; a failed reset keeps it spent and waits for the
        environment. A confirmed stop never reaches here, so it spends no slot.
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] [int]$MutantId,
        [Parameter(Mandatory = $true)] [string]$Why
    )

    Clear-MutSoapActiveMutant -Ctx $Ctx -MutantId $MutantId
    Request-MutEnvironmentRecoveryBudget -MutantId $MutantId -Context $Why
    $resetFailure = $null
    try {
        Reset-MutEnvironment -Env $Ctx.Env -Config $Ctx.Config | Out-Null
        $script:MutEnvironmentRecoveryCount--
        Start-MutPostResetSettle
    }
    catch {
        $resetFailure = $_.Exception.Message
    }
    if ($resetFailure) {
        # Sets Ctx.SweepPending: the sweep runs before the next batch.
        Invoke-MutSoapOutageWait -Ctx $Ctx -MutantId $MutantId -Reason "the environment reset after an unconfirmed runner stop failed: $resetFailure"
        return $false
    }
    return $true
}

function Invoke-MutSoapOrphanSweep {
    <#
        .SYNOPSIS
        Private. §6.10.4 step 1: stop every unfinished runner row (its covering set is unknown,
        so the health codeunit comes from testApp.testCodeunits), then PATCH activeMutantId = 0.
        Finished rows are left (the backend has no call to delete one; they are keyed by a unique
        BatchId, so they are harmless). An unconfirmed stop goes to the stop-failed recovery.
    #>
    param([Parameter(Mandatory = $true)] $Ctx)

    # Cleared first: a sweep that itself waits out an outage sets it again, and the caller loops.
    $Ctx.SweepPending = $false
    try {
        $state = Get-MutRunnerState -Env $Ctx.Env
        $health = ($Ctx.TestCodeunits | ForEach-Object { [string]$_ }) -join '|'
        foreach ($row in @($state.Rows)) {
            if ($row.Finished) { continue }
            $stop = Stop-MutRunnerBatch -Env $Ctx.Env -BatchId $row.BatchId -CodeunitIds $health
            if (-not $stop.Confirmed) {
                $null = Invoke-MutSoapStopFailedRecovery -Ctx $Ctx -MutantId 0 -Why "an orphaned runner (batch $($row.BatchId)) could not be confirmed stopped"
            }
        }
        Clear-MutSoapActiveMutant -Ctx $Ctx
    }
    catch {
        # An interrupted sweep has not finished its job.
        $Ctx.SweepPending = $true
        throw
    }
}

function Invoke-MutSoapBatchCall {
    <#
        .SYNOPSIS
        Private. One Invoke-MutMutantBatch call for $Items (one covering set), with the outage
        wait: any throw other than RunnerStopFailed waits for the environment, re-runs the orphan
        sweep (the failed batch's runner may still be alive), and retries, up to
        $script:MaxOutageRetriesPerMutant times.
        .OUTPUTS
        @{ Kind = 'Result'; Res } | @{ Kind = 'StopFailed'; MutantId; Message } | @{ Kind = 'Error'; Message }
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] [object[]]$Items
    )

    $ids = [int[]]@($Items | ForEach-Object { [int]$_.Mutant.id })
    $head = $Items[0]
    $retries = 0
    while ($true) {
        try {
            # Before EVERY batch while a sweep is pending (after any outage wait, a failed reset,
            # or a call that ended in an outage): a runner may still be alive (S5).
            while ($Ctx.SweepPending) {
                Invoke-MutSoapOrphanSweep -Ctx $Ctx
            }
            $res = Invoke-MutMutantBatch -Env $Ctx.Env -CodeunitIds $head.Covering -MutantIds $ids -RunNo $Ctx.RunNo -MutantBudgetSec $head.Budget
            return [pscustomobject]@{ Kind = 'Result'; Res = $res }
        }
        catch {
            $caught = $_
            if ($caught.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
                throw $caught
            }
            $text = $caught.Exception.Message
            if ($text -like 'RunnerStopFailed*') {
                $culprit = $ids[0]
                if ($text -match '\(mutant (\d+)\)') {
                    $parsed = [int]$Matches[1]
                    if ($ids -contains $parsed) { $culprit = $parsed }
                }
                return [pscustomobject]@{ Kind = 'StopFailed'; MutantId = $culprit; Message = $text }
            }
            # The call ended in an outage: its runner may still be alive, so sweep before the next batch.
            $Ctx.SweepPending = $true
            if ($retries -ge $script:MaxOutageRetriesPerMutant) {
                return [pscustomobject]@{ Kind = 'Error'; Message = $text }
            }
            $retries++
            Invoke-MutSoapOutageWait -Ctx $Ctx -MutantId ([int]$head.Mutant.id) -Reason $text
        }
    }
}

function Get-MutSoapExistingRow {
    <# Private. GET mutantResults for (RunNo, MutantId); the API row or $null. #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] [int]$MutantId
    )

    $path = 'mutantResults?$filter=runNo eq {0} and mutantId eq {1}' -f $Ctx.RunNo, $MutantId
    $response = Invoke-MutSoapApiRetry -Ctx $Ctx -MutantId $MutantId -Action { Invoke-MutApi -Env $Ctx.Env -Method 'GET' -Path $path }
    if (($response) -and (Test-MutHasProperty $response 'value') -and (@($response.value).Count -gt 0)) {
        return @($response.value)[0]
    }
    return $null
}

function Add-MutSoapApiRow {
    <# Private. Records an existing API row (written by the runner or the hook) as the mutant's result. #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] $Item,
        [Parameter(Mandatory = $true)] $ApiRow
    )

    $killing = $null
    if (Test-MutHasProperty $ApiRow 'killingTest') { $killing = $ApiRow.killingTest }
    $duration = $null
    if (Test-MutHasProperty $ApiRow 'durationMs') { $duration = $ApiRow.durationMs }
    Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status ([string]$ApiRow.status) -KillingTest $killing -DurationMs $duration)
}

function Get-MutSoapResultFor {
    <# Private. The Results entry of one mutant id, or $null. #>
    param($Res, [int]$MutantId)

    $match = @(@($Res.Results) | Where-Object { $null -ne $_ -and [int]$_.MutantId -eq $MutantId })
    if ($match.Count -gt 0) { return $match[0] }
    return $null
}

function Test-MutSoapIsId {
    <# Private. True when $Value (a nullable id from a batch result) equals $Id. #>
    param($Value, [int]$Id)

    return ($null -ne $Value) -and ([int]$Value -eq $Id)
}

function Resolve-MutSoapHang {
    <#
        .SYNOPSIS
        Private. §6.10.4 step 4 for one mutant that hung: an existing API row stands (no re-run);
        otherwise re-run it alone (the run-14 confirmation), and POST Timeout only when it hangs
        again. A re-run that finishes stands as its own result; a re-run that returns Empty goes
        through step 3 (Resolve-MutSoapAlone, which never re-enters this function).
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] $Item
    )

    $id = [int]$Item.Mutant.id
    $existing = Get-MutSoapExistingRow -Ctx $Ctx -MutantId $id
    if ($null -ne $existing) {
        Add-MutSoapApiRow -Ctx $Ctx -Item $Item -ApiRow $existing
        return
    }

    Write-Warning "Invoke-MutMutantLoop: mutant $id -- hung the runner; re-running it alone once to confirm (a non-terminating mutant hangs every time, an environment hiccup does not)."
    $call = Invoke-MutSoapBatchCall -Ctx $Ctx -Items @($Item)
    if ($call.Kind -eq 'Error') {
        Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status 'Error' -ErrorText $call.Message)
        return
    }
    if ($call.Kind -eq 'StopFailed') {
        # The re-run hung and its stop was not confirmed: the confirmation is in, the verdict is Timeout.
        $null = Invoke-MutSoapStopFailedRecovery -Ctx $Ctx -MutantId $id -Why "the runner of mutant $id could not be confirmed stopped"
        Send-MutSoapTimeout -Ctx $Ctx -Item $Item
        return
    }

    $res = $call.Res
    $r = Get-MutSoapResultFor -Res $res -MutantId $id
    if (($null -ne $r) -and ($r.Status -eq 'Killed' -or $r.Status -eq 'Survived')) {
        Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status $r.Status -KillingTest $r.KillingTest -DurationMs $r.DurationMs)
        return
    }
    if (Test-MutSoapIsId $res.HungMutantId $id) {
        Send-MutSoapTimeout -Ctx $Ctx -Item $Item
        return
    }
    if ((Test-MutHasProperty $res 'Fault') -and $res.Fault) {
        Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status 'Error' -ErrorText "the runner faulted: $($res.Fault)")
        return
    }

    # Empty (or no result): step 3, environment check, one retry, then Error.
    Resolve-MutSoapAlone -Ctx $Ctx -Item $Item -Reason 'Empty' -FromHang
}

function Resolve-MutSoapAlone {
    <#
        .SYNOPSIS
        Private. Re-runs one mutant alone: after an Empty entry (§6.10.4 step 3, with
        Confirm-MutEnvironmentServing first, PATCH 0 before it) or as the culprit of a fault
        (step 5, under the per-mutant rules: outage wait and re-runs live in
        Invoke-MutSoapBatchCall). A result stands; a hang goes through Resolve-MutSoapHang
        (with -FromHang, the caller already is the hang handling: a second hang is the Timeout);
        anything else is Error (never POSTed).
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] $Item,
        [Parameter(Mandatory = $true)] [ValidateSet('Empty', 'Fault')] [string]$Reason,
        [switch]$FromHang
    )

    $id = [int]$Item.Mutant.id
    if ($Reason -eq 'Empty') {
        Clear-MutSoapActiveMutant -Ctx $Ctx -MutantId $id
        $Ctx.Env = Invoke-MutSoapApiRetry -Ctx $Ctx -MutantId $id -Action { Confirm-MutEnvironmentServing -Env $Ctx.Env -Config $Ctx.Config -MutantId $id }
    }

    $call = Invoke-MutSoapBatchCall -Ctx $Ctx -Items @($Item)
    if ($call.Kind -eq 'Error') {
        Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status 'Error' -ErrorText $call.Message)
        return
    }
    if ($call.Kind -eq 'StopFailed') {
        $null = Invoke-MutSoapStopFailedRecovery -Ctx $Ctx -MutantId $id -Why "the runner of mutant $id could not be confirmed stopped"
        Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status 'Error' -ErrorText $call.Message)
        return
    }

    $res = $call.Res
    $r = Get-MutSoapResultFor -Res $res -MutantId $id
    if (($null -ne $r) -and ($r.Status -eq 'Killed' -or $r.Status -eq 'Survived')) {
        Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status $r.Status -KillingTest $r.KillingTest -DurationMs $r.DurationMs)
        return
    }
    if (Test-MutSoapIsId $res.HungMutantId $id) {
        if ($FromHang) {
            Send-MutSoapTimeout -Ctx $Ctx -Item $Item
        }
        else {
            Resolve-MutSoapHang -Ctx $Ctx -Item $Item
        }
        return
    }
    $why = 'no tests discovered'
    if ((Test-MutHasProperty $res 'Fault') -and $res.Fault) { $why = "the runner faulted: $($res.Fault)" }
    Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status 'Error' -ErrorText $why)
}

function Invoke-MutSoapSafely {
    <#
        .SYNOPSIS
        Private. Runs one per-mutant resolution; an unexpected throw (anything but LimitsExceeded)
        becomes that mutant's Error row, as the cli loop's per-mutant catch does.
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] $Item,
        [Parameter(Mandatory = $true)] [scriptblock]$Action
    )

    try {
        & $Action
    }
    catch {
        $caught = $_
        if ($caught.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
            throw $caught
        }
        if (-not $Ctx.Rows.ContainsKey([int]$Item.Mutant.id)) {
            Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $Item -Status 'Error' -ErrorText $caught.Exception.Message)
        }
    }
}

function Invoke-MutSoapProcessBatch {
    <#
        .SYNOPSIS
        Private. Runs one batch and turns its outcome into rows (§6.10.4 steps 3-5).
        .OUTPUTS
        The items that were not processed and must go back to the front of the queue (the mutants
        after a hung/fault culprit, or after a stop-failed or exhausted batch).
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)] [object[]]$Items
    )

    $call = Invoke-MutSoapBatchCall -Ctx $Ctx -Items $Items
    $head = $Items[0]

    if ($call.Kind -eq 'Error') {
        Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $head -Status 'Error' -ErrorText $call.Message)
        return @($Items | Select-Object -Skip 1)
    }

    if ($call.Kind -eq 'StopFailed') {
        $culprit = [int]$call.MutantId
        $resetOk = Invoke-MutSoapStopFailedRecovery -Ctx $Ctx -MutantId $culprit -Why "the runner of a batch (mutant $culprit) could not be confirmed stopped"
        $remainder = @()
        foreach ($item in $Items) {
            $id = [int]$item.Mutant.id
            $existing = Get-MutSoapExistingRow -Ctx $Ctx -MutantId $id
            if ($null -ne $existing) {
                Add-MutSoapApiRow -Ctx $Ctx -Item $item -ApiRow $existing
            }
            elseif ($id -eq $culprit) {
                # §6.10.4 step 5 (as §6.5.6 for the CLI): after a successful reset the culprit goes
                # through the hang handling (existing row, else one re-run alone, a second hang is
                # Timeout); after a failed reset it is Timeout, POSTed now that the environment
                # serves again, and not re-run.
                $reset = $resetOk
                Invoke-MutSoapSafely -Ctx $Ctx -Item $item -Action {
                    if ($reset) {
                        Resolve-MutSoapHang -Ctx $Ctx -Item $item
                    }
                    else {
                        Send-MutSoapTimeout -Ctx $Ctx -Item $item
                    }
                }
            }
            else {
                $remainder += $item
            }
        }
        return $remainder
    }

    $res = $call.Res
    $culpritId = $null
    $culpritKind = $null
    if ((Test-MutHasProperty $res 'HungMutantId') -and ($null -ne $res.HungMutantId)) {
        $culpritId = [int]$res.HungMutantId
        $culpritKind = 'Hang'
    }
    elseif ((Test-MutHasProperty $res 'FaultMutantId') -and ($null -ne $res.FaultMutantId)) {
        $culpritId = [int]$res.FaultMutantId
        $culpritKind = 'Fault'
    }

    $remainder = @()
    $afterCulprit = $false
    foreach ($item in $Items) {
        $id = [int]$item.Mutant.id
        $r = Get-MutSoapResultFor -Res $res -MutantId $id
        $hasRow = ($null -ne $r) -and ($r.Status -eq 'Killed' -or $r.Status -eq 'Survived')

        if ($afterCulprit) {
            if ($hasRow) {
                Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $item -Status $r.Status -KillingTest $r.KillingTest -DurationMs $r.DurationMs)
            }
            else {
                $remainder += $item
            }
            continue
        }

        if (($null -ne $culpritId) -and ($id -eq $culpritId)) {
            $afterCulprit = $true
            $kind = $culpritKind
            Invoke-MutSoapSafely -Ctx $Ctx -Item $item -Action {
                if ($kind -eq 'Hang') {
                    Resolve-MutSoapHang -Ctx $Ctx -Item $item
                }
                else {
                    Resolve-MutSoapAlone -Ctx $Ctx -Item $item -Reason 'Fault'
                }
            }
            continue
        }

        if ($hasRow) {
            Add-MutSoapRow -Ctx $Ctx -Row (New-MutSoapRow -Item $item -Status $r.Status -KillingTest $r.KillingTest -DurationMs $r.DurationMs)
            continue
        }

        # Empty entry, or (when the call did not return a value) a mutant with neither a row nor a
        # hung/fault id: the CLI's empty result.
        Invoke-MutSoapSafely -Ctx $Ctx -Item $item -Action { Resolve-MutSoapAlone -Ctx $Ctx -Item $item -Reason 'Empty' }
    }

    return $remainder
}

function Invoke-MutSoapMutantLoop {
    <#
        .SYNOPSIS
        Private. The mutant loop for testTransport 'soap' (§6.10.4). Called by Invoke-MutMutantLoop
        after its per-run counters are reset. Same parameters and return shape as the cli loop.

        Order: Test-MutSoapRunner (false throws), orphan sweep, recorded results (resume), then
        batches of consecutive pending mutants with an identical covering set, at most
        soap.batchSize each and at most 120 s of covering-set baseline duration in sum (a single
        mutant always forms a batch). MutantBudgetSec is the §6.5.6 per-mutant budget
        (Get-MutTimeoutBudget) for the covering set. After every outage wait the orphan sweep runs
        again before the next batch (Invoke-MutSoapBatchCall).
    #>
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] $Env,
        [Parameter(Mandatory = $true)] [object[]]$Mutants,
        [Parameter(Mandatory = $true)] $Baseline,
        [Parameter(Mandatory = $true)] $Coverage,
        [Parameter(Mandatory = $true)] $References,
        [Parameter(Mandatory = $true)] [int]$RunNo,
        [Parameter(Mandatory = $true)] [string]$RunDir
    )

    $testCodeunits = [int[]]@($Config.testApp.testCodeunits)
    $batchSize = $script:SoapDefaultBatchSize
    if ((Test-MutHasProperty $Config 'soap') -and (Test-MutHasProperty $Config.soap 'batchSize') -and ($null -ne $Config.soap.batchSize)) {
        $batchSize = [int]$Config.soap.batchSize
    }

    $ctx = @{
        Env                 = $Env
        Config              = $Config
        RunNo               = $RunNo
        RunDir              = $RunDir
        TestCodeunits       = $testCodeunits
        Rows                = @{}
        ConsecutiveErrors   = 0
        ConsecutiveTimeouts = 0
        SweepPending        = $false
        OutageRetries       = @{}
    }

    try {
        if (-not (Test-MutSoapRunner -Env $ctx.Env)) {
            throw 'Invoke-MutMutantLoop: testTransport is soap but the MUTRunner service does not answer (Mutation Core older than 1.1.0.0, or the service is missing).'
        }

        # §6.10.4 step 1: orphans before anything else, before resume data is read.
        $sweepRetries = 0
        while ($true) {
            try {
                Invoke-MutSoapOrphanSweep -Ctx $ctx
                break
            }
            catch {
                $caught = $_
                if (($caught.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) -or ($sweepRetries -ge $script:MaxOutageRetriesPerMutant)) {
                    throw $caught
                }
                $sweepRetries++
                Invoke-MutSoapOutageWait -Ctx $ctx -MutantId 0 -Reason $caught.Exception.Message
            }
        }

        $recordedResults = Get-MutRecordedResultsForRun -Env $ctx.Env -RunNo $RunNo -RunDir $RunDir

        $queue = [System.Collections.Generic.List[object]]::new()
        foreach ($mutant in $Mutants) {
            $mutantId = [int]$mutant.id
            if ($recordedResults.ContainsKey($mutantId)) {
                $prior = $recordedResults[$mutantId]
                $resumedRow = [pscustomobject]@{
                    Id            = $mutant.id
                    Status        = $prior.Status
                    KillingTest   = $prior.KillingTest
                    DurationMs    = $prior.DurationMs
                    CoveringTests = @($prior.CoveringTests)
                }
                if ($prior.Status -eq 'Error') {
                    $resumedRow | Add-Member -NotePropertyName 'Error' -NotePropertyValue $prior.Error
                }
                $ctx.Rows[$mutantId] = $resumedRow
                continue
            }

            $covering = [int[]]@()
            $coverError = $null
            try {
                $found = Get-MutCoveringTests -Mutant $mutant -Coverage $Coverage -References $References -TestCodeunits $testCodeunits
                $covering = [int[]]@($found)
            }
            catch {
                $coverError = $_.Exception.Message
            }

            $budget = 0
            $baselineSec = 0.0
            if ($covering.Count -gt 0) {
                $budget = Get-MutTimeoutBudget -Config $Config -CoveringTests $covering -Baseline $Baseline
                foreach ($codeunitId in $covering) {
                    if ($Baseline.DurationsByCodeunit.ContainsKey("$codeunitId")) {
                        $baselineSec += [double]$Baseline.DurationsByCodeunit["$codeunitId"] / 1000.0
                    }
                }
            }
            $queue.Add([pscustomobject]@{
                    Mutant      = $mutant
                    Covering    = $covering
                    Key         = ($covering | Sort-Object | ForEach-Object { [string]$_ }) -join '|'
                    Budget      = $budget
                    BaselineSec = $baselineSec
                    CoverError  = $coverError
                })
        }

        while ($queue.Count -gt 0) {
            $head = $queue[0]
            $queue.RemoveAt(0)

            if ($head.CoverError) {
                Add-MutSoapRow -Ctx $ctx -Row (New-MutSoapRow -Item $head -Status 'Error' -ErrorText $head.CoverError)
                continue
            }
            if ($head.Covering.Count -eq 0) {
                Add-MutSoapRow -Ctx $ctx -Row (New-MutSoapRow -Item $head -Status 'Uncovered')
                continue
            }

            $batch = @($head)
            $sumSec = [double]$head.BaselineSec
            while (($queue.Count -gt 0) -and ($batch.Count -lt $batchSize)) {
                $next = $queue[0]
                if ($next.Key -ne $head.Key) { break }
                if (($sumSec + [double]$next.BaselineSec) -gt $script:SoapMaxBatchBaselineSec) { break }
                $sumSec += [double]$next.BaselineSec
                $batch += $next
                $queue.RemoveAt(0)
            }

            $remainder = @()
            try {
                $remainder = @(Invoke-MutSoapProcessBatch -Ctx $ctx -Items $batch)
            }
            catch {
                $caught = $_
                if ($caught.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
                    throw $caught
                }
                if (-not $ctx.Rows.ContainsKey([int]$head.Mutant.id)) {
                    Add-MutSoapRow -Ctx $ctx -Row (New-MutSoapRow -Item $head -Status 'Error' -ErrorText $caught.Exception.Message)
                }
                $remainder = @($batch | Select-Object -Skip 1 | Where-Object { -not $ctx.Rows.ContainsKey([int]$_.Mutant.id) })
            }
            if ($remainder.Count -gt 0) {
                $queue.InsertRange(0, [object[]]$remainder)
            }
        }
    }
    catch {
        $caught = $_
        if ($caught.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
            $partial = @($ctx.Rows.Values | Sort-Object -Property Id)
            throw [System.Management.Automation.ErrorRecord]::new($caught.Exception, $caught.FullyQualifiedErrorId, [System.Management.Automation.ErrorCategory]::LimitsExceeded, $partial)
        }
        throw $caught
    }

    $rows = @($ctx.Rows.Values | Sort-Object -Property Id)
    $errorCount = @($rows | Where-Object { $_.Status -eq 'Error' }).Count
    if ($errorCount -gt 0) {
        Write-Warning "Invoke-MutMutantLoop: $errorCount of $(@($Mutants).Count) mutant(s) ended in Error"
    }
    if ($script:MutOutageWaitCount -gt 0) {
        Write-Warning "Invoke-MutMutantLoop: waited out $($script:MutOutageWaitCount) environment outage(s) this run"
    }
    if ($script:MutEnvironmentRecoveryCount -gt 0) {
        Write-Warning "Invoke-MutMutantLoop: environment recovered $($script:MutEnvironmentRecoveryCount) of $($script:MaxEnvironmentRecoveries) allowed time(s) this run"
    }
    return , $rows
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

        FIX (M3, run 3 crash -- see .superpowers/sdd/tasks.json/progress.md): a mid-run crash
        (145 of 157 mutants had completed) previously forced a brand-new run number, because
        re-invoking this loop for the same RunNo re-POSTed every mutant unconditionally and hit
        the `MUT Mutant Result` primary key (Run No., Mutant Id), §6.1.2. Three changes make
        re-invoking this loop for the same RunNo/RunDir resumable and safe:
        1. `Get-MutRecordedResultsForRun` (above) is called once, up front, to find mutants this
           RunNo already has a recorded result for; those are skipped entirely (no covering-test
           lookup, no PATCH, no test run, no POST) and reported from the recorded data instead,
           so the returned rows are still complete for every mutant.
        2. The `Survived` POST now checks for an existing `(runNo, mutantId)` row first, exactly
           like the `Killed` POST already did (the duplicate-key try/catch below is kept too, as
           a safety net for a genuine race, e.g. the table's own OnAfterTestMethodRun hook,
           §6.1.4, racing this code).
        3. Each mutant's entire body (from covering-test selection through the API calls) is
           wrapped in try/catch: an unexpected error of any kind is recorded as `Status = 'Error'`
           with the exception message, `activeMutantId` is still best-effort reset to 0, and the
           loop moves on to the next mutant rather than aborting the run. The count of mutants
           that ended in `Error` is reported via Write-Warning when the loop finishes.
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

    # FIX (F3, run 8 -- finding I6): reset per run invocation -- see Confirm-MutEnvironmentServing.
    $script:MutEnvironmentRecoveryCount = 0
    # FIX (503 bisect): per-run outage-wait count (reported at the end) and the circuit breaker's
    # running count of consecutive Error rows -- see the constants at the top of this module.
    $script:MutOutageWaitCount = 0
    $consecutiveErrors = 0
    $consecutiveTimeouts = 0

    $rows = @()

    # FIX (M3): resume support -- see this function's own FIX note above and
    # Get-MutRecordedResultsForRun's doc comment. Fetched once per loop invocation, not per
    # mutant.
    # T42 (§6.10.4): the one branch point. With testTransport 'soap' the per-mutant loop below is
    # replaced wholesale by the batch loop (Invoke-MutSoapMutantLoop); 'cli' (the default, and an
    # absent key) runs everything below exactly as before.
    if ((Test-MutHasProperty $Config 'testTransport') -and ([string]$Config.testTransport -eq 'soap')) {
        $soapRows = Invoke-MutSoapMutantLoop -Config $Config -Env $Env -Mutants $orderedMutants -Baseline $Baseline `
            -Coverage $Coverage -References $References -RunNo $RunNo -RunDir $RunDir
        return , $soapRows
    }

    $recordedResults = Get-MutRecordedResultsForRun -Env $Env -RunNo $RunNo -RunDir $RunDir

    foreach ($mutant in $orderedMutants) {
        $mutantId = [int]$mutant.id

        if ($recordedResults.ContainsKey($mutantId)) {
            $prior = $recordedResults[$mutantId]
            $resumedRow = [pscustomobject]@{
                Id            = $mutant.id
                Status        = $prior.Status
                KillingTest   = $prior.KillingTest
                DurationMs    = $prior.DurationMs
                CoveringTests = @($prior.CoveringTests)
            }
            if ($prior.Status -eq 'Error') {
                $resumedRow | Add-Member -NotePropertyName 'Error' -NotePropertyValue $prior.Error
            }
            $rows += $resumedRow
            continue
        }

        # FIX (M3): every remaining mutant's whole body is now wrapped so an unexpected error
        # (from covering-test selection, a PATCH, or Invoke-MutTestsWithBudget itself throwing
        # rather than returning an ErrorMessage) records Status 'Error' and continues, instead of
        # aborting the entire loop -- see this function's own FIX note above.
        # FIX (503 bisect): each mutant runs inside a retry loop. A thrown call (typically an API
        # call failing mid-outage) waits for the environment to serve again and re-runs the SAME
        # mutant, up to $script:MaxOutageRetriesPerMutant times, instead of recording Error at
        # once. `continue` inside this do/while (the Uncovered path, and the retry below) jumps to
        # the while condition, so it still ends this mutant when $retryMutant is false.
        $outageRetries = 0
        $timeoutConfirmationDone = $false
        do {
            $retryMutant = $false
            $timeoutRecoveryFailure = $null
            $covering = @()
            try {
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
                    $attemptStartSec = Get-MutClockSeconds
                    $outcome = Invoke-MutTestsWithBudget -Env $Env -Targets $targets -TimeoutSec $innerTimeoutSec -BudgetSec $budget -BackendModulePath $BackendModulePath
                    $attemptElapsedSec = (Get-MutClockSeconds) - $attemptStartSec
                    $isEmptyResult = (-not $outcome.TimedOut) -and (-not $outcome.ErrorMessage) -and ($null -ne $outcome.Result) -and
                        (([int]$outcome.Result.Passed + [int]$outcome.Result.Failed) -eq 0)

                    # FIX (run 10): an empty result that took (nearly) the whole timeout handed to the
                    # backend is not "no tests" -- it is the client wait expiring on a job that is
                    # still running in BC, i.e. a non-terminating mutant. Treat it as TimedOut, so it
                    # is never retried against the still-looping session and the Timeout branch below
                    # resets the environment, which is what kills that session.
                    if ($isEmptyResult -and ($attemptElapsedSec -ge ($script:ClientWaitExpiredFraction * $innerTimeoutSec))) {
                        Write-Warning ("Invoke-MutMutantLoop: mutant {0} -- the test run returned zero tests after {1:N0} s of a {2} s client wait; treating it as a Timeout (a job still running in the environment), not an empty result." -f $mutant.id, $attemptElapsedSec, $innerTimeoutSec)
                        $outcome = [pscustomobject]@{ TimedOut = $true; Result = $null; ErrorMessage = $null; ForcedKill = $false }
                        $isEmptyResult = $false
                    }
                    # FIX (F3b IMPORTANT 1): a dead environment does not only present as an empty
                    # result -- the reviewer reproduced it presenting as a job ErrorMessage too (10/10
                    # mutants, zero environment checks, garbage score, no abort). Treat both the same
                    # way before consuming the retry; TimedOut is deliberately excluded here -- it has
                    # its own handling (Reset-MutEnvironment) below and is never retried in this loop.
                    $isRecoverableOutcome = $isEmptyResult -or ((-not $outcome.TimedOut) -and [bool]$outcome.ErrorMessage)

                    if ($isRecoverableOutcome -and $attempt -lt $maxAttempts) {
                        # FIX (F3b BLOCKER 1): deactivate before Confirm-MutEnvironmentServing's real
                        # probe test job runs -- Mutation Core records a Killed row for ANY failing
                        # test while a mutant is active, without checking it covers that mutant, so
                        # probing with THIS mutant still active could misattribute a false kill to it.
                        # Re-activate before the retry (also closes V9: the mutant was previously left
                        # deactivated across the retry, observed PATCH sequence `42, 0`).
                        Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = $RunNo } | Out-Null
                        # This can throw (recovery cap exceeded, or the probe itself failing this
                        # attempt); either way that propagates out of this try, through this mutant's
                        # own catch below, and is handled there. On success, keep using the (possibly
                        # refreshed) handle it returns for the rest of this run (F3b Minors).
                        $Env = Confirm-MutEnvironmentServing -Env $Env -Config $Config -MutantId $mutant.id
                        Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = $mutant.id; currentRunNo = $RunNo } | Out-Null
                    }
                } while ($isRecoverableOutcome -and $attempt -lt $maxAttempts)

                $status = $null
                $killingTest = $null
                $durationMs = $null
                $errorMessage = $null

                if ($outcome.TimedOut) {
                    # FIX (F3b BLOCKER 1): same hazard as above -- Reset-MutEnvironment's own probe
                    # (when given -Config) runs a real test job, and this mutant is still active.
                    Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = $RunNo } | Out-Null
                    # FIX (F3b IMPORTANT 1): count a timeout-triggered reset against the same
                    # recovery cap -- the reviewer reproduced 5/5 Timeouts with zero environment
                    # checks and each one resetting uncounted; a dead environment must not be allowed
                    # to reset forever just because it happens to present as a timeout.
                    # FIX (run 11): stop just the runaway session first; the full reset below is
                    # now only the fallback.
                    if (-not (Stop-MutRunawayTestSessions -Env $Env -MutantId $mutant.id)) {
                        Request-MutEnvironmentRecoveryBudget -MutantId $mutant.id -Context 'a test run timed out'
                        try {
                            Reset-MutEnvironment -Env $Env -Config $Config | Out-Null
                            # FIX (run 10): the reset returned, so the environment was stopped,
                            # started and settled (its probe passed). The Timeout was this mutant's
                            # own verdict -- a non-terminating mutant is a detected one -- not a lost
                            # environment, so give the slot back. A reset that throws keeps it spent,
                            # so a dead environment presenting as timeouts still reaches the cap; the
                            # consecutive-Timeout breaker bounds the rest.
                            $script:MutEnvironmentRecoveryCount--
                            Start-MutPostResetSettle
                        }
                        catch {
                            # FIX (run 11): the verdict was already reached, so a failed reset must
                            # not re-run this mutant (run 11 re-ran 4371 -- another endless loop and
                            # another reset). Record Timeout, and wait for the environment once the
                            # row is written (see $timeoutRecoveryFailure below).
                            $timeoutRecoveryFailure = $_.Exception.Message
                        }
                    }

                    # FIX (run 14, 2026-10-01): confirm a Timeout before trusting it. Timeout counts as
                    # detected in the score, so an environment hiccup that makes an ordinary mutant
                    # run past its budget is a false kill: run 14's mutant 159 (`Count() > 0` ->
                    # `>= 0`, which survived in 186 ms in run 13) hit its wall-clock budget with no
                    # runaway session behind it. A non-terminating mutant times out every time; a
                    # hiccup does not. So re-run the mutant once -- after waiting for the
                    # environment if the reset failed -- and record Timeout only if it times out
                    # again; otherwise the re-run's own result stands.
                    if (-not $timeoutConfirmationDone) {
                        if ($timeoutRecoveryFailure) {
                            $Env = Wait-MutOutageRecovery -Env $Env -Config $Config -MutantId $mutant.id -RunNo $RunNo -Reason "the environment reset after this mutant's Timeout failed: $timeoutRecoveryFailure"
                            $timeoutRecoveryFailure = $null
                        }
                        $timeoutConfirmationDone = $true
                        Write-Warning "Invoke-MutMutantLoop: mutant $($mutant.id) -- timed out; re-running it once to confirm (a non-terminating mutant times out every time, an environment hiccup does not)."
                        $retryMutant = $true
                        continue
                    }
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
                        # ($existing -and ...) short-circuits: a bare $null response (e.g. a test
                        # double that doesn't shape its GET responses like the real API) must not
                        # throw a PropertyNotFoundException under Set-StrictMode when read as
                        # $existing.value.
                        $hasExistingKilledRow = ($existing) -and (@($existing.value).Count -gt 0)

                        if (-not $hasExistingKilledRow) {
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
                        # FIX (M3): now mirrors the Killed branch above -- GET first, only POST when no
                        # row exists yet -- instead of always POSTing unconditionally. A run resumed at
                        # this step for the same RunNo would previously reach here again (a step earlier
                        # in the pipeline was re-run after a crash, or, live, this loop was re-run to pick
                        # up a fix) and re-process a mutant that already has a Survived row from the
                        # earlier attempt; the upfront resume check (Get-MutRecordedResultsForRun, top of
                        # this function) now normally skips such a mutant entirely, but this GET-before-
                        # POST check is kept as its own, independent guard (e.g. the jsonl fallback missed
                        # a row the API already has). The try/catch around the POST is ALSO kept as a
                        # last-resort safety net for a genuine race between the GET and the POST -- a
                        # duplicate-key failure is swallowed as an idempotent no-op, while any other POST
                        # failure still propagates (caught by this mutant's own try/catch wrapper, below).
                        $survivedFilterPath = 'mutantResults?$filter=runNo eq {0} and mutantId eq {1}' -f $RunNo, $mutant.id
                        $existingSurvived = Invoke-MutApi -Env $Env -Method 'GET' -Path $survivedFilterPath
                        # See the Killed branch's identical null-safety note above.
                        $hasExistingSurvivedRow = ($existingSurvived) -and (@($existingSurvived.value).Count -gt 0)

                        if (-not $hasExistingSurvivedRow) {
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

                # FIX (run 11): the Timeout's fallback reset failed. The row is written, so this
                # mutant's verdict is kept even if the wait below gives up and aborts the run
                # (its LimitsExceeded reaches the catch below, which attaches $rows).
                if ($timeoutRecoveryFailure) {
                    $Env = Wait-MutOutageRecovery -Env $Env -Config $Config -MutantId $mutant.id -RunNo $RunNo -Reason "the environment reset after this mutant's Timeout failed: $timeoutRecoveryFailure"
                }
            }
            catch {
                # FIX (M3): this mutant's own body threw something unhandled (e.g.
                # Invoke-MutTestsWithBudget itself throwing, rather than returning an ErrorMessage, or
                # a PATCH/covering-test failure) -- never let it abort the whole run. Best-effort
                # deactivate, record Status 'Error' with the exception message, and move on.
                $caughtMessage = $_.Exception.Message

                # FIX (F3b Minors): deactivate (best-effort) BEFORE deciding whether to re-throw --
                # previously the recovery-cap-exceeded re-throw (below) happened first, leaving the
                # last mutant active in the environment on an aborted run.
                try {
                    Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = $RunNo } | Out-Null
                }
                catch {
                    # Deactivation itself failing must not mask the original error or abort the run.
                }

                # FIX (F3, run 8 -- finding I6; F3b Minors: matched on a distinct ErrorCategory, not
                # a string-matched marker prefix): the one exception this catch must NOT swallow into
                # a per-mutant Error -- Request-MutEnvironmentRecoveryBudget's recovery-cap-exceeded
                # throw. Re-thrown, with the rows completed so far attached as TargetObject (F3b
                # IMPORTANT 3: so the pipeline can still export a partial result and tell the operator
                # how much finished), so it aborts the whole run rather than limping through the rest
                # of the mutants one Error at a time (the brief's whole point of having a cap).
                if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
                    $enriched = [System.Management.Automation.ErrorRecord]::new($_.Exception, $script:MutEnvironmentRecoveryCapErrorId, [System.Management.Automation.ErrorCategory]::LimitsExceeded, $rows)
                    throw $enriched
                }

                # FIX (503 bisect): wait for the environment and retry this SAME mutant, rather
                # than recording Error and moving on in seconds while the outage lasts. The wait's
                # own give-up (deadline passed) is LimitsExceeded and aborts the run, with the rows
                # so far attached, exactly like the recovery cap above.
                if ($outageRetries -lt $script:MaxOutageRetriesPerMutant) {
                    $outageRetries++
                    try {
                        $Env = Wait-MutOutageRecovery -Env $Env -Config $Config -MutantId $mutant.id -RunNo $RunNo -Reason $caughtMessage
                    }
                    catch {
                        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::LimitsExceeded) {
                            throw [System.Management.Automation.ErrorRecord]::new($_.Exception, 'MutEnvironmentOutageTimeout', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $rows)
                        }
                        throw
                    }
                    $retryMutant = $true
                    continue
                }

                $errorRow = [pscustomobject]@{
                    Id            = $mutant.id
                    Status        = 'Error'
                    KillingTest   = $null
                    DurationMs    = $null
                    CoveringTests = @($covering)
                }
                $errorRow | Add-Member -NotePropertyName 'Error' -NotePropertyValue $caughtMessage

                Write-MutResultsJsonLine -RunDir $RunDir -Row $errorRow
                $rows += $errorRow
            }
        } while ($retryMutant)

        # FIX (503 bisect): the circuit breaker. Any non-Error row resets the count. Run 9
        # recorded 46 Error rows in a row and still published a score with `aborted: false`;
        # now the run aborts with the rows so far attached (TargetObject), the same shape as the
        # recovery cap, so the pipeline exports a partial result and tells the operator.
        if (@($rows).Count -gt 0 -and $rows[-1].Status -eq 'Error') {
            $consecutiveErrors++
        }
        else {
            $consecutiveErrors = 0
        }
        if ($consecutiveErrors -ge $script:MaxConsecutiveErrors) {
            $message = "Invoke-MutMutantLoop: $consecutiveErrors consecutive mutants ended in Error (last: mutant $($mutant.id): $($rows[-1].Error)). A run whose mutants keep failing to produce real results is not producing a trustworthy score; aborting with a partial export rather than continuing."
            $exception = [System.Exception]::new($message)
            throw [System.Management.Automation.ErrorRecord]::new($exception, 'MutConsecutiveErrorsExceeded', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $rows)
        }

        # FIX (run 10): a Timeout whose reset succeeded is no longer charged against the recovery
        # cap (see the Timeout branch), so this is the bound on resets instead. Non-terminating
        # mutants are real but sparse (72918630 has three, never five in a row); five Timeouts in
        # a row means the budget or the environment is wrong, and every one costs a full
        # stop/start.
        if (@($rows).Count -gt 0 -and $rows[-1].Status -eq 'Timeout') {
            $consecutiveTimeouts++
        }
        else {
            $consecutiveTimeouts = 0
        }
        if ($consecutiveTimeouts -ge $script:MaxConsecutiveTimeouts) {
            $message = "Invoke-MutMutantLoop: $consecutiveTimeouts consecutive mutants ended in Timeout (last: mutant $($mutant.id)). Every mutant timing out points at the per-mutant budget or the environment, not at that many non-terminating mutants in a row, and each Timeout costs a full environment reset; aborting with a partial export rather than continuing."
            $exception = [System.Exception]::new($message)
            throw [System.Management.Automation.ErrorRecord]::new($exception, 'MutConsecutiveTimeoutsExceeded', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $rows)
        }
    }

    $errorCount = @($rows | Where-Object { $_.Status -eq 'Error' }).Count
    if ($errorCount -gt 0) {
        Write-Warning "Invoke-MutMutantLoop: $errorCount of $(@($orderedMutants).Count) mutant(s) ended in Error"
    }
    if ($script:MutOutageWaitCount -gt 0) {
        # FIX (503 bisect): visibility into how many environment outages this run waited out.
        Write-Warning "Invoke-MutMutantLoop: waited out $($script:MutOutageWaitCount) environment outage(s) this run"
    }
    if ($script:MutEnvironmentRecoveryCount -gt 0) {
        # FIX (F3, run 8 -- finding I6): visibility into how many times this run had to bring
        # the environment back -- see Confirm-MutEnvironmentServing.
        Write-Warning "Invoke-MutMutantLoop: environment recovered $($script:MutEnvironmentRecoveryCount) of $($script:MaxEnvironmentRecoveries) allowed time(s) this run"
    }

    return , $rows
}

Export-ModuleMember -Function Get-MutTimeoutBudget, Invoke-MutMutantLoop
