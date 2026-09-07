<#
    .SYNOPSIS
    Ensures the mut-spike-01 DemoPortal environment used by every spike and POC run in this
    project is present and Running. See docs/SPEC.md §6.6.1.

    .DESCRIPTION
    Loads mutation.config.json, imports the DemoPortal backend, and calls Get-MutEnvironment
    to look for an existing 'mut-spike-01' environment (matched by description).

    If none exists, calls New-MutEnvironment to create/start/prepare one (records
    CreateDurationSec on the returned handle).

    If one already exists, calls Start-MutEnvironment instead: it idempotently brings a Draft
    or Stopped environment to Running, installs the Continia Core Internal Activation App, and
    sets the workspace default (`env use`). Start-MutEnvironment never creates a new
    environment, so this path is safe to take even when the environment is already Running (in
    which case StartDurationSec is 0 and only the activation-app install and `env use` run
    again). New-MutEnvironment is deliberately not called when a handle is already found — it
    would create a duplicate `mut-spike-01`.

    Prints the resulting handle as JSON (the handle carries no credentials) and appends its
    timings to docs/spike-baseline.md §Environment on every run.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$configPath = Join-Path $repoRoot 'mutation.config.json'
$cfg = Get-Content -Raw -Path $configPath | ConvertFrom-Json

Import-Module "$PSScriptRoot/../orchestrator/backends/DemoPortal.psm1" -Force

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle) {
    $envHandle = New-MutEnvironment -Name $cfg.environmentName -Config $cfg
}
else {
    $envHandle = Start-MutEnvironment -Env $envHandle -Config $cfg
}

$envHandle | ConvertTo-Json -Depth 10 | Write-Output

# New-MutEnvironment adds a CreateDurationSec member to the handle; Start-MutEnvironment does
# not (it never creates an environment). When taking the Get -> Start path against an
# environment created outside this run, the create time is not something this run measured.
$createDurationProperty = $envHandle.PSObject.Properties['CreateDurationSec']
$createDurationValue = 'n/a (created in attempt 2 at 2026-09-07 13:42:53 UTC; started manually)'
if ($null -ne $createDurationProperty) {
    $createDurationValue = $createDurationProperty.Value
}

$baselinePath = Join-Path $repoRoot 'docs\spike-baseline.md'
# docs/spike-baseline.md is UTF-8 without a byte-order mark (it contains literal '§'
# characters). PowerShell 5.1's Get-Content/Set-Content -Encoding UTF8 default to the system
# codepage for BOM-less input and always emit a BOM on write, which double-encodes/corrupts
# the existing '§' bytes into mojibake and adds a BOM the file never had. Read/write via the
# .NET file APIs with an explicit no-BOM UTF8 encoding instead, which round-trips byte-for-byte.
$noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
$lines = @([System.IO.File]::ReadAllLines($baselinePath, [System.Text.Encoding]::UTF8))
$date = '2026-09-07'

$newRows = @(
    "| Environment Id | $($envHandle.Id) | DemoPortal | $date | T03 |"
    "| CreateDurationSec | $createDurationValue | DemoPortal | $date | T03 |"
    "| StartDurationSec | $($envHandle.StartDurationSec) | DemoPortal | $date | T03 |"
    "| ActivationInstallDurationSec | $($envHandle.ActivationInstallDurationSec) | DemoPortal | $date | T03 |"
)

$sectionIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '## Environment') {
        $sectionIndex = $i
        break
    }
}
if ($sectionIndex -lt 0) {
    throw "docs/spike-baseline.md: '## Environment' section not found."
}

$separatorIndex = -1
for ($i = $sectionIndex; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\|---') {
        $separatorIndex = $i
        break
    }
}
if ($separatorIndex -lt 0) {
    throw "docs/spike-baseline.md: table separator not found under '## Environment'."
}

$before = $lines[0..$separatorIndex]
$after = @()
if ($separatorIndex + 1 -lt $lines.Count) {
    $after = $lines[($separatorIndex + 1)..($lines.Count - 1)]
}

$newLines = $before + $newRows + $after
[System.IO.File]::WriteAllLines($baselinePath, [string[]]$newLines, $noBomUtf8)

Write-Output "Appended Environment timing rows to docs/spike-baseline.md for $date (task T03)."
