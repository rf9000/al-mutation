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

    It 'does not throw under StrictMode when the response omits tests entirely (the shape most likely on a 0-tests result)' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                summary = [pscustomobject]@{ total = 0; passed = 0; failed = 0; skipped = 0; durationSeconds = 0.0; codeunitName = 'X' }
            }
        }

        $result = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30

        $result.Passed | Should -Be 0
        $result.Failed | Should -Be 0
        $result.Tests.Count | Should -Be 0
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

        { Invoke-MutTests -Env $badEnv -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'refuses a case-variant of the mut- prefix (MUT-, Mut-, mUt-)' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            $caseEnv = [pscustomobject]@{ Id = 'E1'; Name = $badName; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
            { Invoke-MutTests -Env $caseEnv -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 } | Should -Throw "*does not match '^mut-'*"
        }
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
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

Describe 'Invoke-MutTests -Coverage (T24, U9 raw/xUnit path)' {
    BeforeAll {
        $script:SampleXunitXml = @'
<assemblies>
  <assembly name="Tests">
    <collection name="Collection" total="2" passed="1" failed="1">
      <test name="CTS.Test.Pass1" type="CTS.Test" method="Pass1" time="1.234" result="Pass" />
      <test name="CTS.Test.Fail1" type="CTS.Test" method="Fail1" time="0.5" result="Fail">
        <failure exception-type="Boom">
          <message>Expected true but was false.</message>
        </failure>
      </test>
    </collection>
  </assembly>
</assemblies>
'@
    }

    It 'runs test run <id> <cu> --raw --timeout <s> (no --json) when -Coverage is set' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' } {
            [pscustomobject]@{ ExitCode = 0; StdOut = "Test job started: 4242`n$script:SampleXunitXml"; StdErr = '' }
        }

        Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 -Coverage | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'test' -and $Arguments[1] -eq 'run' -and $Arguments[2] -eq 'E1' -and $Arguments[3] -eq 95155 -and
            $Arguments -contains '--raw' -and
            $Arguments -notcontains '--json' -and
            $Arguments -contains '--timeout' -and ($Arguments[$Arguments.IndexOf('--timeout') + 1]) -eq 30 -and
            $ExpectJson -eq $false -and
            $AllowNonZeroExit -eq $true
        } -Times 1
    }

    It 'parses the job id from "Test job started: <N>" and the xUnit XML into Tests rows' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ ExitCode = 1; StdOut = "Test job started: 4242`n$script:SampleXunitXml"; StdErr = '' }
        }

        $result = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 -Coverage

        $result.JobIds | Should -Be @('4242')
        $result.Passed | Should -Be 1
        $result.Failed | Should -Be 1
        $result.Tests.Count | Should -Be 2

        $passRow = $result.Tests | Where-Object { $_.Function -eq 'Pass1' }
        $passRow.Result | Should -Be 'Pass'
        $passRow.DurationMs | Should -Be 1234
        $passRow.Error | Should -Be ''

        $failRow = $result.Tests | Where-Object { $_.Function -eq 'Fail1' }
        $failRow.Result | Should -Be 'Fail'
        $failRow.DurationMs | Should -Be 500
        $failRow.Error | Should -Be 'Expected true but was false.'
    }

    It 'parses the job id from stderr when it is not in stdout' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ ExitCode = 0; StdOut = $script:SampleXunitXml; StdErr = "Test job started: 777`n" }
        }

        $result = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 -Coverage

        $result.JobIds | Should -Be @('777')
    }

    It 'does not throw when the CLI exits non-zero (test failures under --raw)' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ ExitCode = 1; StdOut = "Test job started: 1`n$script:SampleXunitXml"; StdErr = '' }
        }

        { Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 -Coverage } | Should -Not -Throw
    }

    It 'throws (naming the exit code and stderr), rather than returning a clean Passed=0/Failed=0 result, when stdout under --raw has no parseable xUnit XML' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'panic: could not reach the runner service' }
        }

        { Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 95155; Function = $null }) -TimeoutSec 30 -Coverage } |
            Should -Throw '*ExitCode=1*could not reach the runner service*'
    }
}

