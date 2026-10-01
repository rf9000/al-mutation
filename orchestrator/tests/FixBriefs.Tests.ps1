<#
    .SYNOPSIS
    §6.7.2 stage 1: Get-MutOperatorHint's fixed texts and New-MutFixBriefs' per-survivor
    brief (line location with source drift, context window, covering-test lookup), plus
    Export-MutFixBriefs' file plumbing. Expected values are computed by hand from the spec.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/References.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/FixBriefs.psm1" -Force

    function script:New-FbMutant {
        param([int]$Id, [int]$Line, [string]$Original, [string]$File = 'A.Codeunit.al', [string]$Operator = 'REL')
        [pscustomobject]@{
            id = $Id; stableKey = "key$Id"; objectType = 'codeunit'; objectId = 50000; objectName = 'AUT One'
            procedure = 'Proc'; line = $Line; operator = $Operator; original = $Original; mutated = 'x'; file = $File
        }
    }

    function script:New-FbRow {
        param([int]$Id, [string]$Status, [int[]]$Covering = @(50300))
        [pscustomobject]@{ id = $Id; status = $Status; coveringTests = @($Covering) }
    }

    function script:New-FbIndex {
        @([pscustomobject]@{
                CodeunitId = 50300; CodeunitName = 'Test One'; File = 'Sub/T.Codeunit.al'
                Procedures = @([pscustomobject]@{ Name = 'Test_A'; StartLine = 10; EndLine = 20 })
            })
    }
}

Describe 'Get-MutOperatorHint' {
    It 'returns the exact §6.7.2 text for <Op>' -ForEach @(
        @{ Op = 'REL'; Text = 'A relational operator was changed. Kill it with a test whose input sits exactly on the boundary of the comparison (equal values, zero, empty string), and assert the outcome that differs between the original and the mutated operator.' }
        @{ Op = 'BOOL'; Text = 'and/or was swapped. Kill it with a test where exactly one of the operands is true, and assert the outcome that differs.' }
        @{ Op = 'NOT'; Text = 'A not was added or removed, so the branch inverts. Assert the observable effect of the branch for an input that takes it (returned value, record written, error raised).' }
        @{ Op = 'COND'; Text = 'The condition was forced to a constant. Add a test where the condition evaluates to the other value, and assert the effect of the branch it guards.' }
        @{ Op = 'DEL'; Text = 'A statement was deleted. Assert the effect of that statement: the field value it set, the record it inserted, modified or deleted, the error it raised, or the value it returned.' }
        @{ Op = 'INSFLAG'; Text = 'A flag argument was inverted (e.g. Insert(true) to Insert(false)). Assert the side effect the flag controls, such as trigger logic run by the call.' }
        @{ Op = 'BREAK'; Text = 'A break was inserted. Assert the result of loop iterations after the first one.' }
    ) {
        Get-MutOperatorHint -Operator $Op | Should -BeExactly $Text
    }

    It 'throws on an unknown operator' {
        { Get-MutOperatorHint -Operator 'ZZZ' } | Should -Throw "Unknown operator 'ZZZ'"
    }
}

