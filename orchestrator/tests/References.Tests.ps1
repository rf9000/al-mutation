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

    It 'returns $null (and warns naming the file) for a realistic permissionset whose body has a numeric Permissions list (fix-round-1 regression: must not misread "table 50100 = X" as a header)' {
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
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }

    It 'returns $null (and warns naming the file) for a file whose only object-like content is a permissionset with no numeric Permissions' {
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
        Should -Invoke -ModuleName References Write-Warning -ParameterFilter { $Message -like "*$path*" } -Times 1
    }

    It 'returns $null WITHOUT warning for a genuinely empty file (no first-remaining-line to test at all)' {
        $path = Join-Path $script:HeaderScratch 'truly-empty.al'
        Set-Content -Path $path -Encoding UTF8 -Value ''

        $header = InModuleScope References {
            param($Path)
            Get-MutObjectHeader -Path $Path
        } -Parameters @{ Path = $path }

        $header | Should -BeNullOrEmpty
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
