<#
    .SYNOPSIS
    §6.7.4 stage 3: validates results/<RunNo>-fixes.json against results/<RunNo>-fix-briefs.json.
    On errors prints each one and exits 1; otherwise writes results/<RunNo>-fixes.md, prints
    `ok` and exits 0. Touches no environment.

    .PARAMETER RunNo
    The run whose fix briefs and fixes report to check.
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$RunNo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'FixBriefs.psm1') -Force
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'Config.psm1')
$resultsDir = Get-MutResultsDir -RepoRoot $repoRoot

$briefsPath = Join-Path $resultsDir "$RunNo-fix-briefs.json"
$fixesPath = Join-Path $resultsDir "$RunNo-fixes.json"
$markdownPath = Join-Path $resultsDir "$RunNo-fixes.md"

# Test-MutFixReport returns its [string[]] with the unary comma; wrapping it in @() again would
# make a one-element array holding an empty array, so a valid report would still exit 1.
$errors = Test-MutFixReport -BriefsPath $briefsPath -FixesPath $fixesPath -RepoRoot $repoRoot
if ($errors.Count -gt 0) {
    foreach ($message in $errors) {
        Write-Output $message
    }
    exit 1
}

Export-MutFixMarkdown -BriefsPath $briefsPath -FixesPath $fixesPath -OutPath $markdownPath
Write-Output 'ok'
exit 0
