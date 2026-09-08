Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force

    $script:envHandle = [pscustomobject]@{
        Id      = 'E1'
        Name    = 'mut-spike-01'
        Url     = 'https://demoportaldev.continiaonline.com/E1'
        Backend = 'DemoPortal'
        Shared  = $false
        Status  = 'Running'
        CliPath = './.tools/continia.exe'
    }
    $envHandle = $script:envHandle

    $script:badEnv = [pscustomobject]@{
        Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false
    }
    $badEnv = $script:badEnv

    # Fresh module import in this file's own BeforeAll: $script:CliPath has never been assigned
    # yet under Set-StrictMode -Version Latest (as opposed to being $null), so a bare read would
    # throw. Initialize it once so the exit-code-tolerance Describe below can read/restore it
    # regardless of what ran (or didn't, e.g. mid-TDD-red) before it in this file.
    InModuleScope DemoPortal { $script:CliPath = $null }
}

Describe 'Invoke-MutTests' {
    It 'calls test run exactly twice for targets @(95155, 95913, 95913) (distinct codeunits), sequentially in order' {
        $targets = @(
            [pscustomobject]@{ CodeunitId = 95155; Function = $null }
            [pscustomobject]@{ CodeunitId = 95913; Function = $null }
            [pscustomobject]@{ CodeunitId = 95913; Function = $null }
        )

        $script:__callOrder = @()
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } {
            $script:__callOrder += $Arguments[3]
            [pscustomobject]@{
                status  = 'completed'
                passed  = $true
                summary = [pscustomobject]@{ total = 1; passed = 1; failed = 0; skipped = 0; durationSeconds = 1.0; codeunitName = "CU$($Arguments[3])" }
                tests   = @([pscustomobject]@{ name = 'T1'; fullName = "CU:T1"; result = 'Pass'; durationSeconds = 1.0; errorMessage = $null; stackTrace = $null })
            }
        }

        $result = Invoke-MutTests -Env $envHandle -Targets $targets -TimeoutSec 30

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } -Times 2

        $script:__callOrder | Should -Be @(95155, 95913)
        $result.Passed | Should -Be 2
        $result.Failed | Should -Be 0
    }

    It 'passes --json and --timeout <TimeoutSec>, and only includes Function when given' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                summary = [pscustomobject]@{ total = 0; passed = 0; failed = 0; skipped = 0; durationSeconds = 0.0; codeunitName = 'X' }
                tests   = @()
            }
        }

        Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 45 | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' -and $Arguments[2] -eq 'E1' -and $Arguments[3] -eq 95155 -and
            $Arguments -contains '--json' -and
            $Arguments -contains '--timeout' -and ($Arguments[$Arguments.IndexOf('--timeout') + 1]) -eq 45 -and
            $Arguments.Count -eq 7
        } -Times 1

        Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = 'MyTest' }) -TimeoutSec 45 | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' -and $Arguments[3] -eq 95155 -and $Arguments[4] -eq 'MyTest'
        } -Times 1
    }

    It 'uses TimeoutSec + 60s margin for its own process timeout' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                summary = [pscustomobject]@{ total = 0; passed = 0; failed = 0; skipped = 0; durationSeconds = 0.0; codeunitName = 'X' }
                tests   = @()
            }
        }

        Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $TimeoutSec -eq 90 } -Times 1
    }

    It 'maps result Fail, carries errorMessage, and sums Passed/Failed/DurationMs across jobs' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[3] -eq 95155 } {
            [pscustomobject]@{
                summary = [pscustomobject]@{ total = 2; passed = 1; failed = 1; skipped = 0; durationSeconds = 2.0; codeunitName = 'CTS-CB Test Auth Share Detect' }
                tests   = @(
                    [pscustomobject]@{ name = 'Pass1'; fullName = 'X:Pass1'; result = 'Pass'; durationSeconds = 1.2; errorMessage = $null; stackTrace = $null }
                    [pscustomobject]@{ name = 'Fail1'; fullName = 'X:Fail1'; result = 'Fail'; durationSeconds = 0.8; errorMessage = 'boom'; stackTrace = 'at X' }
                )
            }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[3] -eq 95913 } {
            [pscustomobject]@{
                summary = [pscustomobject]@{ total = 1; passed = 1; failed = 0; skipped = 0; durationSeconds = 1.0; codeunitName = 'CTS-CB Test Auth Granted Acc' }
                tests   = @(
                    [pscustomobject]@{ name = 'Pass2'; fullName = 'Y:Pass2'; result = 'Pass'; durationSeconds = 1.0; errorMessage = $null; stackTrace = $null }
                )
            }
        }

        $targets = @(
            [pscustomobject]@{ CodeunitId = 95155; Function = $null }
            [pscustomobject]@{ CodeunitId = 95913; Function = $null }
        )

        $result = Invoke-MutTests -Env $envHandle -Targets $targets -TimeoutSec 30

        $result.Passed | Should -Be 2
        $result.Failed | Should -Be 1
        $result.Tests.Count | Should -Be 3
        $result.DurationMs | Should -Be 3000

        $failRow = $result.Tests | Where-Object { $_.Function -eq 'Fail1' }
        $failRow.Result | Should -Be 'Fail'
        $failRow.Error | Should -Be 'boom'
        $failRow.Codeunit | Should -Be 'CTS-CB Test Auth Share Detect'
        $failRow.DurationMs | Should -Be 800

        $passRow = $result.Tests | Where-Object { $_.Function -eq 'Pass1' }
        $passRow.Result | Should -Be 'Pass'
        $passRow.DurationMs | Should -Be 1200
    }

    It 'collects a jobId when the response has a jobId property' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                jobId   = 'JOB-1'
                summary = [pscustomobject]@{ total = 0; passed = 0; failed = 0; skipped = 0; durationSeconds = 0.0; codeunitName = 'X' }
                tests   = @()
            }
        }

        $result = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30

        $result.JobIds | Should -Be @('JOB-1')
    }

    It 'falls back to an id property when jobId is absent' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                id      = 'ID-2'
                summary = [pscustomobject]@{ total = 0; passed = 0; failed = 0; skipped = 0; durationSeconds = 0.0; codeunitName = 'X' }
                tests   = @()
            }
        }

        $result = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30

        $result.JobIds | Should -Be @('ID-2')
    }

    It 'returns an empty JobIds array when neither jobId nor id is present (U9 unresolved)' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                summary = [pscustomobject]@{ total = 0; passed = 0; failed = 0; skipped = 0; durationSeconds = 0.0; codeunitName = 'X' }
                tests   = @()
            }
        }

        $result = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30

        @($result.JobIds).Count | Should -Be 0
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Invoke-MutTests -Env $badEnv -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 } | Should -Throw
    }
}

