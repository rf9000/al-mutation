Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Get-MutReferencingTests.ps1: the §6.5.5 reference map, inverted for the given objects, as one
# JSON line. mutant-fixer picks each PR's test codeunits with it.

BeforeAll {
    $script:Script = (Resolve-Path "$PSScriptRoot/../Get-MutReferencingTests.ps1").Path
    $script:Shell = (Get-Process -Id $PID).Path

    $script:AutPath = Join-Path $TestDrive 'aut'
    $script:TestAppPath = Join-Path $TestDrive 'test-app'
    New-Item -ItemType Directory -Path $script:AutPath -Force | Out-Null
    New-Item -ItemType Directory -Path $script:TestAppPath -Force | Out-Null

    Set-Content -Path (Join-Path $script:AutPath 'One.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50000 "AUT One"
{
}
'@
    Set-Content -Path (Join-Path $script:AutPath 'Two.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50001 "AUT Two"
{
}
'@
    # One name, two object types: a Page reference must bind to the page only.
    Set-Content -Path (Join-Path $script:AutPath 'Shared.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50002 "Shared Name"
{
}
'@
    Set-Content -Path (Join-Path $script:AutPath 'Shared.Page.al') -Encoding UTF8 -Value @'
page 50003 "Shared Name"
{
}
'@

    Set-Content -Path (Join-Path $script:TestAppPath 'Both.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50300 "Test Both"
{
    Subtype = Test;

    var
        One: Codeunit "AUT One";
        Two: Codeunit "AUT Two";
}
'@
    Set-Content -Path (Join-Path $script:TestAppPath 'TwoOnly.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50301 "Test Two Only"
{
    Subtype = Test;

    var
        Two: Codeunit "AUT Two";
}
'@
    Set-Content -Path (Join-Path $script:TestAppPath 'SharedPage.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50302 "Test Shared Name Usage"
{
    Subtype = Test;

    var
        P: Page "Shared Name";
}
'@
    Set-Content -Path (Join-Path $script:TestAppPath 'Commented.Codeunit.al') -Encoding UTF8 -Value @'
codeunit 50303 "Test Commented"
{
    Subtype = Test;

    var
        // One: Codeunit "AUT One";
        X: Integer;
}
'@

    function script:Invoke-Referencing {
        param([string]$Objects, [string]$AutPath = $script:AutPath)
        $out = & $script:Shell -NoProfile -File $script:Script -AutPath $AutPath -TestAppPath $script:TestAppPath -Objects $Objects 2>$null
        $code = $LASTEXITCODE
        $line = @($out | Where-Object { "$_".StartsWith('[') }) | Select-Object -Last 1
        $rows = @()
        if ($line) {
            # Piping enumerates the parsed array (Windows PowerShell 5.1 returns it as one object).
            $rows = @($line | ConvertFrom-Json | ForEach-Object { $_ })
        }
        [pscustomobject]@{ Code = $code; Line = $line; Rows = $rows }
    }
}

Describe 'Get-MutReferencingTests.ps1' {
    It 'lists each referencing test codeunit with the objects it references, sorted' {
        $r = Invoke-Referencing -Objects '50001,50000'
        $r.Code | Should -Be 0
        $r.Rows.Count | Should -Be 2
        $r.Rows[0].codeunit | Should -Be 50300
        @($r.Rows[0].objects) | Should -Be @(50000, 50001)
        $r.Rows[1].codeunit | Should -Be 50301
        @($r.Rows[1].objects) | Should -Be @(50001)
    }

    It 'leaves out objects no test references and prints [] when none is referenced' {
        $r = Invoke-Referencing -Objects '59999'
        $r.Code | Should -Be 0
        $r.Line | Should -Be '[]'
        $r.Rows.Count | Should -Be 0
    }

    It 'does not count a reference inside a comment' {
        $r = Invoke-Referencing -Objects '50000'
        @($r.Rows | ForEach-Object { $_.codeunit }) | Should -Be @(50300)
    }

    It 'binds a typed reference to its own object type only' {
        (Invoke-Referencing -Objects '50002').Rows.Count | Should -Be 0
        $page = Invoke-Referencing -Objects '50003'
        $page.Rows.Count | Should -Be 1
        $page.Rows[0].codeunit | Should -Be 50302
    }

    It 'exits 1 when a folder does not exist' {
        (Invoke-Referencing -Objects '50000' -AutPath (Join-Path $TestDrive 'missing')).Code | Should -Be 1
    }

    It 'exits 1 when -Objects is not a list of integers' {
        (Invoke-Referencing -Objects 'abc').Code | Should -Be 1
        (Invoke-Referencing -Objects ' , ').Code | Should -Be 1
    }
}
