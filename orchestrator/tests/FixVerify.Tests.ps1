<#
    .SYNOPSIS
    §6.8.1: Invoke-MutFixApply (apply suggested fixes to a test-app copy) and New-MutTestPatch
    (unified diff relative to the test-app root). Expected file texts are written by hand.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/References.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/FixVerify.psm1" -Force

    # Lines 1-16: A is 5-9, B is 11-15, the codeunit's closing brace is line 16.
    $script:BaseLines = @(
        'codeunit 50300 "T One"',
        '{',
        '    Subtype = Test;',
        '',
        '    [Test]',
        '    procedure A()',
        '    begin',
        '        X := 1;',
        '    end;',
        '',
        '    [Test]',
        '    procedure B()',
        '    begin',
        '        Y := 2;',
        '    end;',
        '}'
    )

    function script:Write-FvFile {
        param([string]$Path, [string[]]$Lines, [string]$Eol = "`n", [bool]$Bom = $false, [bool]$TrailingEol = $true)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $text = $Lines -join $Eol
        if ($TrailingEol) { $text += $Eol }
        [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($Bom)))
    }

    function script:Read-FvBytesText {
        # Raw text including a BOM char if present, so BOM presence is observable.
        param([string]$Path)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    function script:Read-FvLines {
        param([string]$Path)
        return , @([System.IO.File]::ReadAllText($Path) -split "`r?`n")
    }

    function script:New-FvFix {
        param([string]$Id, [string]$File = 'Sub/T.Codeunit.al', [string]$Procedure = 'A', [string]$Change = 'add-assert',
              $After = $null, [string]$Code = '', [string]$Verdict = 'fix')
        $anchor = $null
        if ($null -ne $After) { $anchor = [pscustomobject]@{ afterLine = $After } }
        [pscustomobject]@{
            fixId = $Id; mutantIds = @(1); verdict = $Verdict
            target = [pscustomobject]@{ codeunitId = 50300; codeunitName = 'T One'; file = $File; procedure = $Procedure; isNewProcedure = ($Change -eq 'new-test') }
            change = $Change; anchor = $anchor; alCode = $Code
        }
    }

    function script:New-FvApp {
        param([string]$Name, [string]$Eol = "`n", [bool]$Bom = $false)
        $root = Join-Path $TestDrive $Name
        Write-FvFile -Path (Join-Path $root 'Sub\T.Codeunit.al') -Lines $script:BaseLines -Eol $Eol -Bom $Bom
        return $root
    }
}

