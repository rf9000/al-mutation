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
        param($Env)
        throw 'Reset-MutEnvironment: no backend module has been imported into this session.'
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
        Private. Runs the backend's Invoke-MutTests inside a Start-Job so a hung test run can
        be killed on the wall clock (§6.5.6 step 3), rather than blocking the orchestrator
        forever. The job imports the backend module by path (so it works in a separate
        process/runspace with no access to the caller's already-imported modules) and calls
        Invoke-MutTests with $Env/$Targets/$TimeoutSec.

        Exposed (not exported) so tests can either mock it wholesale (fast, deterministic unit
        tests of Invoke-MutMutantLoop) or call it directly via InModuleScope with a real, tiny
        fake backend module to prove the wall-clock kill actually happens.

        .PARAMETER BudgetSec
        Wall-clock budget for Wait-Job. May differ from $TimeoutSec (which is only the value
        forwarded to the backend's own -TimeoutSec) so a test can shrink the wrapper's patience
        independently of what is told to the backend.

        .OUTPUTS
        [pscustomobject]@{ TimedOut (bool); Result (backend Invoke-MutTests result, or $null);
        ErrorMessage (string, or $null) }.
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
        [string]$BackendModulePath
    )

    $job = Start-Job -ScriptBlock {
        param($JobModulePath, $JobEnv, $JobTargets, $JobTimeoutSec)
        Import-Module $JobModulePath -Force
        Invoke-MutTests -Env $JobEnv -Targets $JobTargets -TimeoutSec $JobTimeoutSec
    } -ArgumentList $BackendModulePath, $Env, $Targets, $TimeoutSec

    Wait-Job -Job $job -Timeout $BudgetSec | Out-Null

    if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
        Stop-Job -Job $job | Out-Null
        Remove-Job -Job $job -Force | Out-Null
        return [pscustomobject]@{ TimedOut = $true; Result = $null; ErrorMessage = $null }
    }

    try {
        $result = Receive-Job -Job $job -ErrorAction Stop
        Remove-Job -Job $job -Force | Out-Null
        return [pscustomobject]@{ TimedOut = $false; Result = $result; ErrorMessage = $null }
    }
    catch {
        Remove-Job -Job $job -Force | Out-Null
        return [pscustomobject]@{ TimedOut = $false; Result = $null; ErrorMessage = $_.Exception.Message }
    }
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
        $targets = @($covering | ForEach-Object { [pscustomobject]@{ CodeunitId = $_; Function = $null } })

        $outcome = Invoke-MutTestsWithBudget -Env $Env -Targets $targets -TimeoutSec $budget -BudgetSec $budget -BackendModulePath $BackendModulePath

        $status = $null
        $killingTest = $null
        $durationMs = $null
        $errorMessage = $null

        if ($outcome.TimedOut) {
            Reset-MutEnvironment -Env $Env | Out-Null
            $status = 'Timeout'
        }
        elseif ($outcome.ErrorMessage) {
            $status = 'Error'
            $errorMessage = $outcome.ErrorMessage
        }
        else {
            $result = $outcome.Result
            $durationMs = $result.DurationMs

            if ($result.Failed -gt 0) {
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
                Invoke-MutApi -Env $Env -Method 'POST' -Path 'mutantResults' -Body @{
                    runNo      = $RunNo
                    mutantId   = $mutant.id
                    status     = 'Survived'
                    durationMs = $durationMs
                } | Out-Null
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
