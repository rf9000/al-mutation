Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# §6.8.1: apply the suggested fixes of results/<N>-fixes.json to a COPY of the test app
# (Invoke-MutFixApply) and build a unified diff between the original and the patched folder
# (New-MutTestPatch). Pure file work: no environment, never writes the source folder.

Import-Module (Join-Path $PSScriptRoot 'References.psm1') -Force

function Get-MutFixText {
    <#
        .SYNOPSIS
        Private. Reads a file as `{ Text; HasBom; Encoding }`. The BOM is not part of Text.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $encoding = New-Object System.Text.UTF8Encoding($hasBom)
    $offset = 0
    if ($hasBom) { $offset = 3 }
    return [pscustomobject]@{
        Text     = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        HasBom   = $hasBom
        Encoding = $encoding
    }
}

function Get-MutFixEol {
    <#
        .SYNOPSIS
        Private. CRLF when the first line break of the text is CRLF, otherwise LF.
    #>
    param([AllowEmptyString()][string]$Text)

    $idx = $Text.IndexOf("`n")
    if ($idx -gt 0 -and $Text[$idx - 1] -eq "`r") {
        return "`r`n"
    }
    return "`n"
}

function Invoke-MutFixApply {
    <#
        .SYNOPSIS
        §6.8.1. Mirrors $SourcePath to $DestinationPath (deleting what is there), then applies
        the add-assert / modify-test / new-test entries of $Fixes in place. Returns one
        `{ fixId; file; insertedStartLine; insertedEndLine }` per applied entry, sorted by
        fixId; lines are 1-based in the PATCHED file. `equivalent` entries are never applied.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Fixes
    )

    $src = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd('\', '/')
    $dst = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath).TrimEnd('\', '/')
    if ($src -ieq $dst) {
        throw 'DestinationPath must differ from SourcePath'
    }

    # 1. Mirror.
    if (Test-Path -LiteralPath $dst) {
        Remove-Item -LiteralPath $dst -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $src -Force)) {
        Copy-Item -LiteralPath $child.FullName -Destination $dst -Recurse -Force
    }

    $applicable = @($Fixes | Where-Object {
            $_.PSObject.Properties['verdict'] -eq $null -or $_.verdict -ne 'equivalent'
        } | Where-Object { $null -ne $_.change -and $null -ne $_.target } | Sort-Object -Property fixId)
    if ($applicable.Count -eq 0) {
        return
    }

    # 2. Locate procedures by name on the unpatched copy, before any edit.
    $index = @(Get-MutTestProcedureIndex -TestAppPath $dst)
    $opsByFile = @{}
    $changedBy = @{}

    foreach ($fix in $applicable) {
        $file = [string]$fix.target.file
        $fileEntry = $index | Where-Object { $_.File -ieq $file } | Select-Object -First 1
        if ($null -eq $fileEntry) {
            throw "Fix $($fix.fixId): target file '$file' is not a test codeunit file of the test app"
        }
        if (-not $opsByFile.ContainsKey($fileEntry.File)) {
            $opsByFile[$fileEntry.File] = @()
        }
        $alLines = @(([string]$fix.alCode).Replace("`r", '') -split "`n")

        if ($fix.change -eq 'new-test') {
            $opsByFile[$fileEntry.File] += [pscustomobject]@{
                Fix = [string]$fix.fixId; Kind = 'new'; Pos = 0; Rank = 1; Remove = 0; Lines = $alLines
            }
            continue
        }

        $procName = [string]$fix.target.procedure
        $proc = @($fileEntry.Procedures) | Where-Object { $_.Name -eq $procName } | Select-Object -First 1
        if ($null -eq $proc) {
            throw "Fix $($fix.fixId): procedure '$procName' not found in $file"
        }

        # 4. A modify-test must be the only edit of its procedure.
        $key = "$($fileEntry.File)|$procName"
        if ($changedBy.ContainsKey($key)) {
            $other = $changedBy[$key]
            if ($other.Change -eq 'modify-test' -or $fix.change -eq 'modify-test') {
                throw "Fix $($other.FixId) and $($fix.fixId) both change procedure '$procName'"
            }
        }
        else {
            $changedBy[$key] = [pscustomobject]@{ FixId = [string]$fix.fixId; Change = [string]$fix.change }
        }

        if ($fix.change -eq 'add-assert') {
            $opsByFile[$fileEntry.File] += [pscustomobject]@{
                Fix = [string]$fix.fixId; Kind = 'add'; Pos = [int]$fix.anchor.afterLine; Rank = 0; Remove = 0; Lines = $alLines
            }
        }
        elseif ($fix.change -eq 'modify-test') {
            $opsByFile[$fileEntry.File] += [pscustomobject]@{
                Fix = [string]$fix.fixId; Kind = 'mod'; Pos = ($proc.StartLine - 1); Rank = 0
                Remove = ($proc.EndLine - $proc.StartLine + 1); Lines = $alLines
            }
        }
        else {
            throw "Fix $($fix.fixId): unknown change '$($fix.change)'"
        }
    }

    # 3. Apply per file, bottom-up.
    $results = @()
    foreach ($relFile in @($opsByFile.Keys)) {
        $full = Join-Path $dst ($relFile -replace '/', '\')
        $info = Get-MutFixText -Path $full
        $eol = Get-MutFixEol -Text $info.Text
        $list = New-Object 'System.Collections.Generic.List[string]'
        $list.AddRange([string[]]@([regex]::Split($info.Text, '\r?\n')))

        $ops = @($opsByFile[$relFile] | Where-Object { $_.Kind -ne 'new' })
        $newOps = @($opsByFile[$relFile] | Where-Object { $_.Kind -eq 'new' })

        $subs = @()
        if ($newOps.Count -gt 0) {
            $closeIdx = -1
            for ($i = $list.Count - 1; $i -ge 0; $i--) {
                if ($list[$i].Trim() -eq '}') { $closeIdx = $i; break }
            }
            if ($closeIdx -lt 0) {
                throw "Fix $($newOps[0].Fix): no closing brace found in $relFile"
            }
            $block = New-Object 'System.Collections.Generic.List[string]'
            foreach ($n in $newOps) {
                $block.Add('')
                $subs += [pscustomobject]@{ Fix = $n.Fix; Offset = $block.Count; Count = @($n.Lines).Count }
                $block.AddRange([string[]]@($n.Lines))
            }
            $ops += [pscustomobject]@{
                Fix = ''; Kind = 'newblock'; Pos = $closeIdx; Rank = 1; Remove = 0; Lines = $block.ToArray()
            }
        }

        foreach ($op in @($ops | Sort-Object -Property @{ Expression = 'Pos'; Descending = $true }, @{ Expression = 'Rank'; Descending = $true }, @{ Expression = 'Fix'; Descending = $true })) {
            if ($op.Remove -gt 0) {
                $list.RemoveRange($op.Pos, $op.Remove)
            }
            $list.InsertRange($op.Pos, [string[]]@($op.Lines))
        }

        # Final ranges: an ascending pass over the same ops.
        $delta = 0
        foreach ($op in @($ops | Sort-Object -Property Pos, Rank, Fix)) {
            $first = $op.Pos + $delta + 1
            if ($op.Kind -eq 'newblock') {
                foreach ($s in $subs) {
                    $results += [pscustomobject]@{
                        fixId = $s.Fix; file = $relFile
                        insertedStartLine = $first + $s.Offset; insertedEndLine = $first + $s.Offset + $s.Count - 1
                    }
                }
            }
            else {
                $results += [pscustomobject]@{
                    fixId = $op.Fix; file = $relFile
                    insertedStartLine = $first; insertedEndLine = $first + @($op.Lines).Count - 1
                }
            }
            $delta += (@($op.Lines).Count - $op.Remove)
        }

        [System.IO.File]::WriteAllText($full, ($list -join $eol), $info.Encoding)
    }

    $results | Sort-Object -Property fixId
}

