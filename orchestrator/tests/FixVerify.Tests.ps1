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

Describe 'Invoke-MutFixVerify' {
    BeforeAll {
        # The backend functions Invoke-MutFixVerify calls are the real ones (so Mock sees their
        # signatures, including Start-MutEnvironment -RequireProbe); nothing below touches them.
        Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force
        Import-Module "$PSScriptRoot/../lib/FixVerify.psm1" -Force

        function script:New-VfFixesJson {
            param([string]$RepoRoot, $Fixes)
            $dir = Join-Path $RepoRoot 'results'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $doc = [pscustomobject]@{ runNo = 15; generatedUtc = '2026-10-01T00:00:00Z'; fixes = @($Fixes) }
            [System.IO.File]::WriteAllText((Join-Path $dir '15-fixes.json'), ($doc | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        }

        function script:New-VfFix {
            param([string]$Id, [string]$Procedure, [int]$After, [string]$Code, [int[]]$Mutants, [string]$Verdict = 'fix', $Revision = $null)
            $f = [ordered]@{
                fixId = $Id; mutantIds = @($Mutants); verdict = $Verdict
                target = [pscustomobject]@{ codeunitId = 50300; codeunitName = 'T One'; file = 'Sub/T.Codeunit.al'; procedure = $Procedure; isNewProcedure = $false }
                change = 'add-assert'; anchor = [pscustomobject]@{ afterLine = $After }; alCode = $Code
            }
            if ($null -ne $Revision) { $f['revision'] = $Revision }
            [pscustomobject]$f
        }
    }

    BeforeEach {
        $id = [guid]::NewGuid().ToString('N')
        $script:Repo = Join-Path $TestDrive "repo$id"
        $script:Work = Join-Path $TestDrive "work$id"
        New-Item -ItemType Directory -Force -Path $script:Repo | Out-Null
        # Original test app: A is 5-9, B is 11-15 (see $script:BaseLines).
        Write-FvFile -Path (Join-Path $script:Work 'test-app\Sub\T.Codeunit.al') -Lines $script:BaseLines -Eol "`r`n"
        $script:Cfg = [pscustomobject]@{
            environmentName = 'mut-test-01'
            workDir         = $script:Work
            rulesets        = [pscustomobject]@{ file = '.cli-ruleset.json' }
        }
        # F001 -> patched line 9 (mutants 10, 11); F002 -> patched line 16 (mutant 20); F003 equivalent.
        New-VfFixesJson -RepoRoot $script:Repo -Fixes @(
            (New-VfFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Assert.IsTrue(A);' -Mutants 10, 11),
            (New-VfFix -Id 'F002' -Procedure 'B' -After 14 -Code '        Assert.IsTrue(B);' -Mutants 20),
            (New-VfFix -Id 'F003' -Procedure 'A' -After 8 -Code '        Never.Applied;' -Mutants 30 -Verdict 'equivalent')
        )

        $global:FvLog = New-Object 'System.Collections.Generic.List[string]'
        $global:FvActive = 0
        $global:FvEnvStatus = 'Running'
        $global:FvPublish = { param($Path, $Call) [pscustomobject]@{ Success = $true; Code = $null; Diagnostics = @(); DurationSec = 1; ErrorMessage = $null } }
        # Default test behaviour: passes on the original, fails (kills) under any active mutant.
        $global:FvTests = {
            param($Function, $Active, $Call)
            if ($Active -eq 0) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 100; Error = $null }) }
            }
            return [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 120; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Fail'; DurationMs = 120; Error = "killed by $Active" }) }
        }
        $global:FvCalls = @{ Publish = 0; Tests = 0 }

        Mock -ModuleName FixVerify Get-MutEnvironment {
            $global:FvLog.Add('GETENV')
            [pscustomobject]@{ Id = 'E1'; Name = $Name; Status = $global:FvEnvStatus; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false; CliPath = 'cli' }
        }
        Mock -ModuleName FixVerify Start-MutEnvironment {
            $global:FvLog.Add('STARTENV')
            [pscustomobject]@{ Id = 'E1'; Name = 'mut-test-01'; Status = 'Running'; Url = 'https://x/E1'; Backend = 'DemoPortal'; Shared = $false; CliPath = 'cli' }
        }
        Mock -ModuleName FixVerify Invoke-MutApi {
            if ($Method -eq 'GET') { return [pscustomobject]@{ activeMutantId = $global:FvActive } }
            $global:FvActive = [int]$Body.activeMutantId
            $global:FvLog.Add("PATCH:$($Body.activeMutantId)")
            return $null
        }
        Mock -ModuleName FixVerify Publish-MutApp {
            $global:FvCalls.Publish++
            $global:FvLog.Add("PUB:$Path")
            if ($Ruleset) { $global:FvLog.Add("PUBRULESET:$Ruleset") }
            if ($AllowDowngrade) { $global:FvLog.Add('PUBDOWNGRADE') }
            & $global:FvPublish $Path $global:FvCalls.Publish
        }
        Mock -ModuleName FixVerify Invoke-MutTests {
            $global:FvCalls.Tests++
            $t = @($Targets)[0]
            $global:FvLog.Add("TEST:$($t.CodeunitId)/$($t.Function)@$($global:FvActive)")
            & $global:FvTests $t.Function $global:FvActive $global:FvCalls.Tests
        }
        Mock -ModuleName FixVerify Stop-MutFixRunawaySessions { $global:FvLog.Add('STOPSESSIONS') }
        Mock -ModuleName FixVerify Start-Sleep { }
    }

    AfterAll {
        foreach ($n in 'FvLog', 'FvActive', 'FvEnvStatus', 'FvPublish', 'FvTests', 'FvCalls') {
            Remove-Variable -Name $n -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'verifies entries whose test passes on the original and is killed under every mutant' {
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $r.runNo | Should -Be 15
        $r.verifyRunNo | Should -Be 9015
        $r.environmentName | Should -Be 'mut-test-01'
        @($r.entries).Count | Should -Be 3
        @($r.entries | ForEach-Object { $_.fixId }) | Should -Be @('F001', 'F002', 'F003')
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'verified'
        $f1.revision | Should -Be 0
        $f1.compile.ok | Should -BeTrue
        @($f1.compile.diagnostics).Count | Should -Be 0
        $f1.original.result | Should -Be 'Pass'
        $f1.original.durationMs | Should -Be 100
        @($f1.mutants).Count | Should -Be 2
        @($f1.mutants | ForEach-Object { $_.mutantId }) | Should -Be @(10, 11)
        @($f1.mutants | ForEach-Object { $_.outcome }) | Should -Be @('killed', 'killed')
        $f1.mutants[0].error | Should -Be 'killed by 10'
        $f1.verifiedUtc | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        ($r.entries | Where-Object fixId -eq 'F002').verdict | Should -Be 'verified'
        @($r.unmappedDiagnostics).Count | Should -Be 0
    }

    It 'writes results/<N>-verified.json with the same content' {
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $path = Join-Path $script:Repo 'results/15-verified.json'
        Test-Path $path | Should -BeTrue
        $disk = Get-Content -Raw -Path $path | ConvertFrom-Json
        $disk.runNo | Should -Be 15
        $disk.verifyRunNo | Should -Be 9015
        @($disk.entries).Count | Should -Be 3
        (Get-Content -Raw -Path $path) | Should -Match '"mutants":\s*\[\s*\]'
    }

    It 'never applies an equivalent entry and gives it skipped-equivalent with null stages' {
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f3 = $r.entries | Where-Object fixId -eq 'F003'
        $f3.verdict | Should -Be 'skipped-equivalent'
        $f3.original | Should -BeNullOrEmpty
        @($f3.mutants).Count | Should -Be 0
        (Get-Content -Raw (Join-Path $script:Work 'fix-verify\15\test-app\Sub\T.Codeunit.al')) | Should -Not -Match 'Never.Applied'
        $global:FvLog | Where-Object { $_ -like 'TEST:*' } | Should -Not -Contain 'TEST:50300/A@30'
        ($global:FvLog | Where-Object { $_ -eq 'PATCH:30' }) | Should -BeNullOrEmpty
    }

    It 'applies into <workDir>/fix-verify/<N>/test-app and publishes it with the ruleset and AllowDowngrade' {
        Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo | Out-Null
        $patched = Join-Path $script:Work 'fix-verify\15\test-app'
        $global:FvLog | Should -Contain "PUB:$patched"
        $global:FvLog | Should -Contain ("PUBRULESET:" + (Join-Path (Join-Path $script:Work 'rulesets') '.cli-ruleset.json'))
        $global:FvLog | Should -Contain 'PUBDOWNGRADE'
        (Get-Content -Raw (Join-Path $patched 'Sub\T.Codeunit.al')) | Should -Match 'Assert.IsTrue\(A\)'
        # The source test app stays unpatched.
        (Get-Content -Raw (Join-Path $script:Work 'test-app\Sub\T.Codeunit.al')) | Should -Not -Match 'Assert.IsTrue'
    }

    It 'starts a Stopped environment and does not start a Running one' {
        $global:FvEnvStatus = 'Stopped'
        Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo | Out-Null
        $global:FvLog | Should -Contain 'STARTENV'
        $global:FvLog.Clear()
        $global:FvEnvStatus = 'Running'
        Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo | Out-Null
        $global:FvLog | Should -Not -Contain 'STARTENV'
    }

    It 'throws when the environment does not exist' {
        Mock -ModuleName FixVerify Get-MutEnvironment { $null }
        { Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo } | Should -Throw '*not found*'
    }

    It 'resets a non-zero activeMutantId before publishing' {
        $global:FvActive = 77
        Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo | Out-Null
        $global:FvLog.IndexOf('PATCH:0') | Should -BeLessThan ($global:FvLog.FindIndex({ param($x) $x -like 'PUB:*' }))
    }

    It 'maps a compile failure to one entry, marks it compile-failed, republishes the rest and verifies them' {
        # F001 is inserted at patched line 9; the first publish fails there.
        $global:FvPublish = {
            param($Path, $Call)
            if ($Call -eq 1) {
                return [pscustomobject]@{ Success = $false; Code = 'compile-failed'; DurationSec = 1; ErrorMessage = 'compile failed'
                    Diagnostics = @([pscustomobject]@{ Severity = 'error'; Code = 'AL0118'; File = 'C:\x\Sub\T.Codeunit.al'; Line = 9; Column = 1; Message = "The name 'A' does not exist" }) }
            }
            [pscustomobject]@{ Success = $true; Code = $null; Diagnostics = @(); DurationSec = 1; ErrorMessage = $null }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'compile-failed'
        $f1.compile.ok | Should -BeFalse
        @($f1.compile.diagnostics).Count | Should -Be 1
        $f1.compile.diagnostics[0] | Should -BeLike '*AL0118*'
        $f1.original | Should -BeNullOrEmpty
        @($f1.mutants).Count | Should -Be 0
        $f2 = $r.entries | Where-Object fixId -eq 'F002'
        $f2.verdict | Should -Be 'verified'
        # Second round started from scratch: the patched copy has no F001 any more.
        (Get-Content -Raw (Join-Path $script:Work 'fix-verify\15\test-app\Sub\T.Codeunit.al')) | Should -Not -Match 'Assert.IsTrue\(A\)'
        ($global:FvLog | Where-Object { $_ -like 'TEST:50300/A@*' }) | Should -BeNullOrEmpty
    }

    It 'records an unmapped diagnostic next to a mapped one under unmappedDiagnostics' {
        $global:FvPublish = {
            param($Path, $Call)
            if ($Call -eq 1) {
                return [pscustomobject]@{ Success = $false; Code = 'compile-failed'; DurationSec = 1; ErrorMessage = 'compile failed'
                    Diagnostics = @(
                        [pscustomobject]@{ Severity = 'error'; Code = 'AL0118'; File = 'Sub/T.Codeunit.al'; Line = 9; Column = 1; Message = 'mapped' },
                        [pscustomobject]@{ Severity = 'error'; Code = 'AL0999'; File = 'Other.al'; Line = 3; Column = 1; Message = 'elsewhere' }) }
            }
            [pscustomobject]@{ Success = $true; Code = $null; Diagnostics = @(); DurationSec = 1; ErrorMessage = $null }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        @($r.unmappedDiagnostics).Count | Should -Be 1
        $r.unmappedDiagnostics[0] | Should -BeLike '*AL0999*'
        ($r.entries | Where-Object fixId -eq 'F002').verdict | Should -Be 'verified'
    }

    It 'marks every remaining entry compile-failed when a failure maps to no entry, then restores' {
        $global:FvPublish = {
            param($Path, $Call)
            if ($Path -like '*fix-verify*') {
                return [pscustomobject]@{ Success = $false; Code = 'compile-failed'; DurationSec = 1; ErrorMessage = 'dependency problem'
                    Diagnostics = @([pscustomobject]@{ Severity = 'error'; Code = 'AL0999'; File = 'Other.al'; Line = 3; Column = 1; Message = 'elsewhere' }) }
            }
            [pscustomobject]@{ Success = $true; Code = $null; Diagnostics = @(); DurationSec = 1; ErrorMessage = $null }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        foreach ($fid in 'F001', 'F002') {
            $e = $r.entries | Where-Object fixId -eq $fid
            $e.verdict | Should -Be 'compile-failed'
            ($e.compile.diagnostics -join ' ') | Should -BeLike '*dependency problem*'
        }
        @($r.unmappedDiagnostics).Count | Should -Be 1
        # One failed publish of the patched copy plus the restore; no test job ran.
        $global:FvCalls.Tests | Should -Be 0
        $global:FvLog[$global:FvLog.Count - 1] -like 'PATCH:*' | Should -BeFalse
        ($global:FvLog | Where-Object { $_ -like 'PUB:*' } | Select-Object -Last 1) | Should -Be ("PUB:" + (Join-Path $script:Work 'test-app'))
    }

    It 'stops after 3 publish rounds when diagnostics keep mapping to new entries' {
        $fixes = @()
        foreach ($n in 1..4) {
            $fixes += New-VfFix -Id ("F10$n") -Procedure 'A' -After 8 -Code "        Line$n;" -Mutants (40 + $n)
        }
        New-VfFixesJson -RepoRoot $script:Repo -Fixes $fixes
        # Same-anchor add-asserts go in fixId order: F101 line 9, F102 line 10, F103 line 11, F104 line 12.
        $global:FvPublish = {
            param($Path, $Call)
            if ($Path -like '*fix-verify*') {
                $line = 8 + $Call
                return [pscustomobject]@{ Success = $false; Code = 'compile-failed'; DurationSec = 1; ErrorMessage = 'x'
                    Diagnostics = @([pscustomobject]@{ Severity = 'error'; Code = 'AL1'; File = 'Sub/T.Codeunit.al'; Line = $line; Column = 1; Message = "round $Call" }) }
            }
            [pscustomobject]@{ Success = $true; Code = $null; Diagnostics = @(); DurationSec = 1; ErrorMessage = $null }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        (@($global:FvLog | Where-Object { $_ -like 'PUB:*fix-verify*' })).Count | Should -Be 3
        foreach ($e in $r.entries) { $e.verdict | Should -Be 'compile-failed' }
    }

    It 'marks an entry whose procedure is not found compile-failed and goes on with the others' {
        New-VfFixesJson -RepoRoot $script:Repo -Fixes @(
            (New-VfFix -Id 'F001' -Procedure 'Missing' -After 8 -Code '        X;' -Mutants 10),
            (New-VfFix -Id 'F002' -Procedure 'B' -After 14 -Code '        Assert.IsTrue(B);' -Mutants 20)
        )
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'compile-failed'
        ($f1.compile.diagnostics -join ' ') | Should -BeLike "*procedure 'Missing' not found*"
        ($r.entries | Where-Object fixId -eq 'F002').verdict | Should -Be 'verified'
    }

    It 'gives fails-on-original with the error text and never activates its mutants' {
        $global:FvTests = {
            param($Function, $Active, $Call)
            if ($Function -eq 'A' -and $Active -eq 0) {
                return [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 90; JobIds = @(); Tests = @([pscustomobject]@{ Function = 'A'; Result = 'Fail'; DurationMs = 90; Error = 'CTS-CB Bank Information permission error' }) }
            }
            if ($Active -eq 0) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 100; Error = $null }) }
            }
            [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 120; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Fail'; DurationMs = 120; Error = 'k' }) }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'fails-on-original'
        $f1.compile.ok | Should -BeTrue
        $f1.original.result | Should -Be 'Fail'
        $f1.original.error | Should -BeLike '*permission error*'
        @($f1.mutants).Count | Should -Be 0
        ($global:FvLog | Where-Object { $_ -eq 'PATCH:10' -or $_ -eq 'PATCH:11' }) | Should -BeNullOrEmpty
        ($r.entries | Where-Object fixId -eq 'F002').verdict | Should -Be 'verified'
    }

    It 'gives not-killed with the per-mutant list when a mutant survives' {
        $global:FvTests = {
            param($Function, $Active, $Call)
            if ($Active -eq 11) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 80; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 80; Error = $null }) }
            }
            if ($Active -eq 0) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 100; Error = $null }) }
            }
            [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 120; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Fail'; DurationMs = 120; Error = "killed by $Active" }) }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'not-killed'
        @($f1.mutants | ForEach-Object { $_.outcome }) | Should -Be @('killed', 'survived')
        $f1.mutants[1].error | Should -BeNullOrEmpty
    }

    It 'counts a client timeout as killed' {
        $global:FvTests = {
            param($Function, $Active, $Call)
            if ($Active -eq 10) { throw 'continia timed out after 180 s: continia test run' }
            if ($Active -eq 0) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 100; Error = $null }) }
            }
            [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 120; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Fail'; DurationMs = 120; Error = 'k' }) }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'verified'
        $f1.mutants[0].outcome | Should -Be 'timeout'
        $f1.mutants[0].error | Should -BeLike '*timed out*'
        $global:FvLog | Should -Contain 'STOPSESSIONS'
        # A timeout is a verdict, not an outage: the job is not re-run.
        (@($global:FvLog | Where-Object { $_ -eq 'TEST:50300/A@10' })).Count | Should -Be 1
    }

    It 'PATCHes activeMutantId 0 after every mutant even when Invoke-MutTests throws, and ends env-error' {
        $global:FvTests = {
            param($Function, $Active, $Call)
            if ($Function -eq 'A' -and $Active -ne 0) { throw '(503) Server Unavailable' }
            if ($Active -eq 0) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 100; Error = $null }) }
            }
            [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 120; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Fail'; DurationMs = 120; Error = 'k' }) }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'env-error'
        # Mutant 10: 3 attempts (1 + 2 retries), each followed by a PATCH 0 straight after the job.
        $log = @($global:FvLog)
        $testIdx = @(0..($log.Count - 1) | Where-Object { $log[$_] -eq 'TEST:50300/A@10' })
        $testIdx.Count | Should -Be 3
        foreach ($i in $testIdx) { $log[$i + 1] | Should -Be 'PATCH:0' }
        # The remaining mutant is not run; the next entry still is.
        (@($f1.mutants | ForEach-Object { $_.outcome })) | Should -Be @('not-run', 'not-run')
        ($f1.mutants[0].error) | Should -BeLike '*503*'
        ($r.entries | Where-Object fixId -eq 'F002').verdict | Should -Be 'verified'
        $global:FvActive | Should -Be 0
    }

    It 'retries the same job after an outage and keeps the retry result' {
        $script:Fail503Once = $true
        $global:FvTests = {
            param($Function, $Active, $Call)
            if ($Function -eq 'B' -and $Active -eq 0 -and -not $global:FvBlipDone) { $global:FvBlipDone = $true; throw '(503) Server Unavailable' }
            if ($Active -eq 0) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 100; Error = $null }) }
            }
            [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 120; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Fail'; DurationMs = 120; Error = 'k' }) }
        }
        $global:FvBlipDone = $false
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        Remove-Variable -Name FvBlipDone -Scope Global -ErrorAction SilentlyContinue
        ($r.entries | Where-Object fixId -eq 'F002').verdict | Should -Be 'verified'
        (@($global:FvLog | Where-Object { $_ -eq 'TEST:50300/B@0' })).Count | Should -Be 2
        # Recovery waited for the environment (readiness check) between the attempts.
        $global:FvLog | Should -Contain 'STARTENV'
    }

    It 'treats an empty test result like an outage and ends env-error after 2 retries' {
        $global:FvTests = {
            param($Function, $Active, $Call)
            if ($Function -eq 'A' -and $Active -eq 0) { return [pscustomobject]@{ Passed = 0; Failed = 0; DurationMs = 0; JobIds = @(); Tests = @() } }
            if ($Active -eq 0) {
                return [pscustomobject]@{ Passed = 1; Failed = 0; DurationMs = 100; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Pass'; DurationMs = 100; Error = $null }) }
            }
            [pscustomobject]@{ Passed = 0; Failed = 1; DurationMs = 120; JobIds = @(); Tests = @([pscustomobject]@{ Function = $Function; Result = 'Fail'; DurationMs = 120; Error = 'k' }) }
        }
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $f1 = $r.entries | Where-Object fixId -eq 'F001'
        $f1.verdict | Should -Be 'env-error'
        $f1.original.result | Should -BeNullOrEmpty
        $f1.original.error | Should -BeLike '*empty result*'
        (@($global:FvLog | Where-Object { $_ -eq 'TEST:50300/A@0' })).Count | Should -Be 3
        ($r.entries | Where-Object fixId -eq 'F002').verdict | Should -Be 'verified'
    }

    It 'republishes <workDir>/test-app last and confirms activeMutantId 0' {
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        $pubs = @($global:FvLog | Where-Object { $_ -like 'PUB:*' })
        $pubs[$pubs.Count - 1] | Should -Be ("PUB:" + (Join-Path $script:Work 'test-app'))
        $global:FvActive | Should -Be 0
        $log = @($global:FvLog)
        $lastPub = [array]::LastIndexOf($log, $pubs[$pubs.Count - 1])
        $lastPub | Should -BeGreaterThan ([array]::LastIndexOf($log, 'TEST:50300/B@20'))
    }

    It 'restores even when a test job throws something unexpected' {
        Mock -ModuleName FixVerify Invoke-MutTests { throw 'boom' }
        # Three failing attempts per job end as env-error; the run still completes and restores.
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        ($r.entries | Where-Object fixId -eq 'F001').verdict | Should -Be 'env-error'
        $pubs = @($global:FvLog | Where-Object { $_ -like 'PUB:*' })
        $pubs[$pubs.Count - 1] | Should -Be ("PUB:" + (Join-Path $script:Work 'test-app'))
    }

    It 'writes verified.json first and then throws when the restore fails' {
        $global:FvPublish = {
            param($Path, $Call)
            if ($Path -like '*fix-verify*') { return [pscustomobject]@{ Success = $true; Code = $null; Diagnostics = @(); DurationSec = 1; ErrorMessage = $null } }
            [pscustomobject]@{ Success = $false; Code = 'publish-failed'; Diagnostics = @(); DurationSec = 1; ErrorMessage = 'restore broke' }
        }
        { Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo } | Should -Throw '*restore*'
        $path = Join-Path $script:Repo 'results/15-verified.json'
        Test-Path $path | Should -BeTrue
        $disk = Get-Content -Raw -Path $path | ConvertFrom-Json
        (@($disk.entries | Where-Object fixId -eq 'F001')).verdict | Should -Be 'verified'
    }

    It 'with -FixIds verifies only those entries and merges into an existing verified.json' {
        $existing = [ordered]@{
            runNo = 15; verifyRunNo = 9015; updatedUtc = '2026-10-01T10:00:00Z'; environmentName = 'mut-test-01'
            entries = @(
                [ordered]@{ fixId = 'F001'; revision = 0; verdict = 'compile-failed'; verifiedUtc = '2026-10-01T09:00:00Z'; compile = [ordered]@{ ok = $false; diagnostics = @('old') }; original = $null; mutants = @() },
                [ordered]@{ fixId = 'F009'; revision = 2; verdict = 'verified'; verifiedUtc = '2026-10-01T09:30:00Z'; compile = [ordered]@{ ok = $true; diagnostics = @() }
                    original = [ordered]@{ result = 'Pass'; error = $null; durationMs = 5 }
                    mutants = @([ordered]@{ mutantId = 7; outcome = 'killed'; error = 'e'; durationMs = 6 }) })
            unmappedDiagnostics = @()
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Repo 'results') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:Repo 'results/15-verified.json'), ($existing | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -FixIds 'F001' -RepoRoot $script:Repo
        @($r.entries | ForEach-Object { $_.fixId }) | Should -Be @('F001', 'F009')
        ($r.entries | Where-Object fixId -eq 'F001').verdict | Should -Be 'verified'
        $f9 = $r.entries | Where-Object fixId -eq 'F009'
        $f9.revision | Should -Be 2
        $f9.verifiedUtc | Should -Be '2026-10-01T09:30:00Z'
        $f9.mutants[0].mutantId | Should -Be 7
        @($f9.mutants).Count | Should -Be 1
        # F002 was not selected: not applied, not tested.
        ($global:FvLog | Where-Object { $_ -like 'TEST:50300/B@*' }) | Should -BeNullOrEmpty
        # The file on disk matches, with the old entry's timestamp still an ISO string.
        (Get-Content -Raw (Join-Path $script:Repo 'results/15-verified.json')) | Should -Match '"verifiedUtc":\s*"2026-10-01T09:30:00Z"'
    }

    It 'throws for a -FixIds entry that is not in the fixes report' {
        { Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -FixIds 'F999' -RepoRoot $script:Repo } | Should -Throw '*F999*'
    }

    It 'copies the revision of the fix into its entry' {
        New-VfFixesJson -RepoRoot $script:Repo -Fixes @(
            (New-VfFix -Id 'F001' -Procedure 'A' -After 8 -Code '        Assert.IsTrue(A);' -Mutants 10 -Revision 3),
            (New-VfFix -Id 'F002' -Procedure 'B' -After 14 -Code '        Assert.IsTrue(B);' -Mutants 20)
        )
        $r = Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo
        ($r.entries | Where-Object fixId -eq 'F001').revision | Should -Be 3
        ($r.entries | Where-Object fixId -eq 'F002').revision | Should -Be 0
    }

    It 'activates mutants with currentRunNo 9000 + RunNo' {
        $script:Bodies = @()
        Mock -ModuleName FixVerify Invoke-MutApi {
            if ($Method -eq 'GET') { return [pscustomobject]@{ activeMutantId = $global:FvActive } }
            $global:FvActive = [int]$Body.activeMutantId
            if ($Body.activeMutantId -ne 0) { $global:FvLog.Add("ACT:$($Body.activeMutantId):$($Body.currentRunNo)") }
            return $null
        }
        Invoke-MutFixVerify -Config $script:Cfg -RunNo 15 -RepoRoot $script:Repo | Out-Null
        $global:FvLog | Should -Contain 'ACT:10:9015'
        $global:FvLog | Should -Contain 'ACT:20:9015'
    }
}
