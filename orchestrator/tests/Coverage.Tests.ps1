Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/Coverage.psm1" -Force

    $script:SampleCsvPath = "$PSScriptRoot/../../fixtures/coverage/sample.csv"
    $script:SampleCsv = Get-Content -Path $script:SampleCsvPath -Raw
}

Describe 'ConvertFrom-MutCoverageCsv' {
    It 'parses fixtures/coverage/sample.csv (200 rows, no header)' {
        $rows = ConvertFrom-MutCoverageCsv -Csv $script:SampleCsv

        $rows.Count | Should -Be 200
    }

    It 'parses the first row as Codeunit/50000/Object/0/0' {
        $rows = ConvertFrom-MutCoverageCsv -Csv $script:SampleCsv

        $rows[0].ObjectType | Should -Be 'Codeunit'
        $rows[0].ObjectId | Should -Be 50000
        $rows[0].LineType | Should -Be 'Object'
        $rows[0].LineNo | Should -Be 0
        $rows[0].Hits | Should -Be 0
    }

    It 'includes a Code row with Hits 1' {
        $rows = ConvertFrom-MutCoverageCsv -Csv $script:SampleCsv

        $hit = $rows | Where-Object { $_.LineType -eq 'Code' -and $_.Hits -eq 1 } | Select-Object -First 1

        $hit | Should -Not -BeNullOrEmpty
        $hit.ObjectType | Should -Be 'Codeunit'
    }

    It 'produces ObjectId, LineNo and Hits as ints, not strings' {
        $rows = ConvertFrom-MutCoverageCsv -Csv '"Codeunit","50000","Code","12","1"'

        $rows[0].ObjectId | Should -BeOfType 'int'
        $rows[0].LineNo | Should -BeOfType 'int'
        $rows[0].Hits | Should -BeOfType 'int'
    }

    It 'throws when a row has 4 columns instead of 5' {
        { ConvertFrom-MutCoverageCsv -Csv '"Codeunit","50000","Code","12"' } | Should -Throw
    }

    It 'throws when a row has 6 columns instead of 5' {
        { ConvertFrom-MutCoverageCsv -Csv '"Codeunit","50000","Code","12","1","extra"' } | Should -Throw
    }

    It 'throws when ObjectType is not a recognized AL object type' {
        { ConvertFrom-MutCoverageCsv -Csv '"Frobnicator","50000","Code","12","1"' } | Should -Throw
    }

    It 'accepts ObjectType case-insensitively' {
        { ConvertFrom-MutCoverageCsv -Csv '"codeunit","50000","Code","12","1"' } | Should -Not -Throw
    }

    It 'skips blank lines' {
        $rows = ConvertFrom-MutCoverageCsv -Csv "`"Codeunit`",`"50000`",`"Code`",`"12`",`"1`"`r`n`r`n`"Codeunit`",`"50000`",`"Code`",`"13`",`"0`""

        $rows.Count | Should -Be 2
    }

    It 'returns a single-row result as an array, not an unwrapped scalar' {
        $rows = ConvertFrom-MutCoverageCsv -Csv '"Codeunit","50000","Code","12","1"'

        ($rows -is [array]) | Should -Be $true
        $rows.Count | Should -Be 1
    }
}

Describe 'Get-MutCoveringTests' {
    BeforeEach {
        $script:mutant = [pscustomobject]@{ objectId = 50000; line = 12 }
    }

    It 'prefers a coverage row with Hits > 0 over a references fallback' {
        $coverage = @{
            byTestCodeunit = @{
                '95155' = @(
                    [pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50000; LineType = 'Code'; LineNo = 12; Hits = 3 }
                )
            }
        }
        $references = @{ 50000 = @(99999) }

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155, 95913)

        $result | Should -Be @(95155)
    }

    It 'ignores a non-Code row with Hits > 0 at the mutant''s ObjectId/LineNo (falls back to references)' {
        $coverage = @{
            byTestCodeunit = @{
                '95155' = @(
                    [pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50000; LineType = 'Trigger/Function'; LineNo = 12; Hits = 5 }
                )
            }
        }
        $references = @{ 50000 = @(50301) }

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        $result | Should -Be @(50301)
    }

    It 'ignores a non-Code row with Hits > 0 and returns empty when references also has no match' {
        $coverage = @{
            byTestCodeunit = @{
                '95155' = @(
                    [pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50000; LineType = 'Empty'; LineNo = 12; Hits = 5 }
                )
            }
        }
        $references = @{}

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        @($result).Count | Should -Be 0
    }

    It 'still uses a Code row with Hits = 1 as covering (contrast case for the non-Code exclusion above)' {
        $coverage = @{
            byTestCodeunit = @{
                '95155' = @(
                    [pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50000; LineType = 'Trigger/Function'; LineNo = 12; Hits = 5 }
                    [pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50000; LineType = 'Code'; LineNo = 12; Hits = 1 }
                )
            }
        }
        $references = @{}

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        $result | Should -Be @(95155)
    }

    It 'ignores a coverage row for the right line but Hits = 0' {
        $coverage = @{
            byTestCodeunit = @{
                '95155' = @(
                    [pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50000; LineType = 'Code'; LineNo = 12; Hits = 0 }
                )
            }
        }
        $references = @{ 50000 = @(50301) }

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        $result | Should -Be @(50301)
    }

    It 'falls back to References[objectId] when no covering coverage row exists' {
        $coverage = @{ byTestCodeunit = @{} }
        $references = @{ 50000 = @(50301, 50302) }

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        $result | Should -Be @(50301, 50302)
    }

    It 'returns an empty array when neither coverage nor references match' {
        $coverage = @{ byTestCodeunit = @{} }
        $references = @{}

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        @($result).Count | Should -Be 0
    }

    It 'returns a single covering test id as an array, not an unwrapped scalar' {
        $coverage = @{
            byTestCodeunit = @{
                '95155' = @(
                    [pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50000; LineType = 'Code'; LineNo = 12; Hits = 1 }
                )
            }
        }
        $references = @{}

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        ($result -is [array]) | Should -Be $true
        $result.Count | Should -Be 1
        $result[0] | Should -Be 95155
    }

    It 'returns a single references fallback id as an array, not an unwrapped scalar' {
        $coverage = @{ byTestCodeunit = @{} }
        $references = @{ 50000 = @(50301) }

        $result = Get-MutCoveringTests -Mutant $script:mutant -Coverage $coverage -References $references -TestCodeunits @(95155)

        ($result -is [array]) | Should -Be $true
        $result.Count | Should -Be 1
    }
}
