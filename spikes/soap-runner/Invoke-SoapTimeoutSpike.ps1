<#
    .SYNOPSIS
    SOAP-runner timeout spike: can a client stop a SOAP runner stuck in a non-terminating mutant?

    .DESCRIPTION
    Follows Invoke-SoapRunnerSpike.ps1. Findings so far (2026-10-04):
      - A SOAP call stuck in a non-terminating mutant blocks until the client gives up; the
        connection then dropped by itself after ~276 s in one probe, cause unknown.
      - The runner's SOAP session is NOT listed in "Active Session", so the MUT Sessions API
        cannot see or stop it.
    Spike app 1.0.0.3 therefore records each call's SessionId() and current mutant in
    "MUT Spike Runner State" (GetState) and stops a session by id (StopRunner). This script:

      T-1  Starts RunMutants(<mutant>) in a background runspace with a client timeout.
      T-2  Reads GetState: which session runs which mutant, and is it in "Active Session"?
      T-3  Health call while the runaway is alive (other codeunit, separate suite).
      T-4  StopRunner(<session>), then health calls until normal; how long does stopping take?

    Default mutant 4515 is a run-15 Timeout on 95121 (run 15's schemata app must be published).
    Leaves mutationSetup at activeMutantId 0 and clears the runner state.
#>

param(
    [string]$ConfigPath = 'mutation.u2.config.json',
    [int]$CodeunitId = 95121,
    [int]$MutantId = 4515,
    [int]$TimeoutSec = 30,
    [int]$HealthCodeunitId = 95155,
    [int]$RunNo = 99100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outDir = Join-Path $repoRoot 'out\soap-runner'
New-Item -ItemType Directory -Force $outDir | Out-Null
$logPath = Join-Path $outDir ('timeout-{0:yyyyMMdd-HHmmss}.jsonl' -f (Get-Date))

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
$dp = Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force -PassThru -WarningAction SilentlyContinue

function Write-SpikeLog($Record) {
    ($Record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $logPath -Encoding utf8
}

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}
$cfg = Get-MutConfig -Path $resolvedConfigPath -WarningAction SilentlyContinue

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle -or $envHandle.Status -ne 'Running') {
    throw "Invoke-SoapTimeoutSpike: environment '$($cfg.environmentName)' is not running."
}
Assert-MutEnvironmentAllowed $envHandle

$apiBase = Get-MutApiBase -Env $envHandle
$credential = & $dp { param($e) Get-MutCredential -Env $e } $envHandle
$headers = & $dp { param($c) Get-MutBasicAuthHeader -Credential $c } $credential
$company = @((Invoke-RestMethod -Uri "$apiBase/api/v2.0/companies" -Headers $headers).value)[0].name
$serviceUrl = "$apiBase/WS/$([uri]::EscapeDataString($company))/Codeunit/MUTSpikeRunner"
$ns = 'urn:microsoft-dynamics-schemas/codeunit/MUTSpikeRunner'
Write-Output "Environment: $($envHandle.Name) ($($envHandle.Id)), company '$company'."

function New-SoapRequest([string]$Operation, [hashtable]$Arguments) {
    $argXml = ($Arguments.GetEnumerator() | ForEach-Object {
            "<x:$($_.Key)>$([System.Security.SecurityElement]::Escape([string]$_.Value))</x:$($_.Key)>"
        }) -join ''
    $soapHeaders = $headers.Clone()
    $soapHeaders['SOAPAction'] = "$ns`:$Operation"
    return @{
        Headers = $soapHeaders
        Body    = "<s:Envelope xmlns:s=`"http://schemas.xmlsoap.org/soap/envelope/`" xmlns:x=`"$ns`"><s:Body><x:$Operation>$argXml</x:$Operation></s:Body></s:Envelope>"
    }
}

function Invoke-SpikeSoap([string]$Operation, [hashtable]$Arguments, [int]$CallTimeoutSec = 300) {
    $request = New-SoapRequest $Operation $Arguments
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $serviceUrl -Method Post -Headers $request.Headers -ContentType 'text/xml; charset=utf-8' -Body $request.Body -UseBasicParsing -TimeoutSec $CallTimeoutSec
        [xml]$xml = $response.Content
        $value = $xml.SelectSingleNode("//*[local-name()='return_value']")
        return [pscustomobject]@{ Ok = $true; Ms = $sw.ElapsedMilliseconds; Value = $(if ($value) { $value.InnerText }); Fault = $null }
    }
    catch {
        $fault = $_.Exception.Message
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $body = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
            if ($body -match '<faultstring[^>]*>([^<]*)<') { $fault = $Matches[1] }
        }
        return [pscustomobject]@{ Ok = $false; Ms = $sw.ElapsedMilliseconds; Value = $null; Fault = $fault }
    }
}

