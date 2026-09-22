Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Backend-agnostic: no CLI or container-tool names in this module (see spec §4 item 6).

# Mutant status strings used throughout results/<RunNo>.json and results.jsonl (§7.3).
$script:MutantStatuses = @('Pending', 'Killed', 'Survived', 'Equivalent', 'Timeout', 'CompileError', 'Uncovered', 'Error')

function Assert-MutKnownStatus {
    <#
        .SYNOPSIS
        Private. Throws unless $Status is one of the §7.3 mutant status strings
        ($script:MutantStatuses). Guards against a typo'd or unrecognized status (most likely
        arriving via a mutant loop result row) silently ending up in the exported
        results/<RunNo>.json and summary.md.
    #>
    param(
        [string]$Status,
        [int]$MutantId
    )

    if ($script:MutantStatuses -notcontains $Status) {
        throw "Export-MutResults: mutant $MutantId has unknown status '$Status'. Expected one of: $($script:MutantStatuses -join ', ')."
    }
}

function Test-MutHasProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-MutScore {
    <#
        .SYNOPSIS
        §7.3 score formula: (killed + timeout) / (total - equivalent - compileError), rounded
        to 4 decimal places. Returns $null (serialized as JSON `null`, per the amended §7.3)
        when the denominator is not positive -- e.g. every mutant errored, or
        equivalent+compileError+error+pending together account for the whole run -- rather
        than 0. `0.0` and "no mutants could contribute a score" are different facts: the
        former reads as "the suite killed nothing" to anyone (or anything) reading
        results/<RunNo>.json, silently defeating the very reasoning documented below for
        excluding Error/Pending from the denominator in the first place. A human reading a
        Write-Warning can currently tell the difference; a machine parsing the JSON cannot.

        Error and Pending are ALSO excluded from the denominator, alongside Equivalent and
        CompileError: an `Error` mutant recorded an infrastructure failure (a timed-out API
        call, a dropped connection, an unexpected exception in the loop, §6.5.6) rather than any
        observation of whether the test suite would have caught the mutation, and a `Pending`
        mutant was never run at all. Counting either as a de-facto survivor -- which is what
        leaving them in the denominator while never reaching the numerator does -- scores every
        infrastructure hiccup as evidence the test suite is weak, which it is not: it is evidence
        the *run* was incomplete. Both are still counted and reported (Get-MutTotals,
        Get-MutSummaryMarkdown's Errors section) so an infrastructure failure is visible and can
        be retried or investigated; it is simply never treated as a killed/survived signal.

        .PARAMETER Totals
        An object with .total, .killed, .timeout, .equivalent, .compileError, .error, .pending
        (int-like properties; §7.3 totals shape plus the error/pending counts this task adds).

        .OUTPUTS
        [double], or $null when the denominator <= 0 (rounded to 4 decimal places otherwise).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Totals
    )

    $errorCount = 0
    if (Test-MutHasProperty $Totals 'error') {
        $errorCount = $Totals.error
    }
    $pendingCount = 0
    if (Test-MutHasProperty $Totals 'pending') {
        $pendingCount = $Totals.pending
    }

    $denominator = [double]$Totals.total - [double]$Totals.equivalent - [double]$Totals.compileError - [double]$errorCount - [double]$pendingCount
    if ($denominator -le 0) {
        return $null
    }

    $numerator = [double]$Totals.killed + [double]$Totals.timeout

    return [math]::Round($numerator / $denominator, 4)
}