Describe 'Invoke-Continia exit-code tolerance for JSON commands (F18)' {
    It 'parses stdout JSON and does not throw when the process exits 1 (test failures still emit valid JSON on stdout)' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                $result = Invoke-Continia -Arguments @('/c', 'echo {"status":"completed","passed":false} & exit 1') -TimeoutSec 30
                $result.passed | Should -Be $false
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }
}

Describe 'Get-MutCoverageRaw' {
    It 'calls test coverage <id> <jobId> --json per job id and returns each csv string, in order' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[3] -eq 'JOB-1' } {
            [pscustomobject]@{ envId = 'E1'; jobId = 'JOB-1'; csv = "a,b`n1,2" }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[3] -eq 'JOB-2' } {
            [pscustomobject]@{ envId = 'E1'; jobId = 'JOB-2'; csv = "a,b`n3,4" }
        }

        $result = Get-MutCoverageRaw -Env $envHandle -JobIds @('JOB-1', 'JOB-2')

        $result.Count | Should -Be 2
        $result[0] | Should -Be "a,b`n1,2"
        $result[1] | Should -Be "a,b`n3,4"

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'coverage' -and $Arguments[2] -eq 'E1' -and $Arguments -contains '--json'
        } -Times 2
    }

    It 'skips job ids that are null or empty' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ envId = 'E1'; jobId = 'JOB-1'; csv = 'a,b' } }

        $result = Get-MutCoverageRaw -Env $envHandle -JobIds @('JOB-1', $null, '')

        $result.Count | Should -Be 1
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 1
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Get-MutCoverageRaw -Env $badEnv -JobIds @('JOB-1') } | Should -Throw
    }
}
