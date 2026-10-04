<#
    .SYNOPSIS
    SOAP-runner spike: can tests run on DemoPortal without a DemoPortal test job, and faster?

    .DESCRIPTION
    A `continia test run` job costs a median of 10.5 s, while the tests a mutant needs run in a
    median of 188 ms inside BC (run 15). The Continia AL Test Runner's debug path calls a SOAP
    codeunit `TestRunner` directly on the environment instead of creating a DemoPortal job.
    This spike measures that route and a route we own:

      U-A  Is `/WS/<company>/Codeunit/TestRunner` there, and is our `MUTSpikeRunner` there?
      U-B  Latency: CLI job vs. SOAP call, same codeunit, no mutant active.
      U-C  Fidelity: per mutant, CLI outcome vs. SOAP outcome (Killed = any test failed).
      U-D  Hooks: does `MUT Test Hooks` write a Killed row under the SOAP route?
      U-E  In-call loop: all mutants in ONE SOAP call; seconds per mutant.

    `MUTSpikeRunner` is codeunit 50700 of spikes/soap-runner/app, which must be deployed first.

    Guardrails: only an environment whose name starts with `mut-`. One test execution at a time;
    never run while a mutation run is in flight. Never prints credentials. Leaves
    mutationSetup at activeMutantId 0 and deletes its own mutantResults rows.

    .PARAMETER MutantIds
    Mutants to probe for U-C..U-E. They must exist in the schemata app now on the environment.

    .PARAMETER Repeat
    Calls per transport for U-B.
#>

param(
    [string]$ConfigPath = 'mutation.u2.config.json',
    [int]$CodeunitId = 95155,
    [int[]]$MutantIds = @(),
    [int]$Repeat = 5,
    [int]$RunNo = 99100,
    [switch]$SkipCli
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outDir = Join-Path $repoRoot 'out\soap-runner'
New-Item -ItemType Directory -Force $outDir | Out-Null
$logPath = Join-Path $outDir ('{0:yyyyMMdd-HHmmss}.jsonl' -f (Get-Date))

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
$dp = Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force -PassThru -WarningAction SilentlyContinue

function Write-SpikeLog($Record) {
    ($Record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $logPath -Encoding utf8
}

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2) { return $sorted[[int][math]::Floor($n / 2)] }
    return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
}

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}
$cfg = Get-MutConfig -Path $resolvedConfigPath -WarningAction SilentlyContinue

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle -or $envHandle.Status -ne 'Running') {
    throw "Invoke-SoapRunnerSpike: environment '$($cfg.environmentName)' is not running."
}
Assert-MutEnvironmentAllowed $envHandle

$apiBase = Get-MutApiBase -Env $envHandle
$credential = & $dp { param($e) Get-MutCredential -Env $e } $envHandle
$headers = & $dp { param($c) Get-MutBasicAuthHeader -Credential $c } $credential
$company = @((Invoke-RestMethod -Uri "$apiBase/api/v2.0/companies" -Headers $headers).value)[0].name
$wsBase = "$apiBase/WS/$([uri]::EscapeDataString($company))/Codeunit"
Write-Output "Environment: $($envHandle.Name) ($($envHandle.Id)), company '$company'."

function Invoke-SpikeSoap([string]$Service, [string]$Operation, [hashtable]$Arguments, [int]$TimeoutSec = 600) {
    $ns = "urn:microsoft-dynamics-schemas/codeunit/$Service"
    $argXml = ($Arguments.GetEnumerator() | ForEach-Object {
            "<x:$($_.Key)>$([System.Security.SecurityElement]::Escape([string]$_.Value))</x:$($_.Key)>"
        }) -join ''
    $body = "<s:Envelope xmlns:s=`"http://schemas.xmlsoap.org/soap/envelope/`" xmlns:x=`"$ns`"><s:Body><x:$Operation>$argXml</x:$Operation></s:Body></s:Envelope>"
    $soapHeaders = $headers.Clone()
    $soapHeaders['SOAPAction'] = "$ns`:$Operation"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri "$wsBase/$Service" -Method Post -Headers $soapHeaders -ContentType 'text/xml; charset=utf-8' -Body $body -UseBasicParsing -TimeoutSec $TimeoutSec
        [xml]$xml = $response.Content
        $value = $xml.SelectSingleNode("//*[local-name()='return_value']")
        return [pscustomobject]@{ Ok = $true; Ms = $sw.ElapsedMilliseconds; Value = $(if ($value) { $value.InnerText }); Fault = $null }
    }
    catch {
        $fault = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $fault = $_.ErrorDetails.Message
        }
        elseif ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $fault = $reader.ReadToEnd()
        }
        if ($fault -match '<faultstring[^>]*>([^<]*)<') { $fault = $Matches[1] }
        return [pscustomobject]@{ Ok = $false; Ms = $sw.ElapsedMilliseconds; Value = $null; Fault = $fault }
    }
}

