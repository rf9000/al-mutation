Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force

    $script:cfg = [pscustomobject]@{
        backend = 'DemoPortal'
        environmentName = 'mut-spike-01'
        keepEnvironment = $true
        demoPortal = [pscustomobject]@{
            profileId = 'cc557829-71df-40ee-9516-98ca954d4b2f'
            activationAppId = 'c3755ece-dab0-4d16-987d-040661f18522'
            cliPath = './.tools/continia.exe'
        }
    }
    $cfg = $script:cfg
}

Describe 'Get-MutEnvironment' {
    BeforeEach {
        Mock -ModuleName DemoPortal Start-Sleep {}
    }

    It 'returns $null when the env list has no match' {
        Mock -ModuleName DemoPortal Invoke-Continia { @() }

        Get-MutEnvironment -Name 'mut-spike-01' -Config $cfg | Should -BeNullOrEmpty
    }

    It 'returns a handle with Shared=$false for a match' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @(
                [pscustomobject]@{ id = 'E1'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            )
        }

        $h = Get-MutEnvironment -Name 'mut-spike-01' -Config $cfg
        $h | Should -Not -BeNullOrEmpty
        $h.Id | Should -Be 'E1'
        $h.Name | Should -Be 'mut-spike-01'
        $h.Backend | Should -Be 'DemoPortal'
        $h.Shared | Should -Be $false
    }
}

Describe 'Assert-MutEnvironmentAllowed' {
    It 'throws for a name without the mut- prefix' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        { Assert-MutEnvironmentAllowed $env } | Should -Throw
    }

    It 'throws when Shared is $true' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $true }
        { Assert-MutEnvironmentAllowed $env } | Should -Throw
    }
}

Describe 'New-MutEnvironment' {
    BeforeEach {
        Mock -ModuleName DemoPortal Start-Sleep {}
    }

    It 'refuses names without the mut- prefix' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { New-MutEnvironment -Name 'spike-01' -Config $cfg } | Should -Throw
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'creates, starts, polls, installs activation app, and sets workspace env' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'create' } { [pscustomobject]@{ id = 'E1'; description = 'mut-spike-01' } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } { [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false } }
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        $h = New-MutEnvironment -Name 'mut-spike-01' -Config $cfg
        $h.Id | Should -Be 'E1'

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'create'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'start' -and $Arguments[2] -eq 'E1'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[1] -eq 'install-by-id' -and $Arguments[3] -eq $cfg.demoPortal.activationAppId
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'use' -and $Arguments[2] -eq 'E1'
        } -Times 1
    }
}

Describe 'Reset-MutEnvironment' {
    BeforeEach {
        Mock -ModuleName DemoPortal Start-Sleep {}
    }

    It 'stops then starts the environment and returns DurationSec' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }

        InModuleScope DemoPortal { $script:__getCallCount = 0 }

        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'stop' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__getCallCount++
            if ($script:__getCallCount -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Stopped'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }

        $result = Reset-MutEnvironment -Env $env

        $result.DurationSec | Should -Not -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'stop' -and $Arguments[2] -eq 'E1'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'start' -and $Arguments[2] -eq 'E1'
        } -Times 1
    }

    It 'refuses an environment not named mut-*' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Reset-MutEnvironment -Env $env } | Should -Throw
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }
}

Describe 'Remove-MutEnvironment' {
    It 'refuses an environment not named mut-*' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Remove-MutEnvironment -Env $env -Config $cfg } | Should -Throw
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'deletes the environment when keepEnvironment is $false' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }
        $localCfg = [pscustomobject]@{ demoPortal = $cfg.demoPortal; keepEnvironment = $false }
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        Remove-MutEnvironment -Env $env -Config $localCfg

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'delete' -and $Arguments[2] -eq 'E1'
        } -Times 1
    }

    It 'stops (does not delete) the environment when keepEnvironment is $true' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }
        $localCfg = [pscustomobject]@{ demoPortal = $cfg.demoPortal; keepEnvironment = $true }
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        Remove-MutEnvironment -Env $env -Config $localCfg

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'stop' -and $Arguments[2] -eq 'E1'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[1] -eq 'delete'
        } -Times 0
    }
}

Describe 'Invoke-Continia (private, mock point)' {
    It 'is not exported from the module' {
        $exported = (Get-Module DemoPortal).ExportedFunctions.Keys
        $exported | Should -Not -Contain 'Invoke-Continia'
    }

    It 'parses stdout JSON and ignores stderr text (real Process invocation, not mocked)' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                $result = Invoke-Continia -Arguments @('/c', 'echo {"ok":true} & echo warn 1>&2') -TimeoutSec 30
                $result.ok | Should -Be $true
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }

    It 'preserves stdout line order on a large multi-line payload (real Process invocation, not mocked)' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'powershell.exe'
                $result = Invoke-Continia -Arguments @('-NoProfile', '-Command', 'ConvertTo-Json (1..300)') -TimeoutSec 60
                $result.Count | Should -Be 300
                $result[0] | Should -Be 1
                $result[299] | Should -Be 300
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }

    It 'throws when stdout is not JSON (real Process invocation, not mocked)' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                { Invoke-Continia -Arguments @('/c', 'echo not-json') -TimeoutSec 30 } | Should -Throw
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }
}
