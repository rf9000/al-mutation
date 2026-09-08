Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Backend-agnostic (§6.5.5): no continia/docker/BcContainerHelper strings in this module.

# Recognized AL object types for the coverage CSV's ObjectType column. PowerShell's -eq / -contains
# operators are case-insensitive for strings by default, matching the "case-insensitive" ruling.
$script:AllowedObjectTypes = @(
    'Table', 'Page', 'Codeunit', 'Report', 'Query', 'XMLport', 'Enum',
    'PageExtension', 'TableExtension', 'Interface'
)

function ConvertFrom-MutCoverageCsv {
    <#
        .SYNOPSIS
        Parses the coverage CSV produced by the backend's test-coverage command (U9, answered
        2026-09-08, pinned by fixtures/coverage/sample.csv): NO header row; each line is five
        quoted positional columns "ObjectType","ObjectId","LineType","LineNo","Hits", e.g.
        "Codeunit","50000","Code","12","1". LineType is one of Object | Trigger/Function |
        Empty | Code; only Code rows carry meaningful Hits (selection is left to
        Get-MutCoveringTests). Blank lines are skipped.

        Each non-blank line is trimmed, its single leading/trailing '"' stripped, then split on
        '","' -- fields in this format never contain a comma, so this is a safe substitute for
        full CSV/quote-escape parsing. A line that does not split into exactly five columns, or
        whose ObjectType is not one of the recognized AL object types (case-insensitive), throws
        (per §6.5.5: "the parser MUST validate exactly five columns per row and a known
        ObjectType, and MUST throw otherwise").

        .PARAMETER Csv
        The raw CSV document text (as returned by Get-MutCoverageRaw), one row per line.

        .OUTPUTS
        [pscustomobject[]] {ObjectType (string); ObjectId (int); LineType (string); LineNo
        (int); Hits (int)}, in file order.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Csv
    )

    $rows = @()

    foreach ($rawLine in ($Csv -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $inner = $line
        if ($inner.StartsWith('"')) {
            $inner = $inner.Substring(1)
        }
        if ($inner.EndsWith('"')) {
            $inner = $inner.Substring(0, $inner.Length - 1)
        }

        $columns = $inner -split '","'
        if ($columns.Count -ne 5) {
            throw "ConvertFrom-MutCoverageCsv: expected 5 columns (ObjectType,ObjectId,LineType,LineNo,Hits), got $($columns.Count) in row: $line"
        }

        $objectType = $columns[0]
        if ($script:AllowedObjectTypes -notcontains $objectType) {
            throw "ConvertFrom-MutCoverageCsv: unknown ObjectType '$objectType' in row: $line. Expected one of: $($script:AllowedObjectTypes -join ', ')."
        }

        $rows += [pscustomobject]@{
            ObjectType = $objectType
            ObjectId   = [int]$columns[1]
            LineType   = $columns[2]
            LineNo     = [int]$columns[3]
            Hits       = [int]$columns[4]
        }
    }

    # Unary comma: see the identical note on ConvertTo-MutDiagnosticList in DemoPortal.psm1 --
    # a bare `return $rows` would unwrap a 1-element result to a scalar via pipeline enumeration.
    return , $rows
}

function Get-MutCoveringTests {
    <#
        .SYNOPSIS
        Selects the test codeunit ids that cover one mutant (§6.5.5, §7.2 coverage.json shape).

        .PARAMETER Mutant
        An object with at least `objectId` (int) and `line` (int) properties (a mutants.json
        entry, §7.1).

        .PARAMETER Coverage
        `@{ byTestCodeunit = @{ '<testCodeunitId>' = <rows> } }` (§7.2) where each row has
        ObjectType/ObjectId/LineType/LineNo/Hits (ConvertFrom-MutCoverageCsv's shape). Keys of
        byTestCodeunit are looked up as strings (JSON object keys are strings).

        .PARAMETER References
        A hashtable objectId -> int[] testCodeunitIds (Get-MutReferenceMap's shape, or the same
        loaded back from references.json). Keys are compared numerically so either an int-keyed
        or a JSON-round-tripped string-keyed hashtable works.

        .PARAMETER TestCodeunits
        The candidate test codeunit ids to check coverage rows for.

        .DESCRIPTION
        Prefers coverage: any test codeunit in $TestCodeunits whose Coverage rows include one
        with ObjectId -eq $Mutant.objectId, LineNo -eq $Mutant.line, and Hits -gt 0 is a
        covering test. If none qualify, falls back to $References[$Mutant.objectId]. If that is
        also absent, returns an empty array.

        .OUTPUTS
        [int[]] test codeunit ids. Always an array, even for a single result (unary comma).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Mutant,
        [Parameter(Mandatory = $true)]
        $Coverage,
        [Parameter(Mandatory = $true)]
        $References,
        [Parameter(Mandatory = $true)]
        [int[]]$TestCodeunits
    )

    $objectId = [int]$Mutant.objectId
    $line = [int]$Mutant.line

    $covering = @()
    foreach ($testCodeunitId in $TestCodeunits) {
        $rows = $null
        if ($Coverage.byTestCodeunit.ContainsKey("$testCodeunitId")) {
            $rows = $Coverage.byTestCodeunit["$testCodeunitId"]
        }

        $isCovering = $false
        foreach ($row in @($rows)) {
            if ($null -eq $row) {
                continue
            }
            if ($row.ObjectId -eq $objectId -and $row.LineNo -eq $line -and $row.Hits -gt 0) {
                $isCovering = $true
                break
            }
        }

        if ($isCovering) {
            $covering += $testCodeunitId
        }
    }

    if ($covering.Count -gt 0) {
        return , [int[]]$covering
    }

    foreach ($key in $References.Keys) {
        if ([int]$key -eq $objectId) {
            return , [int[]]@($References[$key])
        }
    }

    return , [int[]]@()
}

Export-ModuleMember -Function ConvertFrom-MutCoverageCsv, Get-MutCoveringTests
