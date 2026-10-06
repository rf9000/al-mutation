Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# §6.7.2 stage 1: deterministic fix briefs for the Survived mutants of a run. Read-only on the
# AUT copy and test-app snapshot under <workDir>; writes only results/<N>-fix-briefs.json.
# Stage 3 (§6.7.4) validates and renders results/<N>-fixes.json: Test-MutFixReport and
# Export-MutFixMarkdown.

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'References.psm1') -Force

$script:OperatorHints = @{
    'REL'     = 'A relational operator was changed. Kill it with a test whose input sits exactly on the boundary of the comparison (equal values, zero, empty string), and assert the outcome that differs between the original and the mutated operator.'
    'BOOL'    = 'and/or was swapped. Kill it with a test where exactly one of the operands is true, and assert the outcome that differs.'
    'NOT'     = 'A not was added or removed, so the branch inverts. Assert the observable effect of the branch for an input that takes it (returned value, record written, error raised).'
    'COND'    = 'The condition was forced to a constant. Add a test where the condition evaluates to the other value, and assert the effect of the branch it guards.'
    'DEL'     = 'A statement was deleted. Assert the effect of that statement: the field value it set, the record it inserted, modified or deleted, the error it raised, or the value it returned.'
    'INSFLAG' = 'A flag argument was inverted (e.g. Insert(true) to Insert(false)). Assert the side effect the flag controls, such as trigger logic run by the call.'
    'BREAK'   = 'A break was inserted. Assert the result of loop iterations after the first one.'
}

function Get-MutOperatorHint {
    <#
        .SYNOPSIS
        §6.7.2. The fixed, verbatim guidance text for one mutation operator. Throws
        `Unknown operator '<op>'` for anything outside the seven operators.
    #>
    param([Parameter(Mandatory = $true)][string]$Operator)

    if (-not $script:OperatorHints.ContainsKey($Operator)) {
        throw "Unknown operator '$Operator'"
    }
    return [string]$script:OperatorHints[$Operator]
}

function Get-MutFixBriefSourceLines {
    <#
        .SYNOPSIS
        Private. The lines of an AUT file (BOM-less UTF-8 safe), or $null when it is missing.
        ReadAllLines drops a trailing newline's empty element and handles CRLF, so no `\r`
        survives into a context line.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return , [string[]][System.IO.File]::ReadAllLines($full)
}

