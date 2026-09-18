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

    # T11b (spike U5): a config carrying demoPortal.settleProbe, for tests of the
    # test-readiness probe in Wait-MutEnvironmentSettled.
    $script:cfgWithProbe = [pscustomobject]@{
        backend = 'DemoPortal'
        environmentName = 'mut-spike-01'
        keepEnvironment = $true
        demoPortal = [pscustomobject]@{
            profileId = 'cc557829-71df-40ee-9516-98ca954d4b2f'
            activationAppId = 'c3755ece-dab0-4d16-987d-040661f18522'
            cliPath = './.tools/continia.exe'
            settleProbe = [pscustomobject]@{
                codeunitId = 50300
                functionName = 'IsLargeOrder_Twelve_IsTrue'
            }
        }
    }
    $cfgWithProbe = $script:cfgWithProbe
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

    It 'throws for a case-variant of the mut- prefix: -match is case-insensitive by default, so this MUST use -cnotmatch' {
        # A regression test for the guard being written with a case-insensitive comparison
        # (`-notmatch`), which lets 'MUT-PROD', 'Mut-prod', etc. slip past a guard meant to
        # allow only the literal lower-case 'mut-' prefix.
        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            $env = [pscustomobject]@{ Id = 'E1'; Name = $badName; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
            { Assert-MutEnvironmentAllowed $env } | Should -Throw "*does not match '^mut-'*"
        }
    }

    It 'allows the literal lower-case mut- prefix' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        { Assert-MutEnvironmentAllowed $env } | Should -Not -Throw
    }
}

Describe 'New-MutEnvironment' {
    BeforeEach {
        Mock -ModuleName DemoPortal Start-Sleep {}
    }

    It 'refuses names without the mut- prefix' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { New-MutEnvironment -Name 'spike-01' -Config $cfg } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'refuses a case-variant of the mut- prefix (MUT-, Mut-, mUt-)' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            { New-MutEnvironment -Name $badName -Config $cfg } | Should -Throw "*does not match '^mut-'*"
        }
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
        # T27 fix round 1, finding 4a: Start-MutEnvironment now settles (env apps --all --json)
        # after a real Draft/Stopped -> Running transition; return a non-empty list immediately
        # so this test's own transition (Draft -> Running) does not need to poll more than once.
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } { @([pscustomobject]@{ id = 'app1' }) }

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
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } { @([pscustomobject]@{ id = 'app1' }) }

        $h = Start-MutEnvironment -Env $env -Config $cfg

        $h.Status | Should -Be 'Running'
        $h.StartDurationSec | Should -Not -BeNullOrEmpty
        $h.SettleDurationSec | Should -Not -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'start' -and $Arguments[2] -eq 'E1' -and $ExpectJson -eq $false
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'apps' -and $Arguments[2] -eq 'E1'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[1] -eq 'install-by-id' -and $Arguments[3] -eq $cfg.demoPortal.activationAppId
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'use' -and $Arguments[2] -eq 'E1' -and $ExpectJson -eq $false
        } -Times 1
    }

    It 'settles (T27 fix round 1, finding 4a): polls env apps --all --json until non-empty (empty then non-empty -> 2 calls), then completes' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false; Status = 'Draft' }

        $script:__settleGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__settleGetCalls++
            if ($script:__settleGetCalls -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Draft'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = 'Environment E1 start requested.' } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'install-by-id' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'use' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

        $script:__settleAppsCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } {
            $script:__settleAppsCalls++
            if ($script:__settleAppsCalls -eq 1) {
                return @()
            }
            return @([pscustomobject]@{ id = 'app1' })
        }

        $h = Start-MutEnvironment -Env $env -Config $cfg

        $h.SettleDurationSec | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } -Times 2
    }

    It 'T11b (spike U5): after settling, probes test-readiness (config demoPortal.settleProbe) until summary.total > 0, and records SettleProbeAttempts' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false; Status = 'Draft' }

        $script:__probeGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__probeGetCalls++
            if ($script:__probeGetCalls -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Draft'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'install-by-id' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'use' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } { @([pscustomobject]@{ id = 'app1' }) }

        $script:__probeTestCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } {
            $script:__probeTestCalls++
            if ($script:__probeTestCalls -lt 3) {
                return [pscustomobject]@{ summary = [pscustomobject]@{ total = 0 } }
            }
            return [pscustomobject]@{ summary = [pscustomobject]@{ total = 9 } }
        }

        $h = Start-MutEnvironment -Env $env -Config $cfgWithProbe

        $h.SettleProbeAttempts | Should -Be 3

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' -and $Arguments[2] -eq 'E1' -and
            $Arguments[3] -eq $cfgWithProbe.demoPortal.settleProbe.codeunitId -and
            $Arguments[4] -eq $cfgWithProbe.demoPortal.settleProbe.functionName
        } -Times 3
    }

    It 'T11b (spike U5): throws when the test-readiness probe never reports summary.total > 0 after 10 attempts' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false; Status = 'Draft' }

        $script:__probeThrowGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__probeThrowGetCalls++
            if ($script:__probeThrowGetCalls -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Draft'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } { @([pscustomobject]@{ id = 'app1' }) }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } {
            [pscustomobject]@{ summary = [pscustomobject]@{ total = 0 } }
        }

        { Start-MutEnvironment -Env $env -Config $cfgWithProbe } | Should -Throw

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } -Times 10
    }

    It 'does not call env start, poll, or settle for an already-Running environment, but still installs the activation app and sets the workspace env' {
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

        # T27 fix round 1, finding 4a: Reset-MutEnvironment always settles after reaching
        # Running; return a non-empty app list immediately so the settle poll needs only 1 call.
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } { @([pscustomobject]@{ id = 'app1' }) }

        $result = Reset-MutEnvironment -Env $env

        $result.DurationSec | Should -Not -BeNullOrEmpty
        $result.SettleDurationSec | Should -Not -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'stop' -and $Arguments[2] -eq 'E1'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'start' -and $Arguments[2] -eq 'E1'
        } -Times 1

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'apps' -and $Arguments[2] -eq 'E1'
        } -Times 1
    }

    It 'settles (T27 fix round 1, finding 4a): polls env apps --all --json until non-empty (empty then non-empty -> 2 calls)' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }

        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'stop' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ success = $true } }
        $script:__resetSettleGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__resetSettleGetCalls++
            if ($script:__resetSettleGetCalls -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Stopped'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }

        $script:__resetSettleAppsCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } {
            $script:__resetSettleAppsCalls++
            if ($script:__resetSettleAppsCalls -eq 1) {
                return @()
            }
            return @([pscustomobject]@{ id = 'app1' })
        }

        $result = Reset-MutEnvironment -Env $env

        $result.SettleDurationSec | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } -Times 2
    }

    It 'refuses an environment not named mut-*' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Reset-MutEnvironment -Env $env } | Should -Throw
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'T11b (spike U5): skips the test-readiness probe and warns when -Config is not given' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }

        $script:__resetNoConfigGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'stop' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__resetNoConfigGetCalls++
            if ($script:__resetNoConfigGetCalls -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Stopped'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } { @([pscustomobject]@{ id = 'app1' }) }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } { throw 'must not be called: no Config was given to Reset-MutEnvironment' }

        $result = Reset-MutEnvironment -Env $env -WarningVariable resetWarnings -WarningAction SilentlyContinue

        $result.SettleProbeAttempts | Should -Be 0
        $resetWarnings | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } -Times 0
    }

    It 'T11b (spike U5): probes test-readiness when -Config carries demoPortal.settleProbe, and records SettleProbeAttempts' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }

        $script:__resetProbeGetCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'stop' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'start' } { [pscustomobject]@{ success = $true } }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'get' } {
            $script:__resetProbeGetCalls++
            if ($script:__resetProbeGetCalls -eq 1) {
                return [pscustomobject]@{ id = 'E1'; status = 'Stopped'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
            }
            return [pscustomobject]@{ id = 'E1'; status = 'Running'; description = 'mut-spike-01'; url = 'https://x/E1'; shared = $false }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[1] -eq 'apps' } { @([pscustomobject]@{ id = 'app1' }) }

        $script:__resetProbeTestCalls = 0
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } {
            $script:__resetProbeTestCalls++
            if ($script:__resetProbeTestCalls -lt 3) {
                return [pscustomobject]@{ summary = [pscustomobject]@{ total = 0 } }
            }
            return [pscustomobject]@{ summary = [pscustomobject]@{ total = 9 } }
        }

        $result = Reset-MutEnvironment -Env $env -Config $cfgWithProbe

        $result.SettleProbeAttempts | Should -Be 3
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } -Times 3
    }
}

