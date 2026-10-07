<#
    .SYNOPSIS
    Deletes the environment named in a config (environmentName), also when the config says
    keepEnvironment. mutant-fixer keeps one environment per PR commit through the run and the
    verify, then deletes it with this script.

    .PARAMETER ConfigPath
    Path to a §6.5.1-shaped config file. Relative paths resolve against the repo root.

    .NOTES
    Exit codes: 0 when the environment was deleted or was already gone; 1 on any failure,
    including a name not matching '^mut-' or a Shared environment. Prints one line saying what
    happened. Like every entry script, it never names the backend tool (§4 item 6).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$libDir = Join-Path $PSScriptRoot 'lib'
$backendsDir = Join-Path $PSScriptRoot 'backends'

try {
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

    $deleted = Remove-MutRunEnvironment -Config $config
    if ($null -eq $deleted) {
        Write-Output "Environment '$($config.environmentName)' is already gone."
    }
    else {
        Write-Output "Deleted environment '$deleted'."
    }
    exit 0
}
catch {
    Write-Output "Remove-MutRunEnvironment failed: $($_.Exception.Message)"
    exit 1
}
