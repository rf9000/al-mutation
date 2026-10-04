Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/MutantLoop.psm1" -Force

    function script:New-MutTestConfig {
        param(
            [int]$PerTestFactor = 5,
            [int]$MinSeconds = 60,
            [int]$JobOverheadSeconds = 0,
            [int[]]$TestCodeunits = @(95155, 95913)
        )

        [pscustomobject]@{
            testApp  = [pscustomobject]@{ testCodeunits = $TestCodeunits }
            timeouts = [pscustomobject]@{
                perTestFactor      = $PerTestFactor
                minSeconds         = $MinSeconds
                jobOverheadSeconds = $JobOverheadSeconds
            }
        }
    }

    $script:EnvHandle = [pscustomobject]@{
        Id      = 'E1'
        Name    = 'mut-spike-01'
        Url     = 'https://example.invalid/E1'
        Backend = 'DemoPortal'
        Shared  = $false
    }
}

Describe 'Get-MutTimeoutBudget' {
    It 'returns minSeconds when the computed budget is smaller' {
        $config = New-MutTestConfig -PerTestFactor 2 -MinSeconds 60 -JobOverheadSeconds 0
        $baseline = [pscustomobject]@{
            Tests               = @()
            DurationsByCodeunit = @{ '95155' = 2000 }
        }

        $budget = Get-MutTimeoutBudget -Config $config -CoveringTests @(95155) -Baseline $baseline

        # raw = ceil(2 * 2s + 0) = 4; max(60, 4) = 60
        $budget | Should -Be 60
    }

    It 'returns the computed budget (with ceiling) when it exceeds minSeconds' {
        $config = New-MutTestConfig -PerTestFactor 2 -MinSeconds 5 -JobOverheadSeconds 1
        $baseline = [pscustomobject]@{
            Tests               = @()
            DurationsByCodeunit = @{ '95155' = 3000; '95913' = 4000 }
        }

        $budget = Get-MutTimeoutBudget -Config $config -CoveringTests @(95155, 95913) -Baseline $baseline

        # sum = 7s; raw = 2*7 + 1*2 = 16; max(5, 16) = 16
        $budget | Should -Be 16
    }

    It 'rounds a fractional computed budget up (Ceiling)' {
        $config = New-MutTestConfig -PerTestFactor 3 -MinSeconds 1 -JobOverheadSeconds 0
        $baseline = [pscustomobject]@{
            Tests               = @()
            DurationsByCodeunit = @{ '95155' = 2500 }
        }

        $budget = Get-MutTimeoutBudget -Config $config -CoveringTests @(95155) -Baseline $baseline

        # sum = 2.5s; raw = 3 * 2.5 = 7.5; ceil = 8; max(1, 8) = 8
        $budget | Should -Be 8
    }

    It 'ignores covering codeunits absent from the baseline durations (treated as 0)' {
        $config = New-MutTestConfig -PerTestFactor 1 -MinSeconds 1 -JobOverheadSeconds 0
        $baseline = [pscustomobject]@{
            Tests               = @()
            DurationsByCodeunit = @{ '95155' = 1000 }
        }

        $budget = Get-MutTimeoutBudget -Config $config -CoveringTests @(95155, 99999) -Baseline $baseline

        # sum = 1s (99999 missing -> 0); raw = 1 * 1 = 1; max(1, 1) = 1
        $budget | Should -Be 1
    }

    It 'returns an int' {
        $config = New-MutTestConfig
        $baseline = [pscustomobject]@{ Tests = @(); DurationsByCodeunit = @{} }

        $budget = Get-MutTimeoutBudget -Config $config -CoveringTests @() -Baseline $baseline

        $budget | Should -BeOfType 'int'
    }
}