function New-MutFixBriefs {
    <#
        .SYNOPSIS
        §6.7.2. Builds the §7.7 brief object (runNo, generatedUtc, survivors); the caller adds the
        path fields. -Mutants are §7.1 entries, -Results the parsed results/<N>.json (§7.3),
        -TestIndex the Get-MutTestProcedureIndex output. Only Survived rows are emitted, sorted
        by id.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$RunNo,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Mutants,
        [Parameter(Mandatory = $true)]$Results,
        [Parameter(Mandatory = $true)][string]$AutPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TestIndex,
        [int]$ContextLines = 15
    )

    $mutantById = @{}
    foreach ($mutant in @($Mutants)) {
        $mutantById[[int]$mutant.id] = $mutant
    }
    $indexById = @{}
    foreach ($entry in @($TestIndex)) {
        $indexById[[int]$entry.CodeunitId] = $entry
    }

    $survivorRows = @(@($Results.mutants) | Where-Object { $_.status -eq 'Survived' } | Sort-Object -Property { [int]$_.id })

    $survivors = @()
    foreach ($row in $survivorRows) {
        $id = [int]$row.id
        if (-not $mutantById.ContainsKey($id)) {
            throw "Survivor $id missing from mutants.json"
        }
        $mutant = $mutantById[$id]
        $line = [int]$mutant.line
        $original = [string]$mutant.original

        $sourceLines = Get-MutFixBriefSourceLines -Path (Join-Path $AutPath $mutant.file)

        $resolvedLine = $null
        $sourceDrift = $true
        $context = $null
        if ($null -ne $sourceLines -and @($sourceLines).Count -gt 0) {
            $sourceLines = @($sourceLines)
            $lineCount = $sourceLines.Count

            if ($line -ge 1 -and $line -le $lineCount -and $sourceLines[$line - 1].Contains($original)) {
                $resolvedLine = $line
                $sourceDrift = $false
            }
            else {
                $hits = @()
                for ($n = 1; $n -le $lineCount; $n++) {
                    if ($sourceLines[$n - 1].Contains($original)) {
                        $hits += $n
                    }
                }
                if ($hits.Count -eq 1) {
                    $resolvedLine = $hits[0]
                }
            }

            $centre = [Math]::Min($line, $lineCount)
            if ($null -ne $resolvedLine) {
                $centre = $resolvedLine
            }
            $startLine = [Math]::Max(1, $centre - $ContextLines)
            $endLine = [Math]::Min($lineCount, $centre + $ContextLines)
            if ($startLine -gt $endLine) {
                $startLine = $endLine
            }

            $rendered = @()
            for ($n = $startLine; $n -le $endLine; $n++) {
                $marker = ' '
                if ($n -eq $centre) {
                    $marker = '>'
                }
                $rendered += ('{0}{1,5}: {2}' -f $marker, $n, $sourceLines[$n - 1])
            }
            $context = [pscustomobject]@{
                startLine = $startLine
                endLine   = $endLine
                text      = ($rendered -join "`n")
            }
        }

        $covering = @()
        foreach ($testId in @($row.coveringTests)) {
            $testId = [int]$testId
            if ($indexById.ContainsKey($testId)) {
                $entry = $indexById[$testId]
                $procedures = @()
                foreach ($procedure in @($entry.Procedures)) {
                    $procedures += [pscustomobject]@{
                        name      = $procedure.Name
                        startLine = $procedure.StartLine
                        endLine   = $procedure.EndLine
                    }
                }
                $covering += [pscustomobject]@{
                    codeunitId   = $testId
                    codeunitName = $entry.CodeunitName
                    file         = $entry.File
                    procedures   = $procedures
                }
            }
            else {
                Write-Warning "New-MutFixBriefs: covering test codeunit $testId of survivor $id is not in the test procedure index."
                $covering += [pscustomobject]@{
                    codeunitId   = $testId
                    codeunitName = $null
                    file         = $null
                    procedures   = @()
                }
            }
        }

        $survivors += [pscustomobject]@{
            mutantId      = $id
            stableKey     = $mutant.stableKey
            objectType    = $mutant.objectType
            objectId      = $mutant.objectId
            objectName    = $mutant.objectName
            procedure     = $mutant.procedure
            file          = $mutant.file
            line          = $line
            resolvedLine  = $resolvedLine
            sourceDrift   = $sourceDrift
            operator      = $mutant.operator
            original      = $original
            mutated       = $mutant.mutated
            operatorHint  = Get-MutOperatorHint -Operator $mutant.operator
            context       = $context
            coveringTests = $covering
        }
    }

    return [pscustomobject]@{
        runNo        = $RunNo
        generatedUtc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        survivors    = $survivors
    }
}

