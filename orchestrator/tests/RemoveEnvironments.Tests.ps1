Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Environment cleanup for mutant-fixer's per-PR environments (Linux port, task 11 of the
# headless brief). The logic lives in the backend (Remove-MutRunEnvironment,
# Remove-MutOrphanEnvironments) and is tested here with the CLI mocked; the two entry scripts
# are thin wrappers, tested for the argument guard that runs before any CLI call.

BeforeAll {
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force

    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:Cfg = [pscustomobject]@{
        backend         = 'DemoPortal'
        environmentName = 'mut-pr-42-abc1234'
        keepEnvironment = $true
        demoPortal      = [pscustomobject]@{ activationAppId = 'a'; cliPath = './.tools/continia.exe' }
    }

    function script:New-EnvRow {
        param([string]$Id, [string]$Name, [bool]$Shared = $false)
        [pscustomobject]@{ id = $Id; description = $Name; url = "https://x/$Id"; shared = $Shared; status = 'Running' }
    }
}

Describe 'Remove-MutRunEnvironment' {
    BeforeEach {
        $script:Deleted = @()
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'delete' } { $script:Deleted += $Arguments[2] }
    }

    It 'deletes the config environment even though keepEnvironment is true, and returns its name' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'list' } { @((New-EnvRow 'E1' 'mut-pr-42-abc1234'), (New-EnvRow 'E2' 'mut-pr-7-0000000')) }

        $result = Remove-MutRunEnvironment -Config $script:Cfg

        $result | Should -Be 'mut-pr-42-abc1234'
        $script:Deleted | Should -Be @('E1')
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'stop' } -Times 0
    }

    It 'returns $null and deletes nothing when the environment is already gone' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'list' } { @((New-EnvRow 'E2' 'mut-pr-7-0000000')) }

        Remove-MutRunEnvironment -Config $script:Cfg | Should -BeNullOrEmpty
        $script:Deleted.Count | Should -Be 0
    }

    It 'refuses a Shared environment' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'list' } { @((New-EnvRow 'E1' 'mut-pr-42-abc1234' $true)) }

        { Remove-MutRunEnvironment -Config $script:Cfg } | Should -Throw '*Shared*'
        $script:Deleted.Count | Should -Be 0
    }

    It 'refuses a config environment name not matching ^mut-' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }
        $cfg = $script:Cfg.PSObject.Copy()
        $cfg.environmentName = 'fix-auth'

        { Remove-MutRunEnvironment -Config $cfg } | Should -Throw "*'^mut-'*"
    }
}

Describe 'Remove-MutOrphanEnvironments' {
    BeforeEach {
        $script:Deleted = @()
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'list' } {
            @(
                (New-EnvRow 'E1' 'mut-pr-1-aaaaaaa')
                (New-EnvRow 'E2' 'mut-pr-2-bbbbbbb')
                (New-EnvRow 'E3' 'mut-pr-3-ccccccc' $true)
                (New-EnvRow 'E4' 'mut-spike-02')
                (New-EnvRow 'E5' 'MUT-PR-5-eeeeeee')
                (New-EnvRow 'E6' 'wi-77-feature')
            )
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'delete' } { $script:Deleted += $Arguments[2] }
    }

    It 'deletes every non-shared environment starting with the prefix (case-sensitive), except -Keep' {
        $result = @(Remove-MutOrphanEnvironments -Prefix 'mut-pr-' -Keep 'mut-pr-2-bbbbbbb' -Config $script:Cfg)

        $result | Should -Be @('mut-pr-1-aaaaaaa')
        $script:Deleted | Should -Be @('E1')
    }

    It 'goes on after a failed delete and reports it as a warning' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'delete' -and $Arguments[2] -eq 'E1' } { throw 'delete failed' }

        $warnings = @()
        $result = @(Remove-MutOrphanEnvironments -Prefix 'mut-pr-' -Config $script:Cfg -WarningVariable warnings -WarningAction SilentlyContinue)

        $result | Should -Be @('mut-pr-2-bbbbbbb')
        $script:Deleted | Should -Be @('E2')
        ($warnings -join ' ') | Should -BeLike '*mut-pr-1-aaaaaaa*delete failed*'
    }

    It 'refuses a prefix that does not start with mut- (or is just mut-) before listing' -ForEach @(
        @{ prefix = '' }, @{ prefix = 'wi-' }, @{ prefix = 'mut-' }, @{ prefix = 'Mut-pr-' }
    ) {
        { Remove-MutOrphanEnvironments -Prefix $prefix -Config $script:Cfg } | Should -Throw '*prefix*'
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'list' } -Times 0
    }

    It 'throws when listing fails' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'list' } { throw 'list failed' }

        { Remove-MutOrphanEnvironments -Prefix 'mut-pr-' -Config $script:Cfg } | Should -Throw '*list failed*'
    }
}

Describe 'Remove-MutOrphanEnvironments.ps1 / Remove-MutRunEnvironment.ps1 entry scripts' {
    It 'Remove-MutOrphanEnvironments.ps1 exits 1 for a prefix that does not start with mut-' {
        $script = Join-Path $script:RepoRoot 'orchestrator/Remove-MutOrphanEnvironments.ps1'
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script -Prefix 'wi-' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -BeLike '*prefix*'
    }

    It 'Remove-MutRunEnvironment.ps1 exits 1 when the config file does not exist' {
        $script = Join-Path $script:RepoRoot 'orchestrator/Remove-MutRunEnvironment.ps1'
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script -ConfigPath (Join-Path $TestDrive 'missing.json') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -BeLike '*missing.json*'
    }
}