function Set-SpikeMutant([int]$MutantId) {
    $runNoValue = 0
    if ($MutantId -ne 0) { $runNoValue = $RunNo }
    Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = $MutantId; currentRunNo = $runNoValue } | Out-Null
}

function Remove-SpikeRows {
    $rows = Invoke-MutApi -Env $envHandle -Method 'GET' -Path "mutantResults?`$filter=runNo eq $RunNo"
    foreach ($row in @($rows.value)) {
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=$RunNo,mutantId=$($row.mutantId))" | Out-Null
    }
    return @($rows.value)
}

# --- U-A -----------------------------------------------------------------------------------
Write-Output ''
Write-Output '--- U-A: web services ---'
$services = @{}
foreach ($service in 'TestRunner', 'MUTSpikeRunner') {
    try {
        $wsdl = Invoke-WebRequest -Uri "$wsBase/$service" -Headers $headers -UseBasicParsing
        $ops = @([regex]::Matches($wsdl.Content, '<operation name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $services[$service] = $true
        Write-Output "  $service : present, operations: $($ops -join ', ')"
    }
    catch {
        $services[$service] = $false
        Write-Output "  $service : absent ($($_.Exception.Message))"
    }
    Write-SpikeLog @{ phase = 'U-A'; service = $service; present = $services[$service] }
}
if (-not $services['MUTSpikeRunner']) {
    throw 'MUTSpikeRunner is not published. Deploy spikes/soap-runner/app first.'
}

try {
    Set-SpikeMutant 0
    Remove-SpikeRows | Out-Null

    # --- U-B ---------------------------------------------------------------------------------
    Write-Output ''
    Write-Output "--- U-B: latency, codeunit $CodeunitId, no mutant, $Repeat calls each ---"
    $rows = @()
    $targets = @([pscustomobject]@{ CodeunitId = $CodeunitId; Function = $null })
    for ($i = 1; $i -le $Repeat; $i++) {
        if (-not $SkipCli) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $cli = Invoke-MutTests -Env $envHandle -Targets $targets -TimeoutSec 300
            $rows += [pscustomobject]@{ Transport = 'cli'; Ms = $sw.ElapsedMilliseconds; Passed = $cli.Passed; Failed = $cli.Failed; InBcMs = $cli.DurationMs }
            Write-SpikeLog @{ phase = 'U-B'; transport = 'cli'; ms = $sw.ElapsedMilliseconds; passed = $cli.Passed; failed = $cli.Failed }
        }
        $soap = Invoke-SpikeSoap 'MUTSpikeRunner' 'RunTests' @{ codeunitId = $CodeunitId; functionFilter = '' }
        if (-not $soap.Ok) { throw "U-B: SOAP RunTests failed: $($soap.Fault)" }
        $parsed = $soap.Value | ConvertFrom-Json
        $rows += [pscustomobject]@{ Transport = 'soap'; Ms = $soap.Ms; Passed = $parsed.passed; Failed = $parsed.failed; InBcMs = $parsed.ms }
        Write-SpikeLog @{ phase = 'U-B'; transport = 'soap'; ms = $soap.Ms; passed = $parsed.passed; failed = $parsed.failed; inBcMs = $parsed.ms }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Output
    foreach ($t in 'cli', 'soap') {
        $ms = @($rows | Where-Object Transport -eq $t | ForEach-Object { [double]$_.Ms })
        if ($ms.Count) { Write-Output ("  {0}: median {1:n0} ms, min {2:n0}, max {3:n0}" -f $t, (Get-Median $ms), ($ms | Measure-Object -Minimum).Minimum, ($ms | Measure-Object -Maximum).Maximum) }
    }

    if ($MutantIds.Count -eq 0) {
        Write-Output 'No -MutantIds given; skipping U-C..U-E.'
        return
    }

    # --- U-C / U-D: per mutant, CLI vs SOAP ----------------------------------------------------
    Write-Output ''
    Write-Output "--- U-C/U-D: outcome parity, $($MutantIds.Count) mutants ---"
    $parity = @()
    foreach ($mutantId in $MutantIds) {
        $cliStatus = $null
        if (-not $SkipCli) {
            Remove-SpikeRows | Out-Null
            Set-SpikeMutant $mutantId
            try { $cli = Invoke-MutTests -Env $envHandle -Targets $targets -TimeoutSec 300 }
            finally { Set-SpikeMutant 0 }
            $cliStatus = if ($cli.Failed -gt 0) { 'Killed' } elseif ($cli.Passed -gt 0) { 'Survived' } else { 'Error' }
        }

        Remove-SpikeRows | Out-Null
        $soap = Invoke-SpikeSoap 'MUTSpikeRunner' 'RunMutants' @{ codeunitId = $CodeunitId; functionFilter = ''; mutantIds = "$mutantId"; runNo = $RunNo }
        $soapStatus = 'Error'
        $soapMs = $null
        if ($soap.Ok) {
            $r = @($soap.Value | ConvertFrom-Json | ForEach-Object { $_ })[0]
            $soapStatus = if ($r.failed -gt 0) { 'Killed' } elseif ($r.passed -gt 0) { 'Survived' } else { 'Error' }
            $soapMs = $r.ms
        }
        $hookRows = @(Remove-SpikeRows)
        $parity += [pscustomobject]@{
            MutantId = $mutantId; Cli = $cliStatus; Soap = $soapStatus; Match = ($SkipCli -or $cliStatus -eq $soapStatus)
            HookRow = ($hookRows.Count -gt 0); SoapCallMs = $soap.Ms; SoapInBcMs = $soapMs; Fault = $soap.Fault
        }
        Write-SpikeLog @{ phase = 'U-C'; mutantId = $mutantId; cli = $cliStatus; soap = $soapStatus; hookRow = ($hookRows.Count -gt 0); soapCallMs = $soap.Ms; fault = $soap.Fault }
    }
    $parity | Format-Table -AutoSize | Out-String -Width 250 | Write-Output

    # --- U-E: all mutants in one call ---------------------------------------------------------
    Write-Output ''
    Write-Output "--- U-E: $($MutantIds.Count) mutants in ONE SOAP call ---"
    Remove-SpikeRows | Out-Null
    $batch = Invoke-SpikeSoap 'MUTSpikeRunner' 'RunMutants' @{ codeunitId = $CodeunitId; functionFilter = ''; mutantIds = ($MutantIds -join ','); runNo = $RunNo } -TimeoutSec 1800
    if (-not $batch.Ok) { throw "U-E: SOAP RunMutants failed: $($batch.Fault)" }
    $batchRows = @($batch.Value | ConvertFrom-Json | ForEach-Object { $_ })
    $hookRows = @(Remove-SpikeRows)
    $batchTable = foreach ($r in $batchRows) {
        $status = if ($r.failed -gt 0) { 'Killed' } elseif ($r.passed -gt 0) { 'Survived' } else { 'Error' }
        $single = $parity | Where-Object MutantId -eq $r.mutantId
        [pscustomobject]@{ MutantId = $r.mutantId; Batch = $status; Single = $single.Soap; Match = ($status -eq $single.Soap); InBcMs = $r.ms
            HookRow = [bool](@($hookRows | Where-Object mutantId -eq $r.mutantId).Count) }
    }
    $batchTable | Format-Table -AutoSize | Out-String | Write-Output
    $perMutant = $batch.Ms / [math]::Max(1, $batchRows.Count)
    Write-Output ("  batch call {0:n0} ms total, {1:n0} ms per mutant" -f $batch.Ms, $perMutant)
    Write-SpikeLog @{ phase = 'U-E'; mutants = $batchRows.Count; callMs = $batch.Ms; perMutantMs = $perMutant; rows = $batchTable }
}
finally {
    Set-SpikeMutant 0
    Remove-SpikeRows | Out-Null
    Write-Output ''
    Write-Output "Log: $logPath"
}
