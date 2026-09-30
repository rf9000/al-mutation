<#
    .SYNOPSIS
    Runner-nesting spike: can one DemoPortal test job drive more than one mutant?

    .DESCRIPTION
    §6.1.6 ("Custom TestRunner (deferred)") would collapse the dominant cost of a mutation
    run. Run 8/9 measured ~11 s per mutant of which BC's own reported test execution is a
    median of ~160 ms -- roughly 98% of the cost is per-test-job overhead (session spin-up,
    company open, app load, CLI process, HTTP round trips), paid once per mutant. Amortising
    that over a slice of mutants inside ONE job is worth about 10x.

    F7 blocks the spec'd form: the CLI takes a test codeunit id, and no TestRunner codeunit
    id can be passed. But F7 says nothing about what an ordinary test codeunit may do once
    the job is running. This spike asks the one question everything else depends on:

        Does "MUT Test Hooks" fire for a test invoked from INSIDE another test?

    The hooks subscribe to Codeunit "Test Runner - Mgt" OnBefore/OnAfterTestMethodRun. Those
    events are published by the test framework as it walks a suite's Test Method Lines. So
    the question is really whether a driver can get the framework to run more lines.

    Two mechanisms, one job each:
      A (codeunit 50601) -- CODEUNIT.RUN on a test codeunit. Prior: does not fire; CODEUNIT.RUN
        executes OnRun as an ordinary codeunit and never involves the test framework.
      B (codeunit 50602) -- drive Codeunit "Test Suite Mgt." from inside a test. Prior: likely
        blocked by BC's guard against nested test runs. This is the mechanism that would
        actually deliver §6.1.6.

    Observation is over the API, not from inside AL: the restricted test session cannot read
    Mutation Core's own tables (spike U4). Each mechanism gets its own sentinel mutant id. If
    the hook fired for the victim's deliberately-failing test, a Killed row appears for that
    sentinel; if it did not, no row appears. Both driver tests are written to PASS, so a row
    can only have come from the victim.

    Guardrails: only touches an environment whose name starts with `mut-`. One test job at a
    time -- this script must not run while a mutation run is in flight. Never prints
    credentials. Cleans up its own rows and leaves mutationSetup at activeMutantId 0.

    .PARAMETER ConfigPath
    Config naming the environment to use. Defaults to mutation.config.json.

    .PARAMETER RunNo
    Run number for the sentinel rows. Deliberately high, so it cannot collide with a real
    run's rows.
#>

param(
    [string]$ConfigPath = 'mutation.config.json',
    [int]$RunNo = 9901
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force

$mechanisms = @(
    [pscustomobject]@{ Key = 'A'; CodeunitId = 50601; MutantId = 9901; Description = 'CODEUNIT.RUN on a test codeunit' }
    [pscustomobject]@{ Key = 'B'; CodeunitId = 50602; MutantId = 9902; Description = 'drive "Test Suite Mgt." from inside a test' }
)

Write-Output '=== Runner-nesting spike: does a hook fire for a test invoked from inside a test? ==='

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}
$cfg = Get-MutConfig -Path $resolvedConfigPath

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle) {
    throw "Invoke-RunnerNestingSpike: environment '$($cfg.environmentName)' not found."
}
if ($envHandle.Status -ne 'Running') {
    Write-Output "Environment status is '$($envHandle.Status)'; starting it..."
    $envHandle = Start-MutEnvironment -Env $envHandle -Config $cfg
}
Write-Output "Environment: $($envHandle.Name) ($($envHandle.Id)), status Running."
Write-Output ''

$findings = @()

