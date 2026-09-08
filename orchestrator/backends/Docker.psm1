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
        $Config
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
        $Env
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
        [string]$Ruleset
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
        [string]$SyncMode
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

Export-ModuleMember -Function Get-MutEnvironment, New-MutEnvironment, Start-MutEnvironment, Remove-MutEnvironment, Reset-MutEnvironment, Assert-MutEnvironmentAllowed, Get-MutApiBase, Get-MutCompanyId, Grant-MutPermissionSet, Invoke-MutApi, Install-MutDependencies, Compile-MutApp, Publish-MutApp, Publish-MutAppFile, Unpublish-MutApp, Invoke-MutTests, Get-MutCoverageRaw, Get-MutCoverage