Describe 'Invoke-MutFixApply' {
    BeforeEach {
        $script:Src = New-FvApp -Name ("src" + [guid]::NewGuid().ToString('N'))
        $script:Dst = Join-Path $TestDrive ("dst" + [guid]::NewGuid().ToString('N'))
        $script:File = Join-Path $script:Dst 'Sub\T.Codeunit.al'
    }

    It 'inserts add-assert lines after the anchor line and reports the inserted range' {
        $fix = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Assert.IsTrue(true);'
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix))
        $expected = $script:BaseLines[0..7] + @('        Assert.IsTrue(true);') + $script:BaseLines[8..15]
        (Read-FvLines $script:File) | Should -Be (@($expected) + @(''))
        $r.Count | Should -Be 1
        $r[0].fixId | Should -Be 'F001'
        $r[0].file | Should -Be 'Sub/T.Codeunit.al'
        $r[0].insertedStartLine | Should -Be 9
        $r[0].insertedEndLine | Should -Be 9
    }

    It 'leaves the source untouched' {
        $before = Read-FvBytesText (Join-Path $script:Src 'Sub\T.Codeunit.al')
        $fix = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Z;'
        Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix) | Out-Null
        Read-FvBytesText (Join-Path $script:Src 'Sub\T.Codeunit.al') | Should -BeExactly $before
    }

    It 'modify-test replaces the whole procedure including its attribute lines' {
        $code = "    [Test]`n    [HandlerFunctions('H')]`n    procedure B()`n    begin`n        Y := 3;`n    end;"
        $fix = New-FvFix -Id 'F001' -Procedure 'B' -Change 'modify-test' -Code $code
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix))
        $expected = $script:BaseLines[0..9] + @('    [Test]', "    [HandlerFunctions('H')]", '    procedure B()', '    begin', '        Y := 3;', '    end;') + @('}')
        (Read-FvLines $script:File) | Should -Be (@($expected) + @(''))
        $r[0].insertedStartLine | Should -Be 11
        $r[0].insertedEndLine | Should -Be 16
    }

    It 'appends new-test procedures before the final brace, one blank line each, in fixId order' {
        $f2 = New-FvFix -Id 'F002' -Procedure 'D' -Change 'new-test' -Code "    [Test]`n    procedure D()"
        $f1 = New-FvFix -Id 'F001' -Procedure 'C' -Change 'new-test' -Code "    [Test]`n    procedure C()`n    begin`n    end;"
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($f2, $f1))
        $expected = $script:BaseLines[0..14] + @('', '    [Test]', '    procedure C()', '    begin', '    end;', '', '    [Test]', '    procedure D()', '}')
        (Read-FvLines $script:File) | Should -Be (@($expected) + @(''))
        $r.Count | Should -Be 2
        ($r | Where-Object fixId -eq 'F001').insertedStartLine | Should -Be 17
        ($r | Where-Object fixId -eq 'F001').insertedEndLine | Should -Be 20
        ($r | Where-Object fixId -eq 'F002').insertedStartLine | Should -Be 22
        ($r | Where-Object fixId -eq 'F002').insertedEndLine | Should -Be 23
    }

    It 'applies a mixed add-assert, modify-test and new-test in one file bottom-up with correct ranges' {
        $a = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Add1;'
        $m = New-FvFix -Id 'F002' -Procedure 'B' -Change 'modify-test' -Code "    [Test]`n    procedure B()`n    begin`n        Y := 9;`n        Y := 10;`n    end;"
        $n = New-FvFix -Id 'F003' -Procedure 'C' -Change 'new-test' -Code "    [Test]`n    procedure C()"
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($n, $m, $a))
        $expected = @(
            'codeunit 50300 "T One"', '{', '    Subtype = Test;', '', '    [Test]', '    procedure A()', '    begin',
            '        X := 1;', '        Add1;', '    end;', '',
            '    [Test]', '    procedure B()', '    begin', '        Y := 9;', '        Y := 10;', '    end;',
            '', '    [Test]', '    procedure C()', '}', '')
        (Read-FvLines $script:File) | Should -Be $expected
        $byId = @{}; foreach ($x in $r) { $byId[$x.fixId] = $x }
        $byId['F001'].insertedStartLine | Should -Be 9
        $byId['F001'].insertedEndLine | Should -Be 9
        $byId['F002'].insertedStartLine | Should -Be 12
        $byId['F002'].insertedEndLine | Should -Be 17
        $byId['F003'].insertedStartLine | Should -Be 19
        $byId['F003'].insertedEndLine | Should -Be 20
    }

    It 'orders two add-asserts on the same anchor by fixId regardless of input order' {
        $f2 = New-FvFix -Id 'F002' -Procedure 'A' -After 8 -Code '        Second;'
        $f1 = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        First;'
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($f2, $f1))
        $expected = $script:BaseLines[0..7] + @('        First;', '        Second;') + $script:BaseLines[8..15]
        (Read-FvLines $script:File) | Should -Be (@($expected) + @(''))
        ($r | Where-Object fixId -eq 'F001').insertedStartLine | Should -Be 9
        ($r | Where-Object fixId -eq 'F002').insertedStartLine | Should -Be 10
    }

    It 'handles two add-asserts at different anchors in one procedure' {
        $f1 = New-FvFix -Id 'F001' -Procedure 'A' -After 7 -Code '        Early;'
        $f2 = New-FvFix -Id 'F002' -Procedure 'A' -After 8 -Code '        Late;'
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($f1, $f2))
        $expected = $script:BaseLines[0..6] + @('        Early;') + @($script:BaseLines[7]) + @('        Late;') + $script:BaseLines[8..15]
        (Read-FvLines $script:File) | Should -Be (@($expected) + @(''))
        ($r | Where-Object fixId -eq 'F001').insertedStartLine | Should -Be 8
        ($r | Where-Object fixId -eq 'F002').insertedStartLine | Should -Be 10
    }

    It 'throws when a modify-test and an add-assert change the same procedure' {
        $m = New-FvFix -Id 'F001' -Procedure 'B' -Change 'modify-test' -Code '    x'
        $a = New-FvFix -Id 'F002' -Procedure 'B' -After 14 -Code '        y;'
        { Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($a, $m) } |
            Should -Throw "Fix F001 and F002 both change procedure 'B'"
    }

    It 'throws when two modify-test entries change the same procedure' {
        $m1 = New-FvFix -Id 'F001' -Procedure 'B' -Change 'modify-test' -Code '    x'
        $m2 = New-FvFix -Id 'F002' -Procedure 'B' -Change 'modify-test' -Code '    y'
        { Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($m1, $m2) } |
            Should -Throw "Fix F001 and F002 both change procedure 'B'"
    }

    It 'throws when the target procedure is not found' {
        $fix = New-FvFix -Id 'F007' -Procedure 'Nope' -After 8 -Code '        x;'
        { Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix) } |
            Should -Throw "Fix F007: procedure 'Nope' not found in Sub/T.Codeunit.al"
    }

    It 'throws when the target file is not a test codeunit of the app' {
        $fix = New-FvFix -Id 'F008' -File 'Sub/Missing.Codeunit.al' -Procedure 'A' -After 8 -Code '        x;'
        { Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix) } |
            Should -Throw "*Fix F008*Sub/Missing.Codeunit.al*"
    }

    It 'never applies equivalent entries' {
        $eq = [pscustomobject]@{ fixId = 'F001'; mutantIds = @(1); verdict = 'equivalent'; target = $null; change = $null; anchor = $null; alCode = '' }
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($eq))
        $r.Count | Should -Be 0
        Read-FvBytesText $script:File | Should -BeExactly (Read-FvBytesText (Join-Path $script:Src 'Sub\T.Codeunit.al'))
    }

    It 'keeps CRLF line endings' {
        $src = New-FvApp -Name 'srcCrlf' -Eol "`r`n"
        $fix = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Added;'
        Invoke-MutFixApply -SourcePath $src -DestinationPath $script:Dst -Fixes @($fix) | Out-Null
        $text = Read-FvBytesText $script:File
        $expected = (($script:BaseLines[0..7] + @('        Added;') + $script:BaseLines[8..15]) -join "`r`n") + "`r`n"
        $text | Should -BeExactly $expected
    }

    It 'keeps LF line endings' {
        $fix = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Added;'
        Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix) | Out-Null
        $text = Read-FvBytesText $script:File
        $text.Contains("`r") | Should -BeFalse
        $text | Should -BeExactly ((($script:BaseLines[0..7] + @('        Added;') + $script:BaseLines[8..15]) -join "`n") + "`n")
    }

    It 'keeps a BOM when the file has one' {
        $src = New-FvApp -Name 'srcBom' -Bom $true
        $fix = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Added;'
        Invoke-MutFixApply -SourcePath $src -DestinationPath $script:Dst -Fixes @($fix) | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($script:File)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
        $bytes[3] | Should -Be ([byte][char]'c')
    }

    It 'does not add a BOM when the file has none' {
        $fix = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Added;'
        Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix) | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($script:File)
        $bytes[0] | Should -Be ([byte][char]'c')
    }

    It 'normalises alCode that contains CRLF' {
        $fix = New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code "        L1;`r`n        L2;"
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($fix))
        $text = Read-FvBytesText $script:File
        $text.Contains("`r") | Should -BeFalse
        $text.Contains("        L1;`n        L2;`n") | Should -BeTrue
        $r[0].insertedEndLine - $r[0].insertedStartLine | Should -Be 1
    }

    It 'wipes the destination before copying' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Dst 'Old') | Out-Null
        Set-Content -Path (Join-Path $script:Dst 'Old\stale.txt') -Value 'stale'
        Set-Content -Path (Join-Path $script:Dst 'stale2.txt') -Value 'stale'
        Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @() | Out-Null
        Test-Path (Join-Path $script:Dst 'Old') | Should -BeFalse
        Test-Path (Join-Path $script:Dst 'stale2.txt') | Should -BeFalse
        Test-Path $script:File | Should -BeTrue
    }

    It 'groups entries by file and edits several files' {
        Write-FvFile -Path (Join-Path $script:Src 'Other\U.Codeunit.al') -Lines ($script:BaseLines -replace '50300', '50301')
        $f1 = New-FvFix -Id 'F001' -File 'Sub/T.Codeunit.al' -Procedure 'A' -After 8 -Code '        InT;'
        $f2 = New-FvFix -Id 'F002' -File 'Other/U.Codeunit.al' -Procedure 'A' -After 8 -Code '        InU;'
        $r = @(Invoke-MutFixApply -SourcePath $script:Src -DestinationPath $script:Dst -Fixes @($f1, $f2))
        $r.Count | Should -Be 2
        (Read-FvBytesText (Join-Path $script:Dst 'Sub\T.Codeunit.al')).Contains('InT;') | Should -BeTrue
        (Read-FvBytesText (Join-Path $script:Dst 'Sub\T.Codeunit.al')).Contains('InU;') | Should -BeFalse
        (Read-FvBytesText (Join-Path $script:Dst 'Other\U.Codeunit.al')).Contains('InU;') | Should -BeTrue
    }
}