Describe 'Invoke-Continia -AllowNonZeroExit' {
    It 'suppresses the non-zero-exit throw for a non-JSON command when set' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                $result = Invoke-Continia -Arguments @('/c', 'echo boom & exit 1') -TimeoutSec 30 -ExpectJson:$false -AllowNonZeroExit
                $result.ExitCode | Should -Be 1
                $result.StdOut | Should -Match 'boom'
            }
            finally {
                $script:CliPath = $previousCliPath
            }
        }
    }

    It 'still throws for a non-JSON command with a non-zero exit when not set' {
        InModuleScope DemoPortal {
            $previousCliPath = $script:CliPath
            try {
                $script:CliPath = 'cmd.exe'
                { Invoke-Continia -Arguments @('/c', 'echo boom & exit 1') -TimeoutSec 30 -ExpectJson:$false } | Should -Throw
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

        { Get-MutCoverageRaw -Env $badEnv -JobIds @('JOB-1') } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'refuses a case-variant of the mut- prefix (MUT-, Mut-, mUt-)' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            $caseEnv = [pscustomobject]@{ Id = 'E1'; Name = $badName; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
            { Get-MutCoverageRaw -Env $caseEnv -JobIds @('JOB-1') } | Should -Throw "*does not match '^mut-'*"
        }
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }
}

Describe 'Get-MutCoverage (T24: Get-MutCoverageRaw + ConvertFrom-MutCoverageCsv, merged across jobs)' {
    It 'parses and merges two jobs'' rows, summing Hits for the same (ObjectType, ObjectId, LineNo)' {
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[3] -eq 'JOB-1' } {
            [pscustomobject]@{
                envId = 'E1'
                jobId = 'JOB-1'
                csv   = "`"Codeunit`",`"50000`",`"Object`",`"0`",`"0`"`n`"Codeunit`",`"50000`",`"Code`",`"12`",`"1`""
            }
        }
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[3] -eq 'JOB-2' } {
            [pscustomobject]@{
                envId = 'E1'
                jobId = 'JOB-2'
                csv   = "`"Codeunit`",`"50000`",`"Code`",`"12`",`"2`"`n`"Codeunit`",`"50001`",`"Code`",`"5`",`"1`""
            }
        }

        $result = Get-MutCoverage -Env $envHandle -JobIds @('JOB-1', 'JOB-2')

        $result.Count | Should -Be 3

        $merged = $result | Where-Object { $_.ObjectId -eq 50000 -and $_.LineNo -eq 12 }
        $merged.Hits | Should -Be 3
        $merged.LineType | Should -Be 'Code'

        $unchanged = $result | Where-Object { $_.ObjectId -eq 50000 -and $_.LineNo -eq 0 }
        $unchanged.Hits | Should -Be 0

        $otherObject = $result | Where-Object { $_.ObjectId -eq 50001 }
        $otherObject.Hits | Should -Be 1
    }

    It 'returns a single-row result as an array, not an unwrapped scalar' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ envId = 'E1'; jobId = 'JOB-1'; csv = '"Codeunit","50000","Code","12","1"' }
        }

        $result = Get-MutCoverage -Env $envHandle -JobIds @('JOB-1')

        ($result -is [array]) | Should -Be $true
        $result.Count | Should -Be 1
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Get-MutCoverage -Env $badEnv -JobIds @('JOB-1') } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }

    It 'refuses a case-variant of the mut- prefix (MUT-, Mut-, mUt-)' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            $caseEnv = [pscustomobject]@{ Id = 'E1'; Name = $badName; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
            { Get-MutCoverage -Env $caseEnv -JobIds @('JOB-1') } | Should -Throw "*does not match '^mut-'*"
        }
        Should -Invoke -ModuleName DemoPortal Invoke-Continia -Times 0
    }
}
