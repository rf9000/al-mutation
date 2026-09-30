<#
    .SYNOPSIS
    Stop-session spike: can the orchestrator stop the runaway BC session a non-terminating mutant
    leaves behind, through Mutation Core's sessions API, instead of restarting the environment?

    .DESCRIPTION
    Run 10 found that mutants 4371/4373/4374 (72918630 BuildBatchDisplay) loop forever. The CLI's
    --timeout stops only the client; the BC session keeps looping and poisons every later job.
    Run 11 then showed the fallback, a full environment stop/start, can fail outright: the new
    container's database attach raced the old one. BC documents that StopSession "cannot terminate"
    a session executing AL that does not touch the server connection -- and the mutant's loop is
    pure temp-table work -- so this has to be tested, not assumed.

    Steps: record sessions; activate the mutant; run its covering test codeunit with a short client
    timeout (the runaway); find the new session(s); POST .../sessions(<id>)/Microsoft.NAV.stop;
    poll until they are gone (or give up); deactivate; run the test codeunit again with no mutant
    and require a real result. Guardrails: mut- environment only, one test job at a time, no
    credentials printed, leaves activeMutantId 0.
#>
param(
    [string]$ConfigPath = 'out\mutation.u2.pinned.config.json',
    [int]$MutantId = 4371,
    [int]$TestCodeunitId = 95121,
    [int]$ClientTimeoutSec = 30,
    [int]$StopWaitSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force -WarningAction SilentlyContinue

$cfg = Get-MutConfig -Path (Join-Path $repoRoot $ConfigPath) -WarningAction SilentlyContinue
$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($envHandle.Status -ne 'Running') { throw "environment is $($envHandle.Status)" }

function Get-SpikeSessions {
    $r = Invoke-MutApi -Env $envHandle -Method 'GET' -Path 'sessions'
    return , @($r.value)
}

function Format-Sessions {
    param($Sessions)
    return (@($Sessions) | ForEach-Object { "$($_.sessionId)/$($_.userId)/$($_.clientType)" }) -join ', '
}

$before = Get-SpikeSessions
Write-Output "sessions before: $(Format-Sessions $before)"
$beforeIds = @($before | ForEach-Object { $_.sessionId })

$runaway = @()
try {
    Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = $MutantId; currentRunNo = 9960 } | Out-Null
    $t0 = [datetime]::UtcNow
    $r = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = $TestCodeunitId; Function = $null }) -TimeoutSec $ClientTimeoutSec
    Write-Output ("mutant {0} on {1}: passed {2} failed {3} after {4:N0} s (client timeout {5} s)" -f $MutantId, $TestCodeunitId, $r.Passed, $r.Failed, ([datetime]::UtcNow - $t0).TotalSeconds, $ClientTimeoutSec)
}
finally {
    Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = 0 } | Out-Null
}

$after = Get-SpikeSessions
Write-Output "sessions after the timed-out job: $(Format-Sessions $after)"
$runaway = @($after | Where-Object { ($beforeIds -notcontains $_.sessionId) -and (-not $_.isCurrentSession) })
if ($runaway.Count -eq 0) {
    Write-Output 'NO NEW SESSION found -- the job did not leave a runaway session behind (or it already ended).'
}

foreach ($s in $runaway) {
    try {
        Invoke-MutApi -Env $envHandle -Method 'POST' -Path "sessions($($s.sessionId))/Microsoft.NAV.stop" -Body @{} | Out-Null
        Write-Output "stop requested for session $($s.sessionId) ($($s.userId), $($s.clientType))"
    }
    catch {
        Write-Output "stop FAILED for session $($s.sessionId): $($_.Exception.Message)"
    }
}

$deadline = [datetime]::UtcNow.AddSeconds($StopWaitSec)
$remaining = $runaway
while ($remaining.Count -gt 0 -and [datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 10
    $ids = @(Get-SpikeSessions | ForEach-Object { $_.sessionId })
    $remaining = @($runaway | Where-Object { $ids -contains $_.sessionId })
}
if ($runaway.Count -gt 0) {
    if ($remaining.Count -eq 0) { Write-Output "ALL RUNAWAY SESSIONS GONE within $StopWaitSec s" }
    else { Write-Output "STILL ALIVE after $StopWaitSec s: $(Format-Sessions $remaining)" }
}

$t1 = [datetime]::UtcNow
$check = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = $TestCodeunitId; Function = $null }) -TimeoutSec 120
Write-Output ("follow-up run of {0} with no mutant: passed {1} failed {2} after {3:N0} s" -f $TestCodeunitId, $check.Passed, $check.Failed, ([datetime]::UtcNow - $t1).TotalSeconds)
$rows = Invoke-MutApi -Env $envHandle -Method 'GET' -Path 'mutantResults?$filter=runNo eq 9960'
foreach ($row in @($rows.value)) { Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=9960,mutantId=$($row.mutantId))" | Out-Null }
Write-Output 'SPIKE DONE'
