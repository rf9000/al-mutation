Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Backend-agnostic: no CLI or container-tool names in this module (see spec §4 item 6).

# First non-comment line of an AL object file: `<type> <id> <quoted-or-bare-name>` (§6.5.5).
$script:ObjectHeaderPattern = '^(codeunit|table|page|report|enum|interface|query|xmlport)\s+(\d+)\s+("[^"]+"|\S+)'

# §6.5.5's closed "file preamble" set (fix round 2): a `namespace ...;` or `using ...;`
# declaration, which is legal AL on BC 22+ (the AUT is on BC 29) and may legitimately precede
# the object header. 306 AUT files (plus 37 test-app files, 18 of them Subtype=Test) already
# carry exactly this, commented out, on line 1 -- one uncomment away from being dropped by a
# scan that does not recognise it.
$script:PreambleDeclarationPattern = '^(namespace|using)\s+\S'

# Object/extension keywords that are LEGITIMATELY id-less (interface) or out of this task's
# scope (the *extension kinds, permissionset, controladdin, profile, entitlement, dotnet):
# none of these will ever match $script:ObjectHeaderPattern, which requires a numeric id
# between the keyword and the name. Measured on the real AUT (fix round 3): a scan without
# this set produced 201 warnings on a clean run -- 125 interface, 36 tableextension, 25
# pageextension, 6 permissionsetextension, 3 reportextension, 3 permissionset, 2
# enumextension, 1 controladdin -- and every single one was this, not a genuine anomaly. A
# warning with a 100% false-positive rate trains people to ignore it, which defeats the one
# real anomaly it exists to catch. Treated as expected-and-silent: still no entry (these
# objects correctly do not enter nameToId), but no Write-Warning either.
$script:KnownOutOfScopeObjectPattern = '^(interface|tableextension|pageextension|enumextension|reportextension|permissionsetextension|permissionset|controladdin|profile|entitlement|dotnet)\b'

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
        Parses one .al file's object header (§6.5.5, corrected wording, fix round 2): strip
        `//` and `/* ... */` comments (Remove-MutAlTrivia), then skip the recognised file
        PREAMBLE -- blank lines, `#` compiler directives, and `namespace`/`using`
        declarations -- and test the FIRST REMAINING line against the object-header pattern.
        If that line does not match, the file yields NO entry and a warning naming the file
        is emitted (the preamble set is closed for AL today; anything else appearing before a
        real header must be visible, not silent).

        Two failure modes motivate this exact shape, both live in the real AUT:
        - Scanning forward past ANY non-matching line (an earlier, wrong version of this
          function) attaches a WRONG id: a realistic permissionset whose `Permissions` list
          contains `table 50100 = X` yields `table 50100` named `=`, and header-shaped text
          inside a string literal does the same. A wrong id is worse than none: the real
          object never enters the map and its mutants fall through to `Uncovered`, deflating
          the score with no signal at all.
        - Testing only the first non-comment line WITHOUT a preamble concept (the version
          this replaces) drops a file whose first real line is `namespace ...;` or
          `using ...;` -- legal AL on BC 22+, the AUT is on BC 29 -- entirely. 306 AUT files
          (plus 37 test-app files, 18 of them Subtype=Test codeunits) already carry exactly
          that, commented out, one uncomment away from silently vanishing from nameToId; a
          test codeunit losing its header is worse, since Get-MutReferenceMap then discards
          every reference it contributes.
        - `#pragma`/`#if` before the header (confirmed in the real AUT:
          BankProcessedItems.Page.al) is the same class of preamble as namespace/using.

        The warning on the leftover case (first remaining line is neither a header, recognised
        preamble, nor a known out-of-scope keyword) is what keeps a THIRD, still-unanticipated
        leading construct from silently repeating either failure mode: it converts a silent
        score deflation into something a human sees.

        Fix round 3: that warning initially fired for every `interface`/`*extension`/
        `permissionset`/etc. file too -- legitimately id-less or out-of-scope constructs that
        will never match the header pattern. Measured on the real AUT: 201 warnings on a
        clean run, 100% false positives (125 interface, 36 tableextension, 25 pageextension,
        6 permissionsetextension, 3 reportextension, 3 permissionset, 2 enumextension, 1
        controladdin). A warning that always fires trains people to ignore it, which is
        exactly how the one real anomaly it exists to catch would also get ignored.
        $script:KnownOutOfScopeObjectPattern now silences exactly that closed set, still
        returning $null (these objects correctly never enter nameToId) but without warning.
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
        if ([regex]::IsMatch($line, $script:PreambleDeclarationPattern, 'IgnoreCase')) {
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

        if ([regex]::IsMatch($line, $script:KnownOutOfScopeObjectPattern, 'IgnoreCase')) {
            # A known, legitimately id-less or out-of-scope declaration (interface,
            # *extension, permissionset, controladdin, profile, entitlement, dotnet): this is
            # an EXPECTED $null, not an anomaly, so no warning (fix round 3 -- see
            # $script:KnownOutOfScopeObjectPattern's comment for why this exists).
            return $null
        }

        # First remaining line after comments, the recognised preamble, and the known
        # out-of-scope keywords, and it is STILL not an object header (some other construct
        # neither set knows about): yield no entry, but say so, rather than silently dropping
        # the file the way a bare $null would.
        Write-Warning "Get-MutObjectHeader: '$Path': first non-preamble line does not match an object header ('$line'); this file will not enter the reference map."
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