function Get-MutMergedMutantRows {
    <#
        .SYNOPSIS
        Private. Merges mutants.json entries with the mutant loop's per-mutant results
        (§6.5.6's output shape) and the compile-error id list into one row per mutant, in the
        §7.3 `mutants[]` shape. A mutant present in $CompileErrorIds is always CompileError,
        regardless of whether it also has a $Results row (compile errors are decided before the
        loop ever runs, so it should not have one in practice). A mutant with no matching
        $Results row and not in $CompileErrorIds is left as Pending (should not normally occur
        at export time, but is a safe default rather than a thrown error).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Mutants,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [int[]]$CompileErrorIds
    )

    $resultsById = @{}
    foreach ($result in $Results) {
        $resultsById[[int]$result.Id] = $result
    }
    $compileErrorSet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($id in $CompileErrorIds) {
        [void]$compileErrorSet.Add([int]$id)
    }

    $rows = @()
    foreach ($mutant in $Mutants) {
        $id = [int]$mutant.id

        if ($compileErrorSet.Contains($id)) {
            $status = 'CompileError'
            $killingTest = $null
            $durationMs = $null
            $coveringTests = @()
            $reason = $null
        }
        elseif ($resultsById.ContainsKey($id)) {
            $result = $resultsById[$id]
            $status = $result.Status
            $killingTest = $result.KillingTest
            $durationMs = $result.DurationMs
            $coveringTests = @($result.CoveringTests)
            # §7.5 (amended): the Errors table must carry THE REASON an Error mutant's run
            # failed. Invoke-MutMutantLoop already attaches an `Error` property (the exception
            # message) to a row with Status 'Error' (MutantLoop.psm1); this was previously
            # discarded here before it could reach either results/<RunNo>.json or the summary.
            $reason = $null
            if (Test-MutHasProperty $result 'Error') {
                $reason = $result.Error
            }
        }
        else {
            $status = 'Pending'
            $killingTest = $null
            $durationMs = $null
            $coveringTests = @()
            $reason = $null
        }

        Assert-MutKnownStatus -Status $status -MutantId $id

        $rows += [pscustomobject]@{
            id            = $id
            stableKey     = $mutant.stableKey
            objectId      = $mutant.objectId
            procedure     = $mutant.procedure
            line          = $mutant.line
            operator      = $mutant.operator
            original      = $mutant.original
            mutated       = $mutant.mutated
            status        = $status
            killingTest   = $killingTest
            durationMs    = $durationMs
            coveringTests = $coveringTests
            reason        = $reason
        }
    }

    return , $rows
}

function Get-MutTotals {
    <#
        .SYNOPSIS
        Private. Tallies the §7.3 totals object from the merged mutant rows, plus `error` and
        `pending` counts (this task's addition to §7.3: without them, an `Error` mutant --
        produced by Invoke-MutMutantLoop on an infrastructure failure, §6.5.6 -- sat in the
        denominator, never reached the numerator, and appeared in no bucket at all, so the
        buckets did not sum to `total` and every infrastructure failure silently scored as a
        survivor). See Get-MutScore for why both are excluded from the score denominator.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$MergedRows
    )

    return [pscustomobject]@{
        total        = $MergedRows.Count
        killed       = @($MergedRows | Where-Object { $_.status -eq 'Killed' }).Count
        survived     = @($MergedRows | Where-Object { $_.status -eq 'Survived' }).Count
        timeout      = @($MergedRows | Where-Object { $_.status -eq 'Timeout' }).Count
        compileError = @($MergedRows | Where-Object { $_.status -eq 'CompileError' }).Count
        uncovered    = @($MergedRows | Where-Object { $_.status -eq 'Uncovered' }).Count
        equivalent   = @($MergedRows | Where-Object { $_.status -eq 'Equivalent' }).Count
        error        = @($MergedRows | Where-Object { $_.status -eq 'Error' }).Count
        pending      = @($MergedRows | Where-Object { $_.status -eq 'Pending' }).Count
    }
}

function ConvertTo-MutUtcString {
    param($Value)

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o')
    }
    return [string]$Value
}

function Format-MutMarkdownTableRow {
    param([string[]]$Cells)

    $escaped = $Cells | ForEach-Object {
        if ($null -eq $_) { '' } else { ($_ -replace '\|', '\|') }
    }
    return '| ' + ($escaped -join ' | ') + ' |'
}

