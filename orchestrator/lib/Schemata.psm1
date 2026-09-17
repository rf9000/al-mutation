Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo root is two levels above this module file (orchestrator/lib/Schemata.psm1).
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Cap on the compile-error elimination loop (§6.5.4 step 4): after this many generate+compile
# cycles without a clean compile, Build-MutSchemata throws.
$script:MaxIterations = 10

function Test-MutHasProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function ConvertTo-MutQuotedArgument {
    <#
        .SYNOPSIS
        Quotes one argument for a raw ProcessStartInfo.Arguments command-line string: wraps in
        double quotes only when the argument contains whitespace. Mirrors the backend module's
        own helper (no real argument this module passes -- absolute Windows paths, GUIDs, JSON
        numbers/flags -- ever contains a literal double quote).
    #>
    param([string]$Argument)

    if ($Argument -match '\s') {
        return '"' + $Argument + '"'
    }
    return $Argument
}

function Invoke-MutGenerator {
    <#
        .SYNOPSIS
        Private wrapper around the generator CLI (§6.4.9): runs
        `node <repoRoot>/generator/dist/src/cli.js <Arguments>`. This is the ONLY function in
        this module that may spawn the generator process, and the single Pester mock point for
        Build-MutSchemata's generate calls.

        Runs the process via System.Diagnostics.Process with ReadToEndAsync for stdout/stderr
        (not the `&` operator with `2>&1`, and not Register-ObjectEvent), for the same reasons
        documented on the backend module's own process-invocation helper: Windows PowerShell
        5.1 turns redirected native stderr into terminating errors under
        $ErrorActionPreference = 'Stop', and event-queue-based line capture has no ordering
        guarantee across rapid output.
        .OUTPUTS
        None. Throws (with stdout and stderr) when the process exits non-zero.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $cliJs = Join-Path $script:RepoRoot 'generator/dist/src/cli.js'
    $allArgs = @($cliJs) + $Arguments
    $quotedArgs = ($allArgs | ForEach-Object { ConvertTo-MutQuotedArgument $_ }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'node'
    $psi.Arguments = $quotedArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:RepoRoot

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stdout = ''
    $stderr = ''
    $exitCode = $null
    try {
        $null = $proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 30000) | Out-Null
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $proc.ExitCode
    }
    finally {
        $proc.Dispose()
    }

    if ($exitCode -ne 0) {
        throw "Invoke-MutGenerator: node $quotedArgs exited with code ${exitCode}. stdout: $stdout`nstderr: $stderr"
    }
}

function Get-MutBumpedAutVersion {
    <#
        .SYNOPSIS
        Increments the 4th (build) component of a `1.2.3.4`-shaped version string, per
        schemata.publishStrategy 'bump-build' (§6.5.1/§6.5.4 step 5).
    #>
    param([string]$Version)

    $parts = @($Version -split '\.')
    if ($parts.Count -ne 4) {
        throw "Get-MutBumpedAutVersion: version '$Version' does not have exactly 4 components."
    }
    $parts[3] = [string]([int]$parts[3] + 1)
    return ($parts -join '.')
}

function New-MutGeneratorArguments {
    <#
        .SYNOPSIS
        Builds the `generate` argument list from $Config.generator, $Config.coreApp and
        $Config.schemata.publishStrategy (§6.4.9, §6.5.1), for one --aut/--out pair. Comma-list
        flags (--only-objects, --operators) are omitted entirely when the underlying array is
        empty, rather than being passed as an empty string.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [string]$AutDir,
        [Parameter(Mandatory = $true)]
        [string]$OutDir,
        [string]$ExcludeFile
    )

    $arguments = @(
        'generate',
        '--aut', $AutDir,
        '--out', $OutDir,
        '--core-app-id', $Config.coreApp.appId,
        '--core-app-version', $Config.coreApp.version
    )

    if ($Config.schemata.publishStrategy -eq 'bump-build') {
        $arguments += @('--aut-version', (Get-MutBumpedAutVersion -Version $Config.aut.version))
    }

    $arguments += @('--max-mutants', [string]$Config.generator.maxMutants)
    $arguments += @('--seed', [string]$Config.generator.seed)

    $onlyObjects = @($Config.generator.onlyObjects)
    if ($onlyObjects.Count -gt 0) {
        $arguments += @('--only-objects', (($onlyObjects | ForEach-Object { [string]$_ }) -join ','))
    }

    $operators = @($Config.generator.operators)
    if ($operators.Count -gt 0) {
        $arguments += @('--operators', (($operators | ForEach-Object { [string]$_ }) -join ','))
    }

    if ($Config.generator.includeBreak) {
        $arguments += '--include-break'
    }

    if ($ExcludeFile) {
        $arguments += @('--exclude-stable-keys', $ExcludeFile)
    }

    return , $arguments
}

