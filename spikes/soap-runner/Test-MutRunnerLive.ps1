<#
    .SYNOPSIS
    Live check of the Mutation Core 1.1.0.0 SOAP service MUTRunner (SPEC 6.10.2) on a mut-* environment.

    .DESCRIPTION
    Adapts Invoke-SoapRunnerSpike.ps1 and Invoke-SoapTimeoutSpike.ps1 to the MUTRunner service.
    Run 15's schemata app must be the installed AUT.

      W  WSDL lists RunMutants, RunTests, GetRunnerState, StopRunner, DeleteRunnerState.
      A  RunMutants over the run-15 mutants whose covering set is [95155] (one call), compared with
         out/runs/15/results.jsonl (status; killing test reported separately).
      B  RunMutants with the filter '95155|95110' over a few run-15 mutants. Run 15 has no mutant
         with 2+ covering codeunits, so these are mutants recorded with CoveringTests [95155]; the
         extra codeunit 95110 must not change their outcome.
      C  Mutant 4515 on 95121 (a run-15 Timeout) in a background runspace with a 30 s client
         timeout; GetRunnerState; StopRunner(BatchId); RunTests 95155 until failed = 0 within 30 s;
         DeleteRunnerState.

    Cleans up: result rows of the run number it uses and all runner state rows; leaves
    activeMutantId 0 on every exit path. Exit code 0 only when every check passed.
#>

param(
    [string]$ConfigPath = 'mutation.u2.config.json',
    [int]$RunNo = 99200,
    [int]$ReferenceRun = 15,
    [int]$CodeunitId = 95155,
    [int]$ExtraCodeunitId = 95110,
    [int]$SampleSize = 5,
    [int]$HangCodeunitId = 95121,
    [int]$HangMutantId = 4515,
    [int]$HangClientTimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outDir = Join-Path $repoRoot 'out\soap-runner'
New-Item -ItemType Directory -Force $outDir | Out-Null
$logPath = Join-Path $outDir ('mutrunner-{0:yyyyMMdd-HHmmss}.jsonl' -f (Get-Date))

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
$dp = Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force -PassThru -WarningAction SilentlyContinue

function Write-Log($Record) {
    ($Record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $logPath -Encoding utf8
}

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}
$cfg = Get-MutConfig -Path $resolvedConfigPath -WarningAction SilentlyContinue

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle -or $envHandle.Status -ne 'Running') {
    throw "Test-MutRunnerLive: environment '$($cfg.environmentName)' is not running."
}
Assert-MutEnvironmentAllowed $envHandle

$apiBase = Get-MutApiBase -Env $envHandle
$credential = & $dp { param($e) Get-MutCredential -Env $e } $envHandle
$headers = & $dp { param($c) Get-MutBasicAuthHeader -Credential $c } $credential
$company = @((Invoke-RestMethod -Uri "$apiBase/api/v2.0/companies" -Headers $headers).value)[0].name
$serviceUrl = "$apiBase/WS/$([uri]::EscapeDataString($company))/Codeunit/MUTRunner"
$ns = 'urn:microsoft-dynamics-schemas/codeunit/MUTRunner'
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

function Invoke-Soap([string]$Operation, [hashtable]$Arguments, [int]$TimeoutSec = 600) {
    $request = New-SoapRequest $Operation $Arguments
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $serviceUrl -Method Post -Headers $request.Headers -ContentType 'text/xml; charset=utf-8' -Body $request.Body -UseBasicParsing -TimeoutSec $TimeoutSec
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
            $fault = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
        }
        if ($fault -match '<faultstring[^>]*>([^<]*)<') { $fault = $Matches[1] }
        return [pscustomobject]@{ Ok = $false; Ms = $sw.ElapsedMilliseconds; Value = $null; Fault = $fault }
    }
}

function Set-ActiveMutantZero {
    Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = 0 } | Out-Null
}

function Remove-ResultRows {
    $rows = Invoke-MutApi -Env $envHandle -Method 'GET' -Path "mutantResults?`$filter=runNo eq $RunNo"
    foreach ($row in @($rows.value)) {
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=$RunNo,mutantId=$($row.mutantId))" | Out-Null
    }
    return @($rows.value)
}

function Get-RunnerState {
    $r = Invoke-Soap 'GetRunnerState' @{} 60
    if (-not $r.Ok) { throw "GetRunnerState failed: $($r.Fault)" }
    return ($r.Value | ConvertFrom-Json)
}

