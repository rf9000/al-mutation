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

    It 'returns $null (not 0) when the denominator is zero (review fix round 1: 0.0 is indistinguishable in JSON from "the suite killed nothing")' {
        $totals = [pscustomobject]@{
            total = 2; killed = 0; survived = 0; timeout = 0
            compileError = 1; uncovered = 0; equivalent = 1
        }

        Get-MutScore -Totals $totals | Should -BeNullOrEmpty
        $null -eq (Get-MutScore -Totals $totals) | Should -Be $true
    }

    It 'returns $null (not 0) when the denominator is negative' {
        $totals = [pscustomobject]@{
            total = 1; killed = 0; survived = 0; timeout = 0
            compileError = 1; uncovered = 0; equivalent = 1
        }

        $null -eq (Get-MutScore -Totals $totals) | Should -Be $true
    }

    It 'returns $null (not 0) when total is 0' {
        $totals = [pscustomobject]@{
            total = 0; killed = 0; survived = 0; timeout = 0
            compileError = 0; uncovered = 0; equivalent = 0
        }

        $null -eq (Get-MutScore -Totals $totals) | Should -Be $true
    }

    It 'returns $null (not 0) when every mutant errored (denominator collapses to 0 via the error exclusion itself)' {
        $totals = [pscustomobject]@{
            total = 5; killed = 0; survived = 0; timeout = 0
            compileError = 0; uncovered = 0; equivalent = 0
            error = 5; pending = 0
        }

        $null -eq (Get-MutScore -Totals $totals) | Should -Be $true
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

        # F3c: always present, false on a normal (non--Partial) export.
        $json.aborted | Should -Be $false

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

    It 'F3c: -Partial writes aborted: true into the results JSON' {
        # Regression test: before this fix, a partial (cap-abort) export was indistinguishable
        # from a genuine, low-scored complete run except by inference from totals.pending -gt 0.
        $mutants = @(New-MutTestMutant -Id 1)
        $results = @()

        $paths = Export-MutResults -RunNo 3 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @() -Partial

        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json
        $json.aborted | Should -Be $true
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

        # §7.5 (amended), review fix round 2: the reason must survive into results/<n>.json, not
        # just the summary -- Get-MutMergedMutantRows previously discarded $result.Error entirely.
        ($json.mutants | Where-Object { $_.id -eq 4 }).reason | Should -Be 'API call timed out'

        $summary = Get-Content -Path $paths.SummaryPath -Raw
        $summary | Should -Match '## Errors'
        $summary | Should -Match 'ErroredOne'
        $summary | Should -Match 'API call timed out'

        # The Errors table must carry the reason, not the Survivors/Timeouts table's shape
        # (Original -> Mutated, Covering tests) -- isolate just the Errors section's own text.
        $errorsSection = ($summary -split '## Errors')[1] -split '## Uncovered' | Select-Object -First 1
        $errorsSection | Should -Match 'Reason'
        $errorsSection | Should -Not -Match 'Original -> Mutated'
        $errorsSection | Should -Not -Match 'Covering tests'

        # Mutant 5 is Pending, so the summary must carry a Pending count ("any mutant was
        # never reached", §7.5 amended).
        $summary | Should -Match '## Pending'
        $summary | Should -Match 'Pending: 1'
    }

    It 'does not render a Pending section when no mutant was ever left Pending' {
        $mutants = @(
            New-MutTestMutant -Id 1 -Procedure 'KilledOne'
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:F1'; DurationMs = 100; CoveringTests = @(95155) }
        )

        $paths = Export-MutResults -RunNo 8 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()

        $summary = Get-Content -Path $paths.SummaryPath -Raw
        $summary | Should -Not -Match '## Pending'
    }

    It 'writes score as JSON null (not 0.0), and Get-MutScore returns $null, when every mutant is Error (the denominator collapses to 0)' {
        $mutants = @(
            New-MutTestMutant -Id 1 -Procedure 'ErroredOne'
            New-MutTestMutant -Id 2 -Procedure 'ErroredTwo'
        )
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Error'; KillingTest = $null; DurationMs = $null; CoveringTests = @(); Error = 'API call timed out' }
            [pscustomobject]@{ Id = 2; Status = 'Error'; KillingTest = $null; DurationMs = $null; CoveringTests = @(); Error = 'API call timed out' }
        )

        $paths = Export-MutResults -RunNo 7 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()

        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json
        ($null -eq $json.score) | Should -Be $true

        $rawJsonText = Get-Content -Path $paths.ResultsPath -Raw
        $rawJsonText | Should -Match '"score":\s*null'

        # review fix round 2: "Score: ****" is literal asterisks in GitHub markdown (a
        # rendering bug), not a readable statement that the score could not be computed.
        $summary = Get-Content -Path $paths.SummaryPath -Raw
        $summary | Should -Not -Match '\*\*\*\*'
        $summary | Should -Match 'Score: _not computed'
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

Describe 'Format-MutKillReason' {
    It 'takes the first line (CR or LF), trims it and cuts it to 250 characters' {
        Format-MutKillReason -Text "  Assert.AreEqual failed  `r`nsecond line" | Should -Be 'Assert.AreEqual failed'
        Format-MutKillReason -Text "first`nsecond" | Should -Be 'first'
        Format-MutKillReason -Text "first`rsecond" | Should -Be 'first'
        (Format-MutKillReason -Text ('x' * 400)).Length | Should -Be 250
    }

    It 'returns $null for null, empty or whitespace-only text' {
        Format-MutKillReason -Text $null | Should -BeNullOrEmpty
        Format-MutKillReason -Text '' | Should -BeNullOrEmpty
        Format-MutKillReason -Text "   `r`n  " | Should -BeNullOrEmpty
        $null -eq (Format-MutKillReason -Text '') | Should -BeTrue
    }

    It 'skips leading blank lines and whitespace to the first non-blank line' {
        Format-MutKillReason -Text "`nabc" | Should -Be 'abc'
        Format-MutKillReason -Text "   `r`nabc" | Should -Be 'abc'
        Format-MutKillReason -Text "First`rSecond" | Should -Be 'First'
        Format-MutKillReason -Text '   ' | Should -BeNullOrEmpty
    }

    It 'skips only CR, LF, space and tab at the start, as the AL twin does (not other Unicode whitespace)' {
        Format-MutKillReason -Text "`t `r`n abc" | Should -Be 'abc'
        # A leading no-break space is not skipped, so the first line is blank (the AL Trim set differs per char; this pins the TrimStart set).
        Format-MutKillReason -Text ("{0}`nabc" -f [char]0xA0) | Should -BeNullOrEmpty
    }
}

Describe 'Export-MutResults reason (§6.11.1)' {
    BeforeEach {
        $script:OutDir = "$TestDrive/results-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
    }

    It 'sets reason from KillingError for Killed rows, from Error for Error rows, and null otherwise (also when KillingError is absent)' {
        $mutants = @(1..5 | ForEach-Object { New-MutTestMutant -Id $_ })
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:T'; DurationMs = 5; CoveringTests = @(95155); KillingError = 'Expected 3 but was 4' }
            [pscustomobject]@{ Id = 2; Status = 'Killed'; KillingTest = 'C:T'; DurationMs = 5; CoveringTests = @(95155) }
            [pscustomobject]@{ Id = 3; Status = 'Error'; KillingTest = $null; DurationMs = $null; CoveringTests = @(95155); Error = 'boom' }
            [pscustomobject]@{ Id = 4; Status = 'Survived'; KillingTest = $null; DurationMs = 9; CoveringTests = @(95155); KillingError = $null }
            [pscustomobject]@{ Id = 5; Status = 'Killed'; KillingTest = 'C:T'; DurationMs = 5; CoveringTests = @(95155); KillingError = $null }
        )

        $paths = Export-MutResults -RunNo 7 -Config $script:Config -Env $script:EnvHandle -Mutants $mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()
        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json

        ($json.mutants | Where-Object { $_.id -eq 1 }).reason | Should -Be 'Expected 3 but was 4'
        ($json.mutants | Where-Object { $_.id -eq 2 }).reason | Should -BeNullOrEmpty
        ($json.mutants | Where-Object { $_.id -eq 3 }).reason | Should -Be 'boom'
        ($json.mutants | Where-Object { $_.id -eq 4 }).reason | Should -BeNullOrEmpty
        ($json.mutants | Where-Object { $_.id -eq 5 }).reason | Should -BeNullOrEmpty
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

Describe 'Get-MutTestKey (§6.11.2)' {
    It 'cuts the codeunit name to 30 characters from either form' {
        $long = 'CTS-CB Test Auth Share Detection Extra'
        $cut = $long.Substring(0, 30)
        Get-MutTestKey "${long}:DoIt" | Should -Be "${cut}:DoIt"
        Get-MutTestKey -Codeunit $long -Function 'DoIt' | Should -Be "${cut}:DoIt"
        Get-MutTestKey "${cut}:DoIt" | Should -Be "${cut}:DoIt"
        Get-MutTestKey 'Short:Fn' | Should -Be 'Short:Fn'
    }

    It 'splits at the last colon and tolerates a missing one' {
        Get-MutTestKey 'A:B:Fn' | Should -Be 'A:B:Fn'
        Get-MutTestKey 'NoColon' | Should -Be 'NoColon'
        Get-MutTestKey '' | Should -Be ''
    }
}

Describe 'strictScore, unreliableKills and the summary sections (§6.11.3)' {
    BeforeEach {
        $script:OutDir = "$TestDrive/results-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
        $script:Mutants = @(1..5 | ForEach-Object { New-MutTestMutant -Id $_ })
    }

    It 'Get-MutScore -Strict subtracts unreliableKills from the numerator and keeps the denominator' {
        $totals = [pscustomobject]@{ total = 10; killed = 6; survived = 2; timeout = 1; compileError = 0; uncovered = 1; equivalent = 0; error = 0; pending = 0; unreliableKills = 2 }
        Get-MutScore -Totals $totals | Should -Be 0.7
        Get-MutScore -Totals $totals -Strict | Should -Be 0.5
    }

    It 'Get-MutScore -Strict equals the score when unreliableKills is absent or zero, and is null on the same terms' {
        $plain = [pscustomobject]@{ total = 10; killed = 6; survived = 2; timeout = 1; compileError = 0; uncovered = 1; equivalent = 0 }
        Get-MutScore -Totals $plain -Strict | Should -Be (Get-MutScore -Totals $plain)
        $none = [pscustomobject]@{ total = 2; killed = 0; survived = 0; timeout = 0; compileError = 0; uncovered = 0; equivalent = 0; error = 2; pending = 0; unreliableKills = 0 }
        $null -eq (Get-MutScore -Totals $none -Strict) | Should -BeTrue
    }

    It 'exports unreliable per row, totals.unreliableKills (not a bucket) and strictScore' {
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:T'; DurationMs = 5; CoveringTests = @(1); KillingError = 'x'; Unreliable = $true }
            [pscustomobject]@{ Id = 2; Status = 'Killed'; KillingTest = 'C:U'; DurationMs = 5; CoveringTests = @(1); KillingError = 'y'; Unreliable = $false }
            [pscustomobject]@{ Id = 3; Status = 'Killed'; KillingTest = 'C:U'; DurationMs = 5; CoveringTests = @(1) }
            [pscustomobject]@{ Id = 4; Status = 'Survived'; KillingTest = $null; DurationMs = 5; CoveringTests = @(1); Unreliable = $true }
            [pscustomobject]@{ Id = 5; Status = 'Timeout'; KillingTest = $null; DurationMs = $null; CoveringTests = @(1) }
        )
        $paths = Export-MutResults -RunNo 8 -Config $script:Config -Env $script:EnvHandle -Mutants $script:Mutants -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()
        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json

        $json.totals.killed | Should -Be 3
        $json.totals.unreliableKills | Should -Be 1
        $json.score | Should -Be 0.8
        $json.strictScore | Should -Be 0.6
        ($json.mutants | Where-Object { $_.id -eq 1 }).unreliable | Should -BeTrue
        ($json.mutants | Where-Object { $_.id -eq 2 }).unreliable | Should -BeFalse
        ($json.mutants | Where-Object { $_.id -eq 3 }).unreliable | Should -BeFalse
        # Only a Killed row can be unreliable.
        ($json.mutants | Where-Object { $_.id -eq 4 }).unreliable | Should -BeFalse
        $buckets = $json.totals.killed + $json.totals.survived + $json.totals.timeout + $json.totals.compileError + $json.totals.uncovered + $json.totals.equivalent + $json.totals.error + $json.totals.pending
        $buckets | Should -Be $json.totals.total
    }

    It 'repeats 1 case: no unreliable rows give strictScore equal to score and no new summary sections' {
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:T'; DurationMs = 5; CoveringTests = @(1) }
            [pscustomobject]@{ Id = 2; Status = 'Survived'; KillingTest = $null; DurationMs = 5; CoveringTests = @(1) }
        )
        $paths = Export-MutResults -RunNo 9 -Config $script:Config -Env $script:EnvHandle -Mutants $script:Mutants[0..1] -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @()
        $json = Get-Content -Path $paths.ResultsPath -Raw | ConvertFrom-Json
        $json.strictScore | Should -Be $json.score
        $json.totals.unreliableKills | Should -Be 0
        $md = Get-Content -Path $paths.SummaryPath -Raw
        $md | Should -Not -BeLike '*## Flaky baseline tests*'
        $md | Should -Not -BeLike '*## Unreliable kills*'
    }

    It 'the summary shows both scores, the Flaky baseline tests and the Unreliable kills tables when non-empty' {
        $results = @(
            [pscustomobject]@{ Id = 1; Status = 'Killed'; KillingTest = 'C:Flaky'; DurationMs = 5; CoveringTests = @(1); KillingError = 'timing off | by one'; Unreliable = $true }
            [pscustomobject]@{ Id = 2; Status = 'Survived'; KillingTest = $null; DurationMs = 5; CoveringTests = @(1) }
        )
        $flaky = @([pscustomobject]@{ test = 'C:Flaky'; passed = 2; failed = 1; error = 'timing off' })
        $paths = Export-MutResults -RunNo 10 -Config $script:Config -Env $script:EnvHandle -Mutants $script:Mutants[0..1] -Results $results `
            -OutDir $script:OutDir -StartedUtc (Get-Date) -FinishedUtc (Get-Date) -CompileErrorIds @() -FlakyTests $flaky
        $md = Get-Content -Path $paths.SummaryPath -Raw
        $md | Should -BeLike '*Score: **0.5***'
        $md | Should -BeLike '*Strict score*: **0***'
        $md | Should -BeLike '*## Flaky baseline tests*'
        $md | Should -BeLike '*| C:Flaky | 2 | 1 | timing off |*'
        $md | Should -BeLike '*## Unreliable kills*'
        $md | Should -BeLike '*| 1 | 50200 | IsLargeOrder | 4 | REL | C:Flaky | timing off \| by one |*'
    }
}
