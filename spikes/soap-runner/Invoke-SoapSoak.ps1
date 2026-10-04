<#
    .SYNOPSIS
    SOAP-runner soak: run RunMutants batches back to back for a fixed time and record failures.

    .DESCRIPTION
    The job path failed with 503s after 45-60 minutes / 230-255 jobs of continuous use (503
    bisect). This repeats one batch (default: all 157 mutants of 72918635 on 95155) until
    Minutes have passed. Each batch's outcomes are compared with the first batch; any change,
    SOAP fault or HTTP error is logged. Run 15's schemata app must be published.
#>

param(
    [string]$ConfigPath = 'mutation.u2.config.json',
    [int]$CodeunitId = 95155,
    [int[]]$MutantIds = @(),
    [int]$Minutes = 60,
    [int]$RunNo = 99100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outDir = Join-Path $repoRoot 'out\soap-runner'
New-Item -ItemType Directory -Force $outDir | Out-Null
$logPath = Join-Path $outDir ('soak-{0:yyyyMMdd-HHmmss}.jsonl' -f (Get-Date))

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
$dp = Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force -PassThru -WarningAction SilentlyContinue

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}
$cfg = Get-MutConfig -Path $resolvedConfigPath -WarningAction SilentlyContinue
$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle -or $envHandle.Status -ne 'Running') {
    throw "Invoke-SoapSoak: environment '$($cfg.environmentName)' is not running."
}
Assert-MutEnvironmentAllowed $envHandle

if ($MutantIds.Count -eq 0) {
    $MutantIds = @(Get-Content (Join-Path $repoRoot 'out\runs\15\results.jsonl') | Where-Object { $_ } |
        ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { @($_.CoveringTests) -contains $CodeunitId } | ForEach-Object { [int]$_.Id })
}

$apiBase = Get-MutApiBase -Env $envHandle
$credential = & $dp { param($e) Get-MutCredential -Env $e } $envHandle
$headers = & $dp { param($c) Get-MutBasicAuthHeader -Credential $c } $credential
$company = @((Invoke-RestMethod -Uri "$apiBase/api/v2.0/companies" -Headers $headers).value)[0].name
$serviceUrl = "$apiBase/WS/$([uri]::EscapeDataString($company))/Codeunit/MUTSpikeRunner"
$ns = 'urn:microsoft-dynamics-schemas/codeunit/MUTSpikeRunner'
$soapHeaders = $headers.Clone()
$soapHeaders['SOAPAction'] = "$ns`:RunMutants"
$body = "<s:Envelope xmlns:s=`"http://schemas.xmlsoap.org/soap/envelope/`" xmlns:x=`"$ns`"><s:Body><x:RunMutants><x:codeunitId>$CodeunitId</x:codeunitId><x:functionFilter></x:functionFilter><x:mutantIds>$($MutantIds -join ',')</x:mutantIds><x:runNo>$RunNo</x:runNo></x:RunMutants></s:Body></s:Envelope>"

$reference = $null
$batches = 0
$failures = 0
$deadline = (Get-Date).AddMinutes($Minutes)
try {
    while ((Get-Date) -lt $deadline) {
        $batches++
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $record = [ordered]@{ batch = $batches; at = (Get-Date).ToString('o') }
        try {
            $response = Invoke-WebRequest -Uri $serviceUrl -Method Post -Headers $soapHeaders -ContentType 'text/xml; charset=utf-8' -Body $body -UseBasicParsing -TimeoutSec 600
            [xml]$xml = $response.Content
            $rows = @($xml.SelectSingleNode("//*[local-name()='return_value']").InnerText | ConvertFrom-Json | ForEach-Object { $_ })
            $outcomes = ($rows | ForEach-Object { '{0}:{1}' -f $_.mutantId, $(if ($_.failed -gt 0) { 'K' } else { 'S' }) }) -join ','
            if ($null -eq $reference) { $reference = $outcomes }
            $record.ok = $true
            $record.killed = @($rows | Where-Object { $_.failed -gt 0 }).Count
            $record.sameAsFirst = ($outcomes -eq $reference)
            if (-not $record.sameAsFirst) { $failures++ }
        }
        catch {
            $failures++
            $record.ok = $false
            $record.error = $_.Exception.Message
        }
        $record.ms = $sw.ElapsedMilliseconds
        ($record | ConvertTo-Json -Compress) | Add-Content -Path $logPath -Encoding utf8
        Write-Output ('batch {0}: ok={1} killed={2} same={3} {4:n0} ms {5}' -f $batches, $record.ok, $record['killed'], $record['sameAsFirst'], $record.ms, $record['error'])

        # Leave the 62 hook rows of each batch from piling up.
        $existing = Invoke-MutApi -Env $envHandle -Method 'GET' -Path "mutantResults?`$filter=runNo eq $RunNo"
        foreach ($row in @($existing.value)) {
            Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path "mutantResults(runNo=$RunNo,mutantId=$($row.mutantId))" | Out-Null
        }
    }
}
finally {
    Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = 0 } | Out-Null
    Write-Output "SOAK DONE: $batches batches, $($batches * $MutantIds.Count) mutant runs, $failures failures. Log: $logPath"
}
