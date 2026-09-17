Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force
    Import-Module "$PSScriptRoot/../backends/Docker.psm1" -Force

    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    function Get-MutIsolationViolations {
        <#
            .SYNOPSIS
            Returns the subset of $Lines that contain a forbidden isolation string
            (continia, BcContainerHelper, docker; case-insensitive), skipping any line
            carrying the '# isolation-lint: allow' marker. Shared by the real Config.psm1
            check and the synthetic exemption-behavior test below.
        #>
        param([string[]]$Lines)

        $violations = @()
        foreach ($line in $Lines) {
            if ($line -match '#\s*isolation-lint:\s*allow') {
                continue
            }
            if ($line -match '(?i)continia|BcContainerHelper|docker') {
                $violations += $line
            }
        }
        return , $violations
    }

    function New-MutTestConfigFile {
        param([hashtable]$Overrides = @{})

        $config = [ordered]@{
            backend         = 'DemoPortal'
            environmentName = 'mut-spike-01'
            keepEnvironment = $true
            aut             = [ordered]@{ sourcePath = './fixtures/fixture-aut'; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
            testApp         = [ordered]@{ sourcePath = './fixtures/fixture-test'; appId = '9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e'; testCodeunits = @(50300) }
            rulesets        = $null
            coreApp         = [ordered]@{ path = './core-app'; appId = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b'; version = '1.0.0.0' }
            permissionSets  = @(@{ id = 'MUT Core All'; appId = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b' })
            workDir         = './out'
            generator       = [ordered]@{ maxMutants = 0; onlyObjects = @(); seed = 1; operators = @('REL', 'BOOL'); includeBreak = $false }
            schemata        = [ordered]@{ publishStrategy = 'same-version' }
            timeouts        = [ordered]@{ perTestFactor = 5; minSeconds = 60; jobOverheadSeconds = 0 }
            demoPortal      = [ordered]@{ profileId = 'cc557829-71df-40ee-9516-98ca954d4b2f'; activationAppId = 'c3755ece-dab0-4d16-987d-040661f18522'; cliPath = './.tools/continia.exe'; settleProbe = [ordered]@{ codeunitId = 50300; functionName = 'IsLargeOrder_Twelve_IsTrue' } }
        }

        foreach ($key in $Overrides.Keys) {
            $config[$key] = $Overrides[$key]
        }

        $path = Join-Path $TestDrive ("config-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        return $path
    }
}

Describe 'Get-MutRepoRoot' {
    It 'returns the repo root (two levels above the module file)' {
        Get-MutRepoRoot | Should -Be $script:RepoRoot
    }
}

Describe 'Get-MutConfig' {
    It 'loads a valid config file and resolves relative paths to absolute' {
        $path = New-MutTestConfigFile
        $cfg = Get-MutConfig -Path $path

        [System.IO.Path]::IsPathRooted($cfg.coreApp.path) | Should -Be $true
        $cfg.coreApp.path | Should -Be (Join-Path $script:RepoRoot 'core-app')
        [System.IO.Path]::IsPathRooted($cfg.workDir) | Should -Be $true
        $cfg.workDir | Should -Be (Join-Path $script:RepoRoot 'out')
        [System.IO.Path]::IsPathRooted($cfg.aut.sourcePath) | Should -Be $true
        [System.IO.Path]::IsPathRooted($cfg.testApp.sourcePath) | Should -Be $true
        [System.IO.Path]::IsPathRooted($cfg.demoPortal.cliPath) | Should -Be $true
    }

    It 'leaves already-absolute paths untouched' {
        $overrides = @{ aut = @{ sourcePath = 'C:/GeneralDev/AL/somewhere'; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        $cfg = Get-MutConfig -Path $path

        $cfg.aut.sourcePath | Should -Be 'C:/GeneralDev/AL/somewhere'
    }

    It 'loads the real mutation.config.json without error' {
        { Get-MutConfig -Path (Join-Path $script:RepoRoot 'mutation.config.json') } | Should -Not -Throw
    }

    It 'loads the real mutation.fixture.config.json without error' {
        { Get-MutConfig -Path (Join-Path $script:RepoRoot 'mutation.fixture.config.json') } | Should -Not -Throw
    }

    It 'allows rulesets to be null' {
        $path = New-MutTestConfigFile
        $cfg = Get-MutConfig -Path $path
        $cfg.rulesets | Should -BeNullOrEmpty
    }

    It 'resolves rulesets.sourcePath when rulesets is present' {
        $overrides = @{ rulesets = @{ sourcePath = './somerulesets'; file = '.cli-ruleset-localdeploy.json' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        $cfg = Get-MutConfig -Path $path
        [System.IO.Path]::IsPathRooted($cfg.rulesets.sourcePath) | Should -Be $true
        $cfg.rulesets.file | Should -Be '.cli-ruleset-localdeploy.json'
    }

    It 'throws naming the missing key when backend is absent' {
        $overrides = @{ backend = $null }
        $path = New-MutTestConfigFile -Overrides $overrides
        # remove the key entirely rather than leaving it $null
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Remove('backend')
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

        { Get-MutConfig -Path $path } | Should -Throw '*backend*'
    }

    It 'throws when backend is not DemoPortal or Docker' {
        $overrides = @{ backend = 'Bogus' }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*backend*'
    }

    It "throws when environmentName does not match ^mut-" {
        $overrides = @{ environmentName = 'spike' }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*environmentName*'
    }

    It 'throws naming the key when testApp.testCodeunits is empty' {
        $overrides = @{ testApp = @{ sourcePath = './fixtures/fixture-test'; appId = '9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e'; testCodeunits = @() } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*testCodeunits*'
    }

    It 'throws when schemata.publishStrategy is invalid' {
        $overrides = @{ schemata = @{ publishStrategy = 'bogus-strategy' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*publishStrategy*'
    }

    It 'allows an empty permissionSets array' {
        $overrides = @{ permissionSets = @() }
        $path = New-MutTestConfigFile -Overrides $overrides
        $cfg = Get-MutConfig -Path $path
        @($cfg.permissionSets).Count | Should -Be 0
    }

    It 'throws naming the key when a permissionSets entry is missing appId' {
        $overrides = @{ permissionSets = @(@{ id = 'MUT Core All' }) }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*permissionSets*'
    }

    It 'throws naming the missing key when coreApp.appId is absent' {
        $overrides = @{ coreApp = @{ path = './core-app'; version = '1.0.0.0' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*coreApp.appId*'
    }

    It 'throws naming the missing key when generator is absent' {
        $overrides = @{ generator = $null }
        $path = New-MutTestConfigFile -Overrides $overrides
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Remove('generator')
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

        { Get-MutConfig -Path $path } | Should -Throw '*generator*'
    }

    It 'throws naming the missing key when timeouts.minSeconds is absent' {
        $overrides = @{ timeouts = @{ perTestFactor = 5; jobOverheadSeconds = 0 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*timeouts.minSeconds*'
    }

    It 'throws naming the missing key when demoPortal.cliPath is absent and backend is DemoPortal' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.cliPath*'
    }

    It 'throws naming the missing key when demoPortal.settleProbe is absent and backend is DemoPortal' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y'; cliPath = './.tools/continia.exe' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.settleProbe*'
    }

    It 'throws when demoPortal.settleProbe.codeunitId is not an integer' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y'; cliPath = './.tools/continia.exe'; settleProbe = @{ codeunitId = 'not-a-number'; functionName = 'IsLargeOrder_Twelve_IsTrue' } } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.settleProbe.codeunitId*'
    }

    It 'throws naming the missing key when demoPortal.settleProbe.functionName is absent' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y'; cliPath = './.tools/continia.exe'; settleProbe = @{ codeunitId = 50300 } } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.settleProbe.functionName*'
    }
}

Describe 'Config.psm1 isolation' {
    It 'contains none of the forbidden strings (continia, BcContainerHelper, docker) outside the marked allow-line' {
        $path = "$PSScriptRoot/../lib/Config.psm1"
        $lines = Get-Content -Path $path
        $violations = Get-MutIsolationViolations -Lines $lines
        $violations | Should -BeNullOrEmpty
    }

    It 'flags an unmarked line containing a forbidden string but not a line carrying the allow marker' {
        $sample = @(
            "Set-StrictMode -Version Latest",
            "`$leak = 'docker is mentioned here with no marker'",
            "`$script:AllowedBackends = @('DemoPortal', 'Docker')  # isolation-lint: allow"
        )

        $violations = Get-MutIsolationViolations -Lines $sample

        $violations.Count | Should -Be 1
        $violations[0] | Should -Match 'no marker'
    }
}

Describe 'Docker backend' {
    It 'exports the same function names as DemoPortal' {
        $dockerNames = (Get-Command -All -Module Docker).Name | Sort-Object
        $demoNames = (Get-Command -All -Module DemoPortal).Name | Sort-Object
        $dockerNames | Should -Be $demoNames
    }

    It 'exports the same parameter names as DemoPortal for every function (T11b: Reset-MutEnvironment gained an optional -Config)' {
        $commonParams = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
        $demoNames = (Get-Command -All -Module DemoPortal).Name | Sort-Object
        foreach ($name in $demoNames) {
            $demoParams = (Get-Command -All -Module DemoPortal | Where-Object Name -eq $name).Parameters.Keys | Where-Object { $_ -notin $commonParams } | Sort-Object
            $dockerParams = (Get-Command -All -Module Docker | Where-Object Name -eq $name).Parameters.Keys | Where-Object { $_ -notin $commonParams } | Sort-Object
            $dockerParams | Should -Be $demoParams -Because "function '$name'"
        }
    }

    It 'throws NotImplementedException for every exported function' {
        $fakeEnv = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'Docker'; Shared = $false; CliPath = 'C:/nowhere.exe' }
        $fakeConfig = [pscustomobject]@{ demoPortal = [pscustomobject]@{ cliPath = 'C:/nowhere.exe' } }

        foreach ($name in (Get-Command -All -Module Docker).Name) {
            $command = Get-Command $name -Module Docker -All
            $argCount = $command.Parameters.Count

            $callParams = @{}
            foreach ($p in $command.Parameters.Values) {
                if ($p.Name -in @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) {
                    continue
                }
                switch ($p.Name) {
                    'Env' { $callParams['Env'] = $fakeEnv }
                    'Config' { $callParams['Config'] = $fakeConfig }
                    'Name' { $callParams['Name'] = 'mut-spike-01' }
                    'Method' { $callParams['Method'] = 'GET' }
                    'Path' { $callParams['Path'] = 'x' }
                    'AppPath' { $callParams['AppPath'] = 'x' }
                    'AppFile' { $callParams['AppFile'] = 'x' }
                    'AppId' { $callParams['AppId'] = 'x' }
                    'PermissionSetId' { $callParams['PermissionSetId'] = 'x' }
                    'Targets' { $callParams['Targets'] = @([pscustomobject]@{ CodeunitId = 1; Function = $null }) }
                    'JobIds' { $callParams['JobIds'] = @('x') }
                    default { }
                }
            }

            { & $name @callParams } | Should -Throw -ExceptionType ([System.NotImplementedException])
        }
    }
}
