Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/Results.psm1" -Force

    function script:New-MutResultRow {
        param(
            [int]$Id = 1,
            [string]$Procedure = 'IsLargeOrder',
            [string]$Operator = 'REL',
            [string]$Original = 'Quantity >= 10',
            [string]$Mutated = 'Quantity > 10',
            [string]$Status = 'Survived'
        )
        [pscustomobject]@{
            id        = $Id
            objectId  = 50200
            procedure = $Procedure
            line      = 7
            operator  = $Operator
            original  = $Original
            mutated   = $Mutated
            status    = $Status
        }
    }

    function script:New-MutResultsDoc {
        param([object[]]$Mutants)
        [pscustomobject]@{ runNo = 1; mutants = $Mutants }
    }
}

Describe 'Compare-MutExpectedResults' {
    BeforeEach {
        $script:ResultsPath = "$TestDrive/results-$([guid]::NewGuid().ToString('N')).json"
        $script:ExpectedPath = "$TestDrive/expected-$([guid]::NewGuid().ToString('N')).json"
    }

    It 'reports no mismatches when every expected status matches exactly' {
        $mutants = @(
            (New-MutResultRow -Id 1 -Procedure 'IsLargeOrder' -Operator 'REL' -Mutated 'Quantity > 10' -Status 'Survived')
            (New-MutResultRow -Id 2 -Procedure 'IsLargeOrder' -Operator 'COND' -Original 'Quantity >= 10' -Mutated 'true' -Status 'Killed')
        )
        (New-MutResultsDoc -Mutants $mutants | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ResultsPath -Encoding UTF8

        $expected = @(
            [pscustomobject]@{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; expected = 'Survived' }
            [pscustomobject]@{ procedure = 'IsLargeOrder'; operator = 'COND'; mutated = 'true'; expected = 'Killed' }
        )
        ($expected | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ExpectedPath -Encoding UTF8

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 0
    }

    It 'reports a mismatch when the actual status differs from expected (and is not the Timeout/Killed tolerance)' {
        $mutants = @(
            (New-MutResultRow -Id 1 -Procedure 'IsLargeOrder' -Operator 'REL' -Mutated 'Quantity > 10' -Status 'Killed')
        )
        (New-MutResultsDoc -Mutants $mutants | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ResultsPath -Encoding UTF8

        $expected = @(
            [pscustomobject]@{ procedure = 'IsLargeOrder'; operator = 'REL'; mutated = 'Quantity > 10'; expected = 'Survived' }
        )
        ($expected | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ExpectedPath -Encoding UTF8

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 1
        $mismatches[0].procedure | Should -Be 'IsLargeOrder'
        $mismatches[0].operator | Should -Be 'REL'
        $mismatches[0].expected | Should -Be 'Survived'
        $mismatches[0].actual | Should -Be 'Killed'
    }

    It 'tolerates an actual status of Killed when the expected status is Timeout' {
        $mutants = @(
            (New-MutResultRow -Id 21 -Procedure 'CountBatches' -Operator 'COND' -Original 'Remaining <= 0' -Mutated 'false' -Status 'Killed')
        )
        (New-MutResultsDoc -Mutants $mutants | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ResultsPath -Encoding UTF8

        $expected = @(
            [pscustomobject]@{ procedure = 'CountBatches'; operator = 'COND'; mutated = 'false'; expected = 'Timeout' }
        )
        ($expected | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ExpectedPath -Encoding UTF8

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 0
    }

    It 'does NOT tolerate an actual status of Survived when the expected status is Timeout (tolerance is Killed only)' {
        $mutants = @(
            (New-MutResultRow -Id 21 -Procedure 'CountBatches' -Operator 'COND' -Original 'Remaining <= 0' -Mutated 'false' -Status 'Survived')
        )
        (New-MutResultsDoc -Mutants $mutants | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ResultsPath -Encoding UTF8

        $expected = @(
            [pscustomobject]@{ procedure = 'CountBatches'; operator = 'COND'; mutated = 'false'; expected = 'Timeout' }
        )
        ($expected | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ExpectedPath -Encoding UTF8

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 1
        $mismatches[0].actual | Should -Be 'Survived'
    }

    It 'matches DEL entries on (procedure, operator, mutated="", original) and reports actual=$null when no mutant has that original' {
        $mutants = @(
            (New-MutResultRow -Id 4 -Procedure 'IsLargeOrder' -Operator 'DEL' -Original 'exit(true)' -Mutated '' -Status 'Killed')
        )
        (New-MutResultsDoc -Mutants $mutants | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ResultsPath -Encoding UTF8

        $expected = @(
            [pscustomobject]@{ procedure = 'IsLargeOrder'; operator = 'DEL'; mutated = ''; original = 'exit(true)'; expected = 'Killed' }
            [pscustomobject]@{ procedure = 'IsLargeOrder'; operator = 'DEL'; mutated = ''; original = 'exit(false)'; expected = 'Survived' }
        )
        ($expected | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ExpectedPath -Encoding UTF8

        $mismatches = Compare-MutExpectedResults -ResultsPath $script:ResultsPath -ExpectedPath $script:ExpectedPath

        @($mismatches).Count | Should -Be 1
        $mismatches[0].operator | Should -Be 'DEL'
        $mismatches[0].expected | Should -Be 'Survived'
        $mismatches[0].actual | Should -BeNullOrEmpty
    }

    It 'validates against the real fixtures/expected-results.json: 26 entries, matching key fields present' {
        $path = "$PSScriptRoot/../../fixtures/expected-results.json"
        Test-Path $path | Should -Be $true

        # ConvertFrom-Json on a JSON array already returns a single System.Object[]; wrapping the
        # pipeline itself in @(...) would collect that one array value into a further 1-element
        # outer array instead of flattening it (see the identical note in Schemata.psm1). Assign
        # first, then @()-wrap the already-materialized variable (a safe no-op for a real array,
        # and the correct 0/1-element safety net).
        $parsedEntries = Get-Content -Path $path -Raw | ConvertFrom-Json
        $entries = @($parsedEntries)
        $entries.Count | Should -Be 26

        foreach ($entry in $entries) {
            $entry.procedure | Should -Not -BeNullOrEmpty
            $entry.operator | Should -Not -BeNullOrEmpty
            $entry.expected | Should -Not -BeNullOrEmpty
            if ($entry.operator -eq 'DEL') {
                $entry.mutated | Should -Be ''
                $entry.original | Should -Not -BeNullOrEmpty
            }
        }

        $killed = @($entries | Where-Object { $_.expected -eq 'Killed' }).Count
        $survived = @($entries | Where-Object { $_.expected -eq 'Survived' }).Count
        $timeout = @($entries | Where-Object { $_.expected -eq 'Timeout' }).Count

        $killed | Should -Be 18
        $survived | Should -Be 5
        $timeout | Should -Be 3
    }

    It 'every expected-results.json entry matches exactly one mutant in the normative golden fixtures/generator/05-fixture-aut/expected/mutants.json' {
        $expectedPath = "$PSScriptRoot/../../fixtures/expected-results.json"
        $goldenMutantsPath = "$PSScriptRoot/../../fixtures/generator/05-fixture-aut/expected/mutants.json"
        Test-Path $goldenMutantsPath | Should -Be $true

        $parsedGoldenMutants = Get-Content -Path $goldenMutantsPath -Raw | ConvertFrom-Json
        $goldenMutants = @($parsedGoldenMutants)
        $goldenMutants.Count | Should -Be 26

        # The golden fixture has no 'status' field (it is mutants.json, not a §7.3 results
        # document); add a harmless placeholder status to every mutant so
        # Compare-MutExpectedResults' `.status` read under Set-StrictMode doesn't hit a
        # genuinely-missing property, while never equalling any real expected status string --
        # this test only proves every expected-results.json entry resolves to exactly one golden
        # mutant by key (actual comes back non-null), not that the statuses agree.
        $goldenMutantsWithStatus = $goldenMutants | ForEach-Object {
            $_ | Add-Member -NotePropertyName 'status' -NotePropertyValue 'Pending' -PassThru
        }

        $resultsDoc = [pscustomobject]@{ runNo = 0; mutants = $goldenMutantsWithStatus }
        $resultsPath = "$TestDrive/golden-mutants-as-results.json"
        ($resultsDoc | ConvertTo-Json -Depth 10) | Set-Content -Path $resultsPath -Encoding UTF8
        $mismatches = Compare-MutExpectedResults -ResultsPath $resultsPath -ExpectedPath $expectedPath
        foreach ($mismatch in $mismatches) {
            $mismatch.actual | Should -Not -BeNullOrEmpty -Because "expected-results.json entry '$($mismatch.procedure)/$($mismatch.operator)/$($mismatch.mutated)' must match a golden mutant by (procedure, operator, mutated[, original])"
        }
    }
}
