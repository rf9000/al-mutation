Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/Results.psm1" -Force

    function script:New-MutTestMutant {
        param(
            [int]$Id,
            [string]$StableKey = "sk-$Id",
            [int]$ObjectId = 50200,
            [string]$Procedure = 'IsLargeOrder',
            [int]$Line = 4,
            [string]$Operator = 'REL',
            [string]$Original = 'Quantity >= 10',
            [string]$Mutated = 'Quantity > 10'
        )
        [pscustomobject]@{
            id          = $Id
            stableKey   = $StableKey
            objectType  = 'codeunit'
            objectId    = $ObjectId
            objectName  = 'MUT Fx Order Mgt'
            procedure   = $Procedure
            line        = $Line
            operator    = $Operator
            original    = $Original
            mutated     = $Mutated
            file        = 'src/FxOrderMgt.Codeunit.al'
        }
    }

    $script:Config = [pscustomobject]@{
        backend  = 'DemoPortal'
        aut      = [pscustomobject]@{ appId = 'aut-app-id'; version = '28.5.0.0' }
        coreApp  = [pscustomobject]@{ version = '1.0.0.0' }
        generator = [pscustomobject]@{ seed = 1; maxMutants = 0; onlyObjects = @(72918635); operators = @('REL', 'BOOL') }
    }

    $script:EnvHandle = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01' }
}

Describe 'Get-MutScore' {
    It 'computes the §7.3 example: killed 17, survived 6, timeout 3, total 26 -> 0.7692' {
        $totals = [pscustomobject]@{
            total = 26; killed = 17; survived = 6; timeout = 3
            compileError = 0; uncovered = 0; equivalent = 0
        }

        Get-MutScore -Totals $totals | Should -Be 0.7692
    }

    It 'subtracts equivalent and compileError from the denominator' {
        $totals = [pscustomobject]@{
            total = 30; killed = 17; survived = 6; timeout = 3
            compileError = 2; uncovered = 0; equivalent = 2
        }

        # denom = 30 - 2 - 2 = 26; numerator = 17 + 3 = 20 -> 0.7692
        Get-MutScore -Totals $totals | Should -Be 0.7692
    }

    It 'returns 0 when the denominator is zero' {
        $totals = [pscustomobject]@{
            total = 2; killed = 0; survived = 0; timeout = 0
            compileError = 1; uncovered = 0; equivalent = 1
        }

        Get-MutScore -Totals $totals | Should -Be 0
    }

    It 'returns 0 when the denominator is negative' {
        $totals = [pscustomobject]@{
            total = 1; killed = 0; survived = 0; timeout = 0
            compileError = 1; uncovered = 0; equivalent = 1
        }

        Get-MutScore -Totals $totals | Should -Be 0
    }

    It 'returns 0 when total is 0' {
        $totals = [pscustomobject]@{
            total = 0; killed = 0; survived = 0; timeout = 0
            compileError = 0; uncovered = 0; equivalent = 0
        }

        Get-MutScore -Totals $totals | Should -Be 0
    }

    It 'excludes error and pending from the denominator alongside equivalent and compileError' {
        $totals = [pscustomobject]@{
            total = 30; killed = 17; survived = 6; timeout = 3
            compileError = 2; uncovered = 0; equivalent = 2
            error = 1; pending = 1
        }

        # denom = 30 - 2 - 2 - 1 - 1 = 24; numerator = 17 + 3 = 20 -> 0.8333
        Get-MutScore -Totals $totals | Should -Be 0.8333
    }

    It 'treats a Totals object with no error/pending property as 0 of each (backward compatible)' {
        $totals = [pscustomobject]@{
            total = 26; killed = 17; survived = 6; timeout = 3
            compileError = 0; uncovered = 0; equivalent = 0
        }

        Get-MutScore -Totals $totals | Should -Be 0.7692
    }
}