Describe 'Stop-MutBackendChildProcesses' {
    <#
        T27 fix round 1, finding 2 (controller ruling): the child-process force-kill lives in
        the backend, not lib/MutantLoop.psm1, so lib/ stays free of continia/docker/
        BcContainerHelper. Get-CimInstance and Stop-Process are mocked -- this test proves the
        filtering/call logic, not real process enumeration/termination.
    #>
    It 'refuses an environment not named mut-*' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        Mock -ModuleName DemoPortal Get-CimInstance { throw 'must not be called' }

        { Stop-MutBackendChildProcesses -Env $env } | Should -Throw
    }

    It 'stops only continia.exe processes whose ParentProcessId is this session ($PID), and returns the count stopped' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }

        Mock -ModuleName DemoPortal Get-CimInstance -ParameterFilter { $Filter -eq "Name='continia.exe'" } {
            @(
                [pscustomobject]@{ ProcessId = 1111; ParentProcessId = $PID }
                [pscustomobject]@{ ProcessId = 2222; ParentProcessId = 999999 }
            )
        }
        $script:__stoppedIds = @()
        Mock -ModuleName DemoPortal Stop-Process { param($Id) $script:__stoppedIds += $Id }

        $stopped = Stop-MutBackendChildProcesses -Env $env

        $stopped | Should -Be 1
        $script:__stoppedIds | Should -Be @(1111)
    }

    It 'returns 0 without throwing when no matching continia.exe process is found' {
        $env = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false }

        Mock -ModuleName DemoPortal Get-CimInstance { @() }
        Mock -ModuleName DemoPortal Stop-Process { throw 'must not be called' }

        $stopped = Stop-MutBackendChildProcesses -Env $env

        $stopped | Should -Be 0
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