function Get-MutSummaryMarkdown {
    <#
        .SYNOPSIS
        Private. Renders the §7.5 summary.md sections: header table, totals table, score,
        Survivors table, Timeouts table, Compile errors table, Errors table (with the reason,
        not the Survivors/Timeouts shape), Uncovered count, and a Pending count when any
        mutant was never reached.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [string]$Backend,
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,
        [Parameter(Mandatory = $true)]
        [string]$AutVersion,
        [Parameter(Mandatory = $true)]
        [string]$StartedUtc,
        [Parameter(Mandatory = $true)]
        [string]$FinishedUtc,
        [Parameter(Mandatory = $true)]
        [string]$WallClock,
        [Parameter(Mandatory = $true)]
        $Totals,
        # $null is a valid, meaningful value here (review fix round 1: Get-MutScore returns
        # $null, not 0, when the denominator is not positive) -- AllowNull so Mandatory binding
        # does not reject it.
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Score,
        [Parameter(Mandatory = $true)]
        [object[]]$MergedRows
    )

    $lines = @()

    $lines += '# Mutation run {0} summary' -f $RunNo
    $lines += ''
    $lines += '## Run'
    $lines += ''
    $lines += Format-MutMarkdownTableRow @('Metric', 'Value')
    $lines += Format-MutMarkdownTableRow @('---', '---')
    $lines += Format-MutMarkdownTableRow @('Run no', "$RunNo")
    $lines += Format-MutMarkdownTableRow @('Backend', $Backend)
    $lines += Format-MutMarkdownTableRow @('Environment', $EnvironmentName)
    $lines += Format-MutMarkdownTableRow @('AUT version', $AutVersion)
    $lines += Format-MutMarkdownTableRow @('Started (UTC)', $StartedUtc)
    $lines += Format-MutMarkdownTableRow @('Finished (UTC)', $FinishedUtc)
    $lines += Format-MutMarkdownTableRow @('Wall clock', $WallClock)
    $lines += ''

    $totalsError = 0
    if (Test-MutHasProperty $Totals 'error') {
        $totalsError = $Totals.error
    }
    $totalsPending = 0
    if (Test-MutHasProperty $Totals 'pending') {
        $totalsPending = $Totals.pending
    }

    $lines += '## Totals'
    $lines += ''
    $lines += Format-MutMarkdownTableRow @('Total', 'Killed', 'Survived', 'Timeout', 'Compile error', 'Uncovered', 'Equivalent', 'Error', 'Pending')
    $lines += Format-MutMarkdownTableRow @('---', '---', '---', '---', '---', '---', '---', '---', '---')
    $lines += Format-MutMarkdownTableRow @("$($Totals.total)", "$($Totals.killed)", "$($Totals.survived)", "$($Totals.timeout)", "$($Totals.compileError)", "$($Totals.uncovered)", "$($Totals.equivalent)", "$totalsError", "$totalsPending")
    $lines += ''

    $lines += '## Score'
    $lines += ''
    if ($null -eq $Score) {
        # Not "Score: ****" (Score interpolates to an empty string, and **<empty>** renders as
        # literal asterisks in GitHub markdown -- a rendering bug in the one artifact meant to
        # make a collapsed run legible at a glance). $null means the denominator was not
        # positive (Get-MutScore), i.e. no mutant could contribute a score at all.
        $lines += 'Score: _not computed (no mutant could contribute; see Errors)_'
    }
    else {
        $lines += "Score: **$Score**"
    }
    $lines += ''

    $lines += '## Survivors'
    $lines += ''
    $survivors = @($MergedRows | Where-Object { $_.status -eq 'Survived' })
    if ($survivors.Count -eq 0) {
        $lines += '_None._'
    }
    else {
        $lines += Format-MutMarkdownTableRow @('Id', 'Object', 'Procedure', 'Line', 'Operator', 'Original -> Mutated', 'Covering tests')
        $lines += Format-MutMarkdownTableRow @('---', '---', '---', '---', '---', '---', '---')
        foreach ($row in $survivors) {
            $lines += Format-MutMarkdownTableRow @(
                "$($row.id)", "$($row.objectId)", $row.procedure, "$($row.line)", $row.operator,
                "$($row.original) -> $($row.mutated)", (($row.coveringTests) -join ', ')
            )
        }
    }
    $lines += ''

    $lines += '## Timeouts'
    $lines += ''
    $timeouts = @($MergedRows | Where-Object { $_.status -eq 'Timeout' })
    if ($timeouts.Count -eq 0) {
        $lines += '_None._'
    }
    else {
        $lines += Format-MutMarkdownTableRow @('Id', 'Object', 'Procedure', 'Line', 'Operator', 'Original -> Mutated', 'Covering tests')
        $lines += Format-MutMarkdownTableRow @('---', '---', '---', '---', '---', '---', '---')
        foreach ($row in $timeouts) {
            $lines += Format-MutMarkdownTableRow @(
                "$($row.id)", "$($row.objectId)", $row.procedure, "$($row.line)", $row.operator,
                "$($row.original) -> $($row.mutated)", (($row.coveringTests) -join ', ')
            )
        }
    }
    $lines += ''

    $lines += '## Compile errors'
    $lines += ''
    $compileErrors = @($MergedRows | Where-Object { $_.status -eq 'CompileError' })
    if ($compileErrors.Count -eq 0) {
        $lines += '_None._'
    }
    else {
        $lines += Format-MutMarkdownTableRow @('Id', 'Object', 'Procedure', 'Line', 'Operator', 'Original -> Mutated')
        $lines += Format-MutMarkdownTableRow @('---', '---', '---', '---', '---', '---')
        foreach ($row in $compileErrors) {
            $lines += Format-MutMarkdownTableRow @(
                "$($row.id)", "$($row.objectId)", $row.procedure, "$($row.line)", $row.operator,
                "$($row.original) -> $($row.mutated)"
            )
        }
    }
    $lines += ''

    $lines += '## Errors'
    $lines += ''
    $errors = @($MergedRows | Where-Object { $_.status -eq 'Error' })
    if ($errors.Count -eq 0) {
        $lines += '_None._'
    }
    else {
        # Not the Survivors/Timeouts table's shape (Original -> Mutated, Covering tests): an
        # Error row is an infrastructure failure, not evidence about the mutation itself, so
        # what a reader needs here is WHERE it happened and WHY (§7.5, amended), not the mutation.
        $lines += Format-MutMarkdownTableRow @('Id', 'Object', 'Procedure', 'Line', 'Operator', 'Reason')
        $lines += Format-MutMarkdownTableRow @('---', '---', '---', '---', '---', '---')
        foreach ($row in $errors) {
            $reasonForReport = ''
            if (Test-MutHasProperty $row 'reason') {
                $reasonForReport = $row.reason
            }
            $lines += Format-MutMarkdownTableRow @(
                "$($row.id)", "$($row.objectId)", $row.procedure, "$($row.line)", $row.operator,
                $reasonForReport
            )
        }
    }
    $lines += ''

    $lines += '## Uncovered'
    $lines += ''
    $lines += "Uncovered: $($Totals.uncovered)"
    $lines += ''

    if ($totalsPending -gt 0) {
        # §7.5 (amended): "a Pending count when any mutant was never reached" -- rendered only
        # when it is non-zero, since a completed run has none and Pending is otherwise noise.
        $lines += '## Pending'
        $lines += ''
        $lines += "Pending: $totalsPending"
        $lines += ''
    }

    return ($lines -join "`r`n")
}

