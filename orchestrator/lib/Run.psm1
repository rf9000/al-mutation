<#
    .SYNOPSIS
    §6.5.4: the nine orchestrator run steps, composed from the other lib/*.psm1 modules, plus
    Invoke-MutRunPipeline which runs them in order. Backend-agnostic (§4 item 6): every backend
    function this module calls (Get-MutEnvironment, Start-MutEnvironment, New-MutEnvironment,
    Remove-MutEnvironment, Install-MutDependencies, Publish-MutApp, Publish-MutAppFile,
    Unpublish-MutApp, Grant-MutPermissionSet, Invoke-MutTests, Get-MutCoverage, Invoke-MutApi) is
    called as a plain, unqualified command -- this module never imports a backend module itself.
    The caller (Invoke-MutationRun.ps1, or a test importing a real or fake backend module first)
    is responsible for bringing those names into the session before calling any step here.

    Each step is idempotent per run number: it writes `<RunDir>/<step>.done` on success and, when
    that marker (and the artifact file(s) it guards) is already present, skips its own real work
    and reconstructs its return value from the previously-saved file(s) instead.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AutCopy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'References.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Coverage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Schemata.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MutantLoop.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Results.psm1') -Force

# A generous, fixed wall-clock budget (seconds) for the two whole-suite test runs this module
# makes directly (the baseline run, §6.5.4 step 3, and the inactive-schemata behaviour-preserving
# check, step 5). Unlike the per-mutant budget (§6.5.6, Get-MutTimeoutBudget in MutantLoop.psm1),
# these two runs are not on any wall-clock kill path of their own -- a slow but eventually-passing
# suite should not abort the run -- so a single generous constant is used rather than a formula.
$script:MutWholeSuiteTimeoutSec = 300

function Test-MutHasProperty {
    <#
        .SYNOPSIS
        Private. True when $Object is non-null and has a property named $Name. Every read of a
        possibly-absent JSON property in this module goes through this guard: under
        Set-StrictMode -Version Latest, a bare property access on a PSCustomObject that lacks it
        throws PropertyNotFoundException rather than returning $null (the same pitfall
        documented throughout DemoPortal.psm1/Config.psm1).
    #>
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Test-MutDoneMarker {
    <#
        .SYNOPSIS
        Private. True when both the step's `.done` marker and every one of its guarded artifact
        paths exist -- the idempotent-skip condition every step function checks first.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MarkerPath,
        [Parameter(Mandatory = $true)]
        [string[]]$ArtifactPaths
    )

    if (-not (Test-Path -Path $MarkerPath)) {
        return $false
    }
    foreach ($path in $ArtifactPaths) {
        if (-not (Test-Path -Path $path)) {
            return $false
        }
    }
    return $true
}

function Write-MutDoneMarker {
    <#
        .SYNOPSIS
        Private. Writes `<RunDir>/<Name>.done` with the current UTC timestamp as its content
        (content is informational only; presence is what every step checks).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MarkerPath
    )

    Set-Content -Path $MarkerPath -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8
}

function Get-MutJsonContent {
    <#
        .SYNOPSIS
        Private. Reads and parses one JSON file. NEVER wraps the ConvertFrom-Json call itself in
        `@(...)` -- see the identical warning in Schemata.psm1/DemoPortal.psm1: ConvertFrom-Json
        on a top-level JSON array already returns one System.Object[]; wrapping the pipeline in
        @() would collect that single array value into a further 1-element outer array. Callers
        that need array semantics wrap THIS function's return value in @(), which is a safe
        no-op on an already-materialized array.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

function Get-MutNextRunNo {
    <#
        .SYNOPSIS
        Private. 1 + the highest `<n>.json` under $ResultsDir (§6.5.4 step 1); 1 when the
        directory is absent or has no such file.
    #>
    param([Parameter(Mandatory = $true)][string]$ResultsDir)

    if (-not (Test-Path -Path $ResultsDir)) {
        return 1
    }

    $maxRunNo = 0
    foreach ($file in @(Get-ChildItem -Path $ResultsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($file.BaseName -match '^(\d+)$') {
            $candidate = [int]$Matches[1]
            if ($candidate -gt $maxRunNo) {
                $maxRunNo = $candidate
            }
        }
    }
    return $maxRunNo + 1
}

function ConvertTo-MutBaselineObject {
    <#
        .SYNOPSIS
        Private. Rebuilds the `@{ Tests; DurationsByCodeunit }` shape MutantLoop.psm1's
        Get-MutTimeoutBudget expects (a hashtable with .ContainsKey, keyed by "<codeunitId>")
        from baseline.json's parsed content (a PSCustomObject whose durationsByCodeunit is
        itself a PSCustomObject with one property per codeunit id after a JSON round trip).
    #>
    param($Raw)

    $durations = @{}
    if ((Test-MutHasProperty $Raw 'durationsByCodeunit') -and ($null -ne $Raw.durationsByCodeunit)) {
        foreach ($property in $Raw.durationsByCodeunit.PSObject.Properties) {
            $durations[$property.Name] = $property.Value
        }
    }

    $tests = @()
    if (Test-MutHasProperty $Raw 'tests') {
        $tests = @($Raw.tests)
    }

    return [pscustomobject]@{ Tests = $tests; DurationsByCodeunit = $durations }
}

function ConvertTo-MutCoverageObject {
    <#
        .SYNOPSIS
        Private. Rebuilds the `@{ byTestCodeunit = @{ '<id>' = <rows> } }` shape
        Coverage.psm1's Get-MutCoveringTests expects (byTestCodeunit needs .ContainsKey) from
        coverage.json's parsed content, which may be a bare `{}` (§6.5.4: "else {} and a
        warning") with no byTestCodeunit property at all.
    #>
    param($Raw)

    $byTestCodeunit = @{}
    if ((Test-MutHasProperty $Raw 'byTestCodeunit') -and ($null -ne $Raw.byTestCodeunit)) {
        foreach ($property in $Raw.byTestCodeunit.PSObject.Properties) {
            $byTestCodeunit[$property.Name] = @($property.Value)
        }
    }

    return [pscustomobject]@{ byTestCodeunit = $byTestCodeunit }
}

function ConvertTo-MutReferencesHashtable {
    <#
        .SYNOPSIS
        Private. Rebuilds the objectId -> int[] testCodeunitIds hashtable Coverage.psm1's
        Get-MutCoveringTests expects (it iterates $References.Keys, which a bare PSCustomObject
        from a JSON round trip does not have) from references.json's parsed content
        (Save-MutReferenceMap's `{ "<objectId>": [<testCodeunitId>, ...] }` shape).
    #>
    param($Raw)

    $map = @{}
    if ($null -ne $Raw) {
        foreach ($property in $Raw.PSObject.Properties) {
            $map[$property.Name] = [int[]]@($property.Value | ForEach-Object { [int]$_ })
        }
    }
    return $map
}

function Get-MutSkippedBaselineResult {
    <#
        .SYNOPSIS
        Private. FIX (T27 fix round 1, finding 1 -- task review): the fast path for
        -SkipBaseline, used only once the caller has already verified `baseline.json` exists
        under $RunDir. Returns the same `@{ Baseline; Coverage; References }` shape
        Publish-MutBaseline itself returns, without calling Publish-MutBaseline (and therefore
        without touching the environment at all) -- unlike Publish-MutBaseline's OWN
        marker-based skip (which additionally requires `baseline.done` AND coverage.json AND
        references.json all present), this only requires baseline.json itself, since that is
        the one artifact every later step actually needs and the one -SkipBaseline's caller
        already checked. `coverage.json`/`references.json` are read too when present (the same
        pass that writes baseline.json always writes them), each falling back to its own empty
        shape -- mirroring Publish-MutBaseline's own "no job ids" warning path -- rather than
        throwing, in case an earlier attempt crashed between writing baseline.json and the
        other two.
    #>
    param([Parameter(Mandatory = $true)][string]$RunDir)

    $baselinePath = Join-Path $RunDir 'baseline.json'
    $coveragePath = Join-Path $RunDir 'coverage.json'
    $referencesPath = Join-Path $RunDir 'references.json'

    $baseline = ConvertTo-MutBaselineObject -Raw (Get-MutJsonContent -Path $baselinePath)

    $coverage = [pscustomobject]@{ byTestCodeunit = @{} }
    if (Test-Path -Path $coveragePath) {
        $coverage = ConvertTo-MutCoverageObject -Raw (Get-MutJsonContent -Path $coveragePath)
    }

    $references = @{}
    if (Test-Path -Path $referencesPath) {
        $references = ConvertTo-MutReferencesHashtable -Raw (Get-MutJsonContent -Path $referencesPath)
    }

    return [pscustomobject]@{ Baseline = $baseline; Coverage = $coverage; References = $references }
}

function Initialize-MutRun {
    <#
        .SYNOPSIS
        §6.5.4 step 1. Computes RunNo (the caller's explicit value, or 1 + the highest
        `<n>.json` under the repo's results/ directory) and creates
        `<Config.workDir>/runs/<RunNo>/`.

        .PARAMETER RunNo
        Explicit run number. Omit (or pass 0) to auto-compute the next one.

        .OUTPUTS
        [pscustomobject]@{ Config; RunNo; RunDir }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [int]$RunNo = 0
    )

    $repoRoot = Get-MutRepoRoot
    $resultsDir = Join-Path $repoRoot 'results'

    $resolvedRunNo = $RunNo
    if ($resolvedRunNo -le 0) {
        $resolvedRunNo = Get-MutNextRunNo -ResultsDir $resultsDir
    }

    $runsDir = Join-Path $Config.workDir 'runs'
    $runDir = Join-Path $runsDir "$resolvedRunNo"
    if (-not (Test-Path -Path $runDir)) {
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    }

    $markerPath = Join-Path $runDir 'initialize.done'
    if (-not (Test-Path -Path $markerPath)) {
        Write-MutDoneMarker -MarkerPath $markerPath
    }

    return [pscustomobject]@{ Config = $Config; RunNo = $resolvedRunNo; RunDir = $runDir }
}

function Ensure-MutEnvironment {
    <#
        .SYNOPSIS
        §6.5.4 step 2. Get-MutEnvironment; if not found, New-MutEnvironment (throws first when
        -SkipEnvironment was requested), else Start-MutEnvironment (idempotent: a no-op poll
        confirmation when already Running). Then Sync-MutAutCopy. Persists the environment
        handle to `<RunDir>/environment.json` and writes `environment.done`; a second call for
        the same RunDir skips re-syncing the (potentially large) AUT copy, but always still
        performs the cheap Get-MutEnvironment (and Start-MutEnvironment when not Running) call.

        FIX (T27, live run, 2026-09-09 -- see docs/issues.md): the marker-skip path originally
        returned the CACHED handle straight from environment.json without calling any backend
        function at all. Several backend functions (e.g. Invoke-MutApi's own
        Get-MutApiBase/Get-MutCredential chain) depend on a module-scoped CLI-path variable that
        only Get-MutEnvironment/Start-MutEnvironment/etc. ever set, on the assumption that one of
        them always runs earlier in the same process -- true on a fresh run, but not on a run
        resumed at a LATER step (e.g. the mutant loop) for the same RunNo, where this was the
        first backend call of the whole process and crashed immediately. Always calling
        Get-MutEnvironment (and Start-MutEnvironment whenever an environment was found) here,
        marker or not, keeps that module-scoped state primed regardless of which step a run
        resumes from, and this is also just cheap re-verification of environment health rather
        than blindly trusting an on-disk cache written by a possibly much earlier attempt.

        FIX (F3, run 8, 2026-09-22 -- finding I6): this used to call Start-MutEnvironment only
        `elseif ($env.Status -ne 'Running')`. Both shipped configs set `keepEnvironment: true`,
        so every resumed/repeat run for the same environment took the already-Running branch and
        never confirmed the environment was actually serving -- exactly the gap that let 46
        mutants in a row silently report "no tests discovered" in run 8. Start-MutEnvironment is
        idempotent and (as of the same fix) always probes test-readiness regardless of whether a
        real `env start` was needed, so it is now called unconditionally whenever an environment
        was found, Running or not.

        .OUTPUTS
        The environment handle (§6.5.3 shape, plus whatever extra properties the backend adds).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [string]$RunDir,
        [switch]$SkipEnvironment
    )

    $markerPath = Join-Path $RunDir 'environment.done'
    $statePath = Join-Path $RunDir 'environment.json'

    $alreadyDone = Test-MutDoneMarker -MarkerPath $markerPath -ArtifactPaths @($statePath)

    $env = Get-MutEnvironment -Name $Config.environmentName -Config $Config
    if ($null -eq $env) {
        if ($SkipEnvironment) {
            throw "Ensure-MutEnvironment: environment '$($Config.environmentName)' was not found and -SkipEnvironment was specified."
        }
        $env = New-MutEnvironment -Name $Config.environmentName -Config $Config
    }
    else {
        # FIX (F3, I6): unconditional -- see this function's own FIX note above.
        $env = Start-MutEnvironment -Env $env -Config $Config
    }

    if ($alreadyDone) {
        return $env
    }

    Sync-MutAutCopy -Config $Config | Out-Null

    ($env | ConvertTo-Json -Depth 10) | Set-Content -Path $statePath -Encoding UTF8
    Write-MutDoneMarker -MarkerPath $markerPath

    return $env
}

function Publish-MutBaseline {
    <#
        .SYNOPSIS
        §6.5.4 step 3. Install-MutDependencies for aut-original and test-app (their response is
        never gated on -- "nothing to install" for a dependency-free app, e.g. the fixture AUT,
        is a normal outcome, not a failure); Publish-MutApp for Mutation Core, then aut-original,
        then test-app (ruleset only when $Config.rulesets is not null; -AllowDowngrade always);
        Grant-MutPermissionSet for every $Config.permissionSets entry; then, per test codeunit
        (so each codeunit's own test duration and coverage rows are unambiguous -- a single
        combined Invoke-MutTests call across codeunits would leave DurationMs and JobIds summed
        across all of them), Invoke-MutTests -Coverage.

        Aborts (throws, naming every failing test) if any codeunit has a failure. Saves
        `baseline.json` ({tests; durationsByCodeunit}), `coverage.json` (§7.2 byTestCodeunit;
        `{}` plus a warning when no job ids came back from any codeunit) and `references.json`
        (Get-MutReferenceMap / Save-MutReferenceMap, §6.5.5) under $RunDir.

        .OUTPUTS
        [pscustomobject]@{ Baseline; Coverage; References } -- Baseline/Coverage in the
        hashtable-backed shapes Coverage.psm1/MutantLoop.psm1 expect; References an objectId ->
        int[] hashtable.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$RunDir
    )

    $markerPath = Join-Path $RunDir 'baseline.done'
    $baselinePath = Join-Path $RunDir 'baseline.json'
    $coveragePath = Join-Path $RunDir 'coverage.json'
    $referencesPath = Join-Path $RunDir 'references.json'

    if (Test-MutDoneMarker -MarkerPath $markerPath -ArtifactPaths @($baselinePath, $coveragePath, $referencesPath)) {
        return [pscustomobject]@{
            Baseline   = ConvertTo-MutBaselineObject -Raw (Get-MutJsonContent -Path $baselinePath)
            Coverage   = ConvertTo-MutCoverageObject -Raw (Get-MutJsonContent -Path $coveragePath)
            References = ConvertTo-MutReferencesHashtable -Raw (Get-MutJsonContent -Path $referencesPath)
        }
    }

    $autPath = Join-Path $Config.workDir 'aut-original'
    $testAppPath = Join-Path $Config.workDir 'test-app'

    Install-MutDependencies -Env $Env -AppPath $autPath | Out-Null
    Install-MutDependencies -Env $Env -AppPath $testAppPath | Out-Null

    $rulesetFile = $null
    if ((Test-MutHasProperty $Config 'rulesets') -and ($null -ne $Config.rulesets)) {
        $rulesetFile = Join-Path (Join-Path $Config.workDir 'rulesets') $Config.rulesets.file
    }

    $coreResult = Publish-MutApp -Env $Env -Path $Config.coreApp.path -AllowDowngrade
    if (-not $coreResult.Success) {
        throw "Publish-MutBaseline: publishing Mutation Core (coreApp.path) failed. Code: $($coreResult.Code); Message: $($coreResult.ErrorMessage); Diagnostics: $(($coreResult.Diagnostics | ConvertTo-Json -Depth 10 -Compress))"
    }

    $autPublishParams = @{ Env = $Env; Path = $autPath; AllowDowngrade = $true }
    if ($rulesetFile) { $autPublishParams['Ruleset'] = $rulesetFile }
    $autResult = Publish-MutApp @autPublishParams
    if (-not $autResult.Success) {
        throw "Publish-MutBaseline: publishing aut-original failed. Code: $($autResult.Code); Message: $($autResult.ErrorMessage); Diagnostics: $(($autResult.Diagnostics | ConvertTo-Json -Depth 10 -Compress))"
    }

    $testAppPublishParams = @{ Env = $Env; Path = $testAppPath; AllowDowngrade = $true }
    if ($rulesetFile) { $testAppPublishParams['Ruleset'] = $rulesetFile }
    $testAppResult = Publish-MutApp @testAppPublishParams
    if (-not $testAppResult.Success) {
        throw "Publish-MutBaseline: publishing test-app failed. Code: $($testAppResult.Code); Message: $($testAppResult.ErrorMessage); Diagnostics: $(($testAppResult.Diagnostics | ConvertTo-Json -Depth 10 -Compress))"
    }

    foreach ($permissionSet in @($Config.permissionSets)) {
        Grant-MutPermissionSet -Env $Env -PermissionSetId $permissionSet.id -AppId $permissionSet.appId | Out-Null
    }

    $testCodeunits = @($Config.testApp.testCodeunits)
    $allTests = @()
    $durationsByCodeunit = @{}
    $jobIdsByCodeunit = @{}
    $failingTests = @()

    foreach ($codeunitId in $testCodeunits) {
        $target = @([pscustomobject]@{ CodeunitId = $codeunitId; Function = $null })
        $result = Invoke-MutTests -Env $Env -Targets $target -TimeoutSec $script:MutWholeSuiteTimeoutSec -Coverage

        if (($result.Passed + $result.Failed) -eq 0) {
            # A baseline run that reports zero passed AND zero failed tests is never a clean
            # success: it means the coverage run never actually exercised this codeunit (or its
            # result could not be read), and letting it through would zero out this codeunit's
            # duration (every mutant's timeout budget then collapses to timeouts.minSeconds),
            # produce empty coverage rows, and score every mutant reached through it on a
            # meaningless basis. Fail loudly instead of recording a clean 0/0 baseline.
            throw "Publish-MutBaseline: the baseline test run for codeunit $codeunitId reported zero tests (Passed=0, Failed=0); aborting rather than recording an empty baseline."
        }

        $allTests += @($result.Tests)
        $durationsByCodeunit["$codeunitId"] = $result.DurationMs
        $jobIdsByCodeunit["$codeunitId"] = @($result.JobIds)

        if ($result.Failed -gt 0) {
            foreach ($test in @($result.Tests | Where-Object { $_.Result -eq 'Fail' })) {
                $failingTests += "$($test.Codeunit):$($test.Function) -- $($test.Error)"
            }
        }
    }

    if ($failingTests.Count -gt 0) {
        throw "Publish-MutBaseline: the baseline test run had $($failingTests.Count) failing test(s); aborting (§6.5.4 step 3 must pass before the schemata can be built). Failures:`n$($failingTests -join "`n")"
    }

    $baselineDoc = [pscustomobject]@{ tests = $allTests; durationsByCodeunit = $durationsByCodeunit }
    ($baselineDoc | ConvertTo-Json -Depth 10) | Set-Content -Path $baselinePath -Encoding UTF8

    $anyJobIds = $false
    foreach ($codeunitId in $testCodeunits) {
        if (@($jobIdsByCodeunit["$codeunitId"]).Count -gt 0) {
            $anyJobIds = $true
        }
    }

    $byTestCodeunit = @{}
    if ($anyJobIds) {
        foreach ($codeunitId in $testCodeunits) {
            $jobIds = @($jobIdsByCodeunit["$codeunitId"])
            if ($jobIds.Count -gt 0) {
                $rows = Get-MutCoverage -Env $Env -JobIds $jobIds
                $byTestCodeunit["$codeunitId"] = @($rows)
            }
        }
        $coverageDoc = [pscustomobject]@{ byTestCodeunit = $byTestCodeunit }
        ($coverageDoc | ConvertTo-Json -Depth 10) | Set-Content -Path $coveragePath -Encoding UTF8
    }
    else {
        Write-Warning 'Publish-MutBaseline: no job ids were returned by any baseline test run; coverage.json is empty ({}). Covering-test selection will fall back to the static reference map for every mutant (§6.5.5).'
        '{}' | Set-Content -Path $coveragePath -Encoding UTF8
    }

    $references = Get-MutReferenceMap -AutPath $autPath -TestAppPath $testAppPath
    Save-MutReferenceMap -Map $references -Path $referencesPath

    Write-MutDoneMarker -MarkerPath $markerPath

    return [pscustomobject]@{
        Baseline   = [pscustomobject]@{ Tests = $allTests; DurationsByCodeunit = $durationsByCodeunit }
        Coverage   = [pscustomobject]@{ byTestCodeunit = $byTestCodeunit }
        References = $references
    }
}

function Build-MutSchemataStep {
    <#
        .SYNOPSIS
        §6.5.4 step 4. Thin, idempotent wrapper around Schemata.psm1's Build-MutSchemata: saves
        a `schemata.json` summary of its return value and writes `schemata.done`; a second call
        for the same RunDir reloads that summary instead of re-running the generator/compiler.

        .OUTPUTS
        [pscustomobject]@{ SchemataPath; AppFile; Mutants; CompileErrorIds; ExcludedMutants;
        Iterations; ExcludeFile; RunNo } -- the same shape Build-MutSchemata returns.
        ExcludedMutants carries the mutants.json-shaped records (§7.1) for every id in
        CompileErrorIds -- they never appear in Mutants itself (a compile-error mutant, e.g.
        every BREAK candidate, is excluded from every later generator iteration's own
        mutants.json), so a caller reporting every mutant in the final results (§7.3, including
        compile errors) needs both lists together.

        .OUTPUTS
        [pscustomobject]@{ SchemataPath; AppFile; Mutants; CompileErrorIds; ExcludedMutants;
        Iterations; ExcludeFile; RunNo } -- the same shape Build-MutSchemata returns.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$RunDir,
        [Parameter(Mandatory = $true)]
        [int]$RunNo
    )

    $markerPath = Join-Path $RunDir 'schemata.done'
    $summaryPath = Join-Path $RunDir 'schemata.json'

    if (Test-MutDoneMarker -MarkerPath $markerPath -ArtifactPaths @($summaryPath)) {
        $saved = Get-MutJsonContent -Path $summaryPath
        $compileErrorIds = [int[]]@($saved.compileErrorIds | ForEach-Object { [int]$_ })
        # Rebuilt via ForEach-Object, not a bare @() wrap -- see the note on
        # $plainMutants below: an array that came straight out of ConvertFrom-Json (as
        # $saved.mutants just did) carries hidden ETS members that make a LATER ConvertTo-Json
        # of it serialize as {"value":[...],"Count":N} instead of a plain array; piping it through
        # ForEach-Object rebuilds a plain System.Object[] with no such members attached.
        $mutants = @($saved.mutants | ForEach-Object { $_ })
        $excludedMutants = @()
        if (Test-MutHasProperty $saved 'excludedMutants') {
            $excludedMutants = @($saved.excludedMutants | ForEach-Object { $_ })
        }
        return [pscustomobject]@{
            SchemataPath    = $saved.schemataPath
            AppFile         = $saved.appFile
            Mutants         = $mutants
            CompileErrorIds = $compileErrorIds
            ExcludedMutants = $excludedMutants
            Iterations      = $saved.iterations
            ExcludeFile     = $saved.excludeFile
            RunNo           = $RunNo
        }
    }

    $result = Build-MutSchemata -Config $Config -Env $Env -RunDir $RunDir -RunNo $RunNo

    # FIX (T27, live run, 2026-09-09 -- see docs/issues.md): $result.Mutants (and, for the same
    # reason, $result.ExcludedMutants) is exactly the array Build-MutSchemata got back from
    # `Get-Content mutants.json | ConvertFrom-Json` (Schemata.psm1 deliberately does not re-wrap
    # it in @() for the reason noted there -- a single- or zero-element JSON array must not
    # collapse). That array, though, carries hidden ETS members (added by ConvertFrom-Json
    # itself) that make Windows PowerShell 5.1's ConvertTo-Json serialize it as
    # {"value":[...],"Count":N} instead of a plain JSON array the moment it is nested as a
    # property of ANOTHER object being converted (reproduced directly:
    # `[pscustomobject]@{ x = (ConvertFrom-Json '[{"a":1}]') } | ConvertTo-Json` alone already
    # exhibits this, with no summary/wrapper object of this module's own construction involved).
    # Piping through ForEach-Object rebuilds a plain System.Object[] with none of those members,
    # which serializes as a normal array; live evidence in docs/issues.md (this corrupted the
    # cached schemata.json on the first attempt at resuming a run from the mutant-loop step,
    # collapsing all 26 mutants into one malformed object on read-back).
    $plainMutants = @($result.Mutants | ForEach-Object { $_ })
    $plainExcludedMutants = @($result.ExcludedMutants | ForEach-Object { $_ })

    $summary = [pscustomobject]@{
        schemataPath    = $result.SchemataPath
        appFile         = $result.AppFile
        mutants         = $plainMutants
        compileErrorIds = $result.CompileErrorIds
        excludedMutants = $plainExcludedMutants
        iterations      = $result.Iterations
        excludeFile     = $result.ExcludeFile
    }
    ($summary | ConvertTo-Json -Depth 10) | Set-Content -Path $summaryPath -Encoding UTF8
    Write-MutDoneMarker -MarkerPath $markerPath

    return [pscustomobject]@{
        SchemataPath    = $result.SchemataPath
        AppFile         = $result.AppFile
        Mutants         = $plainMutants
        CompileErrorIds = $result.CompileErrorIds
        ExcludedMutants = $plainExcludedMutants
        Iterations      = $result.Iterations
        ExcludeFile     = $result.ExcludeFile
        RunNo           = $result.RunNo
    }
}

function Publish-MutSchemata {
    <#
        .SYNOPSIS
        §6.5.4 step 5. Publishes the schemata build per $Config.schemata.publishStrategy:
        'same-version' / 'bump-build' both simply Publish-MutAppFile the schemata .app (the
        generator already baked the version bump into the .app for 'bump-build');
        'unpublish-test-app' additionally Unpublish-MutApp's the test app first and
        Publish-MutApp's it back afterward. Then PATCHes `mutationSetup(0)` to
        `{ activeMutantId = 0; currentRunNo = RunNo }` and reruns Invoke-MutTests over
        $Config.testApp.testCodeunits. Aborts (throws) if that rerun has any failure -- the
        schemata must be behaviour-preserving while inactive (§6.5.4 step 5, §8 acceptance
        item 4).

        .OUTPUTS
        None (void). Writes `publish-schemata.done`; a second call for the same RunDir is a
        no-op.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Schemata,
        [Parameter(Mandatory = $true)]
        [string]$RunDir,
        [Parameter(Mandatory = $true)]
        [int]$RunNo
    )

    $markerPath = Join-Path $RunDir 'publish-schemata.done'
    if (Test-Path -Path $markerPath) {
        return
    }

    $strategy = $Config.schemata.publishStrategy

    if ($strategy -eq 'unpublish-test-app') {
        Unpublish-MutApp -Env $Env -AppId $Config.testApp.appId | Out-Null
    }

    if ($strategy -eq 'same-version' -or $strategy -eq 'bump-build' -or $strategy -eq 'unpublish-test-app') {
        $publishFileResult = Publish-MutAppFile -Env $Env -AppFile $Schemata.AppFile
        if (-not $publishFileResult.Success) {
            throw "Publish-MutSchemata: publishing the schemata app ($($Schemata.AppFile)) failed under publishStrategy '$strategy'. Code: $($publishFileResult.Code); Message: $($publishFileResult.ErrorMessage)"
        }
    }
    else {
        throw "Publish-MutSchemata: unknown schemata.publishStrategy '$strategy'."
    }

    if ($strategy -eq 'unpublish-test-app') {
        $testAppPath = Join-Path $Config.workDir 'test-app'
        $rulesetFile = $null
        if ((Test-MutHasProperty $Config 'rulesets') -and ($null -ne $Config.rulesets)) {
            $rulesetFile = Join-Path (Join-Path $Config.workDir 'rulesets') $Config.rulesets.file
        }
        $testAppPublishParams = @{ Env = $Env; Path = $testAppPath; AllowDowngrade = $true }
        if ($rulesetFile) { $testAppPublishParams['Ruleset'] = $rulesetFile }
        $testAppResult = Publish-MutApp @testAppPublishParams
        if (-not $testAppResult.Success) {
            throw "Publish-MutSchemata: republishing test-app after unpublish-test-app failed. Code: $($testAppResult.Code); Message: $($testAppResult.ErrorMessage); Diagnostics: $(($testAppResult.Diagnostics | ConvertTo-Json -Depth 10 -Compress))"
        }
    }

    Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 0; currentRunNo = $RunNo } | Out-Null

    $targets = @($Config.testApp.testCodeunits | ForEach-Object { [pscustomobject]@{ CodeunitId = $_; Function = $null } })
    $testResult = Invoke-MutTests -Env $Env -Targets $targets -TimeoutSec $script:MutWholeSuiteTimeoutSec

    if ($testResult.Failed -gt 0) {
        $failingTests = @($testResult.Tests | Where-Object { $_.Result -eq 'Fail' } | ForEach-Object { "$($_.Codeunit):$($_.Function) -- $($_.Error)" })
        throw "Publish-MutSchemata: the inactive-schemata test run had $($testResult.Failed) failing test(s); the schemata must be behaviour-preserving when inactive (§6.5.4 step 5). Aborting. Failures:`n$($failingTests -join "`n")"
    }

    Write-MutDoneMarker -MarkerPath $markerPath
}

function Push-MutManifest {
    <#
        .SYNOPSIS
        §6.5.4 step 6. PATCHes `mutationSetup(0)` `{ currentRunNo = RunNo }`; GETs `mutants`
        once and POSTs every mutant not already present -- by id OR by stableKey. Fields per
        §6.1.7: id, stableKey, objectType ('Codeunit', capitalised, to match the table's option
        value -- v1 only ever mutates codeunits), objectId, procedureName, lineNo, operator,
        originalText/mutatedText (truncated to 250 characters), status 'Pending'.

        FIX (T27, live run, 2026-09-09 -- see docs/issues.md): originally skipped a mutant only
        when its id already existed in the table. The generator's id numbering is positional
        within ONE generate() call (§6.4.8) and can shift entirely when its flags change (e.g.
        adding BREAK candidates), even though many individual mutations are semantically
        unchanged and so keep the SAME stableKey (deterministic from mutation content, not id)
        across runs. Live evidence: a run with a different generator config than an earlier run
        against the same environment hit the table's own unique index on Stable Key
        (`Internal_EntityWithSameKeyExists`) trying to POST a mutant under a new id whose
        stableKey an earlier run had already registered under a different id -- an unhandled,
        run-ending error. Now skips a mutant already present by EITHER key, matching the table's
        actual uniqueness constraint.

        .OUTPUTS
        None (void). Writes `manifest.done`; a second call for the same RunDir is a no-op.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [object[]]$Mutants,
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [string]$RunDir
    )

    $markerPath = Join-Path $RunDir 'manifest.done'
    if (Test-Path -Path $markerPath) {
        return
    }

    Invoke-MutApi -Env $Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ currentRunNo = $RunNo } | Out-Null

    $existing = Invoke-MutApi -Env $Env -Method 'GET' -Path 'mutants'
    $existingIds = New-Object System.Collections.Generic.HashSet[int]
    $existingStableKeys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($existingMutant in @($existing.value)) {
        [void]$existingIds.Add([int]$existingMutant.id)
        if (Test-MutHasProperty $existingMutant 'stableKey') {
            [void]$existingStableKeys.Add([string]$existingMutant.stableKey)
        }
    }

    foreach ($mutant in $Mutants) {
        $id = [int]$mutant.id
        if ($existingIds.Contains($id) -or $existingStableKeys.Contains([string]$mutant.stableKey)) {
            continue
        }

        $originalText = [string]$mutant.original
        if ($originalText.Length -gt 250) {
            $originalText = $originalText.Substring(0, 250)
        }
        $mutatedText = [string]$mutant.mutated
        if ($mutatedText.Length -gt 250) {
            $mutatedText = $mutatedText.Substring(0, 250)
        }

        $body = @{
            id            = $id
            stableKey     = $mutant.stableKey
            objectType    = 'Codeunit'
            objectId      = $mutant.objectId
            procedureName = $mutant.procedure
            lineNo        = $mutant.line
            operator      = $mutant.operator
            originalText  = $originalText
            mutatedText   = $mutatedText
            status        = 'Pending'
        }
        Invoke-MutApi -Env $Env -Method 'POST' -Path 'mutants' -Body $body | Out-Null
    }

    Write-MutDoneMarker -MarkerPath $markerPath
}

function Get-MutCoveringTestsStep {
    <#
        .SYNOPSIS
        §6.5.4 step 7. Precomputes and saves `covering.json` (mutant id -> covering test
        codeunit ids, via Coverage.psm1's Get-MutCoveringTests) as an audit artifact. Does NOT
        filter $Mutants -- a mutant with no covering test still reaches the mutant loop, which
        itself records it as `Uncovered` without running (§6.5.6, MutantLoop.psm1).

        .OUTPUTS
        [ordered] hashtable "<mutantId>" -> int[] covering test codeunit ids.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [object[]]$Mutants,
        [Parameter(Mandatory = $true)]
        $Coverage,
        [Parameter(Mandatory = $true)]
        $References,
        [Parameter(Mandatory = $true)]
        [string]$RunDir
    )

    $markerPath = Join-Path $RunDir 'covering.done'
    $coveringPath = Join-Path $RunDir 'covering.json'

    if (Test-MutDoneMarker -MarkerPath $markerPath -ArtifactPaths @($coveringPath)) {
        $saved = Get-MutJsonContent -Path $coveringPath
        $map = [ordered]@{}
        if ($null -ne $saved) {
            foreach ($property in $saved.PSObject.Properties) {
                $map[$property.Name] = [int[]]@($property.Value)
            }
        }
        return $map
    }

    $testCodeunits = [int[]]@($Config.testApp.testCodeunits)
    $map = [ordered]@{}
    foreach ($mutant in $Mutants) {
        $covering = Get-MutCoveringTests -Mutant $mutant -Coverage $Coverage -References $References -TestCodeunits $testCodeunits
        $map["$([int]$mutant.id)"] = [int[]]@($covering)
    }

    ($map | ConvertTo-Json -Depth 10) | Set-Content -Path $coveringPath -Encoding UTF8
    Write-MutDoneMarker -MarkerPath $markerPath

    return $map
}

function Invoke-MutMutantLoopStep {
    <#
        .SYNOPSIS
        §6.5.4 step 8. Thin, idempotent wrapper around MutantLoop.psm1's Invoke-MutMutantLoop.
        A second call for the same RunDir reloads the saved rows instead of re-running the loop
        (the loop itself is also independently crash-safe via `results.jsonl`, §6.5.6 step 4,
        but that file is intended for post-mortem recovery/audit, not as this step's own
        skip-source -- `loop-results.json` is written only once the whole loop has completed).

        .OUTPUTS
        [pscustomobject[]] rows, the same shape Invoke-MutMutantLoop returns: {Id; Status;
        KillingTest; DurationMs; CoveringTests}.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [object[]]$Mutants,
        [Parameter(Mandatory = $true)]
        $Baseline,
        [Parameter(Mandatory = $true)]
        $Coverage,
        [Parameter(Mandatory = $true)]
        $References,
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [string]$RunDir,
        [Parameter(Mandatory = $true)]
        [string]$BackendModulePath
    )

    $markerPath = Join-Path $RunDir 'mutant-loop.done'
    $loopResultsPath = Join-Path $RunDir 'loop-results.json'

    if (Test-MutDoneMarker -MarkerPath $markerPath -ArtifactPaths @($loopResultsPath)) {
        $saved = Get-MutJsonContent -Path $loopResultsPath
        return @($saved)
    }

    $rows = Invoke-MutMutantLoop -Config $Config -Env $Env -Mutants $Mutants -Baseline $Baseline `
        -Coverage $Coverage -References $References -RunNo $RunNo -RunDir $RunDir -BackendModulePath $BackendModulePath

    (@($rows) | ConvertTo-Json -Depth 10) | Set-Content -Path $loopResultsPath -Encoding UTF8
    Write-MutDoneMarker -MarkerPath $markerPath

    return @($rows)
}

function Export-MutResultsStep {
    <#
        .SYNOPSIS
        §6.5.4 step 9. Export-MutResults into the repo's `results/` directory, then
        Remove-MutEnvironment unless $Config.keepEnvironment.

        .OUTPUTS
        [pscustomobject]@{ ResultsPath; SummaryPath } (Export-MutResults' own return shape).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [object[]]$Mutants,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [int[]]$CompileErrorIds,
        [Parameter(Mandatory = $true)]
        $StartedUtc,
        [Parameter(Mandatory = $true)]
        $FinishedUtc,
        [Parameter(Mandatory = $true)]
        [string]$RunDir
    )

    $markerPath = Join-Path $RunDir 'export.done'
    $repoRoot = Get-MutRepoRoot
    $outDir = Join-Path $repoRoot 'results'

    if (Test-Path -Path $markerPath) {
        return [pscustomobject]@{
            ResultsPath = Join-Path $outDir "$RunNo.json"
            SummaryPath = Join-Path $outDir "$RunNo-summary.md"
        }
    }

    $paths = Export-MutResults -RunNo $RunNo -Config $Config -Env $Env -Mutants $Mutants -Results $Results `
        -OutDir $outDir -StartedUtc $StartedUtc -FinishedUtc $FinishedUtc -CompileErrorIds $CompileErrorIds

    if (-not $Config.keepEnvironment) {
        Remove-MutEnvironment -Env $Env -Config $Config
    }

    Write-MutDoneMarker -MarkerPath $markerPath

    return $paths
}

function Invoke-MutRunPipeline {
    <#
        .SYNOPSIS
        Runs the nine §6.5.4 steps in order for one run. The caller (Invoke-MutationRun.ps1, or
        a test) is responsible for having already imported the backend module named by
        $Config.backend into the session -- this module never does so itself (§4 item 6): the
        backend module's path is only ever used as data (passed to Invoke-MutMutantLoopStep's
        -BackendModulePath, for its own Start-Job wrapper to import in a separate runspace).

        .PARAMETER SkipBaseline
        FIX (T27 fix round 1, finding 1 -- task review: the earlier implementation of this
        switch only controlled a warning and Publish-MutBaseline was ALWAYS called, making the
        switch inert). Per §6.5.4/T27: when set AND `<RunDir>/baseline.json` already exists,
        Publish-MutBaseline is never called at all -- the baseline/coverage/references are
        loaded straight from RunDir instead (Get-MutSkippedBaselineResult), since later steps
        need them. When set and baseline.json does NOT exist yet, Write-Warning and run the
        baseline step normally (same as omitting the switch).

        .OUTPUTS
        [pscustomobject]@{ ResultsPath; SummaryPath }.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [int]$RunNo = 0,
        [switch]$SkipEnvironment,
        [switch]$SkipBaseline
    )

    $startedUtc = [datetime]::UtcNow

    $init = Initialize-MutRun -Config $Config -RunNo $RunNo
    $runNo = $init.RunNo
    $runDir = $init.RunDir

    $repoRoot = Get-MutRepoRoot
    $backendModulePath = Join-Path $repoRoot "orchestrator\backends\$($Config.backend).psm1"

    $env = Ensure-MutEnvironment -Config $Config -RunDir $runDir -SkipEnvironment:$SkipEnvironment

    $baselinePath = Join-Path $runDir 'baseline.json'
    if ($SkipBaseline -and (Test-Path -Path $baselinePath)) {
        $baselineResult = Get-MutSkippedBaselineResult -RunDir $runDir
    }
    else {
        if ($SkipBaseline) {
            Write-Warning "Invoke-MutRunPipeline: -SkipBaseline was specified but '$baselinePath' does not exist yet; running the baseline step normally."
        }
        $baselineResult = Publish-MutBaseline -Config $Config -Env $env -RunDir $runDir
    }

    $schemata = Build-MutSchemataStep -Config $Config -Env $env -RunDir $runDir -RunNo $runNo

    Publish-MutSchemata -Config $Config -Env $env -Schemata $schemata -RunDir $runDir -RunNo $runNo

    Push-MutManifest -Env $env -Mutants $schemata.Mutants -RunNo $runNo -RunDir $runDir

    Get-MutCoveringTestsStep -Config $Config -Mutants $schemata.Mutants -Coverage $baselineResult.Coverage `
        -References $baselineResult.References -RunDir $runDir | Out-Null

    $loopResults = Invoke-MutMutantLoopStep -Config $Config -Env $env -Mutants $schemata.Mutants `
        -Baseline $baselineResult.Baseline -Coverage $baselineResult.Coverage -References $baselineResult.References `
        -RunNo $runNo -RunDir $runDir -BackendModulePath $backendModulePath

    $finishedUtc = [datetime]::UtcNow

    # Compile-error mutants (e.g. every BREAK candidate, §8 acceptance item 2) never appear in
    # $schemata.Mutants -- they are excluded from every generator iteration after the one that
    # first hit them (§6.5.4 step 4) -- so the final export's mutant list is the union of the
    # ones that were actually manifested/looped and the ones excluded for a compile error, or a
    # BREAK/compile-error mutant would have no row at all in results/<RunNo>.json to be marked
    # CompileError in (T27, live run, 2026-09-09; docs/issues.md).
    $allMutantsForExport = @($schemata.Mutants) + @($schemata.ExcludedMutants)

    $exportResult = Export-MutResultsStep -Config $Config -Env $env -RunNo $runNo -Mutants $allMutantsForExport `
        -Results @($loopResults) -CompileErrorIds $schemata.CompileErrorIds -StartedUtc $startedUtc `
        -FinishedUtc $finishedUtc -RunDir $runDir

    return $exportResult
}

Export-ModuleMember -Function Initialize-MutRun, Ensure-MutEnvironment, Publish-MutBaseline, Build-MutSchemataStep, `
    Publish-MutSchemata, Push-MutManifest, Get-MutCoveringTestsStep, Invoke-MutMutantLoopStep, Export-MutResultsStep, `
    Invoke-MutRunPipeline
