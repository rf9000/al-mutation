Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo root is two levels above this module file (orchestrator/backends/DemoPortal.psm1).
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Poll loop tuning for env get / env stop-start status polling.
$script:PollIntervalSec = 10
$script:MaxPollIterations = 60

function Resolve-MutCliPath {
    param($Config)

    $cliPath = $Config.demoPortal.cliPath
    if ([System.IO.Path]::IsPathRooted($cliPath)) {
        return $cliPath
    }
    return (Join-Path $script:RepoRoot $cliPath)
}

function Invoke-Continia {
    <#
        .SYNOPSIS
        Private wrapper around the Continia CLI. This is the ONLY function in this module
        that may invoke the real CLI process, and the single Pester mock point for every
        other function in this module.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSec = 600
    )

    $cliPath = $script:CliPath
    $output = & $cliPath @Arguments 2>&1
    $text = ($output | Out-String).Trim()

    try {
        return $text | ConvertFrom-Json
    }
    catch {
        throw "Invoke-Continia: non-JSON output from '$cliPath $($Arguments -join ' ')': $text"
    }
}

function Assert-MutEnvironmentAllowed {
    <#
        .SYNOPSIS
        Throws unless the environment handle's Name starts with 'mut-' and it is not Shared.
        MUST be called first by every exported function that receives an $Env handle.
    #>
    param($Env)

    if (-not $Env) {
        throw 'Assert-MutEnvironmentAllowed: $Env is null.'
    }
    if ($Env.Name -notmatch '^mut-') {
        throw "Assert-MutEnvironmentAllowed: environment name '$($Env.Name)' does not match '^mut-'; refusing to target it."
    }
    if ($Env.Shared) {
        throw "Assert-MutEnvironmentAllowed: environment '$($Env.Name)' is marked Shared; refusing to target it."
    }
}

function ConvertTo-MutEnvironmentHandle {
    param($Raw)

    [pscustomobject]@{
        Id      = $Raw.id
        Name    = $Raw.description
        Url     = $Raw.url
        Backend = 'DemoPortal'
        Shared  = [bool]$Raw.shared
    }
}

function Get-MutEnvironment {
    <#
        .SYNOPSIS
        Looks up an existing DemoPortal environment by name (description).
        .OUTPUTS
        A handle [pscustomobject]@{Id;Name;Url;Backend;Shared}, or $null if not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $script:CliPath = Resolve-MutCliPath -Config $Config

    $list = Invoke-Continia -Arguments @('env', 'list', '--json')
    if (-not $list) {
        return $null
    }

    $match = $list | Where-Object { $_.description -eq $Name } | Select-Object -First 1
    if (-not $match) {
        return $null
    }

    return ConvertTo-MutEnvironmentHandle -Raw $match
}

function Wait-MutEnvironmentStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    for ($i = 0; $i -lt $script:MaxPollIterations; $i++) {
        $env = Invoke-Continia -Arguments @('env', 'get', $Id, '--json')
        if ($env.status -eq $Status) {
            return $env
        }
        Start-Sleep -Seconds $script:PollIntervalSec
    }

    throw "Wait-MutEnvironmentStatus: environment '$Id' did not reach status '$Status' within $($script:MaxPollIterations * $script:PollIntervalSec) seconds."
}

function New-MutEnvironment {
    <#
        .SYNOPSIS
        Creates, starts, and prepares a fresh DemoPortal environment: env create, env start,
        poll env get until Running, install the activation app, set the workspace env.
        .OUTPUTS
        A handle plus CreateDurationSec, StartDurationSec, ActivationInstallDurationSec.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Config
    )

    if ($Name -notmatch '^mut-') {
        throw "New-MutEnvironment: name '$Name' does not match '^mut-'; refusing to create it."
    }

    $script:CliPath = Resolve-MutCliPath -Config $Config

    $createStart = Get-Date
    $created = Invoke-Continia -Arguments @('env', 'create', '--name', $Name, '--profile', $Config.demoPortal.profileId, '--json')
    $createDurationSec = ((Get-Date) - $createStart).TotalSeconds

    $envId = $created.id

    $startStart = Get-Date
    Invoke-Continia -Arguments @('env', 'start', $envId, '--json') | Out-Null
    $running = Wait-MutEnvironmentStatus -Id $envId -Status 'Running'
    $startDurationSec = ((Get-Date) - $startStart).TotalSeconds

    $activationStart = Get-Date
    Invoke-Continia -Arguments @('deps', 'install-by-id', $envId, $Config.demoPortal.activationAppId, '--json') | Out-Null
    $activationInstallDurationSec = ((Get-Date) - $activationStart).TotalSeconds

    Invoke-Continia -Arguments @('env', 'use', $envId, '--json') | Out-Null

    $handle = ConvertTo-MutEnvironmentHandle -Raw $running

    Add-Member -InputObject $handle -NotePropertyName 'CreateDurationSec' -NotePropertyValue $createDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'StartDurationSec' -NotePropertyValue $startDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'ActivationInstallDurationSec' -NotePropertyValue $activationInstallDurationSec

    return $handle
}

function Remove-MutEnvironment {
    <#
        .SYNOPSIS
        Deletes the environment (or stops it, when $Config.keepEnvironment is $true).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = Resolve-MutCliPath -Config $Config

    if ($Config.keepEnvironment) {
        Invoke-Continia -Arguments @('env', 'stop', $Env.Id, '--json') | Out-Null
    }
    else {
        Invoke-Continia -Arguments @('env', 'delete', $Env.Id, '--json') | Out-Null
    }
}

function Reset-MutEnvironment {
    <#
        .SYNOPSIS
        Stops then starts the environment, polling for the Stopped and Running states.
        .OUTPUTS
        [pscustomobject]@{ DurationSec }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    $start = Get-Date

    Invoke-Continia -Arguments @('env', 'stop', $Env.Id, '--json') | Out-Null
    Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Stopped' | Out-Null

    Invoke-Continia -Arguments @('env', 'start', $Env.Id, '--json') | Out-Null
    Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Running' | Out-Null

    $durationSec = ((Get-Date) - $start).TotalSeconds

    return [pscustomobject]@{ DurationSec = $durationSec }
}

Export-ModuleMember -Function Get-MutEnvironment, New-MutEnvironment, Remove-MutEnvironment, Reset-MutEnvironment, Assert-MutEnvironmentAllowed