function Invoke-SpikeHealth([string]$Label) {
    $r = Invoke-SpikeSoap 'RunTests' @{ codeunitId = $HealthCodeunitId; functionFilter = '' } 120
    $summary = if ($r.Ok) { $p = $r.Value | ConvertFrom-Json; $firstError = @($p.tests | Where-Object { $_.PSObject.Properties['error'] } | Select-Object -First 1 | ForEach-Object { "$($_.name): $($_.error)" }); "$($p.passed) passed, $($p.failed) failed $firstError" } else { "FAILED: $($r.Fault)" }
    Write-Host ("  {0}: {1}, {2:n0} ms" -f $Label, $summary, $r.Ms)
    Write-SpikeLog @{ step = $Label; ok = $r.Ok; ms = $r.Ms; summary = $summary }
    return $r
}

function Get-SpikeState {
    $r = Invoke-SpikeSoap 'GetState' @{} 60
    if (-not $r.Ok) { throw "GetState failed: $($r.Fault)" }
    return @($r.Value | ConvertFrom-Json | ForEach-Object { $_ })
}

$runspace = $null
try {
    Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = 0 } | Out-Null
    Invoke-SpikeSoap 'ClearState' @{} 60 | Out-Null

    Write-Output ''
    Write-Output '--- baseline ---'
    Invoke-SpikeHealth 'health-before' | Out-Null

    Write-Output ''
    Write-Output "--- T-1: RunMutants($CodeunitId, $MutantId) in the background, client timeout $TimeoutSec s ---"
    $request = New-SoapRequest 'RunMutants' @{ codeunitId = $CodeunitId; functionFilter = ''; mutantIds = "$MutantId"; runNo = $RunNo }
    $runspace = [powershell]::Create()
    [void]$runspace.AddScript({
            param($Uri, $Headers, $Body, $Timeout)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -ContentType 'text/xml; charset=utf-8' -Body $Body -UseBasicParsing -TimeoutSec $Timeout | Out-Null
                "returned after $($sw.ElapsedMilliseconds) ms"
            }
            catch { "failed after $($sw.ElapsedMilliseconds) ms: $($_.Exception.Message)" }
        }).AddArgument($serviceUrl).AddArgument($request.Headers).AddArgument($request.Body).AddArgument($TimeoutSec)
    $async = $runspace.BeginInvoke()
    Start-Sleep -Seconds 10

    Write-Output ''
    Write-Output '--- T-2: runner state ---'
    $state = Get-SpikeState
    $state | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Write-SpikeLog @{ step = 'T-2'; state = $state }
    $runner = @($state | Where-Object { $_.PSObject.Properties['mutantId'] -and $_.mutantId -eq $MutantId -and -not $_.finished }) | Select-Object -First 1
    if ($null -eq $runner) { throw "T-2: no unfinished runner row for mutant $MutantId." }

    Write-Output '--- T-3: health while the runaway runs ---'
    Invoke-SpikeHealth 'health-during' | Out-Null

    $async.AsyncWaitHandle.WaitOne(($TimeoutSec + 30) * 1000) | Out-Null
    Write-Output "  runaway call: $(if ($async.IsCompleted) { $runspace.EndInvoke($async) } else { 'still waiting' })"

    Write-Output ''
    Write-Output "--- T-4: StopRunner($($runner.sessionId)) ---"
    $stopSw = [Diagnostics.Stopwatch]::StartNew()
    $stop = Invoke-SpikeSoap 'StopRunner' @{ runnerSessionId = $runner.sessionId } 60
    Write-Output "  StopRunner: ok=$($stop.Ok) $($stop.Value) $($stop.Fault) ($($stop.Ms) ms)"
    Write-SpikeLog @{ step = 'T-4-stop'; ok = $stop.Ok; value = $stop.Value; fault = $stop.Fault; ms = $stop.Ms }
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 5
        $h = Invoke-SpikeHealth ("health-after-stop-{0:n0}s" -f $stopSw.Elapsed.TotalSeconds)
        if ($h.Ok -and $h.Ms -lt 5000 -and ($h.Value | ConvertFrom-Json).failed -eq 0) { break }
    }
}
finally {
    if ($runspace) { $runspace.Dispose() }
    Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = 0 } | Out-Null
    Invoke-SpikeSoap 'ClearState' @{} 60 | Out-Null
    $rows = Invoke-MutApi -Env $envHandle -Method 'GET' -Path "mutantResults?`$filter=runNo eq $RunNo"
    foreach ($row in @($rows.value)) {
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=$RunNo,mutantId=$($row.mutantId))" | Out-Null
    }
    Write-Output ''
    Write-Output "Log: $logPath"
}