foreach ($mechanism in $mechanisms) {
    Write-Output "--- Mechanism $($mechanism.Key): $($mechanism.Description) (codeunit $($mechanism.CodeunitId), sentinel mutant $($mechanism.MutantId)) ---"

    # Clear any stale row for this sentinel first, so a row found afterwards is provably
    # from THIS run -- the U4 spike recorded a false PASS from exactly this mistake.
    $stale = Invoke-MutApi -Env $envHandle -Method 'GET' -Path "mutantResults?`$filter=runNo eq $RunNo and mutantId eq $($mechanism.MutantId)"
    foreach ($row in @($stale.value)) {
        Write-Output "  clearing a stale sentinel row from an earlier run: $($row.recordedAt)"
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=$RunNo,mutantId=$($mechanism.MutantId))" | Out-Null
    }

    # try/finally: the first live attempt crashed on a StrictMode property read between these
    # two PATCHes and left the sentinel mutant ACTIVE in the environment. Deactivation must
    # happen however the job step ends.
    try {
        Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{
            activeMutantId = $mechanism.MutantId
            currentRunNo   = $RunNo
        } | Out-Null

        $targets = @([pscustomobject]@{ CodeunitId = $mechanism.CodeunitId; Function = $null })
        $testResult = Invoke-MutTests -Env $envHandle -Targets $targets -TimeoutSec 300
    }
    finally {
        Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{
            activeMutantId = 0
            currentRunNo   = 0
        } | Out-Null
    }

    # Invoke-MutTests rows are { Codeunit; Function; Result; DurationMs; Error }.
    Write-Output "  driver test job: $($testResult.Passed) passed, $($testResult.Failed) failed, $($testResult.DurationMs) ms"
    foreach ($test in @($testResult.Tests)) {
        Write-Output "    $($test.Codeunit):$($test.Function): $($test.Result)"
        if ($test.Error) {
            Write-Output "      $($test.Error)"
        }
    }

    $after = Invoke-MutApi -Env $envHandle -Method 'GET' -Path "mutantResults?`$filter=runNo eq $RunNo and mutantId eq $($mechanism.MutantId)"
    $rows = @($after.value)

    # A row alone proves nothing: the first live run found rows for BOTH mechanisms, but
    # each named the DRIVER as killing test -- the drivers themselves failed, so the hook
    # recorded their own failure. Only a row whose killing test is the victim shows the hook
    # fired for a test invoked from inside a test.
    $killingTest = ''
    if ($rows.Count -gt 0) {
        $killingTest = $rows[0].killingTest
    }
    $hookFired = $killingTest -like 'MUT Spike Victim:*'

    Write-Output "  hook fired for the inner test: $hookFired"
    if ($killingTest) {
        Write-Output "  killingTest: $killingTest"
    }
    Write-Output ''

    $findings += [pscustomobject]@{
        Mechanism      = $mechanism.Key
        Description    = $mechanism.Description
        DriverPassed   = $testResult.Passed
        DriverFailed   = $testResult.Failed
        HookFired      = $hookFired
        KillingTest    = $killingTest
    }

    # Leave the table as we found it.
    foreach ($row in $rows) {
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=$RunNo,mutantId=$($mechanism.MutantId))" | Out-Null
    }
}

Write-Output '=== Result ==='
$findings | Format-Table -AutoSize | Out-String | Write-Output

$anyFired = @($findings | Where-Object { $_.HookFired }).Count -gt 0
if ($anyFired) {
    Write-Output 'AT LEAST ONE MECHANISM WORKS -- an in-job mutant loop is reachable on this backend.'
    Write-Output 'Next: measure how many mutants one job can carry before the session or the'
    Write-Output 'transaction scope gives out, and how attribution must change (the hook records a'
    Write-Output 'kill for ANY failing test while a mutant is active -- see bc63504).'
    exit 0
}

Write-Output 'NEITHER MECHANISM WORKS -- the hooks do not fire for a test invoked from inside a test.'
Write-Output 'Combined with F7 (no TestRunner codeunit id can be passed to the CLI), §6.1.6 is not'
Write-Output 'reachable on this backend at all. The routes to it are: the CLI gaining TestRunner'
Write-Output 'support, or a backend where the test runner is under our control.'
exit 1
