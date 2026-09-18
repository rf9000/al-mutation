<#
    .SYNOPSIS
    T10 U1/U3 spike generator: creates the "MUT Guard Bench" app (docs/SPEC.md §6.6.2, §6.0.1)
    used to measure alc.exe's tolerance for ~500 sequential
    `case true of MutationCore.Active(n) ... else ... end;` guard blocks in one codeunit, and
    the runtime overhead that guard adds across a 100,000-iteration loop.

    .DESCRIPTION
    Writes spikes/u1-guard-bench/app/{app.json, .vscode/settings.json, src/*.al}. Everything
    under app/ is generated (see .gitignore: only app/.gitkeep is tracked); this script is the
    only tracked source of truth. Re-running is idempotent: app/src is deleted and rewritten
    each time.

    Generates:
      - app.json: id ad5b6a7e-cf8c-4b9d-9eaf-1a2b3c4d5e6f, name "MUT Guard Bench",
        publisher Continia Software, version 1.0.0.0, idRanges 50500-50599, dependencies on
        Mutation Core (6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b, 1.0.0.0), Microsoft Library Assert
        (dd0be2ea-f733-4d65-bb34-a28f4624fb14, 28.0.0.0) and Microsoft Test Runner
        (23de40a6-dfe8-4f80-80db-d70f83ce8caf, 28.0.0.0); platform/application 28.0.0.0,
        runtime 17.0, target Cloud, features ["NoImplicitWith"].
      - .vscode/settings.json: al.codeAnalyzers = [${CodeCop}, ${UICop}] (per SPEC §9.2).
      - src/MUTGuardBench.Codeunit.al: codeunit 50500 "MUT Guard Bench" (Access = Public) with
        `Guarded(Value: Integer): Integer` (500 sequential guard blocks, n = 1..500) and
        `Unguarded(Value: Integer): Integer` (500 plain `Result := Value;` lines).
      - src/MUTGuardBenchTests.Codeunit.al: codeunit 50501 "MUT Guard Bench Tests"
        (Subtype = Test; TestPermissions = Disabled;) with `Guarded_100k` and `Unguarded_100k`,
        each looping 100,000 times and asserting the result equals the input (MutationCore.Reset()
        is called first in Guarded_100k so the guard is inactive throughout).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appRoot = Join-Path $PSScriptRoot 'app'
$srcDir = Join-Path $appRoot 'src'
$vscodeDir = Join-Path $appRoot '.vscode'

if (Test-Path $srcDir) {
    Remove-Item -Path $srcDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null

# UTF-8 without a BOM, to match the rest of the workspace's .al/.json files.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [string] $Path,
        [string[]] $Lines
    )
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), $utf8NoBom)
}

# --- app.json -----------------------------------------------------------------------------
$appJson = [ordered]@{
    id               = 'ad5b6a7e-cf8c-4b9d-9eaf-1a2b3c4d5e6f'
    name             = 'MUT Guard Bench'
    publisher        = 'Continia Software'
    version          = '1.0.0.0'
    brief            = ''
    description      = ''
    privacyStatement = ''
    EULA             = ''
    help             = ''
    url              = ''
    logo             = ''
    dependencies     = @(
        [ordered]@{ id = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b'; name = 'Mutation Core'; publisher = 'Continia Software'; version = '1.0.0.0' }
        [ordered]@{ id = 'dd0be2ea-f733-4d65-bb34-a28f4624fb14'; name = 'Library Assert'; publisher = 'Microsoft'; version = '28.0.0.0' }
        [ordered]@{ id = '23de40a6-dfe8-4f80-80db-d70f83ce8caf'; name = 'Test Runner'; publisher = 'Microsoft'; version = '28.0.0.0' }
    )
    screenshots      = @()
    platform         = '28.0.0.0'
    application      = '28.0.0.0'
    idRanges         = @(
        [ordered]@{ from = 50500; to = 50599 }
    )
    resourceExposurePolicy = [ordered]@{
        allowDebugging            = $true
        allowDownloadingSource    = $true
        includeSourceInSymbolFile = $true
    }
    runtime  = '17.0'
    target   = 'Cloud'
    features = @('NoImplicitWith')
}
Write-Utf8NoBom -Path (Join-Path $appRoot 'app.json') -Lines @($appJson | ConvertTo-Json -Depth 10)

# --- .vscode/settings.json -----------------------------------------------------------------
$settingsJson = [ordered]@{
    'al.codeAnalyzers' = @('${CodeCop}', '${UICop}')
}
Write-Utf8NoBom -Path (Join-Path $vscodeDir 'settings.json') -Lines @($settingsJson | ConvertTo-Json -Depth 10)

# --- src/MUTGuardBench.Codeunit.al -----------------------------------------------------------
$benchLines = New-Object System.Collections.Generic.List[string]
$benchLines.Add('codeunit 50500 "MUT Guard Bench"')
$benchLines.Add('{')
$benchLines.Add('    Access = Public;')
$benchLines.Add('')
$benchLines.Add('    procedure Guarded(Value: Integer): Integer')
$benchLines.Add('    var')
$benchLines.Add('        MutationCore: Codeunit "MUT Mut";')
$benchLines.Add('        Result: Integer;')
$benchLines.Add('    begin')
for ($n = 1; $n -le 500; $n++) {
    $benchLines.Add('        case true of')
    $benchLines.Add("            MutationCore.Active($n):")
    $benchLines.Add("                Result := Value + $n;")
    $benchLines.Add('            else')
    $benchLines.Add('                Result := Value;')
    $benchLines.Add('        end;')
}
$benchLines.Add('        exit(Result);')
$benchLines.Add('    end;')
$benchLines.Add('')
$benchLines.Add('    procedure Unguarded(Value: Integer): Integer')
$benchLines.Add('    var')
$benchLines.Add('        Result: Integer;')
$benchLines.Add('    begin')
for ($n = 1; $n -le 500; $n++) {
    $benchLines.Add('        Result := Value;')
}
$benchLines.Add('        exit(Result);')
$benchLines.Add('    end;')
$benchLines.Add('}')
Write-Utf8NoBom -Path (Join-Path $srcDir 'MUTGuardBench.Codeunit.al') -Lines $benchLines

# --- src/MUTGuardBenchTests.Codeunit.al -------------------------------------------------------
$testLines = @(
    'codeunit 50501 "MUT Guard Bench Tests"'
    '{'
    '    Subtype = Test;'
    '    TestPermissions = Disabled;'
    '    Access = Internal;'
    ''
    '    var'
    '        Assert: Codeunit "Library Assert";'
    '        MutationCore: Codeunit "MUT Mut";'
    '        Bench: Codeunit "MUT Guard Bench";'
    ''
    '    [Test]'
    '    procedure Guarded_100k()'
    '    var'
    '        Counter: Integer;'
    '        Result: Integer;'
    '    begin'
    '        MutationCore.Reset();'
    '        for Counter := 1 to 100000 do begin'
    '            Result := Bench.Guarded(Counter);'
    "            Assert.AreEqual(Counter, Result, 'Guarded should return its input when the guard is inactive.');"
    '        end;'
    '    end;'
    ''
    '    [Test]'
    '    procedure Unguarded_100k()'
    '    var'
    '        Counter: Integer;'
    '        Result: Integer;'
    '    begin'
    '        for Counter := 1 to 100000 do begin'
    '            Result := Bench.Unguarded(Counter);'
    "            Assert.AreEqual(Counter, Result, 'Unguarded should return its input.');"
    '        end;'
    '    end;'
    '}'
)
Write-Utf8NoBom -Path (Join-Path $srcDir 'MUTGuardBenchTests.Codeunit.al') -Lines $testLines

Write-Output "Generated MUT Guard Bench app at $appRoot"
