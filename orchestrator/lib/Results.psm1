Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Backend-agnostic: no CLI or container-tool names in this module (see spec §4 item 6).

# Mutant status strings used throughout results/<RunNo>.json and results.jsonl (§7.3).
$script:MutantStatuses = @('Pending', 'Killed', 'Survived', 'Equivalent', 'Timeout', 'CompileError', 'Uncovered', 'Error')

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
        to 4 decimal places. Returns 0 when the denominator is not positive.

        .PARAMETER Totals
        An object with .total, .killed, .timeout, .equivalent, .compileError (int-like
        properties; §7.3 totals shape).

        .OUTPUTS
        [double] rounded to 4 decimal places (0 when the denominator <= 0).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Totals
    )

    $denominator = [double]$Totals.total - [double]$Totals.equivalent - [double]$Totals.compileError
    if ($denominator -le 0) {
        return 0
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
        }
        elseif ($resultsById.ContainsKey($id)) {
            $result = $resultsById[$id]
            $status = $result.Status
            $killingTest = $result.KillingTest
            $durationMs = $result.DurationMs
            $coveringTests = @($result.CoveringTests)
        }
        else {
            $status = 'Pending'
            $killingTest = $null
            $durationMs = $null
            $coveringTests = @()
        }

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
        }
    }

    return , $rows
}

function Get-MutTotals {
    <#
        .SYNOPSIS
        Private. Tallies the §7.3 totals object from the merged mutant rows.
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
        Survivors table, Timeouts table, Compile errors table, Uncovered count.
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
        [Parameter(Mandatory = $true)]
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

    $lines += '## Totals'
    $lines += ''
    $lines += Format-MutMarkdownTableRow @('Total', 'Killed', 'Survived', 'Timeout', 'Compile error', 'Uncovered', 'Equivalent')
    $lines += Format-MutMarkdownTableRow @('---', '---', '---', '---', '---', '---', '---')
    $lines += Format-MutMarkdownTableRow @("$($Totals.total)", "$($Totals.killed)", "$($Totals.survived)", "$($Totals.timeout)", "$($Totals.compileError)", "$($Totals.uncovered)", "$($Totals.equivalent)")
    $lines += ''

    $lines += '## Score'
    $lines += ''
    $lines += "Score: **$Score**"
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

    $lines += '## Uncovered'
    $lines += ''
    $lines += "Uncovered: $($Totals.uncovered)"
    $lines += ''

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
        [int[]]$CompileErrorIds
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
        mutants         = $mergedRows
    }

    $resultsPath = Join-Path $OutDir "$RunNo.json"
    ($resultsObject | ConvertTo-Json -Depth 10) | Set-Content -Path $resultsPath -Encoding UTF8

    $wallClock = ''
    if (($StartedUtc -is [datetime]) -and ($FinishedUtc -is [datetime])) {
        $wallClock = [string]($FinishedUtc - $StartedUtc)
    }

    $summaryMarkdown = Get-MutSummaryMarkdown -RunNo $RunNo -Backend $Config.backend -EnvironmentName $Env.Name `
        -AutVersion $Config.aut.version -StartedUtc $startedUtcString -FinishedUtc $finishedUtcString `
        -WallClock $wallClock -Totals $totals -Score $score -MergedRows $mergedRows

    $summaryPath = Join-Path $OutDir "$RunNo-summary.md"
    $summaryMarkdown | Set-Content -Path $summaryPath -Encoding UTF8

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