function Export-MutResults {
    <#
        .SYNOPSIS
        Merges mutants.json with the mutant loop's results and the compile-error id list, then
        writes <OutDir>/<RunNo>.json (§7.3) and <OutDir>/<RunNo>-summary.md (§7.5).

        .PARAMETER Mutants
        mutants.json entries (§7.1).

        .PARAMETER Results
        Invoke-MutMutantLoop's output: [{Id; Status; KillingTest; DurationMs; CoveringTests}].

        .PARAMETER CompileErrorIds
        Mutant ids marked CompileError before the loop ran (§6.5.4 step 4); always exported
        with status CompileError even if absent from $Results.

        .PARAMETER Partial
        FIX (F3c, F3b review "also worth doing"): set when Invoke-MutRunPipeline is exporting
        after the mutant loop aborted on its environment-recovery cap rather than completing
        (Run.psm1's Export-MutResultsStep -AllowPartial). Written into the results JSON as a
        top-level `aborted` boolean (always present, `false` on a normal completed run) -- before
        this, the only way to tell a partial export apart from a real one was `totals.pending
        -gt 0`, and a partial results/<RunNo>.json otherwise looked exactly like a genuine,
        low-scored run to anything scanning `results/` (including Get-MutNextRunNo, Run.psm1).

        .OUTPUTS
        [pscustomobject]@{ ResultsPath; SummaryPath }.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [object[]]$Mutants,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,
        [Parameter(Mandatory = $true)]
        [string]$OutDir,
        [Parameter(Mandatory = $true)]
        $StartedUtc,
        [Parameter(Mandatory = $true)]
        $FinishedUtc,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [int[]]$CompileErrorIds,
        [switch]$Partial
    )

    if (-not (Test-Path -Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $mergedRows = Get-MutMergedMutantRows -Mutants $Mutants -Results $Results -CompileErrorIds $CompileErrorIds
    $totals = Get-MutTotals -MergedRows $mergedRows
    $score = Get-MutScore -Totals $totals

    $startedUtcString = ConvertTo-MutUtcString $StartedUtc
    $finishedUtcString = ConvertTo-MutUtcString $FinishedUtc

    $resultsObject = [pscustomobject]@{
        runNo           = $RunNo
        backend         = $Config.backend
        environmentName = $Env.Name
        startedUtc      = $startedUtcString
        finishedUtc     = $finishedUtcString
        autAppId        = $Config.aut.appId
        autVersion      = $Config.aut.version
        coreAppVersion  = $Config.coreApp.version
        generator       = [pscustomobject]@{
            seed        = $Config.generator.seed
            maxMutants  = $Config.generator.maxMutants
            onlyObjects = @($Config.generator.onlyObjects)
            operators   = @($Config.generator.operators)
        }
        totals          = $totals
        score           = $score
        # FIX (F3c): always present (false on a normal completed run) so a consumer never has to
        # infer partial-ness from totals.pending -gt 0 -- an implicit, easy-to-miss signal that
        # only exists at all because Get-MutMergedMutantRows (below) happens to render an
        # unrun mutant as Pending.
        aborted         = [bool]$Partial
        mutants         = $mergedRows
    }

    # Set-Content -Encoding UTF8 emits a UTF-8 BOM (EF BB BF) under PS 5.1, which jq,
    # JSON.parse and Python all reject outright (ConvertFrom-Json tolerates it, which is why
    # every internal round-trip and Pester assertion previously passed anyway). Write both
    # files with the same BOM-less UTF-8 idiom already used at Schemata.psm1:231-232/261-262.
    $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)

    $resultsPath = Join-Path $OutDir "$RunNo.json"
    $resultsJson = $resultsObject | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($resultsPath, $resultsJson, $noBomUtf8)

    $wallClock = ''
    if (($StartedUtc -is [datetime]) -and ($FinishedUtc -is [datetime])) {
        $wallClock = [string]($FinishedUtc - $StartedUtc)
    }

    $summaryMarkdown = Get-MutSummaryMarkdown -RunNo $RunNo -Backend $Config.backend -EnvironmentName $Env.Name `
        -AutVersion $Config.aut.version -StartedUtc $startedUtcString -FinishedUtc $finishedUtcString `
        -WallClock $wallClock -Totals $totals -Score $score -MergedRows $mergedRows

    $summaryPath = Join-Path $OutDir "$RunNo-summary.md"
    [System.IO.File]::WriteAllText($summaryPath, $summaryMarkdown, $noBomUtf8)

    return [pscustomobject]@{ ResultsPath = $resultsPath; SummaryPath = $summaryPath }
}

function Get-MutExpectedMatchKey {
    <#
        .SYNOPSIS
        Private. Builds the (procedure, operator, mutated[, original for DEL]) match key
        (§7.4) as a single string, so a mutant row and an expected-results entry can be
        compared with one -eq.
    #>
    param($Entry)

    $mutated = ''
    if (Test-MutHasProperty $Entry 'mutated') {
        $mutated = [string]$Entry.mutated
    }

    $key = '{0}|{1}|{2}' -f [string]$Entry.procedure, [string]$Entry.operator, $mutated

    if ($Entry.operator -eq 'DEL' -and (Test-MutHasProperty $Entry 'original')) {
        $key += '|{0}' -f [string]$Entry.original
    }

    return $key
}

function Compare-MutExpectedResults {
    <#
        .SYNOPSIS
        Compares a written results/<RunNo>.json against fixtures/expected-results.json (§7.4).
        Matches on (procedure, operator, mutated) and, for DEL (mutated ''), also original.
        Tolerance: an expected status of 'Timeout' accepts an actual status of 'Killed' (not
        reported as a mismatch).

        .OUTPUTS
        [pscustomobject[]] {procedure; operator; mutated; expected; actual} for every entry
        that does not match (actual is $null when no mutant matches the key at all).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResultsPath,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath
    )

    $resultsDoc = Get-Content -Path $ResultsPath -Raw | ConvertFrom-Json
    $expectedList = Get-Content -Path $ExpectedPath -Raw | ConvertFrom-Json

    $mutantsByKey = @{}
    foreach ($mutant in @($resultsDoc.mutants)) {
        $mutantsByKey[(Get-MutExpectedMatchKey -Entry $mutant)] = $mutant
    }

    $mismatches = @()
    foreach ($expected in @($expectedList)) {
        $key = Get-MutExpectedMatchKey -Entry $expected

        $actual = $null
        if ($mutantsByKey.ContainsKey($key)) {
            $actual = $mutantsByKey[$key].status
        }

        if ($actual -eq $expected.expected) {
            continue
        }
        if ($expected.expected -eq 'Timeout' -and $actual -eq 'Killed') {
            continue
        }

        $mutatedForReport = ''
        if (Test-MutHasProperty $expected 'mutated') {
            $mutatedForReport = $expected.mutated
        }

        $mismatches += [pscustomobject]@{
            procedure = $expected.procedure
            operator  = $expected.operator
            mutated   = $mutatedForReport
            expected  = $expected.expected
            actual    = $actual
        }
    }

    return , $mismatches
}

Export-ModuleMember -Function Get-MutScore, Export-MutResults, Compare-MutExpectedResults