Describe 'Invoke-MutMutantLoop' {
    BeforeEach {
        $global:MutCallLog = @()

        Mock -ModuleName MutantLoop Invoke-MutApi {
            $global:MutCallLog += "API:$Method`:$Path"
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }
            return $null
        }

        Mock -ModuleName MutantLoop Reset-MutEnvironment {
            $global:MutCallLog += 'RESET'
            return [pscustomobject]@{ DurationSec = 1 }
        }

        # Mocked so the (real, live-run-motivated) post-reset settle delay never actually sleeps
        # in this fast, deterministic unit test.
        Mock -ModuleName MutantLoop Start-MutPostResetSettle {
            $global:MutCallLog += 'SETTLE'
        }

        # 503 bisect: a thrown call now waits for the environment (Wait-MutOutageRecovery) and
        # retries the same mutant. Mocked here as an instant "serving again" so these tests never
        # sleep; its own behaviour is covered by the 'Wait-MutOutageRecovery' Describe below.
        Mock -ModuleName MutantLoop Wait-MutOutageRecovery {
            $global:MutCallLog += 'OUTAGE-WAIT'
            return $Env
        }
        Mock -ModuleName MutantLoop Start-Sleep { }

        $script:Config = New-MutTestConfig -PerTestFactor 1 -MinSeconds 5 -JobOverheadSeconds 0
        $script:Baseline = [pscustomobject]@{
            Tests               = @()
            DurationsByCodeunit = @{ '95155' = 1000; '95913' = 1000 }
        }
        # References fallback covers objectId 50000 with test codeunit 95155; objectId 60000
        # has no entry at all, so a mutant on it is Uncovered.
        $script:References = @{ 50000 = @(95155) }
        $script:Coverage = @{ byTestCodeunit = @{} }
        $script:RunDir = "$TestDrive/run-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item Env:\MutCallLog -ErrorAction SilentlyContinue
        Remove-Variable -Name MutCallLog -Scope Global -ErrorAction SilentlyContinue
    }

    It 'marks a mutant with no covering tests as Uncovered without any per-mutant API call or running tests (M3: only the upfront resume-fetch touches the API)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget { throw 'must not be called for an uncovered mutant' }

        $mutant = [pscustomobject]@{ id = 1; objectId = 60000; line = 1 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 1 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results.Count | Should -Be 1
        $results[0].Id | Should -Be 1
        $results[0].Status | Should -Be 'Uncovered'
        $results[0].KillingTest | Should -BeNullOrEmpty
        @($results[0].CoveringTests).Count | Should -Be 0

        # M3: Invoke-MutMutantLoop now makes exactly one upfront GET (the resume-fetch, filtered
        # to runNo only, no mutantId) before the per-mutant loop even starts. An Uncovered mutant
        # still triggers no PATCH/POST and no test run of its own.
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'GET' -and $Path -notlike '*mutantId*'
        } -Times 1
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'PATCH' } -Times 0
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'POST' } -Times 0
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 0
    }

    It 'POSTs Killed with the first failing test as killingTest when no API row exists yet' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $global:MutCallLog += 'TESTS'
            return [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed     = 1
                    Failed     = 1
                    DurationMs = 4200
                    Tests      = @(
                        [pscustomobject]@{ Codeunit = 'MUT Fx Test'; Function = 'TestIsLargeOrder'; Result = 'Fail'; DurationMs = 4200; Error = 'boom' }
                        [pscustomobject]@{ Codeunit = 'MUT Fx Test'; Function = 'TestOther'; Result = 'Pass'; DurationMs = 100; Error = $null }
                    )
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 7; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 3 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Status | Should -Be 'Killed'
        $results[0].KillingTest | Should -Be 'MUT Fx Test:TestIsLargeOrder'
        $results[0].DurationMs | Should -Be 4200

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'GET' -and $Path -like 'mutantResults*runNo eq 3*mutantId eq 7*'
        } -Times 1

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'mutantResults' -and
            $Body.runNo -eq 3 -and $Body.mutantId -eq 7 -and $Body.status -eq 'Killed' -and
            $Body.killingTest -eq 'MUT Fx Test:TestIsLargeOrder' -and $Body.durationMs -eq 4200
        } -Times 1
    }

    It 'does not POST Killed when a mutantResults row already exists for (runNo, mutantId)' {
        # M3: the upfront resume-fetch (GET filtered to runNo only, no mutantId) must return
        # empty here so the mutant is NOT skipped outright -- this test is specifically about the
        # mid-iteration existing-row check (e.g. the table's own OnAfterTestMethodRun hook, §6.1.4,
        # having already inserted the Killed row while the test job ran), distinct from a full,
        # resumed-run skip.
        Mock -ModuleName MutantLoop Invoke-MutApi {
            $global:MutCallLog += "API:$Method`:$Path"
            if ($Method -eq 'GET' -and $Path -like '*mutantId eq*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ mutantId = 9; status = 'Killed' }) }
            }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }
            return $null
        }

        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 0; Failed = 1; DurationMs = 500
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Fail'; DurationMs = 500; Error = 'x' })
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 9; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 3 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Status | Should -Be 'Killed'

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'POSTs Survived when all tests pass' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 2; Failed = 0; DurationMs = 900
                    Tests  = @(
                        [pscustomobject]@{ Codeunit = 'C'; Function = 'F1'; Result = 'Pass'; DurationMs = 400; Error = $null }
                        [pscustomobject]@{ Codeunit = 'C'; Function = 'F2'; Result = 'Pass'; DurationMs = 500; Error = $null }
                    )
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 11; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 2 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Status | Should -Be 'Survived'
        $results[0].KillingTest | Should -BeNullOrEmpty

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'mutantResults' -and
            $Body.mutantId -eq 11 -and $Body.status -eq 'Survived' -and $Body.durationMs -eq 900
        } -Times 1

        # M3: two GETs are now expected -- the upfront resume-fetch (runNo only) plus the
        # existence check before the Survived POST (runNo and mutantId), both against the
        # default BeforeEach mock which returns an empty `value` array for any GET.
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'GET' -and $Path -notlike '*mutantId*'
        } -Times 1
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'GET' -and $Path -like '*mutantId eq 11*'
        } -Times 1
    }

    It 'retries once when the test run comes back with zero total tests (Passed=0, Failed=0), then uses the retry''s real result (regression, T27 live-run fix)' {
        $script:MutEmptyResultCallCount = 0
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutEmptyResultCallCount++
            if ($script:MutEmptyResultCallCount -eq 1) {
                return [pscustomobject]@{
                    TimedOut = $false; ErrorMessage = $null
                    Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
                }
            }
            return [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{
                    Passed = 0; Failed = 1; DurationMs = 55
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Fail'; DurationMs = 55; Error = 'boom' })
                }
            }
        }
        # F3 (I6): an empty result now checks the environment before the retry is consumed --
        # here it is genuinely fine (already Running, probe would pass), so this is a
        # confirmation, not a recovery: no Write-Warning-worthy event, and the recovery cap is
        # not spent.
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 0 } }

        $mutant = [pscustomobject]@{ id = 50; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 10 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $script:MutEmptyResultCallCount | Should -Be 2
        $results[0].Status | Should -Be 'Killed'
        $results[0].DurationMs | Should -Be 55

        Should -Invoke -ModuleName MutantLoop Get-MutEnvironment -Times 1
        Should -Invoke -ModuleName MutantLoop Start-MutEnvironment -Times 1
    }

    It 'does not retry when the first test run already has a non-zero Passed/Failed count' {
        $script:MutRealResultCallCount = 0
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutRealResultCallCount++
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 42
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 42; Error = $null })
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 51; objectId = 50000; line = 4 }

        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 10 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' | Out-Null

        $script:MutRealResultCallCount | Should -Be 1
    }

    It 'still records Status Survived (not an error) when the POST for a Survived result hits a duplicate-key conflict, e.g. from a resumed run (regression, T27 live-run fix)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 67
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 67; Error = $null })
                }
            }
        }
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            $global:MutCallLog += "API:$Method`:$Path"
            if ($Method -eq 'POST' -and $Path -eq 'mutantResults') {
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new('The remote server returned an error: (400) Bad Request.'),
                    'DuplicateKey', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
                $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                    '{"error":{"code":"Internal_EntityWithSameKeyExists","message":"The record in table MUT Mutant Result already exists."}}')
                throw $errorRecord
            }
            return $null
        }

        $mutant = [pscustomobject]@{ id = 1; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 1 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Status | Should -Be 'Survived'

        # The loop must still PATCH activeMutantId back to 0 afterward despite the swallowed
        # POST conflict.
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.activeMutantId -eq 0
        } -Times 1
    }

    It 'records Status Error (and does not abort the loop) when a Survived POST fails for a reason other than a duplicate-key conflict (M3: one mutant must never kill the run)' {
        # Pre-M3, a non-duplicate-key POST failure propagated out of Invoke-MutMutantLoop and
        # aborted the whole run. M3 requirement 3 wraps every mutant's body so ANY unexpected
        # error -- including this one -- is instead recorded as Status 'Error' and the loop moves
        # on to the next mutant.
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 67
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 67; Error = $null })
                }
            }
        }
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            if ($Method -eq 'POST' -and $Path -eq 'mutantResults') {
                throw 'Some other, unrelated server error'
            }
            return $null
        }

        $mutantA = [pscustomobject]@{ id = 1; objectId = 50000; line = 4 }
        $mutantB = [pscustomobject]@{ id = 2; objectId = 60000; line = 4 }

        $results = $null
        $caughtError = $null
        try {
            $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutantA, $mutantB) `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo 1 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'
        }
        catch {
            $caughtError = $_
        }

        $caughtError | Should -BeNullOrEmpty
        $results.Count | Should -Be 2
        $results[0].Status | Should -Be 'Error'
        $results[0].Error | Should -BeLike '*unrelated server error*'
        # The loop continued: mutant 2 (uncovered) was still processed.
        $results[1].Status | Should -Be 'Uncovered'
    }

    It 'on timeout: resets the environment once, records Timeout, and never POSTs a result' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $global:MutCallLog += 'TESTS'
            [pscustomobject]@{ TimedOut = $true; ErrorMessage = $null; Result = $null }
        }

        $mutant = [pscustomobject]@{ id = 13; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 4 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Status | Should -Be 'Timeout'

        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -Times 1
        # T11b (spike U5): Reset-MutEnvironment must receive -Config so its test-readiness probe
        # (Wait-MutEnvironmentSettled, backend-side) has a settleProbe target to poll.
        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -ParameterFilter { $Config -eq $script:Config } -Times 1
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'records Status Error (with the job error message) and continues the loop on a job exception, without aborting' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{ TimedOut = $false; ErrorMessage = 'boom from job'; Result = $null }
        }
        # F3b (IMPORTANT 1): a job ErrorMessage now also triggers the environment-confirm-and-
        # retry path (before consuming the last attempt), same as an empty result -- the
        # environment genuinely IS fine here (Running, probe passes), so this exercises the
        # "confirmed serving but still erroring" case, not a recovery.
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 0 } }

        $mutantA = [pscustomobject]@{ id = 20; objectId = 50000; line = 4 }
        $mutantB = [pscustomobject]@{ id = 21; objectId = 60000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutantA, $mutantB) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 5 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results.Count | Should -Be 2
        $results[0].Status | Should -Be 'Error'
        $results[0].Error | Should -Be 'boom from job'
        # Loop continued: mutant 21 (uncovered) was still processed.
        $results[1].Status | Should -Be 'Uncovered'

        Should -Invoke -ModuleName MutantLoop Start-MutEnvironment -Times 1
    }

    It 'PATCHes activeMutantId to the mutant id before running tests, and back to 0 after (Survived path)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $global:MutCallLog += 'TESTS'
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 100
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 100; Error = $null })
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 30; objectId = 50000; line = 4 }

        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 6 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' | Out-Null

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.activeMutantId -eq 30 -and $Body.currentRunNo -eq 6
        } -Times 1

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.activeMutantId -eq 0 -and $Body.currentRunNo -eq 6
        } -Times 1

        # M3: skip the leading upfront resume-fetch GET (one per loop invocation) before checking
        # this mutant's own PATCH/TESTS/PATCH sequence.
        $callLog = @($global:MutCallLog | Select-Object -Skip 1)
        $callLog[0] | Should -BeLike 'API:PATCH:*'
        $callLog[1] | Should -Be 'TESTS'
        $callLog[-1] | Should -BeLike 'API:PATCH:*'
    }

    It 'PATCHes activeMutantId to 0 BEFORE Reset-MutEnvironment on a timeout too (F3b BLOCKER 1: the reset''s own probe must not run a real test job with this mutant still active), and again after, and spends one recovery from the shared cap (F3c: proven by a real assertion, not just -WarningAction SilentlyContinue)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $global:MutCallLog += 'TESTS'
            [pscustomobject]@{ TimedOut = $true; ErrorMessage = $null; Result = $null }
        }

        $mutant = [pscustomobject]@{ id = 40; objectId = 50000; line = 4 }

        $timeoutWarnings = $null
        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 7 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningVariable timeoutWarnings -WarningAction SilentlyContinue | Out-Null

        # order: GET (M3 upfront resume-fetch) -> PATCH(id) -> TESTS -> PATCH(0, F3b: before the
        # reset's own probe) -> RESET -> SETTLE -> PATCH(0, the usual per-mutant deactivate)
        # run 11: the Timeout branch first lists sessions to stop the runaway one; with none
        # visible (this mock lists nothing) it falls back to the reset -- still after deactivation.
        # run 14: a Timeout is confirmed by one re-run, which repeats the same cycle -- still
        # deactivating before each reset.
        $global:MutCallLog | Should -Be @('API:GET:mutantResults?$filter=runNo eq 7',
            'API:PATCH:mutationSetup(0)', 'TESTS', 'API:PATCH:mutationSetup(0)', 'API:GET:sessions', 'RESET', 'SETTLE',
            'API:PATCH:mutationSetup(0)', 'TESTS', 'API:PATCH:mutationSetup(0)', 'API:GET:sessions', 'RESET', 'SETTLE',
            'API:PATCH:mutationSetup(0)')

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.activeMutantId -eq 0
        } -Times 2

        # F3c: -WarningAction SilentlyContinue alone (the pre-fix state of this test) would
        # suppress the very "recovery N of 3" warning that proves the timeout spent a slot from
        # the shared cap -- -WarningVariable captures it regardless, so this assertion actually
        # fails if Request-MutEnvironmentRecoveryBudget's call on the timeout path is deleted.
        # run 14: the confirmation re-run times out too and spends a slot again; each successful
        # reset refunds its slot, so both warnings read "1 of 3".
        $recoveryWarning = @($timeoutWarnings) | Where-Object { $_ -like '*a test run timed out*recovering*1 of 3*' }
        @($recoveryWarning).Count | Should -Be 2
    }

    It 'processes mutants in id order regardless of input order' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 1
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 1; Error = $null })
                }
            }
        }

        $mutantHigh = [pscustomobject]@{ id = 99; objectId = 50000; line = 4 }
        $mutantLow = [pscustomobject]@{ id = 5; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutantHigh, $mutantLow) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 8 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Id | Should -Be 5
        $results[1].Id | Should -Be 99
    }

    It 'passes TimeoutSec = max(30, Budget - 30) to Invoke-MutTestsWithBudget, strictly less than BudgetSec (T27 fix round 1, finding 2)' {
        # perTestFactor 100, one covering codeunit at 1000ms baseline -> raw = 100 * 1 = 100;
        # max(minSeconds 5, 100) = 100. Inner TimeoutSec must be max(30, 100 - 30) = 70.
        $script:Config = New-MutTestConfig -PerTestFactor 100 -MinSeconds 5 -JobOverheadSeconds 0

        $script:CapturedTimeoutSec = $null
        $script:CapturedBudgetSec = $null
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            param($Env, $Targets, $TimeoutSec, $BudgetSec, $BackendModulePath)
            $script:CapturedTimeoutSec = $TimeoutSec
            $script:CapturedBudgetSec = $BudgetSec
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null; ForcedKill = $false
                Result   = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 1
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 1; Error = $null })
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 60; objectId = 50000; line = 4 }

        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 11 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' | Out-Null

        $script:CapturedBudgetSec | Should -Be 100
        $script:CapturedTimeoutSec | Should -Be 70
        $script:CapturedTimeoutSec | Should -BeLessThan $script:CapturedBudgetSec
    }

    It 'records Status Error with text ''no tests discovered'' (never Survived) when the test run completes with zero Tests, even after the empty-result retry AND the environment is confirmed serving (T27 fix round 1, finding 4b; F3/I6: the existing behaviour must not regress)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null; ForcedKill = $false
                Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
            }
        }
        # F3 (I6): the environment genuinely IS serving here (Running, and the readiness probe
        # inside Start-MutEnvironment succeeds) -- the empty result is a real "no tests
        # discovered", not a non-serving environment, so no recovery should be attempted and the
        # existing Error behaviour must not change.
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 0 } }

        $mutant = [pscustomobject]@{ id = 61; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 12 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Status | Should -Be 'Error'
        $results[0].Error | Should -Be 'no tests discovered'

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'POST' } -Times 0
        # Confirmed serving without a restart is not a "recovery" -- nothing to warn about, and
        # the cap is untouched.
        Should -Invoke -ModuleName MutantLoop Get-MutEnvironment -Times 1
        Should -Invoke -ModuleName MutantLoop Start-MutEnvironment -Times 1
    }

    It 'F3 (I6, run 8): given an empty result and a stopped environment, restarts it and retries, and the mutant gets its real status rather than Error' {
        $script:MutStoppedEnvResultCallCount = 0
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutStoppedEnvResultCallCount++
            if ($script:MutStoppedEnvResultCallCount -eq 1) {
                return [pscustomobject]@{
                    TimedOut = $false; ErrorMessage = $null
                    Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
                }
            }
            return [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 90
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 90; Error = $null })
                }
            }
        }
        # The environment re-check finds it NOT Running (this is run 8's actual root cause: a
        # status of 'Running' alone was trusted, but here it is honestly reported as stopped).
        $script:MutStoppedEnvGetCalls = 0
        Mock -ModuleName MutantLoop Get-MutEnvironment {
            $script:MutStoppedEnvGetCalls++
            [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Starting' }
        }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 42 } }

        $mutant = [pscustomobject]@{ id = 70; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 13 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $script:MutStoppedEnvResultCallCount | Should -Be 2
        $script:MutStoppedEnvGetCalls | Should -Be 1
        $results[0].Status | Should -Be 'Survived'
        $results[0].DurationMs | Should -Be 90

        Should -Invoke -ModuleName MutantLoop Start-MutEnvironment -Times 1
    }

    It 'F3b BLOCKER 1 (V9): deactivates the mutant before the recovery probe and re-activates it before the retry -- PATCH sequence id, 0, id, 0, not the pre-fix id, 0' {
        # Verified live by the reviewer: Confirm-MutEnvironmentServing's Start-MutEnvironment
        # call runs a REAL test job, and Mutation Core's OnAfterTestMethodRun records a Killed
        # row for any failing test while a mutant is active, with no check that it covers that
        # mutant -- probing with the wrong mutant still active could misattribute a false kill.
        # The default Invoke-MutApi mock (BeforeEach) logs the PATH, which is identical
        # ('mutationSetup(0)') for activate and deactivate -- this test needs the BODY, so it
        # supplies its own mock recording activeMutantId values in call order instead.
        $script:MutPatchSequence = New-Object System.Collections.Generic.List[object]
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            if ($Method -eq 'PATCH' -and $Path -eq 'mutationSetup(0)') {
                $script:MutPatchSequence.Add($Body.activeMutantId)
            }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }
            return $null
        }

        $script:MutBlockerCallCount = 0
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutBlockerCallCount++
            if ($script:MutBlockerCallCount -eq 1) {
                return [pscustomobject]@{
                    TimedOut = $false; ErrorMessage = $null
                    Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
                }
            }
            return [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 12
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 12; Error = $null })
                }
            }
        }
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Stopped' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 9 } }

        $mutant = [pscustomobject]@{ id = 71; objectId = 50000; line = 4 }

        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 15 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null

        # 71 (activate) -> 0 (deactivate, before the probe) -> 71 (re-activate, before the retry)
        # -> 0 (the usual per-mutant deactivate after the result). NOT the pre-fix `71, 0`.
        # Joined to a string for comparison: a direct array-vs-array `Should -Be` on this
        # List[object]'s contents intermittently throws a PS 5.1 interpreter/DLR ArgumentException
        # ("Argumenttyperne stemmer ikke overens") unrelated to the actual values here.
        ($script:MutPatchSequence -join ',') | Should -Be '71,0,71,0'
    }

    It 'F3c: after a recovery, the loop keeps using the refreshed handle Start-MutEnvironment returned, not the original $Env passed into Invoke-MutMutantLoop' {
        # Regression test for an untested headline claim (F3b review finding 2):
        # Confirm-MutEnvironmentServing's return value was previously piped to Out-Null and
        # discarded, so a genuinely refreshed handle (e.g. a different Id after a real restart)
        # would silently NOT propagate to the retry, or to any later mutant in the same run.
        $refreshedEnv = [pscustomobject]@{ Id = 'E2'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 5 }

        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Stopped' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { $refreshedEnv }

        $script:MutRefreshCallCount = 0
        $script:MutRefreshEnvIds = New-Object System.Collections.Generic.List[object]
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            param($Env, $Targets, $TimeoutSec, $BudgetSec, $BackendModulePath)
            $script:MutRefreshCallCount++
            $script:MutRefreshEnvIds.Add($Env.Id)
            if ($script:MutRefreshCallCount -eq 1) {
                return [pscustomobject]@{
                    TimedOut = $false; ErrorMessage = $null
                    Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
                }
            }
            return [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 5
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 5; Error = $null })
                }
            }
        }

        # Mutant A triggers the recovery (Get-MutEnvironment reports Stopped) on its first
        # attempt; mutant B has no covering-test issue of its own and, if the refreshed handle
        # propagated, is processed entirely against E2.
        $mutantA = [pscustomobject]@{ id = 101; objectId = 50000; line = 4 }
        $mutantB = [pscustomobject]@{ id = 102; objectId = 50000; line = 4 }

        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutantA, $mutantB) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 17 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null

        # Call 1 (mutant A, attempt 1): still the ORIGINAL handle (E1) -- the recovery has not
        # happened yet at that point. Call 2 (mutant A, attempt 2, after recovery) and call 3
        # (mutant B) must both be E2 -- the refreshed handle, kept for the rest of the run. A
        # `| Out-Null`-discarded refresh would instead read E1, E1, E1 throughout.
        ($script:MutRefreshEnvIds -join ',') | Should -Be 'E1,E2,E2'
    }

    It 'F3b IMPORTANT 4: the ''Running but the readiness probe failed'' branch is also capped and eventually aborts the run (this branch was previously untested and silently disable-able)' {
        # If Get-MutEnvironment always reports Running but Start-MutEnvironment (the probe)
        # always throws, every recovery attempt takes the "$wasRunning" branch inside
        # Confirm-MutEnvironmentServing/Request-MutEnvironmentRecoveryBudget -- distinct code
        # from the "not Running" branch the other cap test exercises.
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
            }
        }
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { throw 'continia: test-readiness probe never reported summary.total -gt 0' }

        $mutants = @(
            [pscustomobject]@{ id = 91; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 92; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 93; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 94; objectId = 50000; line = 4 }
        )

        $caught = $null
        try {
            Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo 16 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)

        # 503 bisect: a probe failure throws, so it now takes the outage-wait-and-retry path.
        # Mutant 91's first attempt and both outage retries each hit the probe failure and each
        # spend one recovery (3 = the cap), so 91 is recorded as Error; mutant 92's identical
        # failure finds the cap already spent and aborts the run. Still capped, still aborting --
        # sooner than before the outage retry existed (3 rows then), which is the right direction
        # for an environment whose probe never passes.
        $partialRows = @($caught.TargetObject)
        $partialRows.Count | Should -Be 1
        $partialRows[0].Id | Should -Be 91
        $partialRows[0].Status | Should -Be 'Error'
    }

    It 'F3 (I6, run 8): caps environment recoveries per run -- after the cap is hit, the run throws rather than continuing to error out mutants one at a time' {
        # Every mutant's environment re-check reports NOT Running, and every test run comes back
        # empty (a persistently broken environment): the first $script:MaxEnvironmentRecoveries
        # mutants each consume one recovery and are recorded as Error ("no tests discovered"),
        # exactly as an isolated non-serving episode would be; the recovery beyond the cap must
        # abort the WHOLE run instead of becoming yet another per-mutant Error.
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
            }
        }
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Stopped' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 5 } }

        $mutants = @(
            [pscustomobject]@{ id = 81; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 82; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 83; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 84; objectId = 50000; line = 4 }
        )

        $caught = $null
        try {
            Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo 14 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        # F3b (Minors): identified by a distinct ErrorCategory, never by matching the exception
        # message text.
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)

        # F3b (IMPORTANT 3): the rows completed so far (mutants 81-83) travel with the thrown
        # error via TargetObject, so the pipeline can still export a partial result.
        $partialRows = @($caught.TargetObject)
        $partialRows.Count | Should -Be 3
        ($partialRows | ForEach-Object { $_.Id }) | Should -Be @(81, 82, 83)

        # Only the first 3 (the cap) mutants were ever recorded -- the 4th aborted the run before
        # it could be written.
        $jsonlPath = Join-Path $script:RunDir 'results.jsonl'
        $lines = Get-Content -Path $jsonlPath
        $lines.Count | Should -Be 3
        Should -Invoke -ModuleName MutantLoop Start-MutEnvironment -Times 3
    }

    It 'appends one JSON line per mutant to results.jsonl immediately' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 1
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 1; Error = $null })
                }
            }
        }

        $mutants = @(
            [pscustomobject]@{ id = 1; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 2; objectId = 60000; line = 4 }
            [pscustomobject]@{ id = 3; objectId = 50000; line = 4 }
        )

        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 9 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' | Out-Null

        $jsonlPath = Join-Path $script:RunDir 'results.jsonl'
        Test-Path $jsonlPath | Should -Be $true

        $lines = Get-Content -Path $jsonlPath
        $lines.Count | Should -Be 3

        $parsed = $lines | ForEach-Object { $_ | ConvertFrom-Json }
        $parsed[0].Id | Should -Be 1
        $parsed[1].Id | Should -Be 2
        $parsed[2].Id | Should -Be 3
    }

    It 'resumes a run where the API already holds results for 2 of 4 mutants: only the other 2 are executed, and all 4 appear in the returned rows with correct statuses (M3)' {
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            $global:MutCallLog += "API:$Method`:$Path"
            if ($Method -eq 'GET' -and $Path -notlike '*mutantId*') {
                # The upfront resume-fetch (runNo only): mutants 1 and 2 already have rows from
                # an earlier, crashed attempt at this same RunNo.
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{ mutantId = 1; status = 'Survived'; killingTest = $null; durationMs = 111 }
                        [pscustomobject]@{ mutantId = 2; status = 'Killed'; killingTest = 'C:F'; durationMs = 222 }
                    )
                }
            }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }
            return $null
        }

        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $global:MutCallLog += 'TESTS'
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 50
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 50; Error = $null })
                }
            }
        }

        $mutants = @(
            [pscustomobject]@{ id = 1; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 2; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 3; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 4; objectId = 50000; line = 4 }
        )

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 20 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results.Count | Should -Be 4
        ($results | Where-Object { $_.Id -eq 1 }).Status | Should -Be 'Survived'
        ($results | Where-Object { $_.Id -eq 2 }).Status | Should -Be 'Killed'
        ($results | Where-Object { $_.Id -eq 2 }).KillingTest | Should -Be 'C:F'
        ($results | Where-Object { $_.Id -eq 3 }).Status | Should -Be 'Survived'
        ($results | Where-Object { $_.Id -eq 4 }).Status | Should -Be 'Survived'

        # Only mutants 3 and 4 (not recorded yet) actually ran a test job.
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 2

        # Resumed mutants 1 and 2 were never (re-)activated.
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'PATCH' -and $Body.activeMutantId -eq 1 } -Times 0
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'PATCH' -and $Body.activeMutantId -eq 2 } -Times 0
    }

    It 'reads coveringTests for API-resumed mutants from covering.json instead of hard-coding an empty list' {
        # covering.json (written by Run.psm1's Get-MutCoveringTestsStep, §6.5.4 step 7) is on
        # disk before the loop ever runs, keyed by mutant id as a string.
        $coveringPath = Join-Path $script:RunDir 'covering.json'
        ([ordered]@{ '1' = @(95155); '2' = @(95155, 95913) } | ConvertTo-Json -Depth 10) |
            Set-Content -Path $coveringPath -Encoding UTF8

        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            if ($Method -eq 'GET' -and $Path -notlike '*mutantId*') {
                # The upfront resume-fetch: mutants 1 and 2 already have API rows, which never
                # carry coveringTests at all (the `MUT Mutant Result` table has no such column).
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{ mutantId = 1; status = 'Survived'; killingTest = $null; durationMs = 111 }
                        [pscustomobject]@{ mutantId = 2; status = 'Killed'; killingTest = 'C:F'; durationMs = 222 }
                    )
                }
            }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }
            return $null
        }

        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 50
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 50; Error = $null })
                }
            }
        }

        $mutants = @(
            [pscustomobject]@{ id = 1; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 2; objectId = 50000; line = 4 }
        )

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 21 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        @(($results | Where-Object { $_.Id -eq 1 }).CoveringTests) | Should -Be @(95155)
        @(($results | Where-Object { $_.Id -eq 2 }).CoveringTests) | Should -Be @(95155, 95913)
    }

    It 'skips the Survived POST when a mutantResults row already exists for (runNo, mutantId) -- mid-iteration idempotency, distinct from a full resume (M3)' {
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            $global:MutCallLog += "API:$Method`:$Path"
            if ($Method -eq 'GET' -and $Path -like '*mutantId eq*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ mutantId = 15; status = 'Survived' }) }
            }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }
            return $null
        }

        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 30
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 30; Error = $null })
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 15; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 21 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results[0].Status | Should -Be 'Survived'

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'records Status Error and continues the loop when a mutant''s execution throws an unhandled exception (M3)' {
        # 503 bisect: a throw now waits for the environment and retries the same mutant up to
        # 2 times, so the failure must persist across all 3 attempts (calls 1-3) for mutant 70
        # to end in Error. Call 4 is mutant 71.
        $script:MutThrowCallCount = 0
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutThrowCallCount++
            if ($script:MutThrowCallCount -le 3) {
                throw 'unexpected runspace failure'
            }
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 20
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 20; Error = $null })
                }
            }
        }

        $mutantA = [pscustomobject]@{ id = 70; objectId = 50000; line = 4 }
        $mutantB = [pscustomobject]@{ id = 71; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutantA, $mutantB) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 22 -RunDir $script:RunDir -BackendModulePath 'unused.psm1'

        $results.Count | Should -Be 2
        $results[0].Status | Should -Be 'Error'
        $results[0].Error | Should -BeLike '*unexpected runspace failure*'
        $results[1].Status | Should -Be 'Survived'

        # activeMutantId must still be reset to 0 after every attempt of the mutant that threw
        # (3) and once for mutant 71 (1).
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.activeMutantId -eq 0 -and $Body.currentRunNo -eq 22
        } -Times 4 -Exactly
        @($global:MutCallLog | Where-Object { $_ -eq 'OUTAGE-WAIT' }).Count | Should -Be 2
    }

    It 'retries the SAME mutant after an outage wait when its execution throws once, recording its real status (503 bisect; M3''s one-off throw used to become Error)' {
        $script:MutThrowOnceCount = 0
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutThrowOnceCount++
            if ($script:MutThrowOnceCount -eq 1) {
                throw 'unexpected runspace failure'
            }
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 20
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 20; Error = $null })
                }
            }
        }

        $mutant = [pscustomobject]@{ id = 72; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 23 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        @($results).Count | Should -Be 1
        $results[0].Status | Should -Be 'Survived'
        @($global:MutCallLog | Where-Object { $_ -eq 'OUTAGE-WAIT' }).Count | Should -Be 1
    }
}

