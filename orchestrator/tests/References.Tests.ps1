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
}

Describe 'Get-MutObjectHeader (private: scans forward past directives instead of testing only the first non-comment line)' {
    BeforeAll {
        $script:HeaderScratch = Join-Path $script:TempRoot 'header-scratch'
        New-Item -ItemType Directory -Path $script:HeaderScratch -Force | Out-Null
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

    It 'returns $null for a file with no object header at all' {
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
