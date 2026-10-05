Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stub backend (§6.5.3): exports the same function names and parameter shapes as the real
# backend module in this directory, each throwing NotImplementedException. Not implemented in
# v1 (§6.6 / task T23).

function Get-MutEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Config
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function New-MutEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Config
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Start-MutEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config,
        [bool]$RequireProbe = $true
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Remove-MutEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Reset-MutEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        $Config
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Assert-MutEnvironmentAllowed {
    param($Env)

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Get-MutApiBase {
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Get-MutCompanyId {
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Grant-MutPermissionSet {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$PermissionSetId,
        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Invoke-MutApi {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        $Body
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Install-MutDependencies {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$AppPath
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Compile-MutApp {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Ruleset,
        [int]$TimeoutSec = 900
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Publish-MutApp {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Ruleset,
        [switch]$AllowDowngrade,
        [string]$SyncMode,
        [int]$TimeoutSec = 900
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Publish-MutAppFile {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$AppFile,
        [string]$SyncMode
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Unpublish-MutApp {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [string]$Version
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Invoke-MutTests {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [object[]]$Targets,
        [int]$TimeoutSec = 120,
        [switch]$Coverage
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Get-MutCoverageRaw {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$JobIds
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Get-MutCoverage {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$JobIds
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Stop-MutBackendChildProcesses {
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Get-MutCompanyName {
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Get-MutRunnerState {
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Stop-MutRunnerBatch {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [string]$BatchId,
        [string]$CodeunitIds,
        [double]$PollIntervalSec = 5,
        [double]$ConfirmWindowSec = 120,
        [int]$HealthTimeoutSec = 30
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Remove-MutRunnerState {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [string]$BatchId
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Invoke-MutMutantBatch {
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [int[]]$CodeunitIds,
        [int[]]$MutantIds,
        [int]$RunNo,
        [int]$MutantBudgetSec,
        [double]$PollIntervalSec = 5,
        [double]$NoRowWindowSec = 60,
        [double]$FaultStallSec = 10,
        [double]$StopConfirmSec = 120,
        [int]$HealthTimeoutSec = 30,
        [double]$ClientTimeoutSec = 0,
        [double]$ReturnGraceSec = 10
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

function Test-MutSoapRunner {
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    throw [System.NotImplementedException]::new('Docker backend is not implemented in v1')
}

Export-ModuleMember -Function Get-MutEnvironment, New-MutEnvironment, Start-MutEnvironment, Remove-MutEnvironment, Reset-MutEnvironment, Assert-MutEnvironmentAllowed, Get-MutApiBase, Get-MutCompanyId, Get-MutCompanyName, Get-MutRunnerState, Stop-MutRunnerBatch, Remove-MutRunnerState, Invoke-MutMutantBatch, Test-MutSoapRunner, Grant-MutPermissionSet, Invoke-MutApi, Install-MutDependencies, Compile-MutApp, Publish-MutApp, Publish-MutAppFile, Unpublish-MutApp, Invoke-MutTests, Get-MutCoverageRaw, Get-MutCoverage, Stop-MutBackendChildProcesses