Describe 'Write-MutResultsJsonLine append retry (M3)' {
    It 'retries the append after a transient failure (e.g. the file-lock IOException that crashed run 3) and eventually succeeds without throwing' {
        $global:MutAddContentAttempts = 0
        Mock -ModuleName MutantLoop Add-Content {
            $global:MutAddContentAttempts++
            if ($global:MutAddContentAttempts -eq 1) {
                throw [System.IO.IOException]::new('The process cannot access the file because it is being used by another process.')
            }
        }
        Mock -ModuleName MutantLoop Start-Sleep {}

        $runDir = "$TestDrive/retry-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        $row = [pscustomobject]@{ Id = 42; Status = 'Survived'; KillingTest = $null; DurationMs = 10; CoveringTests = @(95155) }

        $threw = $false
        try {
            InModuleScope MutantLoop {
                param($RunDir, $Row)
                Write-MutResultsJsonLine -RunDir $RunDir -Row $Row
            } -Parameters @{ RunDir = $runDir; Row = $row }
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $false
        $global:MutAddContentAttempts | Should -Be 2

        Remove-Variable -Name MutAddContentAttempts -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-MutTestsWithBudget (real background-runspace wall-clock kill)' {
    <#
        Fix round 1 (T27, live DemoPortal run, 2026-09-08/09; docs/issues.md): the transport
        under test switched from Start-Job (a separate OS process) to a background runspace
        hosted in this same process, after every live mutant activation hung indefinitely inside
        a Start-Job the moment it tried to spawn continia.exe as a further child process. The
        public contract (TimedOut/Result/ErrorMessage) and this test's assertions are unchanged.
    #>
    BeforeAll {
        $global:MutFakeSlowBackendPath = "$TestDrive/FakeSlowBackend.psm1"
        @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-MutTests {
    param($Env, [object[]]$Targets, [int]$TimeoutSec)
    Start-Sleep -Seconds 30
    return [pscustomobject]@{ Passed = 1; Failed = 0; Tests = @(); DurationMs = 30000; JobIds = @() }
}

Export-ModuleMember -Function Invoke-MutTests
'@ | Set-Content -Path $global:MutFakeSlowBackendPath -Encoding UTF8
    }

    It 'kills the background runspace at the budget (1s) instead of waiting for the 30s sleep to finish' {
        # The sleep (30s) is intentionally far beyond both the 1s budget and the elapsed bound
        # below (20s): runspace/module-import overhead and first-access AV scanning of a
        # freshly written .psm1 are variable and can add several seconds of unrelated jitter on
        # a loaded machine, independent of the kill logic under test. A wide margin here still
        # proves the kill happens long before natural completion without being flaky.
        $envHandle = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01' }
        $targets = @([pscustomobject]@{ CodeunitId = 95155; Function = $null })

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = InModuleScope MutantLoop {
            param($EnvHandle, $Targets, $BackendModulePath)
            Invoke-MutTestsWithBudget -Env $EnvHandle -Targets $Targets -TimeoutSec 1 -BudgetSec 1 -BackendModulePath $BackendModulePath
        } -Parameters @{ EnvHandle = $envHandle; Targets = $targets; BackendModulePath = $global:MutFakeSlowBackendPath }

        $stopwatch.Stop()

        $result.TimedOut | Should -Be $true
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 20

        # No leaked background jobs (the runspace-based implementation never creates any --
        # Get-Job is unrelated to it -- but this also still holds trivially true either way).
        @(Get-Job) | Should -BeNullOrEmpty
    }

    It 'returns TimedOut with no exception within the shortened grace, and force-kills any continia.exe child of this session, when the runspace does not cooperate with .Stop()' {
        <#
            T27 fix round 1, finding 2: a real hang inside the backend's Invoke-Continia is a
            synchronous Process.WaitForExit call PowerShell cannot preempt -- `.Stop()` alone
            does not guarantee the runspace's thread actually returns. This fake backend's
            Invoke-MutTests blocks on a non-interruptible [System.Threading.Thread]::Sleep
            (unlike the cooperative Start-Sleep fake above, whose runspace CAN be torn down
            promptly), to prove the budget+grace+force-kill path still returns cleanly instead
            of hanging or throwing. The module file is written directly in this It (not a second
            top-level BeforeAll in this Describe) to keep this test's own TestDrive path/global
            fully self-contained.
        #>
        $wedgedBackendPath = "$TestDrive/FakeWedgedBackend.psm1"
        @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-MutTests {
    param($Env, [object[]]$Targets, [int]$TimeoutSec)
    [System.Threading.Thread]::Sleep(200000)
    return [pscustomobject]@{ Passed = 1; Failed = 0; Tests = @(); DurationMs = 200000; JobIds = @() }
}

Export-ModuleMember -Function Invoke-MutTests
'@ | Set-Content -Path $wedgedBackendPath -Encoding UTF8

        Mock -ModuleName MutantLoop Stop-MutBackendChildProcesses { $global:MutForcedKillCalled = $true; return 0 }
        $global:MutForcedKillCalled = $false

        $envHandle = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01' }
        $targets = @([pscustomobject]@{ CodeunitId = 95155; Function = $null })

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = $null
        $threw = $false
        try {
            $result = InModuleScope MutantLoop {
                param($EnvHandle, $Targets, $BackendModulePath)
                Invoke-MutTestsWithBudget -Env $EnvHandle -Targets $Targets -TimeoutSec 1 -BudgetSec 1 -GraceSec 3 -BackendModulePath $BackendModulePath
            } -Parameters @{ EnvHandle = $envHandle; Targets = $targets; BackendModulePath = $wedgedBackendPath }
        }
        catch {
            $threw = $true
        }

        $stopwatch.Stop()

        $threw | Should -Be $false
        $result.TimedOut | Should -Be $true
        $result.ForcedKill | Should -Be $true
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 10

        $global:MutForcedKillCalled | Should -Be $true

        # No extra opened runspace leaked from this call (the underlying .NET thread may still
        # be blocked inside Thread.Sleep -- that is the documented, accepted cost of a
        # non-cooperative hang; only the RUNSPACE bookkeeping is asserted clean here).
        @(Get-Runspace | Where-Object { $_.RunspaceStateInfo.State -eq 'Opened' -and $_.Id -ne 1 }) | Should -BeNullOrEmpty

        Remove-Variable -Name MutForcedKillCalled -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-MutMutantLoop: environment outages and the consecutive-Error circuit breaker (503 bisect, 2026-09-30)' {
    <#
        .SYNOPSIS
        Runs 8 and 9 each lost the last 46 of 265 mutants. The 503 bisect showed the cause is a
        transient environment outage after ~45-60 min of continuous test jobs, with no mutant
        active. In run 9, 37 of the 46 were `(503) Server Unavailable` thrown by the PATCH that
        activates each mutant -- a call that sits BEFORE the empty-result retry/recovery, so it
        fell straight into the per-mutant catch, was recorded as Error in seconds, and the loop
        burned through every remaining mutant inside the outage window. Recovery slots spent: 0.
    #>
    BeforeEach {
        $global:MutOutageLog = New-Object System.Collections.Generic.List[string]
        $script:MutCurrentMutant = 0
        $script:MutActivateFailures = @{}

        Mock -ModuleName MutantLoop Reset-MutEnvironment { [pscustomobject]@{ DurationSec = 1 } }
        Mock -ModuleName MutantLoop Start-MutPostResetSettle { }
        Mock -ModuleName MutantLoop Start-Sleep { }
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 0 } }
        Mock -ModuleName MutantLoop Wait-MutOutageRecovery {
            $global:MutOutageLog.Add("WAIT:$MutantId")
            return $Env
        }

        # Activating mutant N throws a 503 while $script:MutActivateFailures[N] is non-zero
        # (decremented per throw; -1 means forever). Every other call behaves like the real API.
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            if ($Method -eq 'PATCH' -and $Path -eq 'mutationSetup(0)') {
                $id = [int]$Body.activeMutantId
                if ($id -ne 0) {
                    $script:MutCurrentMutant = $id
                    if ($script:MutActivateFailures.ContainsKey($id) -and $script:MutActivateFailures[$id] -ne 0) {
                        if ($script:MutActivateFailures[$id] -gt 0) { $script:MutActivateFailures[$id]-- }
                        throw 'Fjernserveren returnerede en fejl: (503) Serveren ikke tilgaengelig..'
                    }
                }
            }
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            return $null
        }

        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null
                Result   = [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 10
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 10; Error = $null })
                }
            }
        }

        $script:Config = New-MutTestConfig -PerTestFactor 1 -MinSeconds 5 -JobOverheadSeconds 0
        $script:Baseline = [pscustomobject]@{ Tests = @(); DurationsByCodeunit = @{ '95155' = 1000 } }
        $script:References = @{ 50000 = @(95155) }
        $script:Coverage = @{ byTestCodeunit = @{} }
        $script:RunDir = "$TestDrive/run-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
    }

    AfterEach {
        Remove-Variable -Name MutOutageLog -Scope Global -ErrorAction SilentlyContinue
    }

    It 'waits for the environment and retries the SAME mutant when an API call throws (run 9: 503 on the activating PATCH), recording its real status instead of Error' {
        $script:MutActivateFailures[30] = 1
        $mutant = [pscustomobject]@{ id = 30; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 30 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results[0].Status | Should -Be 'Survived'
        ($global:MutOutageLog -join ',') | Should -Be 'WAIT:30'
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 1 -Exactly
    }

    It 'records Error only after 2 outage waits for the same mutant, then moves on to the next mutant' {
        $script:MutActivateFailures[31] = -1
        $mutantA = [pscustomobject]@{ id = 31; objectId = 50000; line = 4 }
        $mutantB = [pscustomobject]@{ id = 32; objectId = 50000; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutantA, $mutantB) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 31 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results.Count | Should -Be 2
        $results[0].Status | Should -Be 'Error'
        $results[0].Error | Should -BeLike '*(503)*'
        $results[1].Status | Should -Be 'Survived'
        ($global:MutOutageLog -join ',') | Should -Be 'WAIT:31,WAIT:31'
        # Mutant 31 never reached a test run; mutant 32 ran exactly once.
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 1 -Exactly
        # The retried mutant is written to results.jsonl once, not once per attempt.
        @(Get-Content -Path (Join-Path $script:RunDir 'results.jsonl')).Count | Should -Be 2
    }

    It 'aborts the run with the completed rows attached when the outage wait gives up (environment never serves again)' {
        $script:MutActivateFailures[41] = -1
        Mock -ModuleName MutantLoop Wait-MutOutageRecovery {
            $exception = [System.Exception]::new('Invoke-MutMutantLoop: mutant 41 -- the environment did not return to serving within 900 s')
            throw [System.Management.Automation.ErrorRecord]::new($exception, 'MutEnvironmentOutageTimeout', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $null)
        }
        $mutants = @(
            [pscustomobject]@{ id = 40; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 41; objectId = 50000; line = 4 }
            [pscustomobject]@{ id = 42; objectId = 50000; line = 4 }
        )

        $caught = $null
        try {
            Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo 40 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        $partialRows = @($caught.TargetObject)
        $partialRows.Count | Should -Be 1
        $partialRows[0].Id | Should -Be 40
        # Mutant 42 was never attempted.
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 1 -Exactly
    }

    It 'circuit breaker: aborts after 5 consecutive Error results with those rows attached, and never attempts the 6th mutant (run 9 published a score over 219 of 265 instead)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{ TimedOut = $false; ErrorMessage = 'job failed'; Result = $null }
        }
        $mutants = @(1..6 | ForEach-Object { [pscustomobject]@{ id = 50 + $_; objectId = 50000; line = 4 } })

        $caught = $null
        try {
            Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo 50 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        $caught.Exception.Message | Should -BeLike '*5 consecutive*'
        $partialRows = @($caught.TargetObject)
        $partialRows.Count | Should -Be 5
        ($partialRows | ForEach-Object { $_.Status }) | Should -Be @('Error', 'Error', 'Error', 'Error', 'Error')
        # 5 mutants x 2 attempts each (the existing empty/error retry); mutant 56 never ran.
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 10 -Exactly
    }

    It 'circuit breaker: any non-Error result resets the count, so 4 errors, a survivor, then 4 errors does not abort' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            if ($script:MutCurrentMutant -eq 65) {
                return [pscustomobject]@{
                    TimedOut = $false; ErrorMessage = $null
                    Result   = [pscustomobject]@{
                        Passed = 1; Failed = 0; DurationMs = 10
                        Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 10; Error = $null })
                    }
                }
            }
            [pscustomobject]@{ TimedOut = $false; ErrorMessage = 'job failed'; Result = $null }
        }
        $mutants = @(1..9 | ForEach-Object { [pscustomobject]@{ id = 60 + $_; objectId = 50000; line = 4 } })

        $results = Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $mutants `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 60 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results.Count | Should -Be 9
        @($results | Where-Object { $_.Status -eq 'Error' }).Count | Should -Be 8
        ($results | Where-Object { $_.Id -eq 65 }).Status | Should -Be 'Survived'
    }
}

Describe 'Wait-MutOutageRecovery' {
    BeforeEach {
        $global:MutWaitLog = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName MutantLoop Start-Sleep { $global:MutWaitLog.Add('SLEEP') }
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            $global:MutWaitLog.Add("PATCH:$($Body.activeMutantId)")
            return $null
        }
    }

    AfterEach {
        InModuleScope MutantLoop { $script:OutageWaitDeadlineSec = 900 }
        Remove-Variable -Name MutWaitLog -Scope Global -ErrorAction SilentlyContinue
    }

    It 'deactivates before every readiness check, polls until Start-MutEnvironment confirms serving, and returns that handle' {
        $global:MutWaitStartCalls = 0
        Mock -ModuleName MutantLoop Start-MutEnvironment {
            $global:MutWaitStartCalls++
            $global:MutWaitLog.Add('PROBE')
            if ($global:MutWaitStartCalls -lt 3) { throw 'test-readiness probe never reported summary.total -gt 0' }
            [pscustomobject]@{ Id = 'E2'; Name = 'mut-spike-01'; Status = 'Running' }
        }

        $handle = InModuleScope MutantLoop -Parameters @{ E = $script:EnvHandle } {
            param($E)
            Wait-MutOutageRecovery -Env $E -Config ([pscustomobject]@{}) -MutantId 7 -RunNo 3 -Reason '(503)' -WarningAction SilentlyContinue
        }

        $handle.Id | Should -Be 'E2'
        ($global:MutWaitLog -join ',') | Should -Be 'PATCH:0,PROBE,SLEEP,PATCH:0,PROBE,SLEEP,PATCH:0,PROBE'
    }

    It 'never runs the readiness probe while deactivation is failing -- a probe job with the mutant still active could record a false kill' {
        Mock -ModuleName MutantLoop Invoke-MutApi { throw '(503) Server Unavailable' }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Status = 'Running' } }
        InModuleScope MutantLoop { $script:OutageWaitDeadlineSec = 0 }

        $caught = $null
        try {
            InModuleScope MutantLoop -Parameters @{ E = $script:EnvHandle } {
                param($E)
                Wait-MutOutageRecovery -Env $E -Config ([pscustomobject]@{}) -MutantId 7 -RunNo 3 -Reason '(503)' -WarningAction SilentlyContinue
            }
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        Should -Invoke -ModuleName MutantLoop Start-MutEnvironment -Times 0 -Exactly
    }

    It 'throws LimitsExceeded, naming the deadline and the last readiness error, when the environment never serves again' {
        Mock -ModuleName MutantLoop Start-MutEnvironment { throw 'did not reach status Running within 600 seconds' }
        InModuleScope MutantLoop { $script:OutageWaitDeadlineSec = 0 }

        $caught = $null
        try {
            InModuleScope MutantLoop -Parameters @{ E = $script:EnvHandle } {
                param($E)
                Wait-MutOutageRecovery -Env $E -Config ([pscustomobject]@{}) -MutantId 7 -RunNo 3 -Reason '(503)' -WarningAction SilentlyContinue
            }
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        $caught.Exception.Message | Should -BeLike '*did not return to serving*'
        $caught.Exception.Message | Should -BeLike '*did not reach status Running*'
    }
}

Describe 'Invoke-MutMutantLoop: non-terminating mutants (run 10, 2026-09-30)' {
    <#
        .SYNOPSIS
        Run 10 found the real cause of runs 8/9/10 losing every mutant from execution position 219
        on: mutants 4371, 4373 and 4374 make BuildBatchDisplay's `repeat ... until false` loop
        never exit. The CLI's --timeout only stops the CLIENT waiting and then reports 0 tests; the
        BC session keeps looping (two were still alive ~15 min later). The loop read that as an
        EMPTY result -- "no tests discovered" -- and never reached the Timeout branch, so every later
        job on that test codeunit came back empty too. Run 11 then showed the Timeout branch's full
        environment stop/start can itself fail (the new container's database attach raced the old
        one), so the Timeout branch now stops just the runaway session through Mutation Core's
        sessions API, and falls back to the reset only when it cannot.

        The fake session registry below models the live behaviour verified on 2026-10-01: a job
        whose client wait expires leaves a live 'Client Service' session looping -- DemoPortal's
        long-lived, REUSED test-runner session, so it logged in well before the job started (run
        12's first version filtered on login time and missed it); POST
        sessions(<id>)/Microsoft.NAV.stop removes a live session from the list; a STALE row (a
        session killed by an earlier container restart) is on an older server instance, accepts
        the stop, and never disappears. serverInstanceId increments per service start, and the
        caller's own request session is always listed on the current one.
    #>
    BeforeEach {
        $script:MutClock = 0.0
        $script:MutAttemptSeconds = 1.0
        $script:MutNextSessionId = 80
        $script:MutUnstoppable = @{}
        $script:MutStopRequests = New-Object System.Collections.Generic.List[int]
        $script:MutCurrentInstance = 12
        $script:MutFakeSessions = New-Object System.Collections.Generic.List[object]
        # A stale row from an earlier server instance, and the orchestrator's own API session.
        $script:MutFakeSessions.Add([pscustomobject]@{ sessionId = 4991; userId = 'EH'; clientType = 'Client Service'; serverInstanceId = 9; loginDateTime = [datetime]::UtcNow.AddHours(-2).ToString('o'); isCurrentSession = $false })
        $script:MutApiSession = [pscustomobject]@{ sessionId = -5; userId = 'RF'; clientType = 'Web Service'; serverInstanceId = 12; loginDateTime = [datetime]::UtcNow.ToString('o'); isCurrentSession = $false }
        $script:MutFakeSessions.Add($script:MutApiSession)

        function script:Add-MutRunawaySession {
            # The reused test-runner session: current instance, but logged in long before the job.
            $script:MutNextSessionId++
            $script:MutFakeSessions.Add([pscustomobject]@{ sessionId = $script:MutNextSessionId; userId = 'EH'; clientType = 'Client Service'; serverInstanceId = $script:MutCurrentInstance; loginDateTime = [datetime]::UtcNow.AddMinutes(-30).ToString('o'); isCurrentSession = $false })
        }

        Mock -ModuleName MutantLoop Start-MutPostResetSettle { }
        Mock -ModuleName MutantLoop Start-Sleep { $script:MutClock += $Seconds }
        Mock -ModuleName MutantLoop Get-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running' } }
        Mock -ModuleName MutantLoop Start-MutEnvironment { [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Status = 'Running'; StartDurationSec = 0 } }
        Mock -ModuleName MutantLoop Wait-MutOutageRecovery { return $Env }
        # A reset starts a new server instance: every session alive before it is a stale row on
        # the old instance afterwards, and the caller's request session is on the new one.
        Mock -ModuleName MutantLoop Reset-MutEnvironment {
            $script:MutCurrentInstance++
            $script:MutApiSession.serverInstanceId = $script:MutCurrentInstance
            [pscustomobject]@{ DurationSec = 1 }
        }
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            if ($Method -eq 'GET' -and $Path -eq 'sessions') {
                return [pscustomobject]@{ value = @($script:MutFakeSessions.ToArray()) }
            }
            if ($Method -eq 'POST' -and $Path -match '^sessions\((-?\d+)\)/Microsoft\.NAV\.stop$') {
                $id = [int]$Matches[1]
                $script:MutStopRequests.Add($id)
                $isStale = $id -eq 4991
                if (-not $isStale -and -not $script:MutUnstoppable.ContainsKey($id)) {
                    $victim = @($script:MutFakeSessions | Where-Object { $_.sessionId -eq $id })
                    foreach ($v in $victim) { [void]$script:MutFakeSessions.Remove($v) }
                }
                return $null
            }
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            return $null
        }
        # Each attempt advances the mocked clock; an attempt that takes the whole client wait
        # leaves a runaway session behind, as live.
        Mock -ModuleName MutantLoop Get-MutClockSeconds { return $script:MutClock }
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutClock += $script:MutAttemptSeconds
            if ($script:MutAttemptSeconds -ge 30) { Add-MutRunawaySession }
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null; ForcedKill = $false
                Result   = [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; Tests = @() }
            }
        }

        # minSeconds 5 -> budget 5 -> the CLI's inner timeout is max(30, budget - 30) = 30 s.
        $script:Baseline = [pscustomobject]@{ Tests = @(); DurationsByCodeunit = @{ '95121' = 250 } }
        $script:References = @{ 72918630 = @(95121) }
        $script:Coverage = @{ byTestCodeunit = @{} }
        $script:TimeoutConfig = New-MutTestConfig -PerTestFactor 1 -MinSeconds 5 -JobOverheadSeconds 0 -TestCodeunits @(95121)
        $script:RunDir = "$TestDrive/run-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null

        $script:TimedOutWithRunaway = {
            Add-MutRunawaySession
            [pscustomobject]@{ TimedOut = $true; ErrorMessage = $null; ForcedKill = $false; Result = $null }
        }
    }

    It 'records Timeout, not "no tests discovered", when an empty result took the full client wait -- and stops the runaway session instead of restarting the environment' {
        $script:MutAttemptSeconds = 31.0
        $mutant = [pscustomobject]@{ id = 4371; objectId = 72918630; line = 40 }

        $results = Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 10 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results[0].Status | Should -Be 'Timeout'
        # The attempt and its one confirmation re-run (run 14) each left a runaway, each stopped.
        ($script:MutStopRequests -join ',') | Should -Be '81,82'
        @($script:MutFakeSessions | Where-Object { $_.sessionId -in 81, 82 }).Count | Should -Be 0
        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -Times 0 -Exactly
        # No empty-result retry against the still-looping session (what poisoned runs 8-10) --
        # only the confirmation re-run, after the session was stopped.
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 2 -Exactly
    }

    It 'never stops a stale session row (from an earlier server instance) -- it accepts the stop but never goes away, and would force a needless reset' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget $script:TimedOutWithRunaway
        $mutant = [pscustomobject]@{ id = 4373; objectId = 72918630; line = 44 }

        Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 10 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null

        $script:MutStopRequests | Should -Not -Contain 4991
        $script:MutStopRequests | Should -Not -Contain -5
        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -Times 0 -Exactly
    }

    It 'falls back to the full environment reset when the runaway session does not go away after the stop' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget $script:TimedOutWithRunaway
        $script:MutUnstoppable[81] = $true
        $mutant = [pscustomobject]@{ id = 4374; objectId = 72918630; line = 45 }

        $results = Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 10 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results[0].Status | Should -Be 'Timeout'
        # 81 never goes away -> reset; the confirmation re-run's runaway (82) is then stopped.
        ($script:MutStopRequests -join ',') | Should -Be '81,82'
        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -Times 1 -Exactly
    }

    It 'falls back to the full environment reset when the sessions API is unavailable (an older Mutation Core)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget $script:TimedOutWithRunaway
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            if ($Path -eq 'sessions') { throw "(404) Not Found: the resource 'sessions' does not exist" }
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            return $null
        }
        $mutant = [pscustomobject]@{ id = 4371; objectId = 72918630; line = 40 }

        $results = Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 10 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results[0].Status | Should -Be 'Timeout'
        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -Times 2 -Exactly
    }

    It 'still treats a FAST empty result as empty (retry, then "no tests discovered"), not as Timeout' {
        $script:MutAttemptSeconds = 1.0
        $mutant = [pscustomobject]@{ id = 61; objectId = 72918630; line = 4 }

        $results = Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 11 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results[0].Status | Should -Be 'Error'
        $results[0].Error | Should -Be 'no tests discovered'
        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -Times 0 -Exactly
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 2 -Exactly
    }

    It 'does not spend a recovery slot when the runaway is stopped or the reset succeeds, so 4 non-terminating mutants in one run do not hit the cap of 3' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget $script:TimedOutWithRunaway
        # Every Timeout takes the reset path (no sessions API) and every reset succeeds: 4 mutants x
        # (attempt + confirmation) = 8 resets, none of which may spend the cap of 3. Four in a row
        # stays under the consecutive-Timeout breaker (5), so the cap is what this measures.
        Mock -ModuleName MutantLoop Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            if ($Path -eq 'sessions') { throw '(404) Not Found' }
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            return $null
        }
        $mutants = @(1..4 | ForEach-Object { [pscustomobject]@{ id = 100 + $_; objectId = 72918630; line = 4 } })

        $results = Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants $mutants `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 12 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        @($results).Count | Should -Be 4
        ($results | ForEach-Object { $_.Status }) | Should -Be @('Timeout', 'Timeout', 'Timeout', 'Timeout')
        Should -Invoke -ModuleName MutantLoop Reset-MutEnvironment -Times 8 -Exactly
    }

    It 'waits for the environment after a failed fallback reset before the confirmation re-run, records only confirmed Timeouts, and keeps failed resets'' slots so a dead environment still hits the cap' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{ TimedOut = $true; ErrorMessage = $null; ForcedKill = $false; Result = $null }
        }
        Mock -ModuleName MutantLoop Reset-MutEnvironment { throw "Wait-MutEnvironmentStatus: environment 'E1' did not reach status 'Running' within 600 seconds" }
        $mutants = @(1..4 | ForEach-Object { [pscustomobject]@{ id = 200 + $_; objectId = 72918630; line = 4 } })

        $caught = $null
        try {
            Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants $mutants `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo 13 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        # 201: attempt -> no visible runaway -> reset fails (slot 1 kept) -> wait for the
        # environment -> confirmation re-run -> times out again -> reset fails (slot 2) -> Timeout
        # recorded, then wait. 202: attempt -> reset fails (slot 3) -> wait -> confirmation re-run
        # times out -> the cap is spent -> abort. Only 201's confirmed Timeout is a row; 202's
        # single, unconfirmed Timeout is not recorded (Pending), which is the point of confirming.
        $partialRows = @($caught.TargetObject)
        ($partialRows | ForEach-Object { $_.Status }) | Should -Be @('Timeout')
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 4 -Exactly
        Should -Invoke -ModuleName MutantLoop Wait-MutOutageRecovery -Times 3 -Exactly
    }

    It 'records the real result, not Timeout, when the confirmation re-run finishes -- an environment hiccup is not a kill (run 14, mutant 159)' {
        $script:MutHiccupCalls = 0
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $script:MutHiccupCalls++
            if ($script:MutHiccupCalls -eq 1) {
                return [pscustomobject]@{ TimedOut = $true; ErrorMessage = $null; ForcedKill = $false; Result = $null }
            }
            [pscustomobject]@{
                TimedOut = $false; ErrorMessage = $null; ForcedKill = $false
                Result   = [pscustomobject]@{
                    Passed = 13; Failed = 0; DurationMs = 186
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 186; Error = $null })
                }
            }
        }
        $mutant = [pscustomobject]@{ id = 159; objectId = 72918630; line = 120 }

        $results = Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 15 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue

        $results[0].Status | Should -Be 'Survived'
        $results[0].DurationMs | Should -Be 186
        Should -Invoke -ModuleName MutantLoop Invoke-MutTestsWithBudget -Times 2 -Exactly
        @(Get-Content -Path (Join-Path $script:RunDir 'results.jsonl')).Count | Should -Be 1
    }

    It 'aborts after 5 consecutive Timeouts -- every mutant timing out is a budget or environment problem, not five non-terminating mutants in a row' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget $script:TimedOutWithRunaway
        $mutants = @(1..6 | ForEach-Object { [pscustomobject]@{ id = 300 + $_; objectId = 72918630; line = 4 } })

        $caught = $null
        try {
            Invoke-MutMutantLoop -Config $script:TimeoutConfig -Env $script:EnvHandle -Mutants $mutants `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo 14 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        $caught.Exception.Message | Should -BeLike '*5 consecutive*Timeout*'
        @($caught.TargetObject).Count | Should -Be 5
        $script:MutStopRequests.Count | Should -Be 10
    }
}

