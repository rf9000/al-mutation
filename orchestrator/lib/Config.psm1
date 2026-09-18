Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The allowed backend names (§6.5.1). This is the one line in this module permitted to name
# the alternate backend, per §4 guardrail 6; the isolation lint (T27) exempts lines carrying
# the marker comment below.
$script:AllowedBackends = @('DemoPortal', 'Docker')  # isolation-lint: allow

$script:AllowedPublishStrategies = @('same-version', 'bump-build', 'unpublish-test-app')

function Get-MutRepoRoot {
    <#
        .SYNOPSIS
        Returns the repo root: two levels above this module file
        (orchestrator/lib/Config.psm1 -> repo root).
    #>
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Test-MutHasProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-MutRequiredKey {
    <#
        .SYNOPSIS
        Throws unless $Object has a non-null property named $Name. $KeyPath is the full
        dotted key path used in the error message (e.g. 'aut.sourcePath').
    #>
    param($Object, [string]$Name, [string]$KeyPath)

    if (-not (Test-MutHasProperty $Object $Name)) {
        throw "Get-MutConfig: config is missing required key '$KeyPath'."
    }
    if ($null -eq $Object.$Name) {
        throw "Get-MutConfig: config key '$KeyPath' must not be null."
    }
}

function Assert-MutNonEmptyString {
    param($Object, [string]$Name, [string]$KeyPath)

    Assert-MutRequiredKey $Object $Name $KeyPath
    if ([string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
        throw "Get-MutConfig: config key '$KeyPath' must be a non-empty string."
    }
}

function Resolve-MutConfigPath {
    <#
        .SYNOPSIS
        Resolves a possibly-relative path against $RepoRoot into an absolute path. An
        already-absolute path is returned unchanged.
    #>
    param([string]$RepoRoot, [string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return $Path
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepoRoot, $Path))
}

function Assert-MutConfigShape {
    <#
        .SYNOPSIS
        Validates every required key of §6.5.1's config schema, throwing a message naming
        the first missing or invalid key found.
    #>
    param($Config)

    Assert-MutNonEmptyString $Config 'backend' 'backend'
    if ($script:AllowedBackends -notcontains $Config.backend) {
        throw "Get-MutConfig: config key 'backend' must be one of: $($script:AllowedBackends -join ', '). Got '$($Config.backend)'."
    }

    Assert-MutNonEmptyString $Config 'environmentName' 'environmentName'
    if ($Config.environmentName -cnotmatch '^mut-') {
        throw "Get-MutConfig: config key 'environmentName' ('$($Config.environmentName)') must match '^mut-'."
    }

    Assert-MutRequiredKey $Config 'aut' 'aut'
    Assert-MutNonEmptyString $Config.aut 'sourcePath' 'aut.sourcePath'
    Assert-MutNonEmptyString $Config.aut 'appId' 'aut.appId'
    Assert-MutNonEmptyString $Config.aut 'version' 'aut.version'

    Assert-MutRequiredKey $Config 'testApp' 'testApp'
    Assert-MutNonEmptyString $Config.testApp 'sourcePath' 'testApp.sourcePath'
    Assert-MutNonEmptyString $Config.testApp 'appId' 'testApp.appId'
    Assert-MutRequiredKey $Config.testApp 'testCodeunits' 'testApp.testCodeunits'
    $testCodeunits = @($Config.testApp.testCodeunits)
    if ($testCodeunits.Count -eq 0) {
        throw "Get-MutConfig: config key 'testApp.testCodeunits' must be a non-empty array of integers."
    }
    foreach ($id in $testCodeunits) {
        $parsedId = 0
        if (-not [int]::TryParse([string]$id, [ref]$parsedId)) {
            throw "Get-MutConfig: config key 'testApp.testCodeunits' must contain only integers; found '$id'."
        }
    }

    if (Test-MutHasProperty $Config 'rulesets') {
        if ($null -ne $Config.rulesets) {
            Assert-MutNonEmptyString $Config.rulesets 'sourcePath' 'rulesets.sourcePath'
            Assert-MutNonEmptyString $Config.rulesets 'file' 'rulesets.file'
        }
    }

    Assert-MutRequiredKey $Config 'coreApp' 'coreApp'
    Assert-MutNonEmptyString $Config.coreApp 'path' 'coreApp.path'
    Assert-MutNonEmptyString $Config.coreApp 'appId' 'coreApp.appId'
    Assert-MutNonEmptyString $Config.coreApp 'version' 'coreApp.version'

    Assert-MutRequiredKey $Config 'workDir' 'workDir'
    if ([string]::IsNullOrWhiteSpace([string]$Config.workDir)) {
        throw "Get-MutConfig: config key 'workDir' must be a non-empty string."
    }

    Assert-MutRequiredKey $Config 'generator' 'generator'
    Assert-MutRequiredKey $Config.generator 'maxMutants' 'generator.maxMutants'
    Assert-MutRequiredKey $Config.generator 'onlyObjects' 'generator.onlyObjects'
    Assert-MutRequiredKey $Config.generator 'seed' 'generator.seed'
    Assert-MutRequiredKey $Config.generator 'operators' 'generator.operators'
    Assert-MutRequiredKey $Config.generator 'includeBreak' 'generator.includeBreak'

    Assert-MutRequiredKey $Config 'schemata' 'schemata'
    Assert-MutNonEmptyString $Config.schemata 'publishStrategy' 'schemata.publishStrategy'
    if ($script:AllowedPublishStrategies -notcontains $Config.schemata.publishStrategy) {
        throw "Get-MutConfig: config key 'schemata.publishStrategy' must be one of: $($script:AllowedPublishStrategies -join ', '). Got '$($Config.schemata.publishStrategy)'."
    }

    Assert-MutRequiredKey $Config 'timeouts' 'timeouts'
    Assert-MutRequiredKey $Config.timeouts 'perTestFactor' 'timeouts.perTestFactor'
    Assert-MutRequiredKey $Config.timeouts 'minSeconds' 'timeouts.minSeconds'
    Assert-MutRequiredKey $Config.timeouts 'jobOverheadSeconds' 'timeouts.jobOverheadSeconds'

    if ($Config.backend -eq 'DemoPortal') {
        Assert-MutRequiredKey $Config 'demoPortal' 'demoPortal'
        Assert-MutNonEmptyString $Config.demoPortal 'profileId' 'demoPortal.profileId'
        Assert-MutNonEmptyString $Config.demoPortal 'activationAppId' 'demoPortal.activationAppId'
        Assert-MutNonEmptyString $Config.demoPortal 'cliPath' 'demoPortal.cliPath'

        # T11b (spike U5): the test-readiness probe target for Wait-MutEnvironmentSettled.
        Assert-MutRequiredKey $Config.demoPortal 'settleProbe' 'demoPortal.settleProbe'
        Assert-MutRequiredKey $Config.demoPortal.settleProbe 'codeunitId' 'demoPortal.settleProbe.codeunitId'
        $parsedProbeCodeunitId = 0
        if (-not [int]::TryParse([string]$Config.demoPortal.settleProbe.codeunitId, [ref]$parsedProbeCodeunitId)) {
            throw "Get-MutConfig: config key 'demoPortal.settleProbe.codeunitId' must be an integer."
        }
        Assert-MutNonEmptyString $Config.demoPortal.settleProbe 'functionName' 'demoPortal.settleProbe.functionName'
    }

    Assert-MutRequiredKey $Config 'permissionSets' 'permissionSets'
    $index = 0
    foreach ($set in @($Config.permissionSets)) {
        Assert-MutNonEmptyString $set 'id' "permissionSets[$index].id"
        Assert-MutNonEmptyString $set 'appId' "permissionSets[$index].appId"
        $index++
    }
}

function Get-MutConfig {
    <#
        .SYNOPSIS
        Loads, validates and returns the run configuration (§6.5.1). Relative paths
        (coreApp.path, workDir, aut.sourcePath, testApp.sourcePath, rulesets.sourcePath,
        demoPortal.cliPath) are resolved to absolute paths against the repo root; already
        absolute paths are left unchanged.
        .OUTPUTS
        PSCustomObject: the parsed config with resolved paths.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Get-MutConfig: config file not found: '$Path'."
    }

    $raw = Get-Content -Path $Path -Raw
    $config = $raw | ConvertFrom-Json

    Assert-MutConfigShape $config

    $repoRoot = Get-MutRepoRoot

    $config.coreApp.path = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.coreApp.path
    $config.workDir = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.workDir
    $config.aut.sourcePath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.aut.sourcePath
    $config.testApp.sourcePath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.testApp.sourcePath

    if ((Test-MutHasProperty $config 'rulesets') -and ($null -ne $config.rulesets)) {
        $config.rulesets.sourcePath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.rulesets.sourcePath
    }

    if ($config.backend -eq 'DemoPortal') {
        $config.demoPortal.cliPath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.demoPortal.cliPath
    }

    return $config
}

Export-ModuleMember -Function Get-MutConfig, Get-MutRepoRoot
