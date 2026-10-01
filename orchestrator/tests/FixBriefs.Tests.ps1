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
