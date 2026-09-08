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

    It 'marks a mutant with no covering tests as Uncovered without calling the API or running tests' {
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

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -Times 0
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
        Mock -ModuleName MutantLoop Invoke-MutApi {
            $global:MutCallLog += "API:$Method`:$Path"
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ status = 'Killed' }) }
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

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'GET' } -Times 0
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
        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'records Status Error (with the job error message) and continues the loop on a job exception, without aborting' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{ TimedOut = $false; ErrorMessage = 'boom from job'; Result = $null }
        }

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
    }

    It 'PATCHes activeMutantId to the mutant id before running tests, and back to 0 after (Survived path)' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $global:MutCallLog += 'TESTS'
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; Tests = @() }
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

        $global:MutCallLog[0] | Should -BeLike 'API:PATCH:*'
        $global:MutCallLog[1] | Should -Be 'TESTS'
        $global:MutCallLog[-1] | Should -BeLike 'API:PATCH:*'
    }

    It 'PATCHes activeMutantId back to 0 after a timeout too' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            $global:MutCallLog += 'TESTS'
            [pscustomobject]@{ TimedOut = $true; ErrorMessage = $null; Result = $null }
        }

        $mutant = [pscustomobject]@{ id = 40; objectId = 50000; line = 4 }

        Invoke-MutMutantLoop -Config $script:Config -Env $script:EnvHandle -Mutants @($mutant) `
            -Baseline $script:Baseline -Coverage $script:Coverage -References $script:References `
            -RunNo 7 -RunDir $script:RunDir -BackendModulePath 'unused.psm1' | Out-Null

        # order: PATCH(id) -> TESTS -> RESET -> PATCH(0)
        $global:MutCallLog | Should -Be @('API:PATCH:mutationSetup(0)', 'TESTS', 'RESET', 'API:PATCH:mutationSetup(0)')

        Should -Invoke -ModuleName MutantLoop Invoke-MutApi -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.activeMutantId -eq 0
        } -Times 1
    }

    It 'processes mutants in id order regardless of input order' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 1; Tests = @() }
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

    It 'appends one JSON line per mutant to results.jsonl immediately' {
        Mock -ModuleName MutantLoop Invoke-MutTestsWithBudget {
            [pscustomobject]@{
                TimedOut     = $false
                ErrorMessage = $null
                Result       = [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 1; Tests = @() }
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
}

Describe 'Invoke-MutTestsWithBudget (real Start-Job wall-clock kill)' {
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

    It 'kills the job at the budget (1s) instead of waiting for the 30s sleep to finish' {
        # The sleep (30s) is intentionally far beyond both the 1s budget and the elapsed bound
        # below (20s): child powershell.exe spawn time and first-access AV scanning of a
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

        # No leaked background jobs.
        @(Get-Job) | Should -BeNullOrEmpty
    }
}