function New-MutTestPatch {
    <#
        .SYNOPSIS
        §6.8.1. Writes `git diff --no-index --no-color` between the two folders to $OutPath, with
        paths `a/<file>` and `b/<file>` relative to the test-app root (git is run from a staging
        folder holding copies named `a` and `b`, so no absolute path leaks into the headers).
        Exit code 1 ("differences found") is not an error; an empty diff writes an empty file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [Parameter(Mandatory = $true)][string]$PatchedPath,
        [Parameter(Mandatory = $true)][string]$OutPath
    )

    $orig = (Resolve-Path -LiteralPath $OriginalPath).Path
    $patched = (Resolve-Path -LiteralPath $PatchedPath).Path
    $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
    $outDir = Split-Path -Parent $out
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    $git = (Get-Command git -ErrorAction Stop | Select-Object -First 1).Source
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('mutpatch-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        foreach ($pair in @(@('a', $orig), @('b', $patched))) {
            $target = Join-Path $stage $pair[0]
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            foreach ($child in @(Get-ChildItem -LiteralPath $pair[1] -Force)) {
                Copy-Item -LiteralPath $child.FullName -Destination $target -Recurse -Force
            }
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $git
        $psi.Arguments = '-c core.autocrlf=false -c core.quotepath=false diff --no-index --no-color --no-prefix a b'
        $psi.WorkingDirectory = $stage
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $errTask = $process.StandardError.ReadToEndAsync()
        $stream = New-Object System.IO.MemoryStream
        $process.StandardOutput.BaseStream.CopyTo($stream)
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $stderr = $errTask.Result

        if ($exitCode -gt 1) {
            throw "git diff failed with exit code ${exitCode}: $stderr"
        }
        [System.IO.File]::WriteAllBytes($out, $stream.ToArray())
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-MutFixApply, New-MutTestPatch