Describe 'New-MutFixBriefs' {
    BeforeAll {
        $script:Aut = Join-Path $TestDrive 'aut'
        New-Item -ItemType Directory -Path $script:Aut -Force | Out-Null

        # 10 lines; line 3 and line 8 hold "alpha", line 5 holds the unique "beta".
        $lines = @('l1', 'l2', 'if alpha then', 'l4', 'if beta then', 'l6', 'l7', 'x := alpha;', 'l9', 'l10')
        Set-Content -Path (Join-Path $script:Aut 'A.Codeunit.al') -Value $lines -Encoding UTF8
    }

    It 'emits only Survived rows, sorted by id' {
        $mutants = @((New-FbMutant 7 3 'alpha'), (New-FbMutant 2 5 'beta'), (New-FbMutant 4 3 'alpha'))
        $results = [pscustomobject]@{ mutants = @((New-FbRow 7 'Survived'), (New-FbRow 4 'Killed'), (New-FbRow 9 'Timeout'), (New-FbRow 2 'Survived')) }

        $brief = New-MutFixBriefs -RunNo 3 -Mutants $mutants -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.runNo | Should -Be 3
        @($brief.survivors).Count | Should -Be 2
        @($brief.survivors | ForEach-Object { $_.mutantId }) | Should -Be @(2, 7)
        $brief.survivors[0].operatorHint | Should -Be (Get-MutOperatorHint -Operator 'REL')
        $brief.survivors[0].objectName | Should -Be 'AUT One'
        $brief.survivors[0].stableKey | Should -Be 'key2'
    }

    It 'keeps the line when it still holds the original (sourceDrift false)' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.survivors[0].resolvedLine | Should -Be 3
        $brief.survivors[0].sourceDrift | Should -Be $false
    }

    It 'resolves drift to the unique other line holding the original' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 9 'beta')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.survivors[0].line | Should -Be 9
        $brief.survivors[0].resolvedLine | Should -Be 5
        $brief.survivors[0].sourceDrift | Should -Be $true
        $brief.survivors[0].context.text | Should -Match '(?m)^>    5: if beta then$'
    }

    It 'leaves resolvedLine null when the original is gone (zero occurrences)' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 4 'gamma')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.survivors[0].resolvedLine | Should -BeNullOrEmpty
        $brief.survivors[0].sourceDrift | Should -Be $true
        # Context is centred on the recorded line (4) when nothing resolved.
        $brief.survivors[0].context.text | Should -Match '(?m)^>    4: l4$'
    }

    It 'leaves resolvedLine null when the original is ambiguous (two occurrences, line not one of them)' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 6 'alpha')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.survivors[0].resolvedLine | Should -BeNullOrEmpty
        $brief.survivors[0].sourceDrift | Should -Be $true
    }

    It 'gives a null context when the AUT file is missing' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha' 'Nope.al')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.survivors[0].context | Should -BeNullOrEmpty
        $brief.survivors[0].resolvedLine | Should -BeNullOrEmpty
        $brief.survivors[0].sourceDrift | Should -Be $true
    }

    It 'renders the exact context text and clips the window at the file start' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex) -ContextLines 4

        # c = 3, window max(1,-1)..min(10,7) = 1..7
        $brief.survivors[0].context.startLine | Should -Be 1
        $brief.survivors[0].context.endLine | Should -Be 7
        $brief.survivors[0].context.text | Should -BeExactly ("     1: l1`n     2: l2`n>    3: if alpha then`n     4: l4`n     5: if beta then`n     6: l6`n     7: l7")
    }

    It 'clips the window at the file end' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 8 'x := alpha')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex) -ContextLines 5

        # c = 8, window 3..10
        $brief.survivors[0].context.startLine | Should -Be 3
        $brief.survivors[0].context.endLine | Should -Be 10
        $brief.survivors[0].context.text | Should -Match '(?s)^     3: if alpha then.*>    8: x := alpha;.*    10: l10$'
    }

    It 'centres on min(line, lineCount) when the line is past the end and nothing resolves' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 99 'gone')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex) -ContextLines 2

        # c = min(99, 10) = 10, window 8..10
        $brief.survivors[0].resolvedLine | Should -BeNullOrEmpty
        $brief.survivors[0].sourceDrift | Should -Be $true
        $brief.survivors[0].context.startLine | Should -Be 8
        $brief.survivors[0].context.endLine | Should -Be 10
        $brief.survivors[0].context.text | Should -BeExactly ("     8: x := alpha;`n     9: l9`n>   10: l10")
    }

    It 'gives a null context for an empty AUT file' {
        Set-Content -Path (Join-Path $script:Aut 'Empty.al') -Value @() -Encoding ASCII
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha' 'Empty.al')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.survivors[0].context | Should -BeNullOrEmpty
        $brief.survivors[0].resolvedLine | Should -BeNullOrEmpty
        $brief.survivors[0].sourceDrift | Should -Be $true
    }

    It 'centres on min(line, lineCount) when the line is past the end and nothing resolves' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 99 'gone')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex) -ContextLines 2

        # c = min(99, 10) = 10, window 8..10
        $brief.survivors[0].resolvedLine | Should -BeNullOrEmpty
        $brief.survivors[0].sourceDrift | Should -Be $true
        $brief.survivors[0].context.startLine | Should -Be 8
        $brief.survivors[0].context.endLine | Should -Be 10
        $brief.survivors[0].context.text | Should -BeExactly ("     8: x := alpha;`n     9: l9`n>   10: l10")
    }

    It 'gives a null context for an empty AUT file' {
        Set-Content -Path (Join-Path $script:Aut 'Empty.al') -Value @() -Encoding ASCII
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha' 'Empty.al')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $brief.survivors[0].context | Should -BeNullOrEmpty
        $brief.survivors[0].resolvedLine | Should -BeNullOrEmpty
        $brief.survivors[0].sourceDrift | Should -Be $true
    }

    It 'maps covering tests through the index' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived')) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $ct = @($brief.survivors[0].coveringTests)
        $ct.Count | Should -Be 1
        $ct[0].codeunitId | Should -Be 50300
        $ct[0].codeunitName | Should -Be 'Test One'
        $ct[0].file | Should -Be 'Sub/T.Codeunit.al'
        $ct[0].procedures[0].name | Should -Be 'Test_A'
        $ct[0].procedures[0].startLine | Should -Be 10
        $ct[0].procedures[0].endLine | Should -Be 20
    }

    It 'keeps a covering codeunit missing from the index, with a warning' {
        Mock -ModuleName FixBriefs Write-Warning {}
        $results = [pscustomobject]@{ mutants = @((New-FbRow 1 'Survived' @(50300, 99999))) }
        $brief = New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex)

        $ct = @($brief.survivors[0].coveringTests)
        $ct.Count | Should -Be 2
        $ct[1].codeunitId | Should -Be 99999
        $ct[1].codeunitName | Should -BeNullOrEmpty
        $ct[1].file | Should -BeNullOrEmpty
        @($ct[1].procedures).Count | Should -Be 0
        Should -Invoke -ModuleName FixBriefs Write-Warning -Times 1
    }

    It 'throws when a survivor is missing from mutants.json' {
        $results = [pscustomobject]@{ mutants = @((New-FbRow 5 'Survived')) }
        { New-MutFixBriefs -RunNo 1 -Mutants @((New-FbMutant 1 3 'alpha')) -Results $results -AutPath $script:Aut -TestIndex (New-FbIndex) } |
            Should -Throw 'Survivor 5 missing from mutants.json'
    }
}