function New-MutSchemataRulesetJson {
    <#
        .SYNOPSIS
        Builds the JSON text (BOM-less UTF-8 target; the write itself happens in
        Write-MutSchemataRuleset) for the generated schemata ruleset (§6.5.4 step 4, §6.5.1).
        `name` is required by the AL ruleset loader (its absence is AL1033, "Required property
        'name' not found in JSON" -- live finding, fix round 1, 2026-09-17); `description` is
        conventional (mirrors F12's own ruleset, which has both). The ruleset includes the app's
        own configured ruleset by relative path (mirroring F12's
        `.cli-ruleset-localdeploy.json` -> `./.cli-ruleset.json` style) and downgrades to Info
        the two rules the generator's injected guard declarations (§6.4.7) would otherwise
        trip: AA0072 (the `MutationCore` name does not follow the type-suffix naming
        convention) and AA0137 (a `MutCond_<n>` declaration can be left unused once every
        mutant of its condition is excluded by the compile-error loop).
        .PARAMETER RulesetFileName
        The bare file name (e.g. `.cli-ruleset-localdeploy.json`) of the configured ruleset --
        this becomes `./<RulesetFileName>` in `includedRuleSets`.
    #>
    param([Parameter(Mandatory = $true)][string]$RulesetFileName)

    $ruleset = [pscustomobject]@{
        name             = 'Mutation schemata ruleset'
        description      = "Generated per run by Build-MutSchemata. Includes the app's local-deploy ruleset and downgrades analyzer rules that the generated guard code trips. The schemata app is generated, never shipped, and never read by humans."
        includedRuleSets = @(
            [pscustomobject]@{ action = 'Default'; path = "./$RulesetFileName" }
        )
        rules            = @(
            [pscustomobject]@{
                id            = 'AA0072'
                action        = 'Info'
                justification = 'The generated guard declaration MutationCore: Codeunit "MUT Mut" (SPEC 6.4.7) intentionally does not follow the type-suffix naming convention.'
            },
            [pscustomobject]@{
                id            = 'AA0137'
                action        = 'Info'
                justification = 'When the compile-error loop excludes every mutant of a condition, its MutCond_<n>: Boolean declaration can be left unused in the regenerated schemata; the app''s own code is unaffected because only the generated copy is compiled with this ruleset.'
            }
        )
    }
    return ($ruleset | ConvertTo-Json -Depth 10)
}

function Write-MutSchemataRuleset {
    <#
        .SYNOPSIS
        Writes `<rulesets dir>/.cli-ruleset-schemata.json` (BOM-less UTF-8) next to the
        configured ruleset file, so its `./<file>` relative include resolves exactly like the
        AUT's own `.cli-ruleset-localdeploy.json` does (F12). Regenerating on every run is
        deliberate (idempotent) rather than checking for an existing file first.
        .PARAMETER RulesetFile
        Full path to the configured ruleset (e.g. `<workDir>/rulesets/.cli-ruleset-localdeploy.json`).
        .OUTPUTS
        The full path to the generated schemata ruleset file.
    #>
    param([Parameter(Mandatory = $true)][string]$RulesetFile)

    $rulesetDir = Split-Path -Path $RulesetFile -Parent
    $rulesetFileName = Split-Path -Path $RulesetFile -Leaf
    $schemataRulesetFile = Join-Path $rulesetDir '.cli-ruleset-schemata.json'

    if (-not (Test-Path -Path $rulesetDir)) {
        New-Item -ItemType Directory -Path $rulesetDir -Force | Out-Null
    }

    $json = New-MutSchemataRulesetJson -RulesetFileName $rulesetFileName
    $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($schemataRulesetFile, $json, $noBomUtf8)

    return $schemataRulesetFile
}

function Get-MutLineMapEntries {
    <#
        .SYNOPSIS
        Looks up linemap.json[File] (§6.4.9), normalizing backslashes to forward slashes on
        both sides before comparing: the generator's relative-path keys and a compile
        diagnostic's File may use different separator conventions.
        .OUTPUTS
        [pscustomobject[]] of {mutantIds; startLine; endLine}; an empty array when File has no
        entry in LineMap at all.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $LineMap,
        [Parameter(Mandatory = $true)]
        [string]$File
    )

    $normalizedTarget = $File -replace '\\', '/'
    foreach ($property in $LineMap.PSObject.Properties) {
        $normalizedName = $property.Name -replace '\\', '/'
        if ($normalizedName -eq $normalizedTarget) {
            return , @($property.Value)
        }
    }
    return , @()
}

function Resolve-MutCompileErrorMutantIds {
    <#
        .SYNOPSIS
        Maps every diagnostic to the linemap.json block whose [startLine, endLine] contains
        its Line, matched within that Line's File. A diagnostic that maps to no block is FATAL
        (§6.5.4 step 4, "Diagnostics without a mapped block are fatal") -- this includes a
        diagnostic with no usable location at all (File null/empty, or Line null), NOT just one
        whose File/Line fail to match any block: a compiler-level error unrelated to any mutant
        guard (a bad app.json, a missing symbol package -- AL1003/AL1018/AL1022, say) has no
        File/Line to begin with, and letting it be silently skipped here would leave the
        exclusion set unchanged and spin the loop through the full iteration cap before
        throwing a generic, cause-less error (fix round 1, T25 review).
        .OUTPUTS
        [int[]] mutant ids (not de-duplicated across diagnostics; the caller de-duplicates).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Diagnostics,
        [Parameter(Mandatory = $true)]
        $LineMap
    )

    $ids = @()
    foreach ($diagnostic in $Diagnostics) {
        if ($null -eq $diagnostic) {
            continue
        }

        $hasLocation = (-not [string]::IsNullOrWhiteSpace([string]$diagnostic.File)) -and ($null -ne $diagnostic.Line)

        $block = $null
        if ($hasLocation) {
            $entries = Get-MutLineMapEntries -LineMap $LineMap -File $diagnostic.File
            foreach ($entry in $entries) {
                if ($diagnostic.Line -ge $entry.startLine -and $diagnostic.Line -le $entry.endLine) {
                    $block = $entry
                    break
                }
            }
        }

        if ($null -eq $block) {
            $location = 'no File/Line'
            if ($hasLocation) {
                $location = "'$($diagnostic.File):$($diagnostic.Line)'"
            }
            throw "Build-MutSchemata: compile diagnostic $($diagnostic.Code) at $location does not map to any mutant guard block in linemap.json ($($diagnostic.Message)); this compile error cannot be resolved by excluding mutants."
        }

        foreach ($id in @($block.mutantIds)) {
            $ids += [int]$id
        }
    }

    return , $ids
}

