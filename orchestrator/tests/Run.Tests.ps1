<#
    .SYNOPSIS
    §6.5.4/T27: the nine-step pipeline runs in order, writes `.done` markers, and skips a step
    whose marker (and guarded artifact) already exists on a second call for the same run number.
    Abort paths (baseline failure; inactive-schemata failure) throw and do not proceed.

    Every backend function (§6.5.3) is mocked at ModuleName Run scope: DemoPortal.psm1 is
    imported first purely so a REAL function of each name exists for Mock to attach a proxy to
    (the same pattern Schemata.Tests.ps1 uses for Compile-MutApp) -- no real CLI call is ever
    made. Build-MutSchemata (Schemata.psm1), Invoke-MutMutantLoop (MutantLoop.psm1),
    Get-MutReferenceMap (References.psm1) and Export-MutResults (Results.psm1) are also mocked,
    so this file tests Run.psm1's own orchestration logic, not those modules' internals (each
    has its own dedicated test file already).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/Run.psm1" -Force

    $script:EnvHandle = [pscustomobject]@{
        Id      = 'E1'
        Name    = 'mut-spike-01'
        Url     = 'https://example.invalid/E1'
        Backend = 'DemoPortal'
        Shared  = $false
        Status  = 'Running'
        CliPath = './.tools/fake-cli.exe'
    }

    function script:New-MutRunTestConfig {
        param(
            [string]$WorkDir,
            [bool]$KeepEnvironment = $true,
            [string]$PublishStrategy = 'same-version'
        )

        [pscustomobject]@{
            backend         = 'DemoPortal'
            environmentName = 'mut-spike-01'
            keepEnvironment = $KeepEnvironment
            aut             = [pscustomobject]@{ sourcePath = "$WorkDir/src-aut"; appId = 'aut-app-id'; version = '1.0.0.0' }
            testApp         = [pscustomobject]@{ sourcePath = "$WorkDir/src-test"; appId = 'test-app-id'; testCodeunits = @(50300) }
            rulesets        = $null
            coreApp         = [pscustomobject]@{ path = "$WorkDir/core-app"; appId = 'core-app-id'; version = '1.0.0.0' }
            permissionSets  = @(
                [pscustomobject]@{ id = 'MUT Core All'; appId = 'core-app-id' }
                [pscustomobject]@{ id = 'MUT Fx All'; appId = 'aut-app-id' }
            )
            workDir         = $WorkDir
            generator       = [pscustomobject]@{ maxMutants = 0; onlyObjects = @(); seed = 1; operators = @('REL'); includeBreak = $false }
            schemata        = [pscustomobject]@{ publishStrategy = $PublishStrategy }
            timeouts        = [pscustomobject]@{ perTestFactor = 5; minSeconds = 60; jobOverheadSeconds = 0 }
            demoPortal      = [pscustomobject]@{ profileId = 'p1'; activationAppId = 'a1'; cliPath = './.tools/fake-cli.exe' }
        }
    }

    function script:New-MutFakeMutant {
        param([int]$Id, [int]$ObjectId = 50200, [int]$Line = 7, [string]$Procedure = 'IsLargeOrder', [string]$Operator = 'REL')
        [pscustomobject]@{
            id         = $Id
            stableKey  = "key$Id"
            objectType = 'codeunit'
            objectId   = $ObjectId
            objectName = 'MUT Fx Order Mgt'
            procedure  = $Procedure
            line       = $Line
            operator   = $Operator
            original   = 'Quantity >= 10'
            mutated    = 'Quantity > 10'
            file       = 'src/MUTFxOrderMgt.Codeunit.al'
        }
    }
}