Describe 'Export-MutFixBriefs' {
    BeforeAll {
        $script:Repo = Join-Path $TestDrive 'repo'
        $work = Join-Path $script:Repo 'out'
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'results') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $work 'runs/4/gen') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $work 'aut-original') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $work 'test-app') -Force | Out-Null

        Set-Content -Path (Join-Path $work 'aut-original/A.Codeunit.al') -Value @('l1', 'if alpha then', 'l3') -Encoding UTF8
        Set-Content -Path (Join-Path $work 'test-app/T.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50300 "Test One"
{
    Subtype = Test;

    [Test]
    procedure Test_A()
    begin
    end;
}
'@
        # Two entries: a one-element JSON array hides the 5.1 array-as-one-object behaviour.
        $mutants = @((New-FbMutant 1 2 'alpha'), (New-FbMutant 2 3 'l3'))
        ConvertTo-Json -InputObject $mutants -Depth 10 | Set-Content -Path (Join-Path $work 'runs/4/gen/mutants.json') -Encoding UTF8
        $results = [pscustomobject]@{ runNo = 4; mutants = @((New-FbRow 1 'Survived')) }
        ConvertTo-Json -InputObject $results -Depth 10 | Set-Content -Path (Join-Path $script:Repo 'results/4.json') -Encoding UTF8

        $script:Cfg = [pscustomobject]@{
            workDir = $work
            aut     = [pscustomobject]@{ sourcePath = 'C:/src/aut' }
            testApp = [pscustomobject]@{ sourcePath = 'C:/src/test' }
        }
    }

    It 'writes results/<N>-fix-briefs.json with the §7.7 shape' {
        $path = Export-MutFixBriefs -RunNo 4 -Config $script:Cfg -RepoRoot $script:Repo

        $path | Should -Be (Join-Path $script:Repo 'results/4-fix-briefs.json')
        $json = Get-Content -Path $path -Raw | ConvertFrom-Json
        $json.runNo | Should -Be 4
        $json.autPath | Should -Be 'out/aut-original'
        $json.testAppPath | Should -Be 'out/test-app'
        $json.autSourcePath | Should -Be 'C:/src/aut'
        $json.testAppSourcePath | Should -Be 'C:/src/test'
        @($json.survivors).Count | Should -Be 1
        $json.survivors[0].resolvedLine | Should -Be 2
        $json.survivors[0].coveringTests[0].procedures[0].name | Should -Be 'Test_A'
        $json.survivors[0].coveringTests[0].procedures[0].startLine | Should -Be 5
    }

    It 'writes survivors: [] for a run with none' {
        $noSurv = [pscustomobject]@{ runNo = 4; mutants = @((New-FbRow 1 'Killed')) }
        ConvertTo-Json -InputObject $noSurv -Depth 10 | Set-Content -Path (Join-Path $script:Repo 'results/4.json') -Encoding UTF8

        $path = Export-MutFixBriefs -RunNo 4 -Config $script:Cfg -RepoRoot $script:Repo

        (Get-Content -Path $path -Raw) | Should -Match '"survivors":\s*\[\s*\]'
    }

    It 'throws naming the path when results/<N>.json is missing' {
        { Export-MutFixBriefs -RunNo 77 -Config $script:Cfg -RepoRoot $script:Repo } | Should -Throw '*77.json*'
    }

    It 'throws naming the path when mutants.json is missing' {
        Copy-Item -Path (Join-Path $script:Repo 'results/4.json') -Destination (Join-Path $script:Repo 'results/78.json')
        { Export-MutFixBriefs -RunNo 78 -Config $script:Cfg -RepoRoot $script:Repo } | Should -Throw '*mutants.json*'
    }
}