Describe 'Export-MutResults' {
    BeforeEach {
        $script:OutDir = "$TestDrive/results-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
    }

    It 'writes <RunNo>.json with the §7.3 shape and correct totals/score, and returns both paths' {
        $mutants = @(
            New-MutTestMutant -Id 1 -Procedure 'IsLargeOrder' -Mutated 'Quantity > 10'
            New-MutTestMutant -Id 2 -Procedure 'IsSmallOrder' -Mutated 'Quantity < 10'
            New-MutTestMutant -Id 3 -Procedure 'IsHugeOrder' -Mutated 'Quantity >= 100'
            New-MutTestMutant -Id 4 -Procedure 'IsTinyOrder' -Mutated 'Quantity <= 1'
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:F1'; DurationMs = 100; CoveringTests = @(95155) }
            [pscustomobject]@{ Id = 2; Status = 'Survived'; KillingTest = $null; DurationMs = 200; CoveringTests = @(95155) }
            [pscustomobject]@{ Id = 3; Status = 'Timeout'; KillingTest = $null; DurationMs = $null; CoveringTests = @(95913) }
            [pscustomobject]@{ Id = 4; Status = 'Uncovered'; KillingTest = $null; DurationMs = 0; CoveringTests = @() }
        )

        $paths = Export-MutResults -RunNo 1 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc ([datetime]'2026-09-08T10:00:00Z') -FinishedUtc ([datetime]'2026-09-08T10:05:00Z') `
            -CompileErrorIds @()

        Test-Path $paths.ResultsPath | Should -Be $true
        Test-Path $paths.SummaryPath | Should -Be $true
        $paths.ResultsPath | Should -Be (Join-Path $script:OutDir '1.json')
        $paths.SummaryPath | Should -Be (Join-Path $script:OutDir '1-summary.md')

        # BOM-less UTF-8: the first byte of both written files must not be the UTF-8 BOM (0xEF).
        ([System.IO.File]::ReadAllBytes($paths.ResultsPath)[0]) | Should -Not -Be 0xEF
        ([System.IO.File]::ReadAllBytes($paths.SummaryPath)[0]) | Should -Not -Be 0xEF

        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json

        $json.runNo | Should -Be 1
        $json.backend | Should -Be 'DemoPortal'
        $json.environmentName | Should -Be 'mut-spike-01'
        $json.autAppId | Should -Be 'aut-app-id'
        $json.autVersion | Should -Be '28.5.0.0'
        $json.coreAppVersion | Should -Be '1.0.0.0'
        $json.generator.seed | Should -Be 1

        $json.totals.total | Should -Be 4
        $json.totals.killed | Should -Be 1
        $json.totals.survived | Should -Be 1
        $json.totals.timeout | Should -Be 1
        $json.totals.uncovered | Should -Be 1
        $json.totals.compileError | Should -Be 0
        $json.totals.equivalent | Should -Be 0

        # denom = 4 - 0 - 0 = 4; numerator = killed(1) + timeout(1) = 2 -> 0.5
        $json.score | Should -Be 0.5

        $json.mutants.Count | Should -Be 4
        ($json.mutants | Where-Object { $_.id -eq 1 }).status | Should -Be 'Killed'
        ($json.mutants | Where-Object { $_.id -eq 1 }).killingTest | Should -Be 'C:F1'
        ($json.mutants | Where-Object { $_.id -eq 2 }).procedure | Should -Be 'IsSmallOrder'
    }

    It 'marks CompileErrorIds mutants as CompileError even when absent from Results' {
        $mutants = @(
            New-MutTestMutant -Id 1
            New-MutTestMutant -Id 2
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Survived'; KillingTest = $null; DurationMs = 10; CoveringTests = @() }
        )

        $paths = Export-MutResults -RunNo 2 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @(2)

        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json

        $json.totals.compileError | Should -Be 1
        ($json.mutants | Where-Object { $_.id -eq 2 }).status | Should -Be 'CompileError'
    }

    It 'summary.md contains a Survivors table with the survivor listed' {
        $mutants = @(
            New-MutTestMutant -Id 1 -Procedure 'IsLargeOrder'
            New-MutTestMutant -Id 2 -Procedure 'IsSmallOrder' -Mutated 'Quantity < 10'
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:F1'; DurationMs = 10; CoveringTests = @(95155) }
            [pscustomobject]@{ Id = 2; Status = 'Survived'; KillingTest = $null; DurationMs = 10; CoveringTests = @(95155) }
        )

        $paths = Export-MutResults -RunNo 3 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()

        $summary = Get-Content -Path $paths.SummaryPath -Raw

        $summary | Should -Match 'Survivors'
        $summary | Should -Match 'IsSmallOrder'
        $summary | Should -Not -Match 'IsLargeOrder\b.*\|.*Killed'
    }

    It 'summary.md contains Timeouts, Compile errors sections and an Uncovered count' {
        $mutants = @(
            New-MutTestMutant -Id 1 -Procedure 'TimesOut'
            New-MutTestMutant -Id 2 -Procedure 'BadCompile'
            New-MutTestMutant -Id 3 -Procedure 'NoCoverage'
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Timeout'; KillingTest = $null; DurationMs = $null; CoveringTests = @(95155) }
            [pscustomobject]@{ Id = 3; Status = 'Uncovered'; KillingTest = $null; DurationMs = 0; CoveringTests = @() }
        )

        $paths = Export-MutResults -RunNo 4 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @(2)

        $summary = Get-Content -Path $paths.SummaryPath -Raw

        $summary | Should -Match 'Timeouts'
        $summary | Should -Match 'TimesOut'
        $summary | Should -Match 'Compile errors'
        $summary | Should -Match 'BadCompile'
        $summary | Should -Match 'Uncovered'
        $summary | Should -Match '\b1\b'
    }

    It 'includes Error and Pending mutants: buckets sum to total, both excluded from the score denominator, and an Errors section is rendered' {
        $mutants = @(
            New-MutTestMutant -Id 1 -Procedure 'KilledOne'
            New-MutTestMutant -Id 2 -Procedure 'SurvivedOne'
            New-MutTestMutant -Id 3 -Procedure 'TimedOutOne'
            New-MutTestMutant -Id 4 -Procedure 'ErroredOne'
            New-MutTestMutant -Id 5 -Procedure 'NeverRan'
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:F1'; DurationMs = 100; CoveringTests = @(95155) }
            [pscustomobject]@{ Id = 2; Status = 'Survived'; KillingTest = $null; DurationMs = 200; CoveringTests = @(95155) }
            [pscustomobject]@{ Id = 3; Status = 'Timeout'; KillingTest = $null; DurationMs = $null; CoveringTests = @(95913) }
            [pscustomobject]@{ Id = 4; Status = 'Error'; KillingTest = $null; DurationMs = $null; CoveringTests = @(95155); Error = 'API call timed out' }
            # Mutant 5 has no Results row and is not in CompileErrorIds -> Pending.
        )

        $paths = Export-MutResults -RunNo 6 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()

        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json

        $json.totals.total | Should -Be 5
        $json.totals.error | Should -Be 1
        $json.totals.pending | Should -Be 1

        $bucketSum = $json.totals.killed + $json.totals.survived + $json.totals.timeout + $json.totals.compileError +
            $json.totals.uncovered + $json.totals.equivalent + $json.totals.error + $json.totals.pending
        $bucketSum | Should -Be $json.totals.total

        # denom = 5 - equivalent(0) - compileError(0) - error(1) - pending(1) = 3; numerator = killed(1) + timeout(1) = 2 -> 0.6667
        $json.score | Should -Be 0.6667

        ($json.mutants | Where-Object { $_.id -eq 4 }).status | Should -Be 'Error'
        ($json.mutants | Where-Object { $_.id -eq 5 }).status | Should -Be 'Pending'

        $summary = Get-Content -Path $paths.SummaryPath -Raw
        $summary | Should -Match '## Errors'
        $summary | Should -Match 'ErroredOne'
    }

    It 'throws when a result row carries an unrecognized status, instead of silently exporting it' {
        $mutants = @(
            New-MutTestMutant -Id 1
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Bogus'; KillingTest = $null; DurationMs = 10; CoveringTests = @() }
        )

        {
            Export-MutResults -RunNo 5 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
                -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()
        } | Should -Throw
    }
}

Describe 'Compare-MutExpectedResults' {
    BeforeEach {
        $script:Dir = "$TestDrive/compare-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:ResultsPath = Join-Path $script:Dir 'results.json'
        $script:ExpectedPath = Join-Path $script:Dir 'expected.json'
    }

    It 'reports no mismatch when actual matches expected' {
        @{
            mutants = @(
                @{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; status = 'Survived' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ResultsPath

        @(
            @{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; expected = 'Survived' }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ExpectedPath

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 0
    }

    It 'tolerates expected Timeout when actual is Killed (not a mismatch)' {
        @{
            mutants = @(
                @{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; status = 'Killed' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ResultsPath

        @(
            @{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; expected = 'Timeout' }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ExpectedPath

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 0
    }

    It 'reports a real mismatch when actual differs from expected (and is not the Timeout/Killed tolerance)' {
        @{
            mutants = @(
                @{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; status = 'Killed' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ResultsPath

        @(
            @{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; expected = 'Survived' }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ExpectedPath

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 1
        $mismatches[0].procedure | Should -Be 'IsLargeOrder'
        $mismatches[0].expected | Should -Be 'Survived'
        $mismatches[0].actual | Should -Be 'Killed'
    }

    It 'matches DEL mutants (mutated = "") also on original' {
        @{
            mutants = @(
                @{ procedure = 'DeleteMe'; operator = 'DEL'; mutated = ''; original = 'DoSomething();'; status = 'Killed' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ResultsPath

        @(
            @{ procedure = 'DeleteMe'; operator = 'DEL'; mutated = ''; original = 'DoSomething();'; expected = 'Killed' }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ExpectedPath

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 0
    }

    It 'reports a missing mutant (no match at all) with actual $null' {
        @{ mutants = @() } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ResultsPath

        @(
            @{ procedure = 'Ghost'; operator = 'REL'; mutated = 'x > 1'; expected = 'Survived' }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ExpectedPath

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 1
        $mismatches[0].actual | Should -BeNullOrEmpty
    }
}