function Clear-RunnerState {
    foreach ($row in @((Get-RunnerState).rows)) {
        Invoke-Soap 'DeleteRunnerState' @{ batchId = $row.batchId } 60 | Out-Null
    }
}

function Get-Verdict($Result) {
    if ($Result.failed -gt 0) { return 'Killed' }
    if ($Result.passed -gt 0) { return 'Survived' }
    return 'Error'
}

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Pass, [string]$Detail) {
    $checks.Add([pscustomobject]@{ Check = $Name; Pass = $Pass; Detail = $Detail })
    Write-Output ("  [{0}] {1}: {2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
    Write-Log @{ check = $Name; pass = $Pass; detail = $Detail }
}

$referencePath = Join-Path $repoRoot "out\runs\$ReferenceRun\results.jsonl"
$reference = @(Get-Content $referencePath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$referenceById = @{}
foreach ($r in $reference) { $referenceById[[int]$r.Id] = $r }
$ownMutants = @($reference | Where-Object { @($_.CoveringTests).Count -eq 1 -and @($_.CoveringTests)[0] -eq $CodeunitId -and $_.Status -in 'Killed', 'Survived' } | Sort-Object { [int]$_.Id })
Write-Output "Run $ReferenceRun reference: $($ownMutants.Count) decided mutants covered by $CodeunitId."

$runspace = $null
try {
    Set-ActiveMutantZero
    Clear-RunnerState
    Remove-ResultRows | Out-Null

    # --- W ------------------------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- W: WSDL ---'
    $wsdl = Invoke-WebRequest -Uri $serviceUrl -Headers $headers -UseBasicParsing
    $ops = @([regex]::Matches($wsdl.Content, '<operation name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $missing = @('RunMutants', 'RunTests', 'GetRunnerState', 'StopRunner', 'DeleteRunnerState' | Where-Object { $ops -notcontains $_ })
    Add-Check 'WSDL operations' ($missing.Count -eq 0) "operations: $($ops -join ', ')"

    # --- A ------------------------------------------------------------------------------------
    Write-Output ''
    Write-Output "--- A: RunMutants over $($ownMutants.Count) mutants of $CodeunitId in one call ---"
    $batchA = [guid]::NewGuid().ToString()
    $ids = @($ownMutants | ForEach-Object { [int]$_.Id })
    $a = Invoke-Soap 'RunMutants' @{ batchId = $batchA; codeunitIds = "$CodeunitId"; mutantIds = ($ids -join ','); runNo = $RunNo } 1800
    if (-not $a.Ok) { throw "A: RunMutants failed: $($a.Fault)" }
    $entries = @($a.Value | ConvertFrom-Json | ForEach-Object { $_ })
    $match = 0
    $mismatch = @()
    $killTextDiff = 0
    foreach ($e in $entries) {
        $ref = $referenceById[[int]$e.mutantId]
        if ($e.status -eq $ref.Status) { $match++ } else { $mismatch += "$($e.mutantId): run $ReferenceRun=$($ref.Status) now=$($e.status)" }
        if ($ref.Status -eq 'Killed' -and $e.status -eq 'Killed' -and $e.killingTest -ne $ref.KillingTest) { $killTextDiff++ }
    }
    $apiRows = @(Remove-ResultRows)
    Write-Output ("  call {0:n0} ms total, {1:n0} ms per mutant; {2} API result rows" -f $a.Ms, ($a.Ms / [math]::Max(1, $entries.Count)), $apiRows.Count)
    Write-Output "  killing-test text differing from run $ReferenceRun (informational): $killTextDiff"
    Add-Check 'A parity' (($match -eq $ownMutants.Count) -and ($entries.Count -eq $ownMutants.Count)) "$match/$($ownMutants.Count) match run $ReferenceRun $($mismatch -join '; ')"
    Add-Check 'A result rows' ($apiRows.Count -eq $ownMutants.Count) "$($apiRows.Count) rows for run $RunNo (expected $($ownMutants.Count))"
    $rowA = @((Get-RunnerState).rows | Where-Object { $_.batchId -eq $batchA })
    $okA = $false
    $detailA = 'no row'
    if ($rowA.Count -eq 1) {
        $okA = $rowA[0].finished -and ($rowA[0].mutantId -eq 0) -and ($rowA[0].mutantsDone -eq $ownMutants.Count)
        $detailA = "finished=$($rowA[0].finished) mutantId=$($rowA[0].mutantId) mutantsDone=$($rowA[0].mutantsDone)"
    }
    Add-Check 'A state row' $okA $detailA
    Invoke-Soap 'DeleteRunnerState' @{ batchId = $batchA } 60 | Out-Null

    # --- B ------------------------------------------------------------------------------------
    $multiCovering = @($reference | Where-Object { @($_.CoveringTests).Count -ge 2 -and $_.Status -in 'Killed', 'Survived' })
    if ($multiCovering.Count -ge $SampleSize) {
        $sample = @($multiCovering | Select-Object -First $SampleSize)
        $filterB = (@($sample[0].CoveringTests) -join '|')
        $sampleNote = "run $ReferenceRun mutants with 2+ covering codeunits"
    }
    else {
        $killed = @($ownMutants | Where-Object Status -eq 'Killed' | Select-Object -First ([math]::Ceiling($SampleSize / 2)))
        $survived = @($ownMutants | Where-Object Status -eq 'Survived' | Select-Object -First ($SampleSize - $killed.Count))
        $sample = @($killed + $survived | Sort-Object { [int]$_.Id })
        $filterB = "$CodeunitId|$ExtraCodeunitId"
        $sampleNote = "run $ReferenceRun has no mutant with 2+ covering codeunits; used $SampleSize mutants recorded with [$CodeunitId] and the filter '$filterB'"
    }
    Write-Output ''
    Write-Output "--- B: RunMutants filter '$filterB', mutants $((@($sample | ForEach-Object { $_.Id })) -join ',') ---"
    Write-Output "  ($sampleNote)"
    $batchB = [guid]::NewGuid().ToString()
    $b = Invoke-Soap 'RunMutants' @{ batchId = $batchB; codeunitIds = $filterB; mutantIds = ((@($sample | ForEach-Object { $_.Id })) -join ','); runNo = $RunNo } 600
    if (-not $b.Ok) { throw "B: RunMutants failed: $($b.Fault)" }
    $entriesB = @($b.Value | ConvertFrom-Json | ForEach-Object { $_ })
    $matchB = 0
    foreach ($e in $entriesB) {
        $ref = $referenceById[[int]$e.mutantId]
        $same = ($e.status -eq $ref.Status)
        if ($same) { $matchB++ }
        Write-Output ("  mutant {0}: run {1}={2}, now={3} passed={4} failed={5} killingTest={6}" -f $e.mutantId, $ReferenceRun, $ref.Status, $e.status, $e.passed, $e.failed, $e.killingTest)
    }
    Remove-ResultRows | Out-Null
    Add-Check 'B multi-codeunit sample' (($matchB -eq $sample.Count) -and ($entriesB.Count -eq $sample.Count)) "$matchB/$($sample.Count) match run $ReferenceRun; $sampleNote"
    Invoke-Soap 'DeleteRunnerState' @{ batchId = $batchB } 60 | Out-Null

    # --- C ------------------------------------------------------------------------------------
    Write-Output ''
    Write-Output "--- C: hung mutant $HangMutantId on $HangCodeunitId, client timeout $HangClientTimeoutSec s ---"
    $batchC = [guid]::NewGuid().ToString()
    $request = New-SoapRequest 'RunMutants' @{ batchId = $batchC; codeunitIds = "$HangCodeunitId"; mutantIds = "$HangMutantId"; runNo = $RunNo }
    $runspace = [powershell]::Create()
    [void]$runspace.AddScript({
            param($Uri, $Headers, $Body, $Timeout)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -ContentType 'text/xml; charset=utf-8' -Body $Body -UseBasicParsing -TimeoutSec $Timeout | Out-Null
                "returned after $($sw.ElapsedMilliseconds) ms"
            }
            catch { "failed after $($sw.ElapsedMilliseconds) ms: $($_.Exception.Message)" }
        }).AddArgument($serviceUrl).AddArgument($request.Headers).AddArgument($request.Body).AddArgument($HangClientTimeoutSec)
    $async = $runspace.BeginInvoke()
    Start-Sleep -Seconds 10

    $state = Get-RunnerState
    $rowC = @($state.rows | Where-Object { $_.batchId -eq $batchC })
    $inMutant = ($rowC.Count -eq 1) -and ($rowC[0].mutantId -eq $HangMutantId) -and (-not $rowC[0].finished)
    $detailC = if ($rowC.Count -eq 1) { "sessionId=$($rowC[0].sessionId) mutantId=$($rowC[0].mutantId) startedAt=$($rowC[0].mutantStartedAt) serverNowUtc=$($state.serverNowUtc)" } else { 'no row' }
    Add-Check 'C state row while hung' $inMutant $detailC

    $async.AsyncWaitHandle.WaitOne(($HangClientTimeoutSec + 30) * 1000) | Out-Null
    Write-Output "  runaway call: $(if ($async.IsCompleted) { $runspace.EndInvoke($async) } else { 'still waiting' })"

    $stopSw = [Diagnostics.Stopwatch]::StartNew()
    $stop = Invoke-Soap 'StopRunner' @{ batchId = $batchC } 60
    Write-Output "  StopRunner: ok=$($stop.Ok) $($stop.Value) $($stop.Fault) ($($stop.Ms) ms)"
    Add-Check 'C StopRunner by BatchId' $stop.Ok "$($stop.Value) $($stop.Fault)"

    $healthy = $false
    $stoppedAfterSec = $null
    for ($i = 1; $i -le 24; $i++) {
        Start-Sleep -Seconds 5
        $h = Invoke-Soap 'RunTests' @{ codeunitIds = "$CodeunitId" } 120
        $hp = $null
        if ($h.Ok) { $hp = $h.Value | ConvertFrom-Json }
        Write-Output ("  health after {0:n0} s: {1}, {2:n0} ms" -f $stopSw.Elapsed.TotalSeconds, $(if ($h.Ok) { "$($hp.passed) passed, $($hp.failed) failed" } else { "FAILED: $($h.Fault)" }), $h.Ms)
        if ($h.Ok -and $hp.failed -eq 0 -and $hp.passed -gt 0 -and $h.Ms -lt 30000) {
            $healthy = $true
            $stoppedAfterSec = [math]::Round($stopSw.Elapsed.TotalSeconds, 1)
            break
        }
    }
    Add-Check 'C RunTests after stop' $healthy "failed = 0 within 30 s after $stoppedAfterSec s from StopRunner"

    $rowAfter = @((Get-RunnerState).rows | Where-Object { $_.batchId -eq $batchC })
    Add-Check 'C stop keeps the row' (($rowAfter.Count -eq 1) -and (-not $rowAfter[0].finished)) "row present=$($rowAfter.Count -eq 1)"
    $del = Invoke-Soap 'DeleteRunnerState' @{ batchId = $batchC } 60
    $rowGone = @((Get-RunnerState).rows | Where-Object { $_.batchId -eq $batchC }).Count -eq 0
    Add-Check 'C DeleteRunnerState' ($del.Ok -and $rowGone) "$($del.Value)"
}
finally {
    if ($runspace) { $runspace.Dispose() }
    try { Set-ActiveMutantZero } catch { Write-Output "cleanup: PATCH activeMutantId=0 failed: $($_.Exception.Message)" }
    try { Remove-ResultRows | Out-Null } catch { Write-Output "cleanup: deleting result rows failed: $($_.Exception.Message)" }
    try { Clear-RunnerState } catch { Write-Output "cleanup: clearing runner state failed: $($_.Exception.Message)" }
    try {
        $setup = Invoke-MutApi -Env $envHandle -Method 'GET' -Path 'mutationSetup(0)'
        Add-Check 'health: activeMutantId' ($setup.activeMutantId -eq 0) "activeMutantId=$($setup.activeMutantId) currentRunNo=$($setup.currentRunNo)"
        $left = @((Get-RunnerState).rows).Count
        Add-Check 'health: no runner rows' ($left -eq 0) "$left rows left"
    }
    catch { Write-Output "cleanup: health read failed: $($_.Exception.Message)" }
    Write-Output ''
    Write-Output "Log: $logPath"
}

$failedChecks = @($checks | Where-Object { -not $_.Pass })
Write-Output ''
Write-Output ("{0} checks, {1} failed." -f $checks.Count, $failedChecks.Count)
if ($failedChecks.Count -gt 0) { exit 1 }