Describe 'Invoke-MutRunPipeline (fully mocked backend/lib boundary)' {
    BeforeEach {
        $script:WorkDir = "$TestDrive/work-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
        $script:Config = New-MutRunTestConfig -WorkDir $script:WorkDir

        $script:CallLog = New-Object System.Collections.Generic.List[string]

        Mock -ModuleName Run Get-MutEnvironment { $script:CallLog.Add('Get-MutEnvironment'); return $script:EnvHandle }
        Mock -ModuleName Run New-MutEnvironment { $script:CallLog.Add('New-MutEnvironment'); return $script:EnvHandle }
        Mock -ModuleName Run Start-MutEnvironment { $script:CallLog.Add('Start-MutEnvironment'); return $script:EnvHandle }
        Mock -ModuleName Run Remove-MutEnvironment { $script:CallLog.Add('Remove-MutEnvironment') }
        Mock -ModuleName Run Sync-MutAutCopy {
            $script:CallLog.Add('Sync-MutAutCopy')
            [pscustomobject]@{ AutPath = "$script:WorkDir/aut-original"; TestAppPath = "$script:WorkDir/test-app"; RulesetsPath = $null }
        }
        Mock -ModuleName Run Install-MutDependencies { $script:CallLog.Add('Install-MutDependencies') }
        Mock -ModuleName Run Publish-MutApp {
            $script:CallLog.Add('Publish-MutApp')
            [pscustomobject]@{ Success = $true; Code = $null; Diagnostics = @(); DurationSec = 0.1 }
        }
        Mock -ModuleName Run Publish-MutAppFile {
            $script:CallLog.Add('Publish-MutAppFile')
            [pscustomobject]@{ Success = $true; DurationSec = 0.1 }
        }
        Mock -ModuleName Run Unpublish-MutApp {
            $script:CallLog.Add('Unpublish-MutApp')
            [pscustomobject]@{ Success = $true }
        }
        Mock -ModuleName Run Grant-MutPermissionSet { $script:CallLog.Add('Grant-MutPermissionSet') }
        Mock -ModuleName Run Invoke-MutTests {
            $script:CallLog.Add('Invoke-MutTests')
            [pscustomobject]@{ Passed = 1; Failed = 0; Tests = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 100; Error = $null }); DurationMs = 100; JobIds = @('7') }
        }
        Mock -ModuleName Run Get-MutCoverage {
            $script:CallLog.Add('Get-MutCoverage')
            @([pscustomobject]@{ ObjectType = 'Codeunit'; ObjectId = 50200; LineType = 'Code'; LineNo = 7; Hits = 1 })
        }
        Mock -ModuleName Run Get-MutReferenceMap { $script:CallLog.Add('Get-MutReferenceMap'); @{ 50200 = @(50300) } }
        Mock -ModuleName Run Invoke-MutApi {
            $script:CallLog.Add("Invoke-MutApi:$Method`:$Path")
            if ($Method -eq 'GET' -and $Path -eq 'mutants') {
                return [pscustomobject]@{ value = @() }
            }
            return $null
        }
        Mock -ModuleName Run Build-MutSchemata {
            $script:CallLog.Add('Build-MutSchemata')
            [pscustomobject]@{
                SchemataPath    = "$script:WorkDir/gen/aut-schemata"
                AppFile         = "$script:WorkDir/gen/aut-schemata/Fake.app"
                Mutants         = @((New-MutFakeMutant -Id 1), (New-MutFakeMutant -Id 2 -Operator 'COND'))
                CompileErrorIds = @()
                ExcludedMutants = @()
                Iterations      = 1
                ExcludeFile     = $null
                RunNo           = 1
            }
        }
        Mock -ModuleName Run Invoke-MutMutantLoop {
            $script:CallLog.Add('Invoke-MutMutantLoop')
            @(
                [pscustomobject]@{ Id = 1; Status = 'Survived'; KillingTest = $null; DurationMs = 50; CoveringTests = @(50300) }
                [pscustomobject]@{ Id = 2; Status = 'Killed'; KillingTest = 'C:F'; DurationMs = 60; CoveringTests = @(50300) }
            )
        }
        Mock -ModuleName Run Export-MutResults {
            $script:CallLog.Add('Export-MutResults')
            [pscustomobject]@{ ResultsPath = "$script:WorkDir/results/1.json"; SummaryPath = "$script:WorkDir/results/1-summary.md" }
        }
    }

    It 'runs the nine steps in order and writes every .done marker' {
        $result = Invoke-MutRunPipeline -Config $script:Config -RunNo 1

        $runDir = Join-Path $script:WorkDir 'runs/1'
        foreach ($marker in @('initialize.done', 'environment.done', 'baseline.done', 'schemata.done', 'publish-schemata.done', 'manifest.done', 'covering.done', 'mutant-loop.done', 'export.done')) {
            Test-Path (Join-Path $runDir $marker) | Should -Be $true -Because "marker '$marker' should exist"
        }

        $result.ResultsPath | Should -Be "$script:WorkDir/results/1.json"
        $result.SummaryPath | Should -Be "$script:WorkDir/results/1-summary.md"

        # Environment ensured, then baseline (deps/publish/grant/tests), then schemata build,
        # then schemata publish (+ PATCH + rerun tests), then manifest (PATCH + GET), then the
        # mutant loop, then export -- in that relative order.
        $indexOf = { param($name) $script:CallLog.IndexOf($name) }
        (& $indexOf 'Get-MutEnvironment') | Should -BeGreaterThan -1
        (& $indexOf 'Sync-MutAutCopy') | Should -BeGreaterThan (& $indexOf 'Get-MutEnvironment')
        (& $indexOf 'Install-MutDependencies') | Should -BeGreaterThan (& $indexOf 'Sync-MutAutCopy')
        (& $indexOf 'Grant-MutPermissionSet') | Should -BeGreaterThan (& $indexOf 'Install-MutDependencies')
        (& $indexOf 'Build-MutSchemata') | Should -BeGreaterThan (& $indexOf 'Grant-MutPermissionSet')
        (& $indexOf 'Invoke-MutMutantLoop') | Should -BeGreaterThan (& $indexOf 'Build-MutSchemata')
        (& $indexOf 'Export-MutResults') | Should -BeGreaterThan (& $indexOf 'Invoke-MutMutantLoop')

        # Environment kept (config.keepEnvironment = true): Remove-MutEnvironment never called.
        Should -Invoke -ModuleName Run Remove-MutEnvironment -Times 0
    }

    It 'skips every step''s real work on a second call for the same run number (markers already present)' {
        Invoke-MutRunPipeline -Config $script:Config -RunNo 1 | Out-Null
        $firstCallCounts = @{
            GetEnvironment    = @($script:CallLog | Where-Object { $_ -eq 'Get-MutEnvironment' }).Count
            BuildSchemata     = @($script:CallLog | Where-Object { $_ -eq 'Build-MutSchemata' }).Count
            InvokeMutantLoop  = @($script:CallLog | Where-Object { $_ -eq 'Invoke-MutMutantLoop' }).Count
            InvokeMutTests    = @($script:CallLog | Where-Object { $_ -eq 'Invoke-MutTests' }).Count
            PublishMutAppFile = @($script:CallLog | Where-Object { $_ -eq 'Publish-MutAppFile' }).Count
        }
        $firstCallCounts.GetEnvironment | Should -Be 1
        $firstCallCounts.BuildSchemata | Should -Be 1
        $firstCallCounts.InvokeMutantLoop | Should -Be 1

        $script:CallLog.Clear()

        $secondResult = Invoke-MutRunPipeline -Config $script:Config -RunNo 1

        # Export-MutResultsStep's skip branch always computes results/<RunNo>.json from the real
        # repo root (Get-MutRepoRoot) -- unlike the fresh-work branch, it never calls the (here
        # mocked) Export-MutResults, so it can't echo that mock's fake work-dir-based path.
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $secondResult.ResultsPath | Should -Be (Join-Path $repoRoot 'results\1.json')

        # Ensure-MutEnvironment always re-checks the environment (Get-MutEnvironment, and
        # Start-MutEnvironment when not Running) even on a marker-skipped call -- see that
        # function's own docstring for why (priming the backend's module-scoped CLI-path state
        # regardless of which step a run resumes from). Everything else that does real work
        # must not run again. Asserted via the test's own $script:CallLog (cleared just before
        # this second call) rather than Pester's cumulative Should -Invoke counter, which counts
        # invocations across the whole It block (including the first call above).
        $script:CallLog | Should -Be @('Get-MutEnvironment') -Because "only the cheap environment re-check should run again once every other .done marker exists: $($script:CallLog -join ', ')"
    }

    It 'calls Remove-MutEnvironment when keepEnvironment is false' {
        $script:Config = New-MutRunTestConfig -WorkDir $script:WorkDir -KeepEnvironment $false

        Invoke-MutRunPipeline -Config $script:Config -RunNo 1 | Out-Null

        Should -Invoke -ModuleName Run Remove-MutEnvironment -Times 1
    }

    It 'uses the unpublish-test-app strategy: Unpublish-MutApp then Publish-MutAppFile then Publish-MutApp' {
        $script:Config = New-MutRunTestConfig -WorkDir $script:WorkDir -PublishStrategy 'unpublish-test-app'

        Invoke-MutRunPipeline -Config $script:Config -RunNo 1 | Out-Null

        Should -Invoke -ModuleName Run Unpublish-MutApp -Times 1
        Should -Invoke -ModuleName Run Publish-MutAppFile -Times 1
        # Publish-MutApp: core-app, aut-original, test-app (baseline) + test-app again (schemata republish) = 4
        Should -Invoke -ModuleName Run Publish-MutApp -Times 4
    }

    It 'Build-MutSchemataStep caches mutants as a plain JSON array, not the {value,Count} wrapper a ConvertFrom-Json-sourced array can produce when re-serialized (regression, T27 live-run fix)' {
        # Build-MutSchemata (Schemata.psm1) hands back .Mutants exactly as it came out of
        # `Get-Content mutants.json | ConvertFrom-Json` -- reproduced here with a real
        # ConvertFrom-Json call, not a plain array literal, because only an array that actually
        # came out of ConvertFrom-Json carries the hidden ETS members that make a later
        # ConvertTo-Json of it serialize as {"value":[...],"Count":N} once nested as a property
        # of another object; a literal `@(...)` array never reproduces the bug this guards.
        $mutantsJson = '[{"id":1,"stableKey":"k1","objectType":"codeunit","objectId":50200,"objectName":"X","procedure":"P","line":1,"operator":"REL","original":"a","mutated":"b","file":"f.al"},{"id":2,"stableKey":"k2","objectType":"codeunit","objectId":50200,"objectName":"X","procedure":"P","line":1,"operator":"COND","original":"a","mutated":"true","file":"f.al"}]'
        $mutantsFromJson = $mutantsJson | ConvertFrom-Json

        Mock -ModuleName Run Build-MutSchemata {
            [pscustomobject]@{
                SchemataPath    = "$script:WorkDir/gen/aut-schemata"
                AppFile         = "$script:WorkDir/gen/aut-schemata/Fake.app"
                Mutants         = $mutantsFromJson
                CompileErrorIds = @()
                ExcludedMutants = @()
                Iterations      = 1
                ExcludeFile     = $null
                RunNo           = 1
            }
        }

        $runDir = Join-Path $script:WorkDir 'runs/1'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        $result = Build-MutSchemataStep -Config $script:Config -Env $script:EnvHandle -RunDir $runDir -RunNo 1

        @($result.Mutants).Count | Should -Be 2
        $result.Mutants[0].objectId | Should -Be 50200
        $result.Mutants[1].objectId | Should -Be 50200

        $rawText = Get-Content -Path (Join-Path $runDir 'schemata.json') -Raw
        $rawText | Should -Not -Match '"value"\s*:\s*\['

        $reread = Get-Content -Path (Join-Path $runDir 'schemata.json') -Raw | ConvertFrom-Json
        @($reread.mutants).Count | Should -Be 2
        $reread.mutants[0].objectId | Should -Be 50200

        # The skip (second-call) path must reconstruct the same clean, iterable shape too.
        $second = Build-MutSchemataStep -Config $script:Config -Env $script:EnvHandle -RunDir $runDir -RunNo 1
        @($second.Mutants).Count | Should -Be 2
        $second.Mutants[0].objectId | Should -Be 50200
        $second.Mutants[1].objectId | Should -Be 50200
    }

    It 'Push-MutManifest skips a mutant whose stableKey already exists under a DIFFERENT id (regression, T27 live-run fix: the table''s unique index is on Stable Key, not just Id)' {
        Mock -ModuleName Run Invoke-MutApi {
            param($Env, $Method, $Path, $Body)
            $script:CallLog.Add("Invoke-MutApi:$Method`:$Path")
            if ($Method -eq 'GET' -and $Path -eq 'mutants') {
                # A row from an earlier run already exists under id=999 with the SAME stableKey
                # as the id=1 mutant this call is about to be given -- an earlier generator run
                # with different flags assigned this exact mutation a different id number.
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = 999; stableKey = 'shared-key-1' }) }
            }
            return $null
        }

        $runDir = Join-Path $script:WorkDir 'runs/1'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        $mutants = @(
            [pscustomobject]@{ id = 1; stableKey = 'shared-key-1'; objectId = 50200; procedure = 'P'; line = 1; operator = 'REL'; original = 'a'; mutated = 'b' }
            [pscustomobject]@{ id = 2; stableKey = 'unique-key-2'; objectId = 50200; procedure = 'P'; line = 1; operator = 'COND'; original = 'a'; mutated = 'true' }
        )

        Push-MutManifest -Env $script:EnvHandle -Mutants $mutants -RunNo 1 -RunDir $runDir

        Should -Invoke -ModuleName Run Invoke-MutApi -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'mutants' -and $Body.id -eq 1
        } -Times 0
        Should -Invoke -ModuleName Run Invoke-MutApi -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'mutants' -and $Body.id -eq 2 -and $Body.stableKey -eq 'unique-key-2'
        } -Times 1

        Test-Path (Join-Path $runDir 'manifest.done') | Should -Be $true
    }

    It 'aborts the whole run when the baseline test run has a failure, without building the schemata' {
        Mock -ModuleName Run Invoke-MutTests {
            $script:CallLog.Add('Invoke-MutTests')
            [pscustomobject]@{
                Passed = 0; Failed = 1; DurationMs = 100; JobIds = @()
                Tests  = @([pscustomobject]@{ Codeunit = 'MUT Fx Order Tests'; Function = 'Boom'; Result = 'Fail'; DurationMs = 100; Error = 'deliberate' })
            }
        }

        { Invoke-MutRunPipeline -Config $script:Config -RunNo 1 } | Should -Throw '*baseline*'

        Should -Invoke -ModuleName Run Build-MutSchemata -Times 0
        Should -Invoke -ModuleName Run Invoke-MutMutantLoop -Times 0

        $runDir = Join-Path $script:WorkDir 'runs/1'
        Test-Path (Join-Path $runDir 'baseline.done') | Should -Be $false
    }

    It 'aborts the whole run when the inactive-schemata rerun has a failure, without pushing the manifest or running the mutant loop' {
        $script:BaselineCallCount = 0
        Mock -ModuleName Run Invoke-MutTests {
            $script:BaselineCallCount++
            if ($script:BaselineCallCount -eq 1) {
                # baseline run: passes
                return [pscustomobject]@{
                    Passed = 1; Failed = 0; DurationMs = 100; JobIds = @('7')
                    Tests  = @([pscustomobject]@{ Codeunit = 'C'; Function = 'F'; Result = 'Pass'; DurationMs = 100; Error = $null })
                }
            }
            # inactive-schemata rerun: fails
            return [pscustomobject]@{
                Passed = 0; Failed = 1; DurationMs = 100; JobIds = @()
                Tests  = @([pscustomobject]@{ Codeunit = 'MUT Fx Order Tests'; Function = 'Boom'; Result = 'Fail'; DurationMs = 100; Error = 'deliberate inactive-schemata failure' })
            }
        }

        { Invoke-MutRunPipeline -Config $script:Config -RunNo 1 } | Should -Throw '*inactive-schemata*'

        Should -Invoke -ModuleName Run Invoke-MutApi -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'mutants' } -Times 0
        Should -Invoke -ModuleName Run Invoke-MutMutantLoop -Times 0

        $runDir = Join-Path $script:WorkDir 'runs/1'
        Test-Path (Join-Path $runDir 'publish-schemata.done') | Should -Be $false
        # baseline itself succeeded, so its own marker should still be there.
        Test-Path (Join-Path $runDir 'baseline.done') | Should -Be $true
    }

    It '-SkipBaseline with an existing baseline.json: does not call Publish-MutBaseline at all, and the pipeline still completes (T27 fix round 1, finding 1)' {
        $runDir = Join-Path $script:WorkDir 'runs/1'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        $baselineDoc = [pscustomobject]@{ tests = @(); durationsByCodeunit = @{ '50300' = 1000 } }
        ($baselineDoc | ConvertTo-Json -Depth 10) | Set-Content -Path (Join-Path $runDir 'baseline.json') -Encoding UTF8
        '{}' | Set-Content -Path (Join-Path $runDir 'coverage.json') -Encoding UTF8
        '{}' | Set-Content -Path (Join-Path $runDir 'references.json') -Encoding UTF8

        Mock -ModuleName Run Publish-MutBaseline { $script:CallLog.Add('Publish-MutBaseline'); throw 'must not be called' }

        $result = Invoke-MutRunPipeline -Config $script:Config -RunNo 1 -SkipBaseline

        Should -Invoke -ModuleName Run Publish-MutBaseline -Times 0
        $result.ResultsPath | Should -Not -BeNullOrEmpty
    }

    It '-SkipBaseline with no existing baseline.json: warns and runs Publish-MutBaseline normally, once (T27 fix round 1, finding 1)' {
        Mock -ModuleName Run Publish-MutBaseline {
            $script:CallLog.Add('Publish-MutBaseline')
            [pscustomobject]@{
                Baseline   = [pscustomobject]@{ Tests = @(); DurationsByCodeunit = @{} }
                Coverage   = [pscustomobject]@{ byTestCodeunit = @{} }
                References = @{}
            }
        }

        Invoke-MutRunPipeline -Config $script:Config -RunNo 1 -SkipBaseline -WarningAction SilentlyContinue | Out-Null

        Should -Invoke -ModuleName Run Publish-MutBaseline -Times 1
    }

    It 'Ensure-MutEnvironment throws when -SkipEnvironment is set and no environment exists' {
        Mock -ModuleName Run Get-MutEnvironment { $script:CallLog.Add('Get-MutEnvironment'); return $null }

        { Invoke-MutRunPipeline -Config $script:Config -RunNo 1 -SkipEnvironment } | Should -Throw '*SkipEnvironment*'

        Should -Invoke -ModuleName Run New-MutEnvironment -Times 0
    }

    It 'computes RunNo as 1 + the highest existing results/<n>.json when -RunNo is omitted' {
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $resultsDir = Join-Path $repoRoot 'results'
        $existedBefore = Test-Path $resultsDir
        if (-not $existedBefore) {
            New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
        }
        $probeFile = Join-Path $resultsDir '987654.json'
        '{}' | Set-Content -Path $probeFile -Encoding UTF8
        try {
            $init = Initialize-MutRun -Config $script:Config
            $init.RunNo | Should -Be 987655
        }
        finally {
            Remove-Item -Path $probeFile -Force -ErrorAction SilentlyContinue
            if (-not $existedBefore) {
                Remove-Item -Path $resultsDir -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Publish-MutBaseline error surfacing (M6)' {
    <#
        .SYNOPSIS
        Task M6: this defect cost three live investigations -- a publish/compile failure
        reported only "publishing failed. Diagnostics:" with an empty list, and the actual
        cause (the CLI's error.code / error message) had to be found by re-running the CLI by
        hand. Publish-MutApp now surfaces Code/ErrorMessage for both CLI response shapes
        (§6.5.3, F12); this test focuses on Publish-MutBaseline's own throw message actually
        including them, mocked at the Publish-MutApp boundary rather than through the whole
        Invoke-MutRunPipeline.
    #>
    BeforeEach {
        $script:WorkDir = "$TestDrive/work-$([guid]::NewGuid().ToString('N'))"
        $script:RunDir = Join-Path $script:WorkDir 'runs/1'
        New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
        $script:Config = New-MutRunTestConfig -WorkDir $script:WorkDir

        Mock -ModuleName Run Install-MutDependencies { }
    }

    It 'includes the CLI Code and ErrorMessage when publishing the core app fails' {
        Mock -ModuleName Run Publish-MutApp {
            [pscustomobject]@{
                Success      = $false
                Code         = 'symbol-fetch-failed'
                Diagnostics  = @()
                DurationSec  = 0.1
                ErrorMessage = 'dev-endpoint package failed validation (28.1.49838.50268)'
            }
        }

        { Publish-MutBaseline -Config $script:Config -Env $script:EnvHandle -RunDir $script:RunDir } |
            Should -Throw '*symbol-fetch-failed*dev-endpoint package failed validation*'
    }
}
