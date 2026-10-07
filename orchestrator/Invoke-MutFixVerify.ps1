<#
    .SYNOPSIS
    §6.8.2: verifies the suggested fixes of results/<RunNo>-fixes.json on the environment named
    in the config and writes results/<RunNo>-verified.json (merged with an existing file).
    Use the config the mutation run used, so the environment and the settle probe match.

    .PARAMETER ConfigPath
    Path to a §6.5.1-shaped config file (e.g. mutation.u2.config.json).

    .PARAMETER RunNo
    The mutation run whose fixes report is verified.

    .PARAMETER FixIds
    Optional comma-separated fix ids (F033,F022). Omit to verify every entry.

    .NOTES
    Strictly one test job at a time. Always ends by republishing the unpatched
    <workDir>/test-app and confirming activeMutantId 0. Exit code 0 when the step completed
    (whatever the per-entry verdicts), 1 on a thrown error.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [Parameter(Mandatory = $true)]
    [int]$RunNo,
    [string]$FixIds = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$libDir = Join-Path $PSScriptRoot 'lib'
$backendsDir = Join-Path $PSScriptRoot 'backends'

Import-Module (Join-Path $libDir 'Config.psm1') -Force

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}
$config = Get-MutConfig -Path $resolvedConfigPath

$backendModulePath = Join-Path $backendsDir "$($config.backend).psm1"
if (-not (Test-Path -Path $backendModulePath)) {
    throw "Invoke-MutFixVerify: no backend module found for backend '$($config.backend)' at '$backendModulePath'."
}
Import-Module $backendModulePath -Force
Import-Module (Join-Path $libDir 'FixVerify.psm1') -Force
Import-Module (Join-Path $libDir 'EnvLock.psm1') -Force

$ids = @()
if ($FixIds) {
    $ids = @($FixIds -split '[,\s]+' | Where-Object { $_ })
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Enter-MutEnvLock -WorkDir $config.workDir -RunNo $RunNo -Owner 'Invoke-MutFixVerify.ps1'
    $params = @{ Config = $config; RunNo = $RunNo; RepoRoot = $repoRoot }
    if ($ids.Count -gt 0) { $params['FixIds'] = $ids }
    $result = Invoke-MutFixVerify @params
}
catch {
    Write-Output ("Invoke-MutFixVerify failed: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    Exit-MutEnvLock -WorkDir $config.workDir
}

foreach ($entry in @($result.entries)) {
    $killed = @(@($entry.mutants) | Where-Object { $_.outcome -eq 'killed' -or $_.outcome -eq 'timeout' }).Count
    $original = 'n/a'
    if ($null -ne $entry.original -and $null -ne $entry.original.result) { $original = [string]$entry.original.result }
    Write-Output ('{0,-6} {1,-18} original={2,-5} killed={3}/{4}' -f $entry.fixId, $entry.verdict, $original, $killed, @($entry.mutants).Count)
}
Write-Output ('Environment: {0}; wall clock {1:N1} min' -f $result.environmentName, $stopwatch.Elapsed.TotalMinutes)
Write-Output ('Results:  {0}' -f (Join-Path (Get-MutResultsDir -RepoRoot $repoRoot) "$RunNo-verified.json"))
exit 0