function ConvertTo-MutRepoRelativePath {
    <#
        .SYNOPSIS
        Private. $Path relative to $RepoRoot with forward slashes; an absolute path outside the
        repo is returned absolute (forward slashes).
    #>
    param([string]$Path, [string]$RepoRoot)

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    if ($full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, (Get-MutPathComparison))) {
        return $full.Substring($root.Length + 1).Replace('\', '/')
    }
    return $full.Replace('\', '/')
}

function Export-MutFixBriefs {
    <#
        .SYNOPSIS
        §6.7.2. Reads results/<N>.json and <workDir>/runs/<N>/gen/mutants.json, indexes the
        test procedures of the survivors' covering codeunits in <workDir>/test-app, and writes
        results/<N>-fix-briefs.json. Returns that path. A missing input throws, naming it.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$RunNo,
        [Parameter(Mandatory = $true)]$Config,
        [string]$RepoRoot = (Get-MutRepoRoot)
    )

    $resultsPath = Join-Path (Join-Path $RepoRoot 'results') "$RunNo.json"
    $mutantsPath = Join-Path $Config.workDir "runs/$RunNo/gen/mutants.json"
    foreach ($required in @($resultsPath, $mutantsPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Export-MutFixBriefs: required input not found: '$required'."
        }
    }

    $results = Get-Content -Path $resultsPath -Raw | ConvertFrom-Json
    # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE object; the extra
    # pipeline pass unrolls it into the individual entries.
    $mutants = @((Get-Content -Path $mutantsPath -Raw | ConvertFrom-Json) | ForEach-Object { $_ })

    $autPath = Join-Path $Config.workDir 'aut-original'
    $testAppPath = Join-Path $Config.workDir 'test-app'

    $coveringIds = @(@($results.mutants) | Where-Object { $_.status -eq 'Survived' } |
            ForEach-Object { @($_.coveringTests) } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $index = @()
    if ($coveringIds.Count -gt 0) {
        $index = @(Get-MutTestProcedureIndex -TestAppPath $testAppPath -CodeunitIds $coveringIds)
    }

    $brief = New-MutFixBriefs -RunNo $RunNo -Mutants $mutants -Results $results -AutPath $autPath -TestIndex $index

    $document = [pscustomobject]@{
        runNo             = $brief.runNo
        generatedUtc      = $brief.generatedUtc
        autPath           = ConvertTo-MutRepoRelativePath -Path $autPath -RepoRoot $RepoRoot
        testAppPath       = ConvertTo-MutRepoRelativePath -Path $testAppPath -RepoRoot $RepoRoot
        autSourcePath     = ([string]$Config.aut.sourcePath).Replace('\', '/')
        testAppSourcePath = ([string]$Config.testApp.sourcePath).Replace('\', '/')
        survivors         = $brief.survivors
    }

    $outPath = Join-Path (Join-Path $RepoRoot 'results') "$RunNo-fix-briefs.json"
    ($document | ConvertTo-Json -Depth 10) | Set-Content -Path $outPath -Encoding UTF8
    return $outPath
}

function Get-MutFixProp {
    <#
        .SYNOPSIS
        Private. The named property of $Object, or $null when $Object is null or lacks it
        (StrictMode-safe).
    #>
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-MutFixText {
    # Private. True for a string with a non-whitespace character.
    param($Value)
    return (($Value -is [string]) -and ($Value.Trim().Length -gt 0))
}

function Read-MutFixJson {
    # Private. Parses a JSON file; arrays of the top level are not expected here (objects only).
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Test-MutFixReport {
    <#
        .SYNOPSIS
        §6.7.4. Validates a fixes report against its brief. Returns [string[]] errors (empty
        when valid); each starts with the fixId, or `report` for file-level problems. Without
        -TestIndex the index is built from the brief's testAppPath (resolved against -RepoRoot).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BriefsPath,
        [Parameter(Mandatory = $true)][string]$FixesPath,
        [object[]]$TestIndex = $null,
        [string]$RepoRoot = (Get-MutRepoRoot)
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $BriefsPath -PathType Leaf)) {
        return , [string[]]@("report: briefs file not found: '$BriefsPath'")
    }
    try {
        $brief = Read-MutFixJson -Path $BriefsPath
    }
    catch {
        return , [string[]]@("report: briefs file '$BriefsPath' is not valid JSON: $($_.Exception.Message)")
    }
    if (-not (Test-Path -LiteralPath $FixesPath -PathType Leaf)) {
        return , [string[]]@("report: fixes file not found: '$FixesPath'")
    }
    try {
        $report = Read-MutFixJson -Path $FixesPath
    }
    catch {
        return , [string[]]@("report: fixes file '$FixesPath' is not valid JSON: $($_.Exception.Message)")
    }

    # Rule 1.
    $briefRunNo = Get-MutFixProp $brief 'runNo'
    $runNo = Get-MutFixProp $report 'runNo'
    if ($null -eq $runNo -or $null -eq $briefRunNo -or [string]$runNo -ne [string]$briefRunNo) {
        $errors.Add("report: runNo '$runNo' does not equal the brief's runNo '$briefRunNo'")
    }
    $fixesProp = $null
    if ($null -ne $report -and $null -ne $report.PSObject.Properties['fixes']) {
        $fixesProp = $report.fixes
    }
    if ($null -eq $fixesProp -or $fixesProp -is [string] -or $fixesProp -isnot [System.Collections.IEnumerable]) {
        $errors.Add('report: fixes must be an array')
        return , [string[]]$errors.ToArray()
    }
    $fixes = @($fixesProp)

    # Brief survivors: id -> covering codeunit ids.
    $survivorCovering = @{}
    foreach ($survivor in @(Get-MutFixProp $brief 'survivors')) {
        if ($null -eq $survivor) { continue }
        $covering = @()
        foreach ($test in @(Get-MutFixProp $survivor 'coveringTests')) {
            $covering += [int](Get-MutFixProp $test 'codeunitId')
        }
        $survivorCovering[[int]$survivor.mutantId] = $covering
    }

    # Test index.
    $index = $TestIndex
    if ($null -eq $index) {
        $testAppPath = [string](Get-MutFixProp $brief 'testAppPath')
        if (-not [System.IO.Path]::IsPathRooted($testAppPath)) {
            $testAppPath = Join-Path $RepoRoot $testAppPath
        }
        if (-not (Test-Path -LiteralPath $testAppPath -PathType Container)) {
            $errors.Add("report: test app path not found: '$testAppPath'")
            $index = @()
        }
        else {
            $ids = @($survivorCovering.Values | ForEach-Object { $_ } | Sort-Object -Unique)
            if ($ids.Count -gt 0) {
                $index = @(Get-MutTestProcedureIndex -TestAppPath $testAppPath -CodeunitIds ([int[]]$ids))
            }
            else {
                $index = @()
            }
        }
    }
    $indexById = @{}
    foreach ($entry in @($index)) {
        $indexById[[int]$entry.CodeunitId] = $entry
    }

    $seenFixIds = @{}
    $mutantUse = @{}
    $newProcedures = @{}
    $position = 0
    foreach ($fix in $fixes) {
        $position++
        $fixId = Get-MutFixProp $fix 'fixId'
        $prefix = $fixId
        # Rule 2.
        if (-not (Test-MutFixText $fixId)) {
            $prefix = 'report'
            $errors.Add("report: fixes[$($position - 1)] has no fixId")
        }
        elseif ($seenFixIds.ContainsKey($fixId)) {
            $errors.Add("${prefix}: fixId is not unique")
        }
        else {
            $seenFixIds[$fixId] = $true
        }

        $verdict = Get-MutFixProp $fix 'verdict'
        if (@('fix', 'new-test', 'equivalent') -notcontains $verdict) {
            $errors.Add("${prefix}: verdict '$verdict' must be fix, new-test or equivalent")
        }
        $confidence = Get-MutFixProp $fix 'confidence'
        if (@('high', 'medium', 'low') -notcontains $confidence) {
            $errors.Add("${prefix}: confidence '$confidence' must be high, medium or low")
        }
        if (-not (Test-MutFixText (Get-MutFixProp $fix 'rationale'))) {
            $errors.Add("${prefix}: rationale must be non-empty")
        }
        $mutantIds = @(Get-MutFixProp $fix 'mutantIds')
        if ($mutantIds.Count -eq 0 -or $null -eq $mutantIds[0]) {
            $errors.Add("${prefix}: mutantIds must be a non-empty array")
            $mutantIds = @()
        }

        # Rule 3 (per entry).
        foreach ($mutantId in $mutantIds) {
            $id = [int]$mutantId
            if (-not $survivorCovering.ContainsKey($id)) {
                $errors.Add("${prefix}: mutantId $id is not a survivor of the brief")
                continue
            }
            if (-not $mutantUse.ContainsKey($id)) {
                $mutantUse[$id] = @()
            }
            $mutantUse[$id] += $prefix
        }

        $target = Get-MutFixProp $fix 'target'
        $change = Get-MutFixProp $fix 'change'
        $anchor = Get-MutFixProp $fix 'anchor'
        $alCode = Get-MutFixProp $fix 'alCode'

        if ($verdict -eq 'equivalent') {
            # Rule 4.
            if ($null -ne $target) { $errors.Add("${prefix}: target must be null for an equivalent entry") }
            if ($null -ne $change) { $errors.Add("${prefix}: change must be null for an equivalent entry") }
            if ($null -ne $anchor) { $errors.Add("${prefix}: anchor must be null for an equivalent entry") }
            if ($alCode -isnot [string] -or $alCode -ne '') { $errors.Add("${prefix}: alCode must be the empty string for an equivalent entry") }
        }
        elseif ($verdict -eq 'fix' -or $verdict -eq 'new-test') {
            $codeunitId = $null
            $entry = $null
            $procedureName = $null
            if ($null -eq $target) {
                $errors.Add("${prefix}: target is required for a $verdict entry")
            }
            else {
                $codeunitId = Get-MutFixProp $target 'codeunitId'
                $procedureName = [string](Get-MutFixProp $target 'procedure')
                if ($null -ne $codeunitId -and $indexById.ContainsKey([int]$codeunitId)) {
                    $entry = $indexById[[int]$codeunitId]
                }
                else {
                    $errors.Add("${prefix}: target.codeunitId '$codeunitId' is not a test codeunit in the test index")
                }
            }
            $existing = @()
            if ($null -ne $entry) {
                $existing = @($entry.Procedures)
            }
            $isNew = Get-MutFixProp $target 'isNewProcedure'

            if ($verdict -eq 'fix') {
                # Rule 5.
                if (@('add-assert', 'modify-test') -notcontains $change) {
                    $errors.Add("${prefix}: change '$change' must be add-assert or modify-test for a fix entry")
                }
                if ($null -ne $target -and $isNew -ne $false) {
                    $errors.Add("${prefix}: target.isNewProcedure must be false for a fix entry")
                }
                if ($null -ne $entry) {
                    $procedure = @($existing | Where-Object { $_.Name -eq $procedureName }) | Select-Object -First 1
                    if ($null -eq $procedure) {
                        $errors.Add("${prefix}: target.procedure '$procedureName' is not a procedure of codeunit $codeunitId")
                    }
                    if ([string](Get-MutFixProp $target 'file') -ne [string]$entry.File) {
                        $errors.Add("${prefix}: target.file '$(Get-MutFixProp $target 'file')' does not equal the codeunit's file '$($entry.File)'")
                    }
                    if ($change -eq 'add-assert' -and $null -ne $procedure) {
                        $afterLine = Get-MutFixProp $anchor 'afterLine'
                        if ($null -eq $afterLine -or [int]$afterLine -lt [int]$procedure.StartLine -or [int]$afterLine -gt [int]$procedure.EndLine) {
                            $errors.Add("${prefix}: anchor.afterLine '$afterLine' is not within procedure '$procedureName' [$($procedure.StartLine), $($procedure.EndLine)]")
                        }
                    }
                }
                elseif ($change -eq 'add-assert' -and $null -eq (Get-MutFixProp $anchor 'afterLine')) {
                    $errors.Add("${prefix}: anchor.afterLine is required for add-assert")
                }
                if ($change -eq 'modify-test' -and $null -ne $anchor) {
                    $errors.Add("${prefix}: anchor must be null for modify-test")
                }
                if (-not (Test-MutFixText $alCode)) { $errors.Add("${prefix}: alCode must be non-empty") }
                if (-not (Test-MutFixText (Get-MutFixProp $fix 'expectedEffect'))) { $errors.Add("${prefix}: expectedEffect must be non-empty") }
            }
            else {
                # Rule 6.
                if ($change -ne 'new-test') {
                    $errors.Add("${prefix}: change '$change' must be new-test for a new-test entry")
                }
                if ($null -ne $target -and $isNew -ne $true) {
                    $errors.Add("${prefix}: target.isNewProcedure must be true for a new-test entry")
                }
                if ($null -ne $entry) {
                    if (@($existing | Where-Object { $_.Name -eq $procedureName }).Count -gt 0) {
                        $errors.Add("${prefix}: target.procedure '$procedureName' already exists in codeunit $codeunitId")
                    }
                    $key = "$codeunitId|$($procedureName.ToLowerInvariant())"
                    if ($newProcedures.ContainsKey($key)) {
                        $errors.Add("${prefix}: target.procedure '$procedureName' is not unique among new-test entries of codeunit $codeunitId")
                    }
                    else {
                        $newProcedures[$key] = $true
                    }
                }
                if ($null -ne $anchor) {
                    $errors.Add("${prefix}: anchor must be null for a new-test entry")
                }
                if ($alCode -isnot [string] -or $alCode.IndexOf('[Test]', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    $errors.Add("${prefix}: alCode must contain [Test]")
                }
                if ($alCode -isnot [string] -or $null -eq $target -or $alCode.IndexOf("procedure $procedureName(", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    $errors.Add("${prefix}: alCode must declare 'procedure $procedureName('")
                }
                if (-not (Test-MutFixText (Get-MutFixProp $fix 'expectedEffect'))) { $errors.Add("${prefix}: expectedEffect must be non-empty") }
            }

            # Rule 7.
            if ($null -ne $codeunitId) {
                foreach ($mutantId in $mutantIds) {
                    $id = [int]$mutantId
                    if ($survivorCovering.ContainsKey($id) -and @($survivorCovering[$id]) -notcontains [int]$codeunitId) {
                        $errors.Add("${prefix}: target.codeunitId $codeunitId is not a covering test codeunit of mutant $id")
                    }
                }
            }
        }
    }

    # Rule 3 (coverage of the brief).
    foreach ($id in @($survivorCovering.Keys | Sort-Object)) {
        if (-not $mutantUse.ContainsKey($id)) {
            $errors.Add("report: mutant $id is in no fix entry")
        }
        elseif (@($mutantUse[$id]).Count -gt 1) {
            $errors.Add("report: mutant $id is in more than one fix entry ($(@($mutantUse[$id]) -join ', '))")
        }
    }

    return , [string[]]$errors.ToArray()
}

function Export-MutFixMarkdown {
    <#
        .SYNOPSIS
        §6.7.4. Writes results/<N>-fixes.md: a header (run no, survivor count, counts per
        verdict and confidence), one section per target test codeunit ordered by id (equivalent
        entries last under "Equivalent mutants"), entries ordered by fixId. Assumes a report
        that passed Test-MutFixReport.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BriefsPath,
        [Parameter(Mandatory = $true)][string]$FixesPath,
        [Parameter(Mandatory = $true)][string]$OutPath
    )

    $brief = Read-MutFixJson -Path $BriefsPath
    $report = Read-MutFixJson -Path $FixesPath
    $survivors = @(Get-MutFixProp $brief 'survivors')
    $fixes = @(Get-MutFixProp $report 'fixes')

    $survivorById = @{}
    foreach ($survivor in $survivors) {
        $survivorById[[int]$survivor.mutantId] = $survivor
    }

    $count = {
        param([string]$Property, [string]$Value)
        @($fixes | Where-Object { (Get-MutFixProp $_ $Property) -eq $Value }).Count
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Fix suggestions for run $($report.runNo)")
    $lines.Add('')
    $lines.Add("- Run: $($report.runNo)")
    $lines.Add("- Survivors: $($survivors.Count)")
    $lines.Add("- Fix entries: $($fixes.Count)")
    $lines.Add("- Verdicts: fix $(& $count 'verdict' 'fix'), new-test $(& $count 'verdict' 'new-test'), equivalent $(& $count 'verdict' 'equivalent')")
    $lines.Add("- Confidence: high $(& $count 'confidence' 'high'), medium $(& $count 'confidence' 'medium'), low $(& $count 'confidence' 'low')")

    $renderEntry = {
        param($Fix)
        $lines.Add('')
        $lines.Add("### $($Fix.fixId)")
        $lines.Add('')
        $lines.Add('- Mutants:')
        foreach ($mutantId in @($Fix.mutantIds)) {
            $survivor = $survivorById[[int]$mutantId]
            if ($null -eq $survivor) {
                $lines.Add("  - ${mutantId}")
                continue
            }
            $lineNo = Get-MutFixProp $survivor 'resolvedLine'
            if ($null -eq $lineNo) {
                $lineNo = $survivor.line
            }
            $lines.Add("  - ${mutantId}: ``$($survivor.original)`` -> ``$($survivor.mutated)`` ($($survivor.file):$lineNo)")
        }
        $lines.Add("- Verdict: $($Fix.verdict)")
        if ($null -ne $Fix.change) {
            $lines.Add("- Change: $($Fix.change)")
        }
        if ($null -ne $Fix.target) {
            $lines.Add("- Target procedure: $($Fix.target.procedure)")
        }
        if ($null -ne $Fix.anchor) {
            $lines.Add("- Anchor: after line $($Fix.anchor.afterLine)")
        }
        $lines.Add("- Confidence: $($Fix.confidence)")
        $lines.Add("- Rationale: $($Fix.rationale)")
        if (Test-MutFixText $Fix.expectedEffect) {
            $lines.Add("- Expected effect: $($Fix.expectedEffect)")
        }
        if (Test-MutFixText $Fix.alCode) {
            $lines.Add('')
            $lines.Add('```al')
            $lines.Add([string]$Fix.alCode)
            $lines.Add('```')
        }
    }

    $targeted = @($fixes | Where-Object { $_.verdict -ne 'equivalent' -and $null -ne $_.target })
    $codeunitIds = @($targeted | ForEach-Object { [int]$_.target.codeunitId } | Sort-Object -Unique)
    foreach ($codeunitId in $codeunitIds) {
        $group = @($targeted | Where-Object { [int]$_.target.codeunitId -eq $codeunitId } | Sort-Object -Property fixId)
        $lines.Add('')
        $lines.Add("## Test codeunit $codeunitId $($group[0].target.codeunitName)")
        $lines.Add('')
        $lines.Add("File: $($group[0].target.file)")
        foreach ($fix in $group) {
            & $renderEntry $fix
        }
    }

    $equivalent = @($fixes | Where-Object { $_.verdict -eq 'equivalent' } | Sort-Object -Property fixId)
    if ($equivalent.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Equivalent mutants')
        foreach ($fix in $equivalent) {
            & $renderEntry $fix
        }
    }

    $lines.Add('')
    $directory = Split-Path -Parent $OutPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-Content -Path $OutPath -Value ($lines.ToArray()) -Encoding UTF8
}

Export-ModuleMember -Function Get-MutOperatorHint, New-MutFixBriefs, Export-MutFixBriefs, Test-MutFixReport, Export-MutFixMarkdown
