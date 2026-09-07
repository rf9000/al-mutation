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

    It 'creates, waits for status to appear, starts (ExpectJson:$false), polls, installs activation app, and sets workspace env (ExpectJson:$false)' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'create' } { [pscustomobject]@{ id = 'E1'; description = 'mut-spike-01' } }

        # A plain (not InModuleScope-wrapped) $script: variable, unique to this test: a Mock
        # -ModuleName script block executes in this test FILE's own script scope, not inside
        # the target module's scope, so `InModuleScope DemoPortal { $script:x = 0 }` resets a
        # *different* variable than the one a Mock body's `$script:x++` reads/writes (found by
        # direct experiment in T02 fix round 3). Reusing one counter name across multiple tests
        # in this file previously leaked its value between tests for exactly this reason.
        $script:__newMutEnvGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__newMutEnvGetCalls++
            # Call 1: Wait-MutEnvironmentAppears (just needs a 'status' property at all).
            # Call 2: Start-MutEnvironment's own status refresh (still Draft -> triggers env start).
            # Call 3+: Wait-MutEnvironmentStatus polling for Running.
            if ($script:__newMutEnvGetCalls -le 2) {
                return [pscustomobject]@{ id = 'E1'; status = 'Draft'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = 'Environment E1 start requested.' } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'install-by-id' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'use' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

        $h = New-MutEnvironment -Name 'mut-spike-01' -Config $cfg
        $h.Id | Should -Be 'E1'
        $h.Status | Should -Be 'Running'
        $h.CreateDurationSec | Should -Not -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'create'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'start' -and $Arguments[2] -eq 'E1' -and $ExpectJson -eq $false
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[1] -eq 'install-by-id' -and $Arguments[3] -eq $cfg.demoPortal.activationAppId
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'use' -and $Arguments[2] -eq 'E1' -and $ExpectJson -eq $false
        } -Times 1
    }
}

Describe 'Start-MutEnvironment' {
    BeforeEach {
        Mock -ModuleName DemoPortal Start-Sleep {}
    }

    It 'refuses an environment not named mut-*' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false; Status = 'Draft' }
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Start-MutEnvironment -Env $env -Config $cfg } | Should -Throw
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'starts a Draft environment: refreshes status, calls env start with ExpectJson:$false, polls, installs the activation app, and sets the workspace env' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false; Status = 'Draft' }

        $script:__startMutEnvGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__startMutEnvGetCalls++
            if ($script:__startMutEnvGetCalls -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Draft'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = 'Environment E1 start requested.' } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'install-by-id' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'use' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

        $h = Start-MutEnvironment -Env $env -Config $cfg

        $h.Status | Should -Be 'Running'
        $h.StartDurationSec | Should -Not -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'start' -and $Arguments[2] -eq 'E1' -and $ExpectJson -eq $false
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[1] -eq 'install-by-id' -and $Arguments[3] -eq $cfg.demoPortal.activationAppId
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'use' -and $Arguments[2] -eq 'E1' -and $ExpectJson -eq $false
        } -Times 1
    }

    It 'does not call env start or poll for an already-Running environment, but still installs the activation app and sets the workspace env' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false; Status = 'Running' }

        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { throw 'must not be called' }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'install-by-id' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'use' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

        $h = Start-MutEnvironment -Env $env -Config $cfg

        $h.Status | Should -Be 'Running'
        $h.StartDurationSec | Should -Be 0

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } -Times 0
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } -Times 1
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'install-by-id' } -Times 1
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'use' } -Times 1
    }
}

Describe 'Wait-MutEnvironmentStatus' {
    BeforeEach {
        Mock -ModuleName DemoPortal Start-Sleep {}
    }

    It 'tolerates a first poll response without a status property and succeeds on the second' {
        $script:__waitStatusGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__waitStatusGetCalls++
            if ($script:__waitStatusGetCalls -eq 1) {
                return [pscustomobject]@{}
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running' }
        }

        $result = InModuleScope DemoPortal { Wait-MutEnvironmentStatus -Id 'E1' -Status 'Running' }

        $result.status | Should -Be 'Running'
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } -Times 2
    }
}

Describe 'Reset-MutEnvironment' {
    BeforeEach {
        Mock -ModuleName DemoPortal Start-Sleep {}
    }

    It 'stops then starts the environment and returns DurationSec' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }

        $script:__resetMutEnvGetCalls = 0

        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'stop' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__resetMutEnvGetCalls++
            if ($script:__resetMutEnvGetCalls -eq 1) {
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

    It 'throws when stdout is empty under the default ExpectJson (real Process invocation, not mocked)' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                { Invoke-Continia -Arguments @('/c', 'rem') -TimeoutSec 30 } | Should -Throw
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }

    It '-ExpectJson:$false returns ExitCode/StdOut/StdErr without parsing JSON (real Process invocation, not mocked)' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                $result = Invoke-Continia -Arguments @('/c', 'echo hi 1>&2') -TimeoutSec 30 -ExpectJson:$false
                $result.ExitCode | Should -Be 0
                $result.StdErr | Should -Match 'hi'
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }

    It '-ExpectJson:$false throws when the exit code is non-zero (real Process invocation, not mocked)' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                { Invoke-Continia -Arguments @('/c', 'exit 3') -TimeoutSec 30 -ExpectJson:$false } | Should -Throw
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }
}
