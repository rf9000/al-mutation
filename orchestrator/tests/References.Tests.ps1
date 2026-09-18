Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/References.psm1" -Force

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mut-ref-test-" + [guid]::NewGuid())
    $script:AutPath = Join-Path $script:TempRoot 'aut'
    $script:TestAppPath = Join-Path $script:TempRoot 'test-app'
    New-Item -ItemType Directory -Path $script:AutPath -Force | Out-Null
    New-Item -ItemType Directory -Path $script:TestAppPath -Force | Out-Null

    Set-Content -Path (Join-Path $script:AutPath 'One.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50000 "AUT One"
{
    procedure DoSomething()
    begin
    end;
}
'@

    Set-Content -Path (Join-Path $script:AutPath 'Two.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50001 "AUT Two"
{
    procedure DoSomethingElse()
    begin
    end;
}
'@

    # References "AUT One" by `Codeunit "…"` (a var declaration) and "AUT Two" by
    # `Codeunit::"…"` (an object-id expression) -- the two forms named in §6.5.5 and the brief.
    Set-Content -Path (Join-Path $script:TestAppPath 'Tests.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50300 "AUT Tests"
{
    Subtype = Test;

    var
        One: Codeunit "AUT One";

    [Test]
    procedure Test1()
    var
        ObjId: Integer;
    begin
        ObjId := Codeunit::"AUT Two";
        One.DoSomething();
    end;
}
'@

    # A non-test codeunit in the test app: its references must NOT contribute to the map.
    Set-Content -Path (Join-Path $script:TestAppPath 'Helper.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50301 "AUT Test Helper"
{
    var
        One: Codeunit "AUT One";
}
'@
}

AfterAll {
    Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MutReferenceMap' {
    It 'maps a plain Codeunit "…" reference to the referencing test codeunit id' {
        $map = Get-MutReferenceMap -AutPath $script:AutPath -TestAppPath $script:TestAppPath

        $map[50000] | Should -Be @(50300)
    }

    It 'maps a Codeunit::"…" reference to the referencing test codeunit id' {
        $map = Get-MutReferenceMap -AutPath $script:AutPath -TestAppPath $script:TestAppPath

        $map[50001] | Should -Be @(50300)
    }

    It 'ignores references from a non-test codeunit (no Subtype = Test)' {
        $map = Get-MutReferenceMap -AutPath $script:AutPath -TestAppPath $script:TestAppPath

        $map[50000] | Should -Not -Contain 50301
    }

    It 'positive companion: the SAME Helper.Codeunit.al content, but with Subtype = Test added, DOES contribute its reference (proves the exclusion above is the Subtype check, not a parser that finds nothing)' {
        $subtypeAutPath = Join-Path $script:TempRoot 'aut-subtype-companion'
        $subtypeTestAppPath = Join-Path $script:TempRoot 'test-app-subtype-companion'
        New-Item -ItemType Directory -Path $subtypeAutPath -Force | Out-Null
        New-Item -ItemType Directory -Path $subtypeTestAppPath -Force | Out-Null

        Set-Content -Path (Join-Path $subtypeAutPath 'One.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50000 "AUT One"
{
}
'@
        Set-Content -Path (Join-Path $subtypeTestAppPath 'Helper.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50301 "AUT Test Helper"
{
    Subtype = Test;

    var
        One: Codeunit "AUT One";

    [Test]
    procedure Test1()
    begin
    end;
}
'@

        $map = Get-MutReferenceMap -AutPath $subtypeAutPath -TestAppPath $subtypeTestAppPath

        $map[50000] | Should -Be @(50301)
    }

    It 'still maps an AUT object whose file opens with a #pragma compiler directive before the object header (real AUT: BankProcessedItems.Page.al)' {
        $pragmaAutPath = Join-Path $script:TempRoot 'aut-pragma'
        $pragmaTestAppPath = Join-Path $script:TempRoot 'test-app-pragma'
        New-Item -ItemType Directory -Path $pragmaAutPath -Force | Out-Null
        New-Item -ItemType Directory -Path $pragmaTestAppPath -Force | Out-Null

        Set-Content -Path (Join-Path $pragmaAutPath 'Pragma.Page.al') -Encoding UTF8 -Value @'
#pragma warning disable AL0432
page 50010 "AUT Pragma Page"
{
    layout
    {
    }
}
'@

        Set-Content -Path (Join-Path $pragmaTestAppPath 'PragmaTests.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50310 "AUT Pragma Tests"
{
    Subtype = Test;

    var
        P: Page "AUT Pragma Page";

    [Test]
    procedure Test1()
    begin
    end;
}
'@

        $map = Get-MutReferenceMap -AutPath $pragmaAutPath -TestAppPath $pragmaTestAppPath

        $map[50010] | Should -Be @(50310)
    }

    It 'still maps an AUT object whose file opens with a namespace declaration, AND still discovers a test codeunit whose file opens with one (fix round 2: the worse half of the bug -- Get-MutReferenceMap continues past a headerless test codeunit, discarding every reference it contributes)' {
        $nsAutPath = Join-Path $script:TempRoot 'aut-namespace'
        $nsTestAppPath = Join-Path $script:TempRoot 'test-app-namespace'
        New-Item -ItemType Directory -Path $nsAutPath -Force | Out-Null
        New-Item -ItemType Directory -Path $nsTestAppPath -Force | Out-Null

        Set-Content -Path (Join-Path $nsAutPath 'Namespaced.Codeunit.al') -Encoding UTF8 -Value @'
namespace Continia.Banking.Base.Validation;

codeunit 50011 "AUT Namespaced Codeunit"
{
}
'@

        Set-Content -Path (Join-Path $nsTestAppPath 'NamespacedTests.Codeunit.al') -Encoding UTF8 -Value @'
namespace Continia.Banking.Base.Validation.Test;

using Continia.Banking.Base.Validation;

codeunit 50311 "AUT Namespaced Tests"
{
    Subtype = Test;

    var
        N: Codeunit "AUT Namespaced Codeunit";

    [Test]
    procedure Test1()
    begin
    end;
}
'@

        $map = Get-MutReferenceMap -AutPath $nsAutPath -TestAppPath $nsTestAppPath

        $map[50011] | Should -Be @(50311)
    }

    It 'keys the map by (object type, name): a codeunit and a page sharing a name must not let a reference to the page resolve to the codeunit''s id (fix round 4 -- the live Tier B bug, reproduced exactly: page 72918635 "CTS-CB JPMorgan Assist Setup" vs codeunit 72918654 of the same name, colliding with the unrelated pilot codeunit 72918635 "CTS-CB Auth Share Detection")' {
        $collisionAutPath = Join-Path $script:TempRoot 'aut-type-collision'
        $collisionTestAppPath = Join-Path $script:TempRoot 'test-app-type-collision'
        New-Item -ItemType Directory -Path $collisionAutPath -Force | Out-Null
        New-Item -ItemType Directory -Path $collisionTestAppPath -Force | Out-Null

        # Same name, two different object TYPES, two different ids -- the exact live shape.
        Set-Content -Path (Join-Path $collisionAutPath 'JPMorganSetup.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 72918654 "CTS-CB JPMorgan Assist Setup"
{
}
'@
        Set-Content -Path (Join-Path $collisionAutPath 'JPMorganSetup.Page.al') -Encoding UTF8 -Value @'
page 72918635 "CTS-CB JPMorgan Assist Setup"
{
}
'@
        Set-Content -Path (Join-Path $collisionAutPath 'AuthShareDetection.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 72918635 "CTS-CB Auth Share Detection"
{
}
'@

        # References the CODEUNIT "CTS-CB JPMorgan Assist Setup" by name -- exactly the real
        # bug's shape (SetupGuardBankTest.Codeunit.al declares `Codeunit "CTS-CB JPMorgan
        # Assist Setup"`, never mentions Auth Share Detection anywhere).
        Set-Content -Path (Join-Path $collisionTestAppPath 'JPMorganTests.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 95179 "SetupGuardBankTest"
{
    Subtype = Test;

    var
        C: Codeunit "CTS-CB JPMorgan Assist Setup";

    [Test]
    procedure Test1()
    begin
    end;
}
'@

        # References the CODEUNIT "CTS-CB Auth Share Detection" by name -- the genuine
        # covering test.
        Set-Content -Path (Join-Path $collisionTestAppPath 'AuthShareTests.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 95155 "AuthShareTests"
{
    Subtype = Test;

    var
        C: Codeunit "CTS-CB Auth Share Detection";

    [Test]
    procedure Test1()
    begin
    end;
}
'@

        $map = Get-MutReferenceMap -AutPath $collisionAutPath -TestAppPath $collisionTestAppPath

        # References[72918635] must be ONLY 95155 -- never 95179, which references the
        # unrelated PAGE that merely happens to share the codeunit's id.
        $map[72918635] | Should -Be @(95155)
        $map[72918654] | Should -Be @(95179)
    }

    It 'warns and keeps the first-seen id when two objects of the SAME type share a name (a genuine within-type ambiguity, distinct from the cross-type case above)' {
        $ambiguousAutPath = Join-Path $script:TempRoot 'aut-within-type-ambiguous'
        $ambiguousTestAppPath = Join-Path $script:TempRoot 'test-app-within-type-ambiguous'
        New-Item -ItemType Directory -Path $ambiguousAutPath -Force | Out-Null
        New-Item -ItemType Directory -Path $ambiguousTestAppPath -Force | Out-Null

        Set-Content -Path (Join-Path $ambiguousAutPath 'First.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 60000 "AUT Ambiguous"
{
}
'@
        Set-Content -Path (Join-Path $ambiguousAutPath 'Second.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 60001 "AUT Ambiguous"
{
}
'@
        Set-Content -Path (Join-Path $ambiguousTestAppPath 'AmbiguousTests.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 60300 "AUT Ambiguous Tests"
{
    Subtype = Test;

    var
        C: Codeunit "AUT Ambiguous";

    [Test]
    procedure Test1()
    begin
    end;
}
'@

        Mock -ModuleName References Write-Warning { }

        $map = Get-MutReferenceMap -AutPath $ambiguousAutPath -TestAppPath $ambiguousTestAppPath

        # Exactly one of the two ids wins (first-seen); the reference resolves to that one id,
        # never both, never neither.
        $wonBy60000 = $map.ContainsKey(60000)
        $wonBy60001 = $map.ContainsKey(60001)
        ($wonBy60000 -and -not $wonBy60001) -or ($wonBy60001 -and -not $wonBy60000) | Should -Be $true

        if ($wonBy60000) {
            $map[60000] | Should -Be @(60300)
        }
        else {
            $map[60001] | Should -Be @(60300)
        }

        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like '*ambiguous codeunit*AUT Ambiguous*' } -Times 1
    }

    It 'does not bind a test to an object referenced only inside a comment (fix round 4: references are now collected from trivia-stripped content)' {
        $commentedAutPath = Join-Path $script:TempRoot 'aut-commented-reference'
        $commentedTestAppPath = Join-Path $script:TempRoot 'test-app-commented-reference'
        New-Item -ItemType Directory -Path $commentedAutPath -Force | Out-Null
        New-Item -ItemType Directory -Path $commentedTestAppPath -Force | Out-Null

        Set-Content -Path (Join-Path $commentedAutPath 'Commented.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 70000 "AUT Commented Target"
{
}
'@
        Set-Content -Path (Join-Path $commentedTestAppPath 'CommentedTests.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 70300 "AUT Commented Tests"
{
    Subtype = Test;

    // var
    //     C: Codeunit "AUT Commented Target";
    /* C2: Codeunit "AUT Commented Target"; */

    [Test]
    procedure Test1()
    begin
    end;
}
'@

        $map = Get-MutReferenceMap -AutPath $commentedAutPath -TestAppPath $commentedTestAppPath

        $map.ContainsKey(70000) | Should -Be $false
    }

    It 'does not misread a TestPage handler parameter as a Page reference (fix round 4, found chasing the real-AUT acceptance check: "Page" is a plain substring of "TestPage", and without a leading word boundary a TestPage "…" handler for one object reproduced the exact wrong-attribution class this whole fix round exists to close, via a different mechanism)' {
        $testPageAutPath = Join-Path $script:TempRoot 'aut-testpage'
        $testPageTestAppPath = Join-Path $script:TempRoot 'test-app-testpage'
        New-Item -ItemType Directory -Path $testPageAutPath -Force | Out-Null
        New-Item -ItemType Directory -Path $testPageTestAppPath -Force | Out-Null

        # A page and an unrelated codeunit that happen to share a numeric id -- exactly the
        # live shape (page 72918635 "CTS-CB JPMorgan Assist Setup" / codeunit 72918635 "CTS-CB
        # Auth Share Detection"), reproduced with small ids for a self-contained fixture.
        Set-Content -Path (Join-Path $testPageAutPath 'SomePage.Page.al') -Encoding UTF8 -Value @'
page 80000 "AUT Some Page"
{
}
'@
        Set-Content -Path (Join-Path $testPageAutPath 'UnrelatedCodeunit.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 80000 "AUT Unrelated Codeunit"
{
}
'@

        # References the page ONLY via a TestPage handler parameter -- never via a plain
        # `Page "…"`/`Page::"…"` reference, and never mentions the unrelated codeunit at all.
        Set-Content -Path (Join-Path $testPageTestAppPath 'PageHandlerTests.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 80300 "AUT Page Handler Tests"
{
    Subtype = Test;

    [Test]
    procedure Test1()
    begin
    end;

    procedure SomePageHandler(var AUTSomePage: TestPage "AUT Some Page")
    begin
    end;
}
'@

        $map = Get-MutReferenceMap -AutPath $testPageAutPath -TestAppPath $testPageTestAppPath

        # Neither id may be attributed to 80300: a TestPage handler parameter is not one of
        # §6.5.5's recognised reference forms (Codeunit/Record/Page/Enum/Database), so this
        # test contributes no reference to either object at all -- must NOT resolve to the
        # unrelated codeunit that merely shares the page's numeric id.
        $map.ContainsKey(80000) | Should -Be $false
    }
}

Describe 'Get-MutObjectHeader (private: strip comments, skip the closed preamble -- blank/`#`/`namespace`/`using` -- test the first remaining line, warn+null if it is not a header)' {
    BeforeAll {
        $script:HeaderScratch = Join-Path $script:TempRoot 'header-scratch'
        New-Item -ItemType Directory -Path $script:HeaderScratch -Force | Out-Null
    }

    BeforeEach {
        Mock -ModuleName References Write-Warning { }
    }

    It 'finds the header when the file opens with a #pragma directive' {
        $path = Join-Path $script:HeaderScratch 'pragma.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
#pragma warning disable AL0432
codeunit 50020 "AUT Pragma Codeunit"
{
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.ObjectType | Should -Be 'codeunit'
        $header.Id | Should -Be 50020
        $header.Name | Should -Be 'AUT Pragma Codeunit'
    }

    It 'finds the header when the file opens with an #if directive' {
        $path = Join-Path $script:HeaderScratch 'if.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
#if CLEAN22
codeunit 50021 "AUT If Codeunit"
{
}
#endif
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.ObjectType | Should -Be 'codeunit'
        $header.Id | Should -Be 50021
        $header.Name | Should -Be 'AUT If Codeunit'
    }

    It 'finds the header past a multi-line /* ... */ block comment, WITHOUT attaching the id of a fake header commented out inside it (fix-round-1 regression: the id must be 50100, never the 50999 inside the comment)' {
        $path = Join-Path $script:HeaderScratch 'block-comment.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
/*
    codeunit 50999 "Old Fake Codeunit"
*/
codeunit 50100 "Real Codeunit"
{ }
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50100
        $header.Name | Should -Be 'Real Codeunit'
    }

    It 'finds the header past a single-line /* ... */ block comment' {
        $path = Join-Path $script:HeaderScratch 'single-line-block-comment.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
/* license header */
codeunit 50101 "AUT Single Line Comment Codeunit"
{ }
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50101
        $header.Name | Should -Be 'AUT Single Line Comment Codeunit'
    }

    It 'finds the header when real code follows the closing */ on the same line' {
        $path = Join-Path $script:HeaderScratch 'same-line-after-comment.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
/* license header */codeunit 50102 "AUT Same Line Codeunit"
{ }
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50102
        $header.Name | Should -Be 'AUT Same Line Codeunit'
    }

    It 'returns $null WITHOUT warning for a realistic permissionset whose body has a numeric Permissions list (fix-round-1 regression guard: must not misread "table 50100 = X" as a header; fix-round-3: permissionset is a known out-of-scope keyword, so this is silent, not a warning)' {
        $path = Join-Path $script:HeaderScratch 'permissionset-with-numeric-permissions.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
permissionset 50200 "My Perm Set"
{
    Permissions = tabledata "Customer" = RIMD,
                  table 50100 = X, page 50101 = X;
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'positive companion: the SAME numeric-Permissions fixture, but with the keyword line swapped for a real header, yields 50100 and no warning (proves the harness recognises a header when one is present)' {
        $path = Join-Path $script:HeaderScratch 'permissionset-with-numeric-permissions-positive.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
codeunit 50100 "X"
{
    Permissions = tabledata "Customer" = RIMD,
                  table 50100 = X, page 50101 = X;
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50100
        $header.Name | Should -Be 'X'
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'returns $null WITHOUT warning for a permissionset with no numeric Permissions either (fix round 3: permissionset is expected-and-silent)' {
        $path = Join-Path $script:HeaderScratch 'no-header.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
permissionset 50022 "AUT Permissions"
{
    Assignable = true;
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'positive companion: the SAME no-numeric-Permissions fixture, but with the keyword line swapped for a real header, yields 50100 and no warning' {
        $path = Join-Path $script:HeaderScratch 'no-header-positive.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
codeunit 50100 "X"
{
    Assignable = true;
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50100
        $header.Name | Should -Be 'X'
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'returns $null WITHOUT warning for an interface declaration (fix round 3: interfaces have no numeric id and can never match the header pattern -- 125 of the AUT''s 201 pre-fix false-positive warnings were exactly this)' {
        $path = Join-Path $script:HeaderScratch 'interface.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
interface "CTS-CB IAuthentication"
{
    procedure DoSomething();
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'positive companion: the SAME interface fixture, but with the keyword line swapped for a real header, yields 50100 and no warning' {
        $path = Join-Path $script:HeaderScratch 'interface-positive.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
codeunit 50100 "X"
{
    procedure DoSomething();
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50100
        $header.Name | Should -Be 'X'
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'returns $null WITHOUT warning for the other known out-of-scope declaration keywords (tableextension, pageextension, enumextension, reportextension, permissionsetextension, controladdin, profile, entitlement, dotnet)' {
        $keywords = @('tableextension', 'pageextension', 'enumextension', 'reportextension', 'permissionsetextension', 'controladdin', 'profile', 'entitlement', 'dotnet')
        foreach ($keyword in $keywords) {
            $path = Join-Path $script:HeaderScratch "$keyword-scratch.al"
            Set-Content -Path $path -Encoding UTF8 -Value "$keyword 50000 `"Some Name`" extends `"Some Base`"`n{`n}`n"

            $header = InModuleScope References {
                param($Path)
                Get-MutObjectHeader -Path $Path
            } -Parameters @{ Path = $path }

            $header | Should -BeNullOrEmpty
        }
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'positive companion: the SAME other-keywords fixtures, but with each keyword line swapped for a real header, yield 50100 and no warning' {
        $keywords = @('tableextension', 'pageextension', 'enumextension', 'reportextension', 'permissionsetextension', 'controladdin', 'profile', 'entitlement', 'dotnet')
        foreach ($keyword in $keywords) {
            $path = Join-Path $script:HeaderScratch "$keyword-scratch-positive.al"
            Set-Content -Path $path -Encoding UTF8 -Value "codeunit 50100 `"X`"`n{`n}`n"

            $header = InModuleScope References {
                param($Path)
                Get-MutObjectHeader -Path $Path
            } -Parameters @{ Path = $path }

            $header | Should -Not -BeNullOrEmpty
            $header.Id | Should -Be 50100
        }
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'returns $null AND WARNS for a genuinely empty file (fix round 4: the "no remaining line at all" path used to return $null silently -- the one path the mandated warning did not cover)' {
        $path = Join-Path $script:HeaderScratch 'truly-empty.al'
        Set-Content -Path $path -Encoding UTF8 -Value ''

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }

    It 'returns $null AND warns for a header hidden entirely inside a block comment (compiles fine; realistic when someone comments an object out)' {
        $path = Join-Path $script:HeaderScratch 'header-entirely-commented-out.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
/*
codeunit 50100 "X"
{
}
*/
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }

    It 'returns $null AND warns for an unterminated /* that swallows the rest of the file' {
        $path = Join-Path $script:HeaderScratch 'unterminated-block-comment.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
/*
codeunit 50100 "X"
{
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }

    It 'returns $null AND warns for a comments-only file' {
        $path = Join-Path $script:HeaderScratch 'comments-only.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
// just a comment
// another comment
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }

    It 'returns $null AND warns for a whitespace-only file' {
        $path = Join-Path $script:HeaderScratch 'whitespace-only.al'
        Set-Content -Path $path -Encoding UTF8 -Value "   `n`t`n   `n"

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }

    It 'positive companion: a non-empty file with a real header at the top does not warn (control for the empty-file-now-warns tests above)' {
        $path = Join-Path $script:HeaderScratch 'not-empty-positive.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
codeunit 50100 "X"
{
}
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50100
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'finds the header past a namespace declaration (fix round 2: legal AL on BC 22+, the AUT is on BC 29, and 306 AUT files carry this commented out on line 1)' {
        $path = Join-Path $script:HeaderScratch 'namespace-first.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
namespace Continia.Banking.Base.Validation;

codeunit 50103 "AUT Namespace Codeunit"
{ }
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50103
        $header.Name | Should -Be 'AUT Namespace Codeunit'
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'finds the header past a using declaration' {
        $path = Join-Path $script:HeaderScratch 'using-first.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
using Continia.Banking.Base;

codeunit 50104 "AUT Using Codeunit"
{ }
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50104
        $header.Name | Should -Be 'AUT Using Codeunit'
        Should -Invoke -ModuleName References Write-Warning -Times 0
    }

    It 'finds the header past BOTH a namespace and a using declaration, in either order the preamble allows' {
        $path = Join-Path $script:HeaderScratch 'namespace-and-using.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
namespace Continia.Banking.Base.Validation;

using Continia.Banking.Base;
using Continia.Banking.Base.Other;

codeunit 50105 "AUT Namespace And Using Codeunit"
{ }
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -Not -BeNullOrEmpty
        $header.Id | Should -Be 50105
        $header.Name | Should -Be 'AUT Namespace And Using Codeunit'
    }

    It 'returns $null AND warns naming the file when the first non-preamble line is an unrecognised construct (the gap that let the namespace/using bug through)' {
        $path = Join-Path $script:HeaderScratch 'unrecognised-leading-construct.al'
        Set-Content -Path $path -Encoding UTF8 -Value @'
namespace Continia.Banking.Base.Validation;

apply obsolete;
codeunit 50106 "AUT Unreachable Codeunit"
{ }
'@

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }
}

Describe 'Save-MutReferenceMap' {
    It 'round-trips a map to references.json and back' {
        $map = Get-MutReferenceMap -AutPath $script:AutPath -TestAppPath $script:TestAppPath
        $outPath = Join-Path $script:TempRoot 'references.json'

        Save-MutReferenceMap -Map $map -Path $outPath

        Test-Path -Path $outPath | Should -Be $true

        $loaded = Get-Content -Path $outPath -Raw | ConvertFrom-Json
        @($loaded.'50000') | Should -Be @(50300)
        @($loaded.'50001') | Should -Be @(50300)
    }
}