function Build-MutSchemata {
    <#
        .SYNOPSIS
        §6.5.4 step 4: runs the generator into `<RunDir>/gen`, then Compile-MutApp on
        `<RunDir>/gen/aut-schemata`. On a failed compile, every diagnostic's line is mapped
        through linemap.json to the mutant ids of its guard block; those ids are marked
        CompileError, their stableKeys (from the mutants.json of the iteration that produced
        them) are appended to `<RunDir>/gen/exclude.json`, and the generator is re-run with
        `--exclude-stable-keys` pointing at that file. Capped at 10 iterations, then throws.

        Compile-MutApp is called here as a plain, unqualified command -- this module never
        imports a backend module -- so whichever backend module the caller has imported into
        the session (per §6.5.3, every backend exports the same function names) is the one
        actually invoked. In unit tests, importing backends/DemoPortal.psm1 and then
        `Mock -ModuleName Schemata Compile-MutApp` intercepts that unqualified call from inside
        this module without this module ever referencing the backend by name.
        .OUTPUTS
        [pscustomobject]@{ SchemataPath; AppFile; Mutants; CompileErrorIds; Iterations;
        ExcludeFile; RunNo } -- ExcludeFile is $null when the first iteration compiled cleanly
        (no exclude.json was ever written); RunNo echoes the caller's $RunNo unchanged (T27
        threads it through the run's results).
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

    $autDir = Join-Path $Config.workDir 'aut-original'
    $genDir = Join-Path $RunDir 'gen'
    $schemataDir = Join-Path $genDir 'aut-schemata'
    $excludeFile = Join-Path $genDir 'exclude.json'

    $rulesetFile = $null
    if ((Test-MutHasProperty $Config 'rulesets') -and ($null -ne $Config.rulesets)) {
        $rulesetFile = Join-Path (Join-Path $Config.workDir 'rulesets') $Config.rulesets.file
    }

    # The schemata compile must never be gated by the AUT's own human-code style rules: the
    # generator's injected guard declarations (§6.4.7) do not follow them by design (live
    # finding, first Tier B run: AA0072 on `MutationCore`). Compile the generated copy under a
    # sibling ruleset that includes the configured one and downgrades just those rules to Info,
    # instead of the configured ruleset directly.
    $schemataRulesetFile = $null
    if ($rulesetFile) {
        $schemataRulesetFile = Write-MutSchemataRuleset -RulesetFile $rulesetFile
    }

    $compileErrorIds = @()
    $excludedStableKeys = @()
    $excludedMutants = @()
    $excludeFileWritten = $null
    $lastDiagnostics = @()

    for ($iteration = 1; $iteration -le $script:MaxIterations; $iteration++) {
        $excludeArg = $null
        if ($excludedStableKeys.Count -gt 0) {
            $excludeArg = $excludeFile
        }

        $arguments = New-MutGeneratorArguments -Config $Config -AutDir $autDir -OutDir $genDir -ExcludeFile $excludeArg
        Invoke-MutGenerator -Arguments $arguments

        # ConvertFrom-Json on a JSON array (even a single- or zero-element one) already returns a
        # proper System.Object[]; wrapping it again in @() would instead collect that one array
        # value into a further 1-element outer array (verified by direct experiment in this
        # task), so it is deliberately NOT re-wrapped here.
        $mutants = Get-Content -Path (Join-Path $genDir 'mutants.json') -Raw | ConvertFrom-Json
        $lineMap = Get-Content -Path (Join-Path $genDir 'linemap.json') -Raw | ConvertFrom-Json

        $compileParams = @{
            Env  = $Env
            Path = $schemataDir
        }
        if ($schemataRulesetFile) {
            $compileParams['Ruleset'] = $schemataRulesetFile
        }

        $compileResult = Compile-MutApp @compileParams
        $lastDiagnostics = @($compileResult.Diagnostics)

        if ($compileResult.Success) {
            return [pscustomobject]@{
                SchemataPath    = $schemataDir
                AppFile         = $compileResult.AppFile
                Mutants         = $mutants
                CompileErrorIds = $compileErrorIds
                ExcludedMutants = $excludedMutants
                Iterations      = $iteration
                ExcludeFile     = $excludeFileWritten
                RunNo           = $RunNo
            }
        }

        $newIds = Resolve-MutCompileErrorMutantIds -Diagnostics $lastDiagnostics -LineMap $lineMap
        $compileErrorIds = @($compileErrorIds) + @($newIds)

        foreach ($id in $newIds) {
            $mutant = $mutants | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if ($mutant) {
                $excludedStableKeys += $mutant.stableKey
                # Retained here (not just the stableKey) so the caller can still report this
                # mutant's own id/procedure/original/mutated/etc. in the final results export
                # (§7.3) even though it is about to be excluded from every later iteration's
                # mutants.json -- a compile-error mutant (e.g. every BREAK candidate,
                # §6.4.5/§8 acceptance item 2) never appears in the successful iteration's own
                # $mutants at all, so without this it would have no row to be marked
                # CompileError in at export time (T27, live run, 2026-09-09; docs/issues.md).
                $excludedMutants += $mutant
            }
        }
        $excludedStableKeys = @($excludedStableKeys | Select-Object -Unique)
        $excludedMutants = @($excludedMutants | Sort-Object -Property id -Unique)

        if (-not (Test-Path -Path $genDir)) {
            New-Item -ItemType Directory -Path $genDir -Force | Out-Null
        }
        [pscustomobject]@{ stableKeys = $excludedStableKeys } | ConvertTo-Json -Depth 10 | Set-Content -Path $excludeFile
        $excludeFileWritten = $excludeFile
    }

    $diagnosticsSummary = ($lastDiagnostics | Select-Object -First 10 | ForEach-Object { "$($_.Code): $($_.Message)" }) -join '; '
    throw "Build-MutSchemata: compile did not succeed within $script:MaxIterations iteration(s); last CompileErrorIds: $($compileErrorIds -join ', '); last compile diagnostics: $diagnosticsSummary"
}

Export-ModuleMember -Function Build-MutSchemata
