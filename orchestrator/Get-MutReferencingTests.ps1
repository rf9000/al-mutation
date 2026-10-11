<#
    .SYNOPSIS
    Lists the test codeunits in a test app that reference the given AUT objects: the §6.5.5
    reference map, inverted. mutant-fixer uses it to pick the test codeunits for each PR.

    .PARAMETER AutPath
    The AUT source folder.

    .PARAMETER TestAppPath
    The test app source folder.

    .PARAMETER Objects
    Comma-separated AUT object ids, e.g. '72918731,72918734'. A string, so it passes through
    `pwsh -File` unchanged.

    .NOTES
    Prints one JSON line: [ { "codeunit": <id>, "objects": [<ids>] } ], sorted by codeunit id,
    objects ascending; [] when no test codeunit references any of the objects. Parser warnings go
    to stderr. Exit codes: 0 on success, also for []; 1 when a folder does not exist, or -Objects
    is empty or holds a value that is not an integer. Starts no environment.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$AutPath,

    [Parameter(Mandatory = $true)]
    [string]$TestAppPath,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Objects
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    foreach ($path in @($AutPath, $TestAppPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "folder not found: '$path'."
        }
    }

    $wanted = @{}
    foreach ($part in ($Objects -split ',')) {
        $text = $part.Trim()
        if ($text -eq '') { continue }
        $id = 0
        if (-not [int]::TryParse($text, [ref]$id)) {
            throw "-Objects holds '$text', which is not an integer."
        }
        $wanted[$id] = $true
    }
    if ($wanted.Count -eq 0) {
        throw '-Objects is empty.'
    }

    Import-Module (Join-Path $PSScriptRoot 'lib/References.psm1') -Force

    # Warnings go to stderr, so stdout carries only the JSON line.
    $map = $null
    Get-MutReferenceMap -AutPath $AutPath -TestAppPath $TestAppPath 3>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.WarningRecord]) {
            [Console]::Error.WriteLine("WARNING: $($_.Message)")
        }
        else {
            $map = $_
        }
    }

    $byCodeunit = @{}
    if ($null -ne $map) {
        foreach ($key in $map.Keys) {
            $objectId = [int]$key
            if (-not $wanted.ContainsKey($objectId)) { continue }
            foreach ($codeunit in $map[$key]) {
                $codeunitId = [int]$codeunit
                if (-not $byCodeunit.ContainsKey($codeunitId)) {
                    $byCodeunit[$codeunitId] = New-Object System.Collections.Generic.List[int]
                }
                if (-not $byCodeunit[$codeunitId].Contains($objectId)) {
                    $byCodeunit[$codeunitId].Add($objectId)
                }
            }
        }
    }

    $rows = @(foreach ($codeunitId in ($byCodeunit.Keys | Sort-Object)) {
        [ordered]@{ codeunit = $codeunitId; objects = [int[]]@($byCodeunit[$codeunitId] | Sort-Object) }
    })
    Write-Output (ConvertTo-Json -InputObject $rows -Compress -Depth 5)
    exit 0
}
catch {
    Write-Output "Get-MutReferencingTests failed: $($_.Exception.Message)"
    exit 1
}
