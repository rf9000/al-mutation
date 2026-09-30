<#
    .SYNOPSIS
    503 bisect: is the (503) Server Unavailable loss in runs 8/9 caused by particular mutants,
    or by the environment dying after a fixed amount of work?

    .DESCRIPTION
    Runs 8 and 9 each lost 46 of 265 mutants. The first reading was object-specific: every
    error fell on 71553757 (covered by 95058) and 72918630 (covered by 95121). But the loop
    runs objects in the same order every time, and in BOTH runs the errors begin at exactly
    execution position 219 with no success after it. 71553757's 13 mutants are also benign on
    inspection (DEL of an exit that falls through to another exit; COND on a set membership;
    no loops, no recursion). So position is the stronger hypothesis.

    Phase 1 -- the 13 mutants of 71553757, alone, each against 95058. If they all return real
    results, the mutants are exonerated.

    Phase 2 -- endurance: run 95058 repeatedly with NO mutant active, until the first failure
    or -MaxJobs. If the environment dies near ~230 test jobs, the loss is a backend/environment
    limit and has nothing to do with mutation.

    Every job is logged with its index, UTC time and outcome to out/503-bisect/jobs.jsonl.
    Guardrails: mut- environment only (Assert-MutEnvironmentAllowed in the backend), one
    job at a time, no credentials printed. Leaves activeMutantId 0 and deletes its own rows.
#>
param(
    [string]$ConfigPath = 'mutation.u2.config.json',
    [int]$RunNo = 9950,
    [int]$MaxJobs = 320,
    [int]$TestCodeunitId = 95058,
    [int[]]$MutantIds = @(15031, 15032, 15033, 15034, 15035, 15036, 15037, 15038, 15039, 15040, 15041, 15042, 15043),
    [switch]$SkipPhase1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force -WarningAction SilentlyContinue

$outDir = Join-Path $repoRoot 'out\503-bisect'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$jobsPath = Join-Path $outDir 'jobs.jsonl'

$cfg = Get-MutConfig -Path (Join-Path $repoRoot $ConfigPath) -WarningAction SilentlyContinue
$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle -or $envHandle.Status -ne 'Running') {
    throw "Invoke-503Bisect: environment '$($cfg.environmentName)' is not Running; start it first."
}

$script:JobIndex = 0
$started = [datetime]::UtcNow

function Invoke-BisectJob {
    param([string]$Phase, [int]$MutantId)

    $script:JobIndex++
    $t0 = [datetime]::UtcNow
    $row = [ordered]@{
        job = $script:JobIndex; phase = $Phase; mutantId = $MutantId; utc = $t0.ToString('o')
        elapsedMin = [math]::Round(($t0 - $started).TotalMinutes, 2)
        passed = $null; failed = $null; wallMs = $null; error = $null; killingTest = $null
    }
    try {
        Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = $MutantId; currentRunNo = $RunNo } | Out-Null
        $targets = @([pscustomobject]@{ CodeunitId = $TestCodeunitId; Function = $null })
        $r = Invoke-MutTests -Env $envHandle -Targets $targets -TimeoutSec 300
        $row.passed = $r.Passed
        $row.failed = $r.Failed
        $failing = @($r.Tests | Where-Object { $_.Result -ne 'Pass' } | Select-Object -First 1)
        if ($failing.Count -gt 0) { $row.killingTest = "$($failing[0].Codeunit):$($failing[0].Function)" }
    }
    catch {
        $row.error = $_.Exception.Message
    }
    finally {
        try {
            Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = 0 } | Out-Null
        }
        catch {
            if (-not $row.error) { $row.error = "deactivate failed: $($_.Exception.Message)" }
        }
    }
    $row.wallMs = [int]([datetime]::UtcNow - $t0).TotalMilliseconds
    $json = ([pscustomobject]$row | ConvertTo-Json -Compress)
    Add-Content -Path $jobsPath -Value $json -Encoding UTF8
    Write-Host $json  # Write-Host, not Write-Output: output would join the return value
    return [pscustomobject]$row
}

function Test-BisectJobBad {
    param($Row)
    return ([bool]$Row.error) -or (($Row.passed + $Row.failed) -eq 0)
}

if (-not $SkipPhase1) {
    Write-Output "=== Phase 1: $($MutantIds.Count) mutants of 71553757, alone, against $TestCodeunitId ==="
    foreach ($id in $MutantIds) {
        $row = Invoke-BisectJob -Phase 'mutant' -MutantId $id
        if (Test-BisectJobBad $row) {
            Write-Output "PHASE 1 FAILURE at mutant $id (job $($row.job)); stopping."
            break
        }
    }
}

Write-Output "=== Phase 2: endurance, no mutant active, up to $MaxJobs jobs ==="
$firstBad = $null
while ($script:JobIndex -lt $MaxJobs) {
    $row = Invoke-BisectJob -Phase 'endurance' -MutantId 0
    if (Test-BisectJobBad $row) {
        $firstBad = $row
        break
    }
}

$status = (Get-MutEnvironment -Name $cfg.environmentName -Config $cfg).Status
if ($null -ne $firstBad) {
    Write-Output "ENDURANCE FAILURE at job $($firstBad.job), $($firstBad.elapsedMin) min in: $($firstBad.error). Environment status now: $status"
}
else {
    Write-Output "ENDURANCE OK: $($script:JobIndex) jobs without failure. Environment status now: $status"
}

# Clean up any Killed rows this script's jobs caused.
try {
    $rows = Invoke-MutApi -Env $envHandle -Method 'GET' -Path "mutantResults?`$filter=runNo eq $RunNo"
    foreach ($r in @($rows.value)) {
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=$RunNo,mutantId=$($r.mutantId))" | Out-Null
    }
    Write-Output "cleaned $(@($rows.value).Count) row(s) for runNo $RunNo"
}
catch {
    Write-Output "cleanup skipped: $($_.Exception.Message)"
}
Write-Output 'BISECT DONE'
