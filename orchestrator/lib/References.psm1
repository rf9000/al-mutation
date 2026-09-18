Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Backend-agnostic: no CLI or container-tool names in this module (see spec §4 item 6).

# First non-comment line of an AL object file: `<type> <id> <quoted-or-bare-name>` (§6.5.5).
$script:ObjectHeaderPattern = '^(codeunit|table|page|report|enum|interface|query|xmlport)\s+(\d+)\s+("[^"]+"|\S+)'

# Quoted object-name references inside AL code: `Codeunit "…"`, `Record "…"`, `Page "…"`,
# `Enum "…"`, `Codeunit::"…"`, `Page::"…"`, `Database::"…"` (§6.5.5).
$script:ReferencePattern = '(?:Codeunit|Record|Page|Enum|Database)(?:::)?\s*"([^"]+)"'

function Remove-MutAlTrivia {
    <#
        .SYNOPSIS
        Private. Strips `//` line comments and `/* ... */` block comments from $Content
        (tracking block-comment state across the whole file, so a block comment that spans
        multiple lines, one that opens and closes on a single line, and one with code after
        its closing `*/` are all handled). Every newline in $Content is preserved in the
        output -- even inside a stripped block comment -- so the result's line numbers still
        correspond 1:1 to $Content's own lines. `#` compiler directives are left untouched
        here; they are a whole-line construct with no closing delimiter to track, so the
        header scan itself skips a line whose trimmed text starts with `#` instead.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $sb = New-Object System.Text.StringBuilder
    $inBlockComment = $false
    $length = $Content.Length
    $i = 0
    while ($i -lt $length) {
        if ($inBlockComment) {
            if (($i + 1) -lt $length -and $Content[$i] -eq '*' -and $Content[$i + 1] -eq '/') {
                $inBlockComment = $false
                $i += 2
                continue
            }
            if ($Content[$i] -eq "`n") {
                [void]$sb.Append("`n")
            }
            $i++
            continue
        }

        if (($i + 1) -lt $length -and $Content[$i] -eq '/' -and $Content[$i + 1] -eq '*') {
            $inBlockComment = $true
            $i += 2
            continue
        }

        if (($i + 1) -lt $length -and $Content[$i] -eq '/' -and $Content[$i + 1] -eq '/') {
            while ($i -lt $length -and $Content[$i] -ne "`n") {
                $i++
            }
            continue
        }

        [void]$sb.Append($Content[$i])
        $i++
    }

    return $sb.ToString()
}

function Get-MutObjectHeader {
    <#
        .SYNOPSIS
        Parses one .al file's object header (§6.5.5, amended wording): "first meaningful
        line" -- skipping blank lines, `//` comments, `/* ... */` block comments (which may
        span lines) and `#` compiler directives -- is tested ONCE against the object-header
        pattern; $null is returned if it does not match, rather than scanning further into
        the object body.

        A file may legitimately open with a block comment or a compiler directive
        (`#pragma warning disable ...`, `#if ...`) before its object header (confirmed in the
        real AUT: BankProcessedItems.Page.al opens with `#pragma warning disable AL0432`),
        and 24 AUT files contain `/*`. An earlier version of this function kept scanning
        forward past ANY non-matching line looking for one that matched, which is broader
        than this: it could walk straight into the object BODY and attach the id of some
        unrelated `table <id> = ...` token inside a permission-set's `Permissions` list, or
        resurrect an object header commented out inside a `/* ... */` block just above the
        real one -- silently mapping the wrong id into nameToId, worse than the $null this
        function returns when there is genuinely no header at all.
        .OUTPUTS
        [pscustomobject]@{ ObjectType; Id (int); Name (quotes stripped) }, or $null.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = Get-Content -Path $Path -Raw -ErrorAction Stop
    if ($null -eq $content) {
        $content = ''
    }

    $stripped = Remove-MutAlTrivia -Content $content

    foreach ($rawLine in ($stripped -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line.StartsWith('#')) {
            continue
        }

        $match = [regex]::Match($line, $script:ObjectHeaderPattern, 'IgnoreCase')
        if ($match.Success) {
            return [pscustomobject]@{
                ObjectType = $match.Groups[1].Value
                Id         = [int]$match.Groups[2].Value
                Name       = $match.Groups[3].Value.Trim('"')
            }
        }
        # This is the first meaningful line and it does NOT match the object-header pattern
        # (e.g. a permissionset/enum-extension file): §6.5.5 tests only this one line, so
        # stop here rather than scanning further into the object body, where a numeric token
        # (a Permissions list entry, a field id, ...) could otherwise be misread as a header.
        return $null
    }
    return $null
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