Describe 'Test-MutFixReport' {
    BeforeAll {
        function script:New-FxSurvivor {
            param([int]$Id, [int[]]$Covering)
            $tests = @()
            foreach ($c in $Covering) {
                $tests += @{ codeunitId = $c; codeunitName = "CU $c"; file = "T$c.Codeunit.al"; procedures = @() }
            }
            @{
                mutantId = $Id; file = 'Aut/A.Codeunit.al'; line = 10 + $Id; resolvedLine = 10 + $Id
                original = "orig$Id"; mutated = "mut$Id"; coveringTests = $tests
            }
        }

        function script:New-FxIndex {
            @(
                [pscustomobject]@{
                    CodeunitId = 50300; CodeunitName = 'CU 50300'; File = 'T50300.Codeunit.al'
                    Procedures = @(
                        [pscustomobject]@{ Name = 'Test_A'; StartLine = 10; EndLine = 20 }
                        [pscustomobject]@{ Name = 'Test_B'; StartLine = 30; EndLine = 40 })
                }
                [pscustomobject]@{
                    CodeunitId = 50301; CodeunitName = 'CU 50301'; File = 'T50301.Codeunit.al'
                    Procedures = @([pscustomobject]@{ Name = 'Test_C'; StartLine = 5; EndLine = 9 })
                }
            )
        }

        # Valid pair: add-assert covering two mutants, modify-test, new-test, equivalent.
        function script:New-FxPair {
            $brief = @{
                runNo = 15; testAppPath = 'out/test-app'
                survivors = @(
                    (New-FxSurvivor 1 @(50300)), (New-FxSurvivor 2 @(50300)), (New-FxSurvivor 3 @(50300)),
                    (New-FxSurvivor 4 @(50300, 50301)), (New-FxSurvivor 5 @(50300)))
            }
            $fixes = @{
                runNo = 15
                fixes = @(
                    @{ fixId = 'F001'; mutantIds = @(1, 2); verdict = 'fix'
                        target = @{ codeunitId = 50300; codeunitName = 'CU 50300'; file = 'T50300.Codeunit.al'; procedure = 'Test_A'; isNewProcedure = $false }
                        change = 'add-assert'; anchor = @{ afterLine = 15 }; alCode = '        Assert.IsTrue(true, 1);'
                        rationale = 'r'; expectedEffect = 'e'; confidence = 'high' }
                    @{ fixId = 'F002'; mutantIds = @(3); verdict = 'fix'
                        target = @{ codeunitId = 50300; codeunitName = 'CU 50300'; file = 'T50300.Codeunit.al'; procedure = 'Test_B'; isNewProcedure = $false }
                        change = 'modify-test'; anchor = $null; alCode = "    [Test]`n    procedure Test_B()`n    begin`n    end;"
                        rationale = 'r'; expectedEffect = 'e'; confidence = 'medium' }
                    @{ fixId = 'F003'; mutantIds = @(4); verdict = 'new-test'
                        target = @{ codeunitId = 50301; codeunitName = 'CU 50301'; file = 'T50301.Codeunit.al'; procedure = 'Test_New'; isNewProcedure = $true }
                        change = 'new-test'; anchor = $null; alCode = "    [Test]`n    procedure Test_New()`n    begin`n    end;"
                        rationale = 'r'; expectedEffect = 'e'; confidence = 'low' }
                    @{ fixId = 'F004'; mutantIds = @(5); verdict = 'equivalent'
                        target = $null; change = $null; anchor = $null; alCode = ''
                        rationale = 'Count() > 0 and Count() >= 1 are identical'; expectedEffect = $null; confidence = 'high' }
                )
            }
            @{ Brief = $brief; Fixes = $fixes }
        }

        function script:Invoke-FxCase {
            param([hashtable]$Pair)
            $b = Join-Path $TestDrive 'brief.json'
            $f = Join-Path $TestDrive 'fixes.json'
            ConvertTo-Json -InputObject $Pair.Brief -Depth 10 | Set-Content -Path $b -Encoding UTF8
            ConvertTo-Json -InputObject $Pair.Fixes -Depth 10 | Set-Content -Path $f -Encoding UTF8
            , @(Test-MutFixReport -BriefsPath $b -FixesPath $f -TestIndex (New-FxIndex))
        }

        function script:Get-FxMatch {
            param($Errors, [string]$Pattern)
            @(@($Errors) | Where-Object { $_ -like $Pattern }).Count
        }
    }

    It 'returns no errors for a valid pair (fix, modify, new-test, equivalent, one entry for two mutants)' {
        $errors = Invoke-FxCase (New-FxPair)
        $errors | Should -BeNullOrEmpty
    }

    It 'rule 1: reports a missing fixes file' {
        $b = Join-Path $TestDrive 'brief.json'
        ConvertTo-Json -InputObject (New-FxPair).Brief -Depth 10 | Set-Content -Path $b -Encoding UTF8
        $errors = @(Test-MutFixReport -BriefsPath $b -FixesPath (Join-Path $TestDrive 'nope.json') -TestIndex (New-FxIndex))
        $errors.Count | Should -Be 1
        $errors[0] | Should -BeLike 'report*'
    }

    It 'rule 1: reports unparseable JSON' {
        $b = Join-Path $TestDrive 'brief.json'
        $f = Join-Path $TestDrive 'bad.json'
        ConvertTo-Json -InputObject (New-FxPair).Brief -Depth 10 | Set-Content -Path $b -Encoding UTF8
        Set-Content -Path $f -Value '{ not json' -Encoding UTF8
        $errors = @(Test-MutFixReport -BriefsPath $b -FixesPath $f -TestIndex (New-FxIndex))
        $errors[0] | Should -BeLike 'report*'
    }

    It 'rule 1: reports a runNo that differs from the brief' {
        $p = New-FxPair; $p.Fixes.runNo = 16
        Get-FxMatch (Invoke-FxCase $p) 'report*runNo*' | Should -Be 1
    }

    It 'rule 1: reports a missing fixes array' {
        $p = New-FxPair; $p.Fixes.Remove('fixes')
        Get-FxMatch (Invoke-FxCase $p) 'report*fixes*' | Should -BeGreaterThan 0
    }

    It 'rule 2: reports a duplicate fixId' {
        $p = New-FxPair; $p.Fixes.fixes[1].fixId = 'F001'
        Get-FxMatch (Invoke-FxCase $p) 'F001*unique*' | Should -Be 1
    }

    It 'rule 2: reports a missing fixId under report' {
        $p = New-FxPair; $p.Fixes.fixes[1].Remove('fixId')
        Get-FxMatch (Invoke-FxCase $p) 'report*fixId*' | Should -Be 1
    }

    It 'rule 2: reports an invalid verdict' {
        $p = New-FxPair; $p.Fixes.fixes[3].verdict = 'maybe'
        Get-FxMatch (Invoke-FxCase $p) 'F004*verdict*' | Should -Be 1
    }

    It 'rule 2: reports an invalid confidence' {
        $p = New-FxPair; $p.Fixes.fixes[0].confidence = 'certain'
        Get-FxMatch (Invoke-FxCase $p) 'F001*confidence*' | Should -Be 1
    }

    It 'rule 2: reports an empty rationale' {
        $p = New-FxPair; $p.Fixes.fixes[0].rationale = ''
        Get-FxMatch (Invoke-FxCase $p) 'F001*rationale*' | Should -Be 1
    }

    It 'rule 2: reports an empty mutantIds' {
        $p = New-FxPair; $p.Fixes.fixes[3].mutantIds = @()
        Get-FxMatch (Invoke-FxCase $p) 'F004*mutantIds*' | Should -BeGreaterThan 0
    }

    It 'rule 3: reports a survivor that is in no entry' {
        $p = New-FxPair; $p.Fixes.fixes[0].mutantIds = @(1)
        Get-FxMatch (Invoke-FxCase $p) 'report*mutant 2*' | Should -Be 1
    }

    It 'rule 3: reports a survivor that is in two entries' {
        $p = New-FxPair; $p.Fixes.fixes[1].mutantIds = @(3, 1)
        Get-FxMatch (Invoke-FxCase $p) 'report*mutant 1*' | Should -Be 1
    }

    It 'rule 3: reports an id that is not a survivor' {
        $p = New-FxPair; $p.Fixes.fixes[3].mutantIds = @(5, 99)
        Get-FxMatch (Invoke-FxCase $p) 'F004*99*' | Should -Be 1
    }

    It 'rule 4: reports an equivalent entry with a target' {
        $p = New-FxPair
        $p.Fixes.fixes[3].target = @{ codeunitId = 50300; file = 'T50300.Codeunit.al'; procedure = 'Test_A'; isNewProcedure = $false }
        Get-FxMatch (Invoke-FxCase $p) 'F004*target*' | Should -Be 1
    }

    It 'rule 4: reports an equivalent entry with a change' {
        $p = New-FxPair; $p.Fixes.fixes[3].change = 'add-assert'
        Get-FxMatch (Invoke-FxCase $p) 'F004*change*' | Should -Be 1
    }

    It 'rule 4: reports an equivalent entry with an anchor' {
        $p = New-FxPair; $p.Fixes.fixes[3].anchor = @{ afterLine = 1 }
        Get-FxMatch (Invoke-FxCase $p) 'F004*anchor*' | Should -Be 1
    }

    It 'rule 4: reports an equivalent entry with alCode' {
        $p = New-FxPair; $p.Fixes.fixes[3].alCode = 'x'
        Get-FxMatch (Invoke-FxCase $p) 'F004*alCode*' | Should -Be 1
    }

    It 'rule 5: reports a fix change outside add-assert/modify-test' {
        $p = New-FxPair; $p.Fixes.fixes[0].change = 'new-test'
        Get-FxMatch (Invoke-FxCase $p) 'F001*change*' | Should -Be 1
    }

    It 'rule 5: reports isNewProcedure true on a fix' {
        $p = New-FxPair; $p.Fixes.fixes[0].target.isNewProcedure = $true
        Get-FxMatch (Invoke-FxCase $p) 'F001*isNewProcedure*' | Should -Be 1
    }

    It 'rule 5: reports a procedure that is not in the codeunit' {
        $p = New-FxPair; $p.Fixes.fixes[0].target.procedure = 'Test_Zzz'
        Get-FxMatch (Invoke-FxCase $p) 'F001*Test_Zzz*' | Should -Be 1
    }

    It 'rule 5: reports a file that differs from the index' {
        $p = New-FxPair; $p.Fixes.fixes[0].target.file = 'Other.al'
        Get-FxMatch (Invoke-FxCase $p) 'F001*file*' | Should -Be 1
    }

    It 'rule 5: reports an add-assert anchor outside the procedure' {
        $p = New-FxPair; $p.Fixes.fixes[0].anchor.afterLine = 25
        Get-FxMatch (Invoke-FxCase $p) 'F001*afterLine*' | Should -Be 1
    }

    It 'rule 5: reports an add-assert without an anchor' {
        $p = New-FxPair; $p.Fixes.fixes[0].anchor = $null
        Get-FxMatch (Invoke-FxCase $p) 'F001*anchor*' | Should -Be 1
    }

    It 'rule 5: reports a modify-test with an anchor' {
        $p = New-FxPair; $p.Fixes.fixes[1].anchor = @{ afterLine = 35 }
        Get-FxMatch (Invoke-FxCase $p) 'F002*anchor*' | Should -Be 1
    }

    It 'rule 5: reports empty alCode on a fix' {
        $p = New-FxPair; $p.Fixes.fixes[0].alCode = ''
        Get-FxMatch (Invoke-FxCase $p) 'F001*alCode*' | Should -Be 1
    }

    It 'rule 5: reports empty expectedEffect on a fix' {
        $p = New-FxPair; $p.Fixes.fixes[0].expectedEffect = ''
        Get-FxMatch (Invoke-FxCase $p) 'F001*expectedEffect*' | Should -Be 1
    }

    It 'rule 6: reports a new-test with change other than new-test' {
        $p = New-FxPair; $p.Fixes.fixes[2].change = 'add-assert'
        Get-FxMatch (Invoke-FxCase $p) 'F003*change*' | Should -Be 1
    }

    It 'rule 6: reports isNewProcedure false on a new-test' {
        $p = New-FxPair; $p.Fixes.fixes[2].target.isNewProcedure = $false
        Get-FxMatch (Invoke-FxCase $p) 'F003*isNewProcedure*' | Should -Be 1
    }

    It 'rule 6: reports a new procedure that already exists in the codeunit' {
        $p = New-FxPair
        $p.Fixes.fixes[2].target.procedure = 'Test_C'
        $p.Fixes.fixes[2].alCode = "    [Test]`n    procedure Test_C()`n    begin`n    end;"
        Get-FxMatch (Invoke-FxCase $p) 'F003*already*' | Should -Be 1
    }

    It 'rule 6: reports two new-tests with the same procedure in one codeunit' {
        $p = New-FxPair
        $p.Brief.survivors += (New-FxSurvivor 6 @(50301))
        $p.Fixes.fixes += @{ fixId = 'F005'; mutantIds = @(6); verdict = 'new-test'
            target = @{ codeunitId = 50301; codeunitName = 'CU 50301'; file = 'T50301.Codeunit.al'; procedure = 'test_new'; isNewProcedure = $true }
            change = 'new-test'; anchor = $null; alCode = "    [Test]`n    procedure test_new()`n    begin`n    end;"
            rationale = 'r'; expectedEffect = 'e'; confidence = 'low' }
        Get-FxMatch (Invoke-FxCase $p) 'F005*unique*' | Should -Be 1
    }

    It 'rule 6: reports a new-test with an anchor' {
        $p = New-FxPair; $p.Fixes.fixes[2].anchor = @{ afterLine = 6 }
        Get-FxMatch (Invoke-FxCase $p) 'F003*anchor*' | Should -Be 1
    }

    It 'rule 6: reports alCode without [Test]' {
        $p = New-FxPair; $p.Fixes.fixes[2].alCode = "    procedure Test_New()`n    begin`n    end;"
        Get-FxMatch (Invoke-FxCase $p) 'F003*`[Test`]*' | Should -Be 1
    }

    It 'rule 6: reports alCode that does not declare the target procedure' {
        $p = New-FxPair; $p.Fixes.fixes[2].alCode = "    [Test]`n    procedure Other()`n    begin`n    end;"
        Get-FxMatch (Invoke-FxCase $p) 'F003*procedure Test_New(*' | Should -Be 1
    }

    It 'rule 6: reports empty expectedEffect on a new-test' {
        $p = New-FxPair; $p.Fixes.fixes[2].expectedEffect = ''
        Get-FxMatch (Invoke-FxCase $p) 'F003*expectedEffect*' | Should -Be 1
    }

    It 'rule 7: reports a target codeunit that does not cover every mutant' {
        $p = New-FxPair
        $p.Brief.survivors[3].coveringTests = @(@{ codeunitId = 50300; codeunitName = 'CU 50300'; file = 'T50300.Codeunit.al'; procedures = @() })
        Get-FxMatch (Invoke-FxCase $p) 'F003*covering*' | Should -Be 1
    }

    It 'handles a single-element fixes array and survivors array' {
        $p = New-FxPair
        $p.Brief.survivors = @((New-FxSurvivor 5 @(50300)))
        $p.Fixes.fixes = @($p.Fixes.fixes[3])
        $errors = Invoke-FxCase $p
        $errors | Should -BeNullOrEmpty
    }

    It 'builds the index from the brief testAppPath when -TestIndex is omitted' {
        $repo = Join-Path $TestDrive 'repo'
        $app = Join-Path $repo 'out/test-app'
        New-Item -ItemType Directory -Path $app -Force | Out-Null
        $al = @('codeunit 50300 "CU 50300"', '{', '    Subtype = Test;', '', '    [Test]', '    procedure Test_A()', '    begin', '    end;', '}')
        Set-Content -Path (Join-Path $app 'T50300.Codeunit.al') -Value $al -Encoding UTF8
        $brief = @{ runNo = 1; testAppPath = 'out/test-app'; survivors = @((New-FxSurvivor 1 @(50300))) }
        $fixes = @{ runNo = 1; fixes = @(@{ fixId = 'F001'; mutantIds = @(1); verdict = 'fix'
                    target = @{ codeunitId = 50300; codeunitName = 'CU 50300'; file = 'T50300.Codeunit.al'; procedure = 'Test_A'; isNewProcedure = $false }
                    change = 'modify-test'; anchor = $null; alCode = 'x'; rationale = 'r'; expectedEffect = 'e'; confidence = 'high' }) }
        ConvertTo-Json -InputObject $brief -Depth 10 | Set-Content -Path (Join-Path $repo 'b.json') -Encoding UTF8
        ConvertTo-Json -InputObject $fixes -Depth 10 | Set-Content -Path (Join-Path $repo 'f.json') -Encoding UTF8

        $errors = @(Test-MutFixReport -BriefsPath (Join-Path $repo 'b.json') -FixesPath (Join-Path $repo 'f.json') -RepoRoot $repo)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Export-MutFixMarkdown' {
    BeforeAll {
        $p = New-FxPair
        $script:MdBrief = Join-Path $TestDrive 'md-brief.json'
        $script:MdFixes = Join-Path $TestDrive 'md-fixes.json'
        $script:MdOut = Join-Path $TestDrive 'out/15-fixes.md'
        ConvertTo-Json -InputObject $p.Brief -Depth 10 | Set-Content -Path $script:MdBrief -Encoding UTF8
        ConvertTo-Json -InputObject $p.Fixes -Depth 10 | Set-Content -Path $script:MdFixes -Encoding UTF8
        Export-MutFixMarkdown -BriefsPath $script:MdBrief -FixesPath $script:MdFixes -OutPath $script:MdOut
        $script:Md = Get-Content -Path $script:MdOut -Raw
    }

    It 'writes the header with run no, survivor count and per-verdict/confidence counts' {
        $script:Md | Should -Match '(?m)^# Fix suggestions for run 15?$'
        $script:Md | Should -Match '(?m)^- Survivors: 5?$'
        $script:Md | Should -Match '(?m)^- Fix entries: 4?$'
        $script:Md | Should -Match '(?m)^- Verdicts: fix 2, new-test 1, equivalent 1?$'
        $script:Md | Should -Match '(?m)^- Confidence: high 2, medium 1, low 1?$'
    }

    It 'orders sections by codeunit id with equivalent mutants last' {
        $a = $script:Md.IndexOf('## Test codeunit 50300')
        $b = $script:Md.IndexOf('## Test codeunit 50301')
        $e = $script:Md.IndexOf('## Equivalent mutants')
        $a | Should -BeGreaterThan -1
        $b | Should -BeGreaterThan $a
        $e | Should -BeGreaterThan $b
    }

    It 'orders entries by fix id within a section' {
        $script:Md.IndexOf('### F001') | Should -BeLessThan $script:Md.IndexOf('### F002')
        $script:Md.IndexOf('### F002') | Should -BeLessThan $script:Md.IndexOf('### F003')
        $script:Md.IndexOf('### F003') | Should -BeLessThan $script:Md.IndexOf('### F004')
    }

    It 'renders each entry field' {
        $script:Md | Should -Match '(?m)^  - 1: `orig1` -> `mut1` \(Aut/A\.Codeunit\.al:11\)?$'
        $script:Md | Should -Match '(?m)^  - 2: `orig2` -> `mut2` \(Aut/A\.Codeunit\.al:12\)?$'
        $script:Md | Should -Match '(?m)^- Verdict: fix?$'
        $script:Md | Should -Match '(?m)^- Change: add-assert?$'
        $script:Md | Should -Match '(?m)^- Target procedure: Test_A?$'
        $script:Md | Should -Match '(?m)^- Anchor: after line 15?$'
        $script:Md | Should -Match '(?m)^- Confidence: medium?$'
        $script:Md | Should -Match '(?m)^- Rationale: Count\(\) > 0 and Count\(\) >= 1 are identical?$'
        $script:Md | Should -Match '(?m)^- Expected effect: e?$'
    }

    It 'puts alCode inside an al fence' {
        $script:Md | Should -Match '(?s)```al\r?\n        Assert\.IsTrue\(true, 1\);\r?\n```'
        $script:Md | Should -Match '(?s)```al\r?\n    \[Test\]\r?\n    procedure Test_New\(\)'
    }

    It 'does not fence the empty alCode of an equivalent entry' {
        $tail = $script:Md.Substring($script:Md.IndexOf('## Equivalent mutants'))
        $tail | Should -Not -Match '```'
    }
}