# ---------------------------------------------------------------------------------------------
# T42 (§6.10.4/§6.10.6 item 1): testTransport 'soap'. The backend (Invoke-MutMutantBatch,
# Get-MutRunnerState, Stop-MutRunnerBatch, Test-MutSoapRunner) and every recovery helper are
# mocked at ModuleName MutantLoop; Invoke-MutMutantBatch follows a script of per-call responses.
# ---------------------------------------------------------------------------------------------
Describe 'Invoke-MutMutantLoop (testTransport soap)' {
    BeforeAll {
        function script:New-MutBatchRes {
            param($Results = @(), $Hung = $null, $Fault = $null, $FaultText = $null)
            [pscustomobject]@{ Results = @($Results); HungMutantId = $Hung; FaultMutantId = $Fault; Fault = $FaultText; Stopped = ($null -ne $Hung -or $null -ne $Fault) }
        }
        function script:New-MutBatchEntry {
            param([int]$Id, [string]$Status = 'Survived', [string]$Killing = '', [int]$Ms = 100)
            [pscustomobject]@{ MutantId = $Id; Status = $Status; KillingTest = $Killing; DurationMs = $Ms; Passed = 1; Failed = 0 }
        }
    }

    BeforeEach {
        $global:SoapLog = New-Object System.Collections.ArrayList
        $global:SoapCalls = New-Object System.Collections.ArrayList
        $global:SoapScript = New-Object System.Collections.ArrayList
        $global:SoapDefault = $null
        $global:SoapPosts = New-Object System.Collections.ArrayList
        $global:SoapExisting = @{}
        $global:SoapResumeRows = @()
        $global:SoapStateRows = @()
        $global:SoapRunnerOk = $true
        $global:SoapStopConfirmed = $true
        $global:SoapStopCalls = New-Object System.Collections.ArrayList
        $global:SoapResetThrows = $false
        $global:SoapFailOnce = New-Object System.Collections.ArrayList

        Mock -ModuleName MutantLoop Invoke-MutApi {
            if ($global:SoapFailOnce.Contains($Method)) {
                $global:SoapFailOnce.Remove($Method)
                throw '(503) Server Unavailable'
            }
            if ($Method -eq 'PATCH') {
                [void]$global:SoapLog.Add("PATCH:$($Body.activeMutantId)")
                return $null
            }
            if ($Method -eq 'POST') {
                [void]$global:SoapLog.Add("POST:$($Body.status)")
                [void]$global:SoapPosts.Add($Body)
                return $null
            }
            if ($Path -match 'mutantId eq (\d+)') {
                $id = [int]$Matches[1]
                [void]$global:SoapLog.Add("GET-ROW:$id")
                if ($global:SoapExisting.ContainsKey($id)) {
                    return [pscustomobject]@{ value = @($global:SoapExisting[$id]) }
                }
                return [pscustomobject]@{ value = @() }
            }
            [void]$global:SoapLog.Add('GET-RESUME')
            return [pscustomobject]@{ value = @($global:SoapResumeRows) }
        }
        Mock -ModuleName MutantLoop Test-MutSoapRunner { [void]$global:SoapLog.Add('PROBE'); return $global:SoapRunnerOk }
        Mock -ModuleName MutantLoop Get-MutRunnerState {
            [void]$global:SoapLog.Add('STATE')
            return [pscustomobject]@{ ServerNowUtc = [datetime]::UtcNow; Rows = @($global:SoapStateRows) }
        }
        Mock -ModuleName MutantLoop Stop-MutRunnerBatch {
            [void]$global:SoapLog.Add("STOP:$BatchId")
            [void]$global:SoapStopCalls.Add([pscustomobject]@{ BatchId = $BatchId; CodeunitIds = $CodeunitIds })
            return [pscustomobject]@{ Confirmed = $global:SoapStopConfirmed }
        }
        Mock -ModuleName MutantLoop Invoke-MutMutantBatch {
            [void]$global:SoapLog.Add("BATCH:$(@($MutantIds) -join ',')")
            [void]$global:SoapCalls.Add([pscustomobject]@{ CodeunitIds = @($CodeunitIds); MutantIds = @($MutantIds); RunNo = $RunNo; Budget = $MutantBudgetSec })
            $sb = $null
            if ($global:SoapScript.Count -gt 0) {
                $sb = $global:SoapScript[0]
                $global:SoapScript.RemoveAt(0)
            }
            elseif ($null -ne $global:SoapDefault) {
                $sb = $global:SoapDefault
            }
            if ($null -ne $sb) { return (& $sb @($MutantIds)) }
            return [pscustomobject]@{
                Results      = @($MutantIds | ForEach-Object { [pscustomobject]@{ MutantId = $_; Status = 'Survived'; KillingTest = ''; DurationMs = 10; Passed = 1; Failed = 0 } })
                HungMutantId = $null; FaultMutantId = $null; Fault = $null; Stopped = $false
            }
        }
        Mock -ModuleName MutantLoop Confirm-MutEnvironmentServing { [void]$global:SoapLog.Add('CONFIRM'); return $Env }
        Mock -ModuleName MutantLoop Reset-MutEnvironment {
            [void]$global:SoapLog.Add('RESET')
            if ($global:SoapResetThrows) { throw 'reset failed' }
            return [pscustomobject]@{ DurationSec = 1 }
        }
        Mock -ModuleName MutantLoop Start-MutPostResetSettle { }
        Mock -ModuleName MutantLoop Wait-MutOutageRecovery { [void]$global:SoapLog.Add('OUTAGE-WAIT'); return $Env }
        Mock -ModuleName MutantLoop Start-Sleep { }
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget { throw 'the cli runner must not be used with testTransport soap' }

        $script:Config = New-MutTestConfig -PerTestFactor 1 -MinSeconds 5 -JobOverheadSeconds 0
        $script:Config | Add-Member -NotePropertyName testTransport -NotePropertyValue 'soap'
        $script:Config | Add-Member -NotePropertyName soap -NotePropertyValue ([pscustomobject]@{ batchSize = 50 })
        $script:Baseline = [pscustomobject]@{ Tests = @(); DurationsByCodeunit = @{ '95155' = 1000; '95913' = 1000 } }
        # 50000/50003 -> 95155; 50001 -> 95155+95913; 50002 -> 95913; 60000 -> uncovered.
        $script:References = @{ 50000 = @(95155); 50001 = @(95155, 95913); 50002 = @(95913); 50003 = @(95155) }
        $script:Coverage = @{ byTestCodeunit = @{} }
        $script:RunDir = "$TestDrive/soap-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null

        function script:Invoke-SoapLoop {
            param($Mutants, [int]$RunNo = 1)
            Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants $Mutants `
                -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
                -RunNo $RunNo -RunDir $script:RunDir -BackendModulePath 'unused.psm1' -WarningAction SilentlyContinue
        }
        function script:New-SoapMutants {
            param([int[]]$Ids, [int]$ObjectId = 50000)
            , @($Ids | ForEach-Object { [pscustomobject]@{ id = $_; objectId = $ObjectId; line = 1 } })
        }
    }

    AfterEach {
        foreach ($name in 'SoapLog', 'SoapCalls', 'SoapScript', 'SoapDefault', 'SoapPosts', 'SoapExisting', 'SoapResumeRows', 'SoapStateRows', 'SoapRunnerOk', 'SoapStopConfirmed', 'SoapStopCalls', 'SoapResetThrows', 'SoapFailOnce') {
            Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'throws before any further work when Test-MutSoapRunner is false' {
        $global:SoapRunnerOk = $false
        { Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1) } | Should -Throw '*MUTRunner*'
        $global:SoapLog | Should -Not -Contain 'STATE'
        $global:SoapCalls.Count | Should -Be 0
    }

    It 'does not use the soap backend when testTransport is cli' {
        $script:Config.testTransport = 'cli'
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{ TimedOut = $false; ErrorMessage = $null; Result = [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 5; Tests = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass' }) } }
        }
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1)
        $rows[0].Status | Should -Be 'Survived'
        $global:SoapCalls.Count | Should -Be 0
        $global:SoapLog | Should -Not -Contain 'PROBE'
    }

    It 'stops unfinished orphan rows with the testApp codeunits as health set, then PATCHes 0, all before resume data and the first batch' {
        $global:SoapStateRows = @(
            [pscustomobject]@{ BatchId = 'orphan-1'; Finished = $false }
            [pscustomobject]@{ BatchId = 'done-1'; Finished = $true }
        )
        Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1) | Out-Null

        $global:SoapStopCalls.Count | Should -Be 1
        $global:SoapStopCalls[0].BatchId | Should -Be 'orphan-1'
        $global:SoapStopCalls[0].CodeunitIds | Should -Be '95155|95913'
        $log = @($global:SoapLog)
        $log.IndexOf('PROBE') | Should -BeLessThan $log.IndexOf('STATE')
        $log.IndexOf('STOP:orphan-1') | Should -BeLessThan $log.IndexOf('PATCH:0')
        $log.IndexOf('PATCH:0') | Should -BeLessThan $log.IndexOf('GET-RESUME')
        $log.IndexOf('GET-RESUME') | Should -BeLessThan $log.IndexOf('BATCH:1')
    }

    It 'sends an orphan whose stop is not confirmed to PATCH 0 then Reset-MutEnvironment' {
        $global:SoapStateRows = @([pscustomobject]@{ BatchId = 'orphan-1'; Finished = $false })
        $global:SoapStopConfirmed = $false
        Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1) | Out-Null
        $log = @($global:SoapLog)
        $log.IndexOf('RESET') | Should -BeGreaterThan $log.IndexOf('STOP:orphan-1')
        $log[($log.IndexOf('RESET') - 1)] | Should -Be 'PATCH:0'
        $log.IndexOf('RESET') | Should -BeLessThan $log.IndexOf('BATCH:1')
    }

    It 'batches consecutive mutants with an identical covering set, capped by soap.batchSize' {
        $script:Config.soap.batchSize = 2
        $mutants = (New-SoapMutants -Ids 1, 2, 3, 4, 5) + (New-SoapMutants -Ids 6 -ObjectId 50001) + (New-SoapMutants -Ids 7 -ObjectId 50000)
        Invoke-SoapLoop -Mutants $mutants | Out-Null

        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2', '3,4', '5', '6', '7')
        $global:SoapCalls[0].CodeunitIds | Should -Be @(95155)
        $global:SoapCalls[3].CodeunitIds | Should -Be @(95155, 95913)
        $global:SoapCalls[0].RunNo | Should -Be 1
    }

    It 'batches mutants whose covering sets are equal as sets, and passes CodeunitIds in the head mutant order (health codeunit first)' {
        $script:References[50002] = @(95913, 95155)
        $mutants = (New-SoapMutants -Ids 1 -ObjectId 50001) + (New-SoapMutants -Ids 2 -ObjectId 50002)
        Invoke-SoapLoop -Mutants $mutants | Out-Null
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2')
        $global:SoapCalls[0].CodeunitIds | Should -Be @(95155, 95913)
    }

    It 'caps a batch at 120 s of summed covering-set baseline duration, and a single mutant always forms a batch' {
        $script:Baseline.DurationsByCodeunit['95155'] = 50000
        $script:Baseline.DurationsByCodeunit['95913'] = 130000
        $mutants = (New-SoapMutants -Ids 1, 2, 3) + (New-SoapMutants -Ids 4, 5 -ObjectId 50002)
        Invoke-SoapLoop -Mutants $mutants | Out-Null
        # 50 + 50 = 100 <= 120, a third would make 150; each 130 s mutant stands alone.
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2', '3', '4', '5')
    }

    It 'uses the §6.5.6 per-mutant budget of the covering set as MutantBudgetSec' {
        $script:Config.timeouts.minSeconds = 5
        $script:Config.timeouts.perTestFactor = 3
        $script:Baseline.DurationsByCodeunit['95155'] = 4000
        Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2) | Out-Null
        $global:SoapCalls[0].Budget | Should -Be (Get-MutTimeoutBudget -Config $script:Config -CoveringTests @(95155) -Baseline $script:Baseline)
        $global:SoapCalls[0].Budget | Should -Be 12
    }

    It 'appends batch results to results.jsonl in the cli row shape with no POST and no per-mutant PATCH' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @(
                    (New-MutBatchEntry -Id 1 -Status 'Killed' -Killing 'T:F' -Ms 42)
                    (New-MutBatchEntry -Id 2 -Status 'Survived' -Ms 7)) }) | Out-Null

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2)

        $rows.Count | Should -Be 2
        $rows[0].Id | Should -Be 1
        $rows[0].Status | Should -Be 'Killed'
        $rows[0].KillingTest | Should -Be 'T:F'
        $rows[0].DurationMs | Should -Be 42
        @($rows[0].CoveringTests) | Should -Be @(95155)
        $rows[1].Status | Should -Be 'Survived'
        $rows[1].KillingTest | Should -BeNullOrEmpty

        $lines = @(Get-Content -Path (Join-Path $script:RunDir 'results.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        $lines.Count | Should -Be 2
        $lines[0].Id | Should -Be 1
        $lines[0].Status | Should -Be 'Killed'
        $lines[0].KillingTest | Should -Be 'T:F'
        $lines[0].DurationMs | Should -Be 42
        @($lines[0].CoveringTests) | Should -Be @(95155)

        $global:SoapPosts.Count | Should -Be 0
        # Only the loop-start PATCH 0 (after the orphan sweep).
        @($global:SoapLog | Where-Object { $_ -like 'PATCH:*' }).Count | Should -Be 1
    }

    It 'marks an uncovered mutant Uncovered without a backend call and keeps id order' {
        $mutants = (New-SoapMutants -Ids 1) + (New-SoapMutants -Ids 2 -ObjectId 60000) + (New-SoapMutants -Ids 3)
        $rows = Invoke-SoapLoop -Mutants $mutants
        @($rows | ForEach-Object { $_.Status }) | Should -Be @('Survived', 'Uncovered', 'Survived')
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1', '3')
    }

    It 'on an Empty entry: PATCH 0, environment check, one retry alone, and the retry result stands' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 1), (New-MutBatchEntry -Id 2 -Status 'Empty')) }) | Out-Null
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 2 -Status 'Killed' -Killing 'T:G')) }) | Out-Null

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2)

        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2', '2')
        $log = @($global:SoapLog)
        $log[($log.IndexOf('CONFIRM') - 1)] | Should -Be 'PATCH:0'
        $log.IndexOf('CONFIRM') | Should -BeLessThan ([array]::LastIndexOf($log, 'BATCH:2'))
        $rows[1].Status | Should -Be 'Killed'
        $rows[1].KillingTest | Should -Be 'T:G'
    }

    It 'records Error (not POSTed) when the Empty retry is Empty again' {
        $global:SoapDefault = { param($ids) New-MutBatchRes -Results @($ids | ForEach-Object { New-MutBatchEntry -Id $_ -Status 'Empty' }) }
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1)
        $rows[0].Status | Should -Be 'Error'
        $rows[0].Error | Should -Be 'no tests discovered'
        $global:SoapCalls.Count | Should -Be 2
        $global:SoapPosts.Count | Should -Be 0
    }

    It 'treats a mutant with neither a result nor a hung/fault id like Empty' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 1)) }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2)
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2', '2')
        $rows[1].Status | Should -Be 'Survived'
        $global:SoapLog | Should -Contain 'CONFIRM'
    }

    It 'lets an existing row of a hung mutant stand with no re-run, and continues the rest as a new batch' {
        $global:SoapExisting[2] = [pscustomobject]@{ status = 'Killed'; killingTest = 'T:H'; durationMs = 55 }
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 1)) -Hung 2 }) | Out-Null

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)

        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '3')
        @($rows | ForEach-Object { $_.Status }) | Should -Be @('Survived', 'Killed', 'Survived')
        $rows[1].KillingTest | Should -Be 'T:H'
        $global:SoapPosts.Count | Should -Be 0
    }

    It 're-runs a hung mutant without a row once; a re-run that passes stands' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 1)) -Hung 2 }) | Out-Null
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 2 -Status 'Survived' -Ms 186)) }) | Out-Null

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)

        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '2', '3')
        $rows[1].Status | Should -Be 'Survived'
        $rows[1].DurationMs | Should -Be 186
        $global:SoapPosts.Count | Should -Be 0
    }

    It 'POSTs Timeout when the re-run hangs again, so resume skips the mutant' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 1)) -Hung 2 }) | Out-Null
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Hung 2 }) | Out-Null

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)

        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '2', '3')
        $rows[1].Status | Should -Be 'Timeout'
        $global:SoapPosts.Count | Should -Be 1
        $global:SoapPosts[0].status | Should -Be 'Timeout'
        $global:SoapPosts[0].mutantId | Should -Be 2
        $global:SoapPosts[0].runNo | Should -Be 1
        $rows[2].Status | Should -Be 'Survived'
    }

    It 'isolates a fault culprit: earlier mutants keep their results, the culprit re-runs alone, the rest continue as a new batch' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 1)) -Fault 2 -FaultText 'boom' }) | Out-Null
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 2 -Status 'Killed' -Killing 'T:K')) }) | Out-Null

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)

        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '2', '3')
        @($rows | ForEach-Object { $_.Status }) | Should -Be @('Survived', 'Killed', 'Survived')
        $global:SoapPosts.Count | Should -Be 0
    }

    It 'records Error (not POSTed) for a fault culprit that faults again alone' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Fault 1 -FaultText 'boom' }) | Out-Null
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Fault 1 -FaultText 'boom again' }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2)
        $rows[0].Status | Should -Be 'Error'
        $rows[0].Error | Should -BeLike '*boom again*'
        $rows[1].Status | Should -Be 'Survived'
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2', '1', '2')
        $global:SoapPosts.Count | Should -Be 0
    }

    It 'waits out an outage thrown by a batch, re-runs the orphan sweep (stopping its runner), then retries the batch' {
        $global:SoapScript.Add({
                param($ids)
                $e = [System.Net.WebException]::new('(503) Server Unavailable')
                $e.Data['BatchId'] = 'live-batch'
                throw $e
            }) | Out-Null
        Mock -ModuleName MutantLoop Get-MutRunnerState {
            [void]$global:SoapLog.Add('STATE')
            $rows = @()
            # The sweep after the outage wait sees the live runner of the failed batch.
            if (@($global:SoapLog | Where-Object { $_ -eq 'OUTAGE-WAIT' }).Count -gt 0) {
                $rows = @([pscustomobject]@{ BatchId = 'live-batch'; Finished = $false })
            }
            return [pscustomobject]@{ ServerNowUtc = [datetime]::UtcNow; Rows = $rows }
        }

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1)

        $log = @($global:SoapLog)
        $log | Should -Contain 'OUTAGE-WAIT'
        $log.IndexOf('OUTAGE-WAIT') | Should -BeLessThan $log.IndexOf('STOP:live-batch')
        $log.IndexOf('STOP:live-batch') | Should -BeLessThan ([array]::LastIndexOf($log, 'BATCH:1'))
        $global:SoapCalls.Count | Should -Be 2
        $rows[0].Status | Should -Be 'Survived'
    }

    It 'records Error for the batch head after the outage retries are spent, and continues with the rest' {
        $global:SoapScript.Add({ param($ids) throw 'down' }) | Out-Null
        $global:SoapScript.Add({ param($ids) throw 'down' }) | Out-Null
        $global:SoapScript.Add({ param($ids) throw 'down' }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2)
        $rows[0].Status | Should -Be 'Error'
        $rows[0].Error | Should -Be 'down'
        $rows[1].Status | Should -Be 'Survived'
        @($global:SoapLog | Where-Object { $_ -eq 'OUTAGE-WAIT' }).Count | Should -Be 2
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2', '1,2', '1,2', '2')
    }

    It 'on RunnerStopFailed with a successful reset: PATCH 0, reset, the culprit goes through the hang handling (re-run alone), predecessors keep their rows, the rest continue' {
        $global:SoapExisting[1] = [pscustomobject]@{ status = 'Survived'; killingTest = ''; durationMs = 9 }
        $global:SoapScript.Add({ param($ids) throw 'RunnerStopFailed: the runner of batch b was not confirmed stopped within 120 s (mutant 2).' }) | Out-Null

        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)

        $log = @($global:SoapLog)
        $log[($log.IndexOf('RESET') - 1)] | Should -Be 'PATCH:0'
        @($rows | ForEach-Object { $_.Status }) | Should -Be @('Survived', 'Survived', 'Survived')
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '2', '3')
        $global:SoapPosts.Count | Should -Be 0
    }

    It 'on RunnerStopFailed with a successful reset: an existing row of the culprit stands with no re-run' {
        $global:SoapExisting[2] = [pscustomobject]@{ status = 'Killed'; killingTest = 'T:Z'; durationMs = 5 }
        $global:SoapExisting[1] = [pscustomobject]@{ status = 'Survived'; killingTest = ''; durationMs = 9 }
        $global:SoapScript.Add({ param($ids) throw 'RunnerStopFailed: x (mutant 2).' }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)
        $rows[1].Status | Should -Be 'Killed'
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '3')
    }

    It 'on RunnerStopFailed with a successful reset: a culprit whose re-run hangs again is Timeout' {
        $global:SoapExisting[1] = [pscustomobject]@{ status = 'Survived'; killingTest = ''; durationMs = 9 }
        $global:SoapScript.Add({ param($ids) throw 'RunnerStopFailed: x (mutant 2).' }) | Out-Null
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Hung 2 }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)
        $rows[1].Status | Should -Be 'Timeout'
        $global:SoapPosts.Count | Should -Be 1
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '2', '3')
    }

    It 'on RunnerStopFailed with a failed reset: the culprit is Timeout, POSTed after the outage wait, and not re-run' {
        $global:SoapResetThrows = $true
        $global:SoapExisting[1] = [pscustomobject]@{ status = 'Survived'; killingTest = ''; durationMs = 9 }
        $global:SoapScript.Add({ param($ids) throw 'RunnerStopFailed: x (mutant 2).' }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3)

        $rows[1].Status | Should -Be 'Timeout'
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2,3', '3')
        $global:SoapPosts.Count | Should -Be 1
        $global:SoapPosts[0].status | Should -Be 'Timeout'
        $log = @($global:SoapLog)
        $log.IndexOf('OUTAGE-WAIT') | Should -BeLessThan $log.IndexOf('POST:Timeout')
    }

    It 'a failed reset then an outage wait: the orphan sweep runs before the next batch' {
        $global:SoapResetThrows = $true
        $global:SoapExisting[1] = [pscustomobject]@{ status = 'Survived'; killingTest = ''; durationMs = 9 }
        $global:SoapScript.Add({ param($ids) throw 'RunnerStopFailed: x (mutant 2).' }) | Out-Null
        Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3) | Out-Null
        $log = @($global:SoapLog)
        $after = @($log[($log.IndexOf('OUTAGE-WAIT') + 1)..($log.Count - 1)])
        $after.IndexOf('STATE') | Should -BeGreaterThan -1
        $after.IndexOf('STATE') | Should -BeLessThan $after.IndexOf('BATCH:3')
    }

    It 'a confirmed reset after RunnerStopFailed gives its recovery slot back' {
        foreach ($n in 1..4) {
            $global:SoapScript.Add([scriptblock]::Create("param(`$ids) throw 'RunnerStopFailed: x (mutant $n).'")) | Out-Null
            $global:SoapScript.Add([scriptblock]::Create("param(`$ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id $n))")) | Out-Null
        }
        $script:Config.soap.batchSize = 1
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3, 4)
        @($rows | ForEach-Object { $_.Status }) | Should -Be @('Survived', 'Survived', 'Survived', 'Survived')
        @($global:SoapLog | Where-Object { $_ -eq 'RESET' }).Count | Should -Be 4
    }

    It 'a 503 on a per-item GET after RunnerStopFailed is waited out, not turned into Error' {
        $global:SoapScript.Add({ param($ids) [void]$global:SoapFailOnce.Add('GET'); throw 'RunnerStopFailed: x (mutant 2).' }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2)
        @($rows | ForEach-Object { $_.Status }) | Should -Be @('Survived', 'Survived')
        $global:SoapLog | Should -Contain 'OUTAGE-WAIT'
    }

    It 'a failed reset after RunnerStopFailed keeps its slot spent, and the recovery cap aborts with the rows so far' {
        $global:SoapResetThrows = $true
        foreach ($n in 1..4) {
            $global:SoapScript.Add([scriptblock]::Create("param(`$ids) throw 'RunnerStopFailed: x (mutant $n).'")) | Out-Null
        }
        $script:Config.soap.batchSize = 1
        $caught = $null
        try { Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3, 4) | Out-Null } catch { $caught = $_ }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        @($caught.TargetObject).Count | Should -Be 3
        @($global:SoapLog | Where-Object { $_ -eq 'RESET' }).Count | Should -Be 3
    }

    It 'aborts after 5 consecutive Timeouts with the rows so far' {
        $global:SoapDefault = { param($ids) New-MutBatchRes -Hung $ids[0] }
        $script:Config.soap.batchSize = 1
        $caught = $null
        try { Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3, 4, 5, 6) | Out-Null } catch { $caught = $_ }

        $caught | Should -Not -BeNullOrEmpty
        $caught.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        $caught.Exception.Message | Should -BeLike '*5 consecutive*Timeout*'
        @($caught.TargetObject).Count | Should -Be 5
        @($global:SoapPosts | Where-Object { $_.status -eq 'Timeout' }).Count | Should -Be 5
    }

    It 'aborts after 5 consecutive Error rows' {
        $global:SoapDefault = { param($ids) New-MutBatchRes -Results @($ids | ForEach-Object { New-MutBatchEntry -Id $_ -Status 'Empty' }) }
        $script:Config.soap.batchSize = 1
        $caught = $null
        try { Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3, 4, 5, 6) | Out-Null } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -BeLike '*5 consecutive*Error*'
        @($caught.TargetObject).Count | Should -Be 5
    }

    It 'resume: skips recorded mutants (no batch for them) and still returns their rows' {
        $global:SoapResumeRows = @(
            [pscustomobject]@{ mutantId = 1; status = 'Killed'; killingTest = 'T:A'; durationMs = 3 }
            [pscustomobject]@{ mutantId = 2; status = 'Survived'; killingTest = ''; durationMs = 4 }
        )
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2, 3, 4)

        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('3,4')
        @($rows | ForEach-Object { $_.Id }) | Should -Be @(1, 2, 3, 4)
        $rows[0].Status | Should -Be 'Killed'
        $rows[0].KillingTest | Should -Be 'T:A'
        # Resumed rows are not appended again.
        @(Get-Content -Path (Join-Path $script:RunDir 'results.jsonl')).Count | Should -Be 2
    }

    It 'a batch interrupted by an outage is re-run whole; rows the runner already wrote are not POSTed' {
        $global:SoapScript.Add({ param($ids) throw 'connection refused' }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2)
        @($rows | ForEach-Object { $_.Status }) | Should -Be @('Survived', 'Survived')
        $global:SoapPosts.Count | Should -Be 0
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1,2', '1,2')
        @(Get-Content -Path (Join-Path $script:RunDir 'results.jsonl')).Count | Should -Be 2
    }

    It 'outage retries exhausted: the orphan sweep runs before the remainder starts its batch' {
        foreach ($i in 1..3) { $global:SoapScript.Add({ param($ids) throw 'down' }) | Out-Null }
        Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1, 2) | Out-Null
        $log = @($global:SoapLog)
        $lastFailed = [array]::LastIndexOf($log, 'BATCH:1,2')
        $after = @($log[($lastFailed + 1)..($log.Count - 1)])
        $after.IndexOf('STATE') | Should -BeGreaterThan -1
        $after.IndexOf('STATE') | Should -BeLessThan $after.IndexOf('BATCH:2')
    }

    It 'a 503 on the PATCH 0 before the environment check is waited out and the mutant still gets its retry result' {
        $global:SoapScript.Add({ param($ids) [void]$global:SoapFailOnce.Add('PATCH'); New-MutBatchRes -Results @((New-MutBatchEntry -Id 1 -Status 'Empty')) }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1)
        $rows[0].Status | Should -Be 'Survived'
        $log = @($global:SoapLog)
        $log.IndexOf('OUTAGE-WAIT') | Should -BeGreaterThan -1
        $log.IndexOf('OUTAGE-WAIT') | Should -BeLessThan $log.IndexOf('CONFIRM')
    }

    It 'a 503 on the Timeout POST is waited out and the POST retried: the verdict stays Timeout' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Hung 1 }) | Out-Null
        $global:SoapScript.Add({ param($ids) [void]$global:SoapFailOnce.Add('POST'); New-MutBatchRes -Hung 1 }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1)
        $rows[0].Status | Should -Be 'Timeout'
        $global:SoapPosts.Count | Should -Be 1
        $log = @($global:SoapLog)
        $log.IndexOf('OUTAGE-WAIT') | Should -BeLessThan $log.IndexOf('POST:Timeout')
    }

    It 'a hang re-run that returns Empty goes through the environment check and one retry (step 3)' {
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Hung 1 }) | Out-Null
        $global:SoapScript.Add({ param($ids) New-MutBatchRes -Results @((New-MutBatchEntry -Id 1 -Status 'Empty')) }) | Out-Null
        $rows = Invoke-SoapLoop -Mutants (New-SoapMutants -Ids 1)
        $global:SoapLog | Should -Contain 'CONFIRM'
        @($global:SoapCalls | ForEach-Object { $_.MutantIds -join ',' }) | Should -Be @('1', '1', '1')
        $rows[0].Status | Should -Be 'Survived'
    }
}
