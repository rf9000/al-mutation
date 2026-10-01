<#
    .SYNOPSIS
    §6.7.2: writes results/<RunNo>-fix-briefs.json for a finished run (stage 1 of the fix
    suggestions). Works on any past run; touches no environment.

    .PARAMETER ConfigPath
    Path to a §6.5.1-shaped config file (e.g. mutation.config.json); relative paths resolve
    against the repo root.

    .PARAMETER RunNo
    The run whose results/<RunNo>.json and <workDir>/runs/<RunNo>/gen/mutants.json to read.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [Parameter(Mandatory = $true)]
    [int]$RunNo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$libDir = Join-Path $PSScriptRoot 'lib'

# FixBriefs.psm1 first: it nests its own imports of Config/References privately, so those two
# are re-imported afterwards to make Get-MutConfig resolvable at this script's own scope (the
# same ordering Invoke-MutationRun.ps1 needs).
Import-Module (Join-Path $libDir 'FixBriefs.psm1') -Force
Import-Module (Join-Path $libDir 'Config.psm1') -Force
Import-Module (Join-Path $libDir 'References.psm1') -Force

$resolvedConfigPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $repoRoot $ConfigPath
}

$config = Get-MutConfig -Path $resolvedConfigPath
$path = Export-MutFixBriefs -RunNo $RunNo -Config $config -RepoRoot $repoRoot

Write-Output "Fix briefs: $path"
