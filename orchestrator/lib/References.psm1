Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Backend-agnostic: no CLI or container-tool names in this module (see spec §4 item 6).

# First non-comment line of an AL object file: `<type> <id> <quoted-or-bare-name>` (§6.5.5).
$script:ObjectHeaderPattern = '^(codeunit|table|page|report|enum|interface|query|xmlport)\s+(\d+)\s+("[^"]+"|\S+)'

# Quoted object-name references inside AL code: `Codeunit "…"`, `Record "…"`, `Page "…"`,
# `Enum "…"`, `Codeunit::"…"`, `Page::"…"`, `Database::"…"` (§6.5.5).
$script:ReferencePattern = '(?:Codeunit|Record|Page|Enum|Database)(?:::)?\s*"([^"]+)"'

function Get-MutFirstNonCommentLine {
    <#
        .SYNOPSIS
        Returns the first non-blank, non-`//`-comment line of $Lines (trimmed), or $null.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    foreach ($rawLine in $Lines) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line.StartsWith('//')) {
            continue
        }
        return $line
    }
    return $null
}

function Get-MutObjectHeader {
    <#
        .SYNOPSIS
        Parses one .al file's first non-comment line as an AL object header (§6.5.5). Returns
        $null when the file has no such line (e.g. a permission-set/enum-extension file this
        task does not need, or an empty file).
        .OUTPUTS
        [pscustomobject]@{ ObjectType; Id (int); Name (quotes stripped) }, or $null.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = @(Get-Content -Path $Path -ErrorAction Stop)
    $firstLine = Get-MutFirstNonCommentLine -Lines $lines
    if ($null -eq $firstLine) {
        return $null
    }

    $match = [regex]::Match($firstLine, $script:ObjectHeaderPattern, 'IgnoreCase')
    if (-not $match.Success) {
        return $null
    }

    return [pscustomobject]@{
        ObjectType = $match.Groups[1].Value
        Id         = [int]$match.Groups[2].Value
        Name       = $match.Groups[3].Value.Trim('"')
    }
}

function Test-MutIsTestCodeunit {
    <#
        .SYNOPSIS
        True when the file's content declares `Subtype = Test` (§6.5.5's test-codeunit rule).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    return [regex]::IsMatch($Content, 'Subtype\s*=\s*Test', 'IgnoreCase')
}

function Get-MutReferencedNames {
    <#
        .SYNOPSIS
        Collects every quoted object name referenced via `Codeunit "…"`, `Record "…"`,
        `Page "…"`, `Enum "…"`, `Codeunit::"…"`, `Page::"…"`, `Database::"…"` in $Content.
        .OUTPUTS
        [string[]] names, in file order, not deduplicated.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $names = @()
    foreach ($match in [regex]::Matches($Content, $script:ReferencePattern)) {
        $names += $match.Groups[1].Value
    }
    return , $names
}

function Get-MutReferenceMap {
    <#
        .SYNOPSIS
        Builds the reference map for covering-test selection (§6.5.5): a name -> id map is
        built from every AUT .al file's object header, then every test-app .al file whose
        content declares `Subtype = Test` is scanned for quoted object-name references; each
        recognized name is mapped to the AUT object id, and that id accumulates the referencing
        test codeunit's own id.

        Names not found in the AUT name map (references to objects inside the test app itself,
        e.g. "Library Assert", or to the test codeunit's own name) are silently ignored.

        .PARAMETER AutPath
        Root of the AUT source tree (e.g. `<workDir>/aut-original`), searched recursively for
        `*.al` files.

        .PARAMETER TestAppPath
        Root of the test app source tree (e.g. `<workDir>/test-app`), searched recursively for
        `*.al` files.

        .OUTPUTS
        [hashtable] int objectId -> [int[]] test codeunit ids (deduplicated, ascending).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AutPath,
        [Parameter(Mandatory = $true)]
        [string]$TestAppPath
    )

    $nameToId = @{}
    foreach ($file in @(Get-ChildItem -Path $AutPath -Filter '*.al' -Recurse -File)) {
        $header = Get-MutObjectHeader -Path $file.FullName
        if ($null -eq $header) {
            continue
        }
        $nameToId[$header.Name] = $header.Id
    }

    $map = @{}
    foreach ($file in @(Get-ChildItem -Path $TestAppPath -Filter '*.al' -Recurse -File)) {
        $content = Get-Content -Path $file.FullName -Raw
        if (-not (Test-MutIsTestCodeunit -Content $content)) {
            continue
        }

        $header = Get-MutObjectHeader -Path $file.FullName
        if ($null -eq $header) {
            continue
        }
        $testCodeunitId = $header.Id

        foreach ($name in (Get-MutReferencedNames -Content $content)) {
            if (-not $nameToId.ContainsKey($name)) {
                continue
            }
            $autObjectId = $nameToId[$name]

            if (-not $map.ContainsKey($autObjectId)) {
                $map[$autObjectId] = New-Object System.Collections.Generic.List[int]
            }
            if (-not $map[$autObjectId].Contains($testCodeunitId)) {
                $map[$autObjectId].Add($testCodeunitId)
            }
        }
    }

    $result = @{}
    foreach ($key in $map.Keys) {
        $result[$key] = [int[]]@(($map[$key] | Sort-Object))
    }

    return $result
}

function Save-MutReferenceMap {
    <#
        .SYNOPSIS
        Writes $Map (int objectId -> int[] testCodeunitIds) to $Path as references.json:
        `{ "<objectId>": [<testCodeunitId>, …] }` (§6.5.4 step 3).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Map,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $ordered = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object)) {
        $ordered["$key"] = @($Map[$key])
    }

    ($ordered | ConvertTo-Json -Depth 10) | Set-Content -Path $Path -Encoding UTF8
}

Export-ModuleMember -Function Get-MutReferenceMap, Save-MutReferenceMap
