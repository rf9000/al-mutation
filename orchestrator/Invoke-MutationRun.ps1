<#
    .SYNOPSIS
    §6.5.4: entry point for one mutation-testing run. Loads the config, imports the orchestrator
    libs and the backend module named by the config, runs the nine-step pipeline
    (orchestrator/lib/Run.psm1), and prints the results/summary paths.

    .PARAMETER ConfigPath
    Path to a §6.5.1-shaped config file (e.g. mutation.fixture.config.json).

    .PARAMETER RunNo
    Explicit run number. Omit to auto-compute 1 + the highest `<n>.json` under results/.

    .PARAMETER SkipEnvironment
    Requires an already-existing, already-known environment (throws if none is found); never
    creates one.

    .PARAMETER SkipBaseline
    Skips the baseline step's real work only when `<RunDir>/baseline.json` already exists for
    this run number; otherwise it has no effect (§6.5.4/T27).

    .NOTES
    §4 item 6: this script and orchestrator/lib/*.psm1 must never name the backend CLI tool or
    the container-based backend by name in source text -- only orchestrator/backends/*.psm1 may.
    The backend module to import is resolved entirely from the config's own `backend` value.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [int]$RunNo = 0,
    [switch]$SkipEnvironment,
    [switch]$SkipBaseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$libDir = Join-Path $PSScriptRoot 'lib'
$backendsDir = Join-Path $PSScriptRoot 'backends'

# Run.psm1 is imported FIRST: it nests its own Import-Module of Config.psm1 (and the other lib
# modules) inside its own private module session state at load time, which is the correct
# behaviour for Run.psm1's own unqualified internal calls but does NOT publish those commands to
# the global scope this script itself runs in. Re-importing Config.psm1 directly afterward (line
# below) re-registers it as a top-level, globally-visible module so this script's own
# `Get-MutConfig` call resolves -- verified empirically: importing Run.psm1 after Config.psm1
# instead left Get-MutConfig unresolvable at the script's own scope even though Config.psm1 was
# already imported once above.
Import-Module (Join-Path $libDir 'Run.psm1') -Force
Import-Module (Join-Path $libDir 'Config.psm1') -Force

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}

$config = Get-MutConfig -Path $resolvedConfigPath

$backendModulePath = Join-Path $backendsDir "$($config.backend).psm1"
if (-not (Test-Path -Path $backendModulePath)) {
    throw "Invoke-MutationRun: no backend module found for backend '$($config.backend)' at '$backendModulePath'."
}
Import-Module $backendModulePath -Force

$pipelineParams = @{
    Config          = $config
    SkipEnvironment = [bool]$SkipEnvironment
    SkipBaseline    = [bool]$SkipBaseline
}
if ($RunNo -gt 0) {
    $pipelineParams['RunNo'] = $RunNo
}

$result = Invoke-MutRunPipeline @pipelineParams

Write-Output "Results:  $($result.ResultsPath)"
Write-Output "Summary:  $($result.SummaryPath)"
