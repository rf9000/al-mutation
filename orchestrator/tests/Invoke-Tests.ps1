<#
    .SYNOPSIS
    Runs the orchestrator Pester suite on the current host (Windows PowerShell 5.1 or pwsh 7).

    .PARAMETER Path
    Test file or folder; defaults to this folder.

    .PARAMETER Output
    Pester output verbosity (None, Normal, Detailed, Diagnostic).

    .NOTES
    Exits 0 when every test passed, 1 otherwise. Skipped tests are platform-specific and do not
    fail the run.
#>
param(
    [string[]]$Path = @($PSScriptRoot),
    [string]$Output = 'Normal'
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99

$result = Invoke-Pester -Path $Path -Output $Output -PassThru
'Passed={0} Failed={1} Skipped={2} NotRun={3}' -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount
if ($null -eq $result -or $result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
exit 0