Describe 'New-MutTestPatch' {
    BeforeEach {
        $id = [guid]::NewGuid().ToString('N')
        $script:Orig = New-FvApp -Name "orig$id"
        $script:Patched = Join-Path $TestDrive "patched$id"
        Copy-Item -Recurse -Path $script:Orig -Destination $script:Patched
        $script:Out = Join-Path $TestDrive "out$id\fix.patch"
    }

    It 'writes a diff with a/<file> and b/<file> paths relative to the app root' {
        Write-FvFile -Path (Join-Path $script:Patched 'Sub\T.Codeunit.al') -Lines ($script:BaseLines[0..7] + @('        Added;') + $script:BaseLines[8..15])
        New-MutTestPatch -OriginalPath $script:Orig -PatchedPath $script:Patched -OutPath $script:Out
        $text = [System.IO.File]::ReadAllText($script:Out)
        $text | Should -Match '(?m)^diff --git a/Sub/T\.Codeunit\.al b/Sub/T\.Codeunit\.al$'
        $text | Should -Match '(?m)^--- a/Sub/T\.Codeunit\.al$'
        $text | Should -Match '(?m)^\+\+\+ b/Sub/T\.Codeunit\.al$'
        $text | Should -Match '(?m)^\+        Added;$'
        $text | Should -Not -Match '[A-Za-z]:/'
        $text | Should -Not -Match 'orig'
    }

    It 'produces a patch that applies with git apply -p1 --check inside a copy of the original' {
        Write-FvFile -Path (Join-Path $script:Patched 'Sub\T.Codeunit.al') -Lines ($script:BaseLines[0..7] + @('        Added;') + $script:BaseLines[8..15])
        Write-FvFile -Path (Join-Path $script:Patched 'Sub\New.Codeunit.al') -Lines @('codeunit 50302 "N"', '{', '}')
        New-MutTestPatch -OriginalPath $script:Orig -PatchedPath $script:Patched -OutPath $script:Out
        $check = Join-Path $TestDrive ("check" + [guid]::NewGuid().ToString('N'))
        Copy-Item -Recurse -Path $script:Orig -Destination $check
        Push-Location $check
        try {
            & git apply -p1 --check $script:Out
            $LASTEXITCODE | Should -Be 0
        }
        finally { Pop-Location }
    }

    It 'applies a patch built for CRLF files' {
        $orig = New-FvApp -Name 'origCrlf' -Eol "`r`n"
        $patched = Join-Path $TestDrive 'patchedCrlf'
        Invoke-MutFixApply -SourcePath $orig -DestinationPath $patched -Fixes @(New-FvFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Added;') | Out-Null
        New-MutTestPatch -OriginalPath $orig -PatchedPath $patched -OutPath $script:Out
        $check = Join-Path $TestDrive 'checkCrlf'
        Copy-Item -Recurse -Path $orig -Destination $check
        Push-Location $check
        try {
            & git apply -p1 --check $script:Out
            $LASTEXITCODE | Should -Be 0
        }
        finally { Pop-Location }
    }

    It 'writes an empty file for an empty diff and does not treat that as an error' {
        { New-MutTestPatch -OriginalPath $script:Orig -PatchedPath $script:Patched -OutPath $script:Out } | Should -Not -Throw
        Test-Path $script:Out | Should -BeTrue
        (Get-Item $script:Out).Length | Should -Be 0
    }

    It 'treats git diff exit code 1 as success and creates the output folder' {
        Write-FvFile -Path (Join-Path $script:Patched 'Sub\T.Codeunit.al') -Lines @('changed')
        { New-MutTestPatch -OriginalPath $script:Orig -PatchedPath $script:Patched -OutPath $script:Out } | Should -Not -Throw
        (Get-Item $script:Out).Length | Should -BeGreaterThan 0
    }
}
