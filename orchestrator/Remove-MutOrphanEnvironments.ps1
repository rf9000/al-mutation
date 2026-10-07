<#
    .SYNOPSIS
    Deletes every environment whose name starts with -Prefix, except -Keep and except Shared
    ones. mutant-fixer runs it at the start of every poll cycle with -Prefix mut-pr- to remove
    per-PR environments that a crashed or killed job left behind.

    .PARAMETER Prefix
    Name prefix. Must start with 'mut-' and be longer than it (case-sensitive).

    .PARAMETER Keep
    An environment name to leave alone, even though it matches the prefix.

    .PARAMETER ConfigPath
    Config file that supplies the backend and its CLI path (MUT_CLI_PATH overrides the latter).
    Defaults to the repo's mutation.config.json.

    .NOTES
    Exit codes: 0 when the sweep ran, also when a single delete failed (printed as a warning);
    1 when the prefix is refused or the environments cannot be listed. Prints one line per
    deleted environment. Like every entry script, it never names the backend tool (§4 item 6).
#>
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Prefix,
    [string]$Keep = '',
    [string]$ConfigPath = 'mutation.config.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$libDir = Join-Path $PSScriptRoot 'lib'
$backendsDir = Join-Path $PSScriptRoot 'backends'

try {
    # Checked here as well as in the backend, so a bad prefix fails before any config or CLI work.
    if (-not $Prefix.StartsWith('mut-', [System.StringComparison]::Ordinal) -or $Prefix.Length -le 'mut-'.Length) {
        throw "prefix '$Prefix' must start with 'mut-' and name more than 'mut-' itself; refusing to sweep."
    }

    Import-Module (Join-Path $libDir 'Config.psm1') -Force

    $resolvedConfigPath = $ConfigPath
    if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
        $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
    }
    $config = Get-MutConfig -Path $resolvedConfigPath 3>$null

    $backendModulePath = Join-Path $backendsDir "$($config.backend).psm1"
    if (-not (Test-Path -LiteralPath $backendModulePath)) {
        throw "no backend module found for backend '$($config.backend)' at '$backendModulePath'."
    }
    Import-Module $backendModulePath -Force 3>$null

    foreach ($name in @(Remove-MutOrphanEnvironments -Prefix $Prefix -Keep $Keep -Config $config)) {
        Write-Output "Deleted environment '$name'."
    }
    exit 0
}
catch {
    Write-Output "Remove-MutOrphanEnvironments failed: $($_.Exception.Message)"
    exit 1
}
