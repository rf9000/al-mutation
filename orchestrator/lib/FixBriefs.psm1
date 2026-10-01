Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# §6.7.2 stage 1: deterministic fix briefs for the Survived mutants of a run. Read-only on the
# AUT copy and test-app snapshot under <workDir>; writes only results/<N>-fix-briefs.json.
# Test-MutFixReport and Export-MutFixMarkdown (stage 3) arrive in a later task and are not
# exported until they exist.

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
        if ($null -ne $sourceLines) {
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

            $centre = $line
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
    if ($full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
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

Export-ModuleMember -Function Get-MutOperatorHint, New-MutFixBriefs, Export-MutFixBriefs
