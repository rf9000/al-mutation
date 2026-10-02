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

# ---------------------------------------------------------------------------------------------
# §6.8.2: live verification. The backend functions below are interface functions (§6.5.3) this
# module calls unqualified; the caller imports the backend module first. When nothing has
# defined them yet (a unit test importing only this module), a placeholder with the real
# signature is registered so Pester's `Mock -ModuleName FixVerify` has a command to attach to.
# Importing a real backend module (before or after this one) always wins.
# ---------------------------------------------------------------------------------------------
if (-not (Get-Command -Name 'Get-MutEnvironment' -ErrorAction SilentlyContinue)) {
    function global:Get-MutEnvironment {
        param([string]$Name, $Config)
        throw 'Get-MutEnvironment: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Start-MutEnvironment' -ErrorAction SilentlyContinue)) {
    function global:Start-MutEnvironment {
        param($Env, $Config, [bool]$RequireProbe = $true)
        throw 'Start-MutEnvironment: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Reset-MutEnvironment' -ErrorAction SilentlyContinue)) {
    function global:Reset-MutEnvironment {
        param($Env, $Config)
        throw 'Reset-MutEnvironment: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Invoke-MutApi' -ErrorAction SilentlyContinue)) {
    function global:Invoke-MutApi {
        param($Env, [string]$Method, [string]$Path, $Body)
        throw 'Invoke-MutApi: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Publish-MutApp' -ErrorAction SilentlyContinue)) {
    function global:Publish-MutApp {
        param($Env, [string]$Path, [string]$Ruleset, [switch]$AllowDowngrade, [string]$SyncMode, [int]$TimeoutSec = 900)
        throw 'Publish-MutApp: no backend module has been imported into this session.'
    }
}
if (-not (Get-Command -Name 'Invoke-MutTests' -ErrorAction SilentlyContinue)) {
    function global:Invoke-MutTests {
        param($Env, $Targets, [int]$TimeoutSec = 120, [switch]$Coverage)
        throw 'Invoke-MutTests: no backend module has been imported into this session.'
    }
}

$script:FixJobTimeoutSec = 120
$script:FixPublishTimeoutSec = 900
$script:FixMaxPublishRounds = 3
$script:FixJobRetries = 2
$script:FixRecoveryPolls = 30
$script:FixRecoveryPollSec = 30
$script:FixClientWaitExpiredFraction = 0.9

function Write-MutFixLog {
    param([string]$Message)
    Write-Verbose ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message)
}

function Set-MutFixActive {
    <#
        .SYNOPSIS
        Private. PATCH mutationSetup(0) `activeMutantId` (and `currentRunNo` when given).
    #>
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][int]$MutantId,
        [int]$RunNo = 0
    )
    $body = @{ activeMutantId = $MutantId }
    if ($RunNo -gt 0) { $body['currentRunNo'] = $RunNo }
    Invoke-MutApi -Env $Ctx.Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body $body | Out-Null
}

function Get-MutFixActive {
    <#
        .SYNOPSIS
        Private. GET mutationSetup(0) and return `activeMutantId` as an int.
    #>
    param([Parameter(Mandatory = $true)]$Ctx)
    $r = Invoke-MutApi -Env $Ctx.Env -Method 'GET' -Path 'mutationSetup(0)'
    if ($null -ne $r -and $r.PSObject.Properties['activeMutantId']) { return [int]$r.activeMutantId }
    if ($null -ne $r -and $r.PSObject.Properties['value']) {
        $v = @($r.value) | Select-Object -First 1
        if ($null -ne $v -and $v.PSObject.Properties['activeMutantId']) { return [int]$v.activeMutantId }
    }
    throw "Get-MutFixActive: unexpected mutationSetup response: $($r | ConvertTo-Json -Depth 4 -Compress)"
}

function Wait-MutFixRecovery {
    <#
        .SYNOPSIS
        Private. §6.8.2 step 6 / §6.5.6: polls every 30 s (at most 30 polls, about 15 min) until
        the environment serves again. Each poll PATCHes activeMutantId 0 first (the readiness
        check is a real test job and must never run with a mutant active), then re-reads the
        environment and runs Start-MutEnvironment (its probe confirms serving). Updates
        $Ctx.Env. Throws when the environment does not come back.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    Write-Warning "Invoke-MutFixVerify: an environment call failed ($Reason); waiting for the environment to serve again."
    $lastError = $Reason
    for ($poll = 1; $poll -le $script:FixRecoveryPolls; $poll++) {
        try {
            Set-MutFixActive -Ctx $Ctx -MutantId 0
            $h = Get-MutEnvironment -Name $Ctx.Config.environmentName -Config $Ctx.Config
            if ($null -eq $h) { throw "environment '$($Ctx.Config.environmentName)' not found" }
            $Ctx.Env = Start-MutEnvironment -Env $h -Config $Ctx.Config
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Write-MutFixLog "recovery poll $poll failed: $lastError"
        }
        Start-Sleep -Seconds $script:FixRecoveryPollSec
    }
    throw "environment did not return to serving ($Reason; last error: $lastError)"
}

function Invoke-MutFixPublish {
    <#
        .SYNOPSIS
        Private. Publish-MutApp with the test app's publish arguments (ruleset, AllowDowngrade).
        An exception (not a failed result) waits for the environment and retries, at most
        $script:FixJobRetries times.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Ruleset,
        [Parameter(Mandatory = $true)][string]$What
    )
    $attempt = 0
    while ($true) {
        try {
            if ($Ruleset) {
                return (Publish-MutApp -Env $Ctx.Env -Path $Path -Ruleset $Ruleset -AllowDowngrade -TimeoutSec $script:FixPublishTimeoutSec)
            }
            return (Publish-MutApp -Env $Ctx.Env -Path $Path -AllowDowngrade -TimeoutSec $script:FixPublishTimeoutSec)
        }
        catch {
            $attempt++
            if ($attempt -gt $script:FixJobRetries) { throw }
            Wait-MutFixRecovery -Ctx $Ctx -Reason "$What : $($_.Exception.Message)"
        }
    }
}

function Stop-MutFixRunawaySessions {
    <#
        .SYNOPSIS
        Private. Best effort after a client timeout: stop the job's own test session through the
        mutant loop's helper, and fall back to an environment reset when that cannot.
    #>
    param([Parameter(Mandatory = $true)]$Ctx)
    try {
        $loop = Get-Module -Name 'MutantLoop'
        if ($null -eq $loop) {
            Import-Module (Join-Path $PSScriptRoot 'MutantLoop.psm1') | Out-Null
            $loop = Get-Module -Name 'MutantLoop'
        }
        $stopped = & $loop { param($e) Stop-MutRunawayTestSessions -Env $e -MutantId 0 } $Ctx.Env
        if (-not $stopped) {
            Reset-MutEnvironment -Env $Ctx.Env -Config $Ctx.Config | Out-Null
        }
    }
    catch {
        Write-MutFixLog "stopping the runaway session failed: $($_.Exception.Message)"
    }
}

function Invoke-MutFixJob {
    <#
        .SYNOPSIS
        Private. One test job for one target (codeunit + function) with an optional active
        mutant. Returns `{ Outcome; Error; DurationMs }` with Outcome Pass | Fail | Timeout |
        EnvError. A mutant is activated per attempt and deactivated in a `finally`. An
        exception (other than a client timeout), a failed deactivation or an empty result waits
        for the environment and retries the same job (up to 2 retries).
    #>
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][int]$MutantId
    )

    $lastProblem = $null
    for ($attempt = 0; $attempt -le $script:FixJobRetries; $attempt++) {
        $problem = $null
        $result = $null
        $deactivateError = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            try {
                if ($MutantId -gt 0) {
                    Set-MutFixActive -Ctx $Ctx -MutantId $MutantId -RunNo (9000 + $Ctx.RunNo)
                }
                $result = Invoke-MutTests -Env $Ctx.Env -Targets @($Target) -TimeoutSec $script:FixJobTimeoutSec
            }
            finally {
                if ($MutantId -gt 0) {
                    try { Set-MutFixActive -Ctx $Ctx -MutantId 0 }
                    catch { $deactivateError = $_.Exception.Message }
                }
            }
        }
        catch {
            $problem = $_.Exception.Message
        }
        $elapsedMs = [int]$sw.Elapsed.TotalMilliseconds

        if ($null -ne $problem -and $problem -match 'timed out') {
            Stop-MutFixRunawaySessions -Ctx $Ctx
            return [pscustomobject]@{ Outcome = 'Timeout'; Error = $problem; DurationMs = $elapsedMs }
        }
        if ($null -eq $problem -and $null -ne $deactivateError) {
            $problem = "deactivating the mutant failed: $deactivateError"
        }
        if ($null -eq $problem -and ([int]$result.Passed + [int]$result.Failed) -eq 0) {
            # A client-side wait that expired returns no tests and no stderr while the session keeps running (see 6.5.6).
            if ($sw.Elapsed.TotalSeconds -ge ($script:FixClientWaitExpiredFraction * $script:FixJobTimeoutSec)) {
                Stop-MutFixRunawaySessions -Ctx $Ctx
                return [pscustomobject]@{ Outcome = 'Timeout'; Error = "client wait expired after $([int]$sw.Elapsed.TotalSeconds) s (no tests reported)"; DurationMs = $elapsedMs }
            }
            $problem = 'empty result (0 tests executed)'
        }

        if ($null -eq $problem) {
            $durationMs = $elapsedMs
            if ($result.PSObject.Properties['DurationMs'] -and $null -ne $result.DurationMs) { $durationMs = [int]$result.DurationMs }
            if ([int]$result.Failed -gt 0) {
                $failedTest = @($result.Tests | Where-Object { $_.Result -eq 'Fail' }) | Select-Object -First 1
                $err = $null
                if ($null -ne $failedTest) { $err = [string]$failedTest.Error }
                return [pscustomobject]@{ Outcome = 'Fail'; Error = $err; DurationMs = $durationMs }
            }
            return [pscustomobject]@{ Outcome = 'Pass'; Error = $null; DurationMs = $durationMs }
        }

        $lastProblem = $problem
        if ($attempt -lt $script:FixJobRetries) {
            try { Wait-MutFixRecovery -Ctx $Ctx -Reason $problem }
            catch {
                return [pscustomobject]@{ Outcome = 'EnvError'; Error = "$problem; $($_.Exception.Message)"; DurationMs = $elapsedMs }
            }
        }
    }
    return [pscustomobject]@{ Outcome = 'EnvError'; Error = $lastProblem; DurationMs = 0 }
}

function Get-MutFixDiagnostics {
    <#
        .SYNOPSIS
        Private. The error diagnostics of a failed Publish-MutApp result as `{ File; Line; Text }`;
        falls back to parsing `file.al(line,col): error CODE: text` out of ErrorMessage.
    #>
    param($Publish)
    $out = @()
    foreach ($d in @($Publish.Diagnostics)) {
        if ($null -eq $d) { continue }
        if ("$($d.Severity)" -ne '' -and "$($d.Severity)".ToLower() -ne 'error') { continue }
        $out += [pscustomobject]@{
            File = "$($d.File)"; Line = [int]$d.Line
            Text = ("{0}({1}): {2} {3}" -f $d.File, $d.Line, $d.Code, $d.Message)
        }
    }
    if ($out.Count -eq 0 -and $Publish.ErrorMessage) {
        foreach ($m in [regex]::Matches("$($Publish.ErrorMessage)", '(?m)(?<f>[^\r\n()]+\.al)\((?<l>\d+),\d+\):\s*error\s+(?<c>\w+):\s*(?<m>[^\r\n]*)')) {
            $out += [pscustomobject]@{
                File = $m.Groups['f'].Value.Trim(); Line = [int]$m.Groups['l'].Value
                Text = ("{0}({1}): {2} {3}" -f $m.Groups['f'].Value.Trim(), $m.Groups['l'].Value, $m.Groups['c'].Value, $m.Groups['m'].Value)
            }
        }
    }
    return , $out
}

function ConvertTo-MutFixUtcString {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    return [string]$Value
}

function Invoke-MutFixVerify {
    <#
        .SYNOPSIS
        §6.8.2. Applies the suggested fixes of results/<N>-fixes.json to out/fix-verify/<N>/test-app,
        publishes the copy, and proves each entry on the environment: the changed test passes on
        the unmutated AUT and is killed under every mutant the entry names. Always ends by
        republishing the unpatched <workDir>/test-app and confirming activeMutantId 0. Returns the
        §7.9 object, also written (merged with an existing file) to results/<N>-verified.json.
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][int]$RunNo,
        [string[]]$FixIds,
        [string]$RepoRoot
    )

    if ([string]::IsNullOrEmpty($RepoRoot)) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }
    $workDir = [string]$Config.workDir
    if (-not [System.IO.Path]::IsPathRooted($workDir)) { $workDir = Join-Path $RepoRoot $workDir }
    $workDir = [System.IO.Path]::GetFullPath($workDir)
    $sourceTestApp = Join-Path $workDir 'test-app'
    $patchedRoot = Join-Path (Join-Path $workDir 'fix-verify') ([string]$RunNo)
    $patchedTestApp = Join-Path $patchedRoot 'test-app'
    $fixesPath = Join-Path $RepoRoot "results/$RunNo-fixes.json"
    $verifiedPath = Join-Path $RepoRoot "results/$RunNo-verified.json"

    $ruleset = $null
    if ($Config.PSObject.Properties['rulesets'] -and $null -ne $Config.rulesets) {
        $ruleset = Join-Path (Join-Path $workDir 'rulesets') $Config.rulesets.file
    }

    # 1. Select the entries.
    if (-not (Test-Path -LiteralPath $fixesPath)) { throw "Invoke-MutFixVerify: $fixesPath not found" }
    $report = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $fixesPath -Raw)
    $allFixes = @($report.fixes)
    $selected = @()
    if ($null -ne $FixIds -and @($FixIds).Count -gt 0) {
        foreach ($id in @($FixIds)) {
            $f = $allFixes | Where-Object { $_.fixId -eq $id } | Select-Object -First 1
            if ($null -eq $f) { throw "Invoke-MutFixVerify: fix '$id' not found in $fixesPath" }
            $selected += $f
        }
    }
    else {
        $selected = $allFixes
    }
    $selected = @($selected | Sort-Object -Property fixId -Unique)

    $now = { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $state = @{}
    foreach ($fix in $selected) {
        $revision = 0
        if ($fix.PSObject.Properties['revision'] -and $null -ne $fix.revision) { $revision = [int]$fix.revision }
        $state[[string]$fix.fixId] = [ordered]@{
            fixId = [string]$fix.fixId; revision = $revision; verdict = $null; verifiedUtc = $null
            compile = $null; original = $null; mutants = @()
        }
    }
    $active = @()
    foreach ($fix in $selected) {
        $isEquivalent = $fix.PSObject.Properties['verdict'] -and ([string]$fix.verdict -eq 'equivalent')
        if ($isEquivalent) {
            $state[[string]$fix.fixId].verdict = 'skipped-equivalent'
            $state[[string]$fix.fixId].verifiedUtc = & $now
        }
        else {
            $active += $fix
        }
    }

    $unmapped = @()
    $ctx = @{ Env = $null; Config = $Config; RunNo = $RunNo }
    $mainError = $null
    $touched = $false

    try {
        # 2. Environment.
        $handle = Get-MutEnvironment -Name $Config.environmentName -Config $Config
        if ($null -eq $handle) { throw "Invoke-MutFixVerify: environment '$($Config.environmentName)' not found" }
        if ($handle.Status -ne 'Running') {
            $handle = Start-MutEnvironment -Env $handle -Config $Config
        }
        $ctx.Env = $handle
        if ($active.Count -gt 0) {
            $touched = $true
            if ((Get-MutFixActive -Ctx $ctx) -ne 0) { Set-MutFixActive -Ctx $ctx -MutantId 0 }
        }

        # 3. Compile and publish.
        $published = $false
        $rounds = 0
        $ranges = @{}
        $guard = 0
        while ($active.Count -gt 0 -and $rounds -lt $script:FixMaxPublishRounds -and $guard -lt 50) {
            $guard++
            try {
                $applied = @(Invoke-MutFixApply -SourcePath $sourceTestApp -DestinationPath $patchedTestApp -Fixes @($active))
            }
            catch {
                $msg = $_.Exception.Message
                $bad = $null
                if ($msg -match '^Fix [^\s:]+ and ([^\s:]+) both change') { $bad = $Matches[1] }
                elseif ($msg -match '^Fix ([^\s:]+):') { $bad = $Matches[1] }
                $badIds = @($active | Where-Object { $_.fixId -eq $bad } | ForEach-Object { [string]$_.fixId })
                if ($badIds.Count -eq 0) {
                    foreach ($e in $active) {
                        $state[[string]$e.fixId].compile = [ordered]@{ ok = $false; diagnostics = @("apply: $msg") }
                    }
                    $active = @()
                    break
                }
                $state[$bad].compile = [ordered]@{ ok = $false; diagnostics = @("apply: $msg") }
                $active = @($active | Where-Object { [string]$_.fixId -ne $bad })
                continue
            }

            $ranges = @{}
            foreach ($a in $applied) { $ranges[[string]$a.fixId] = $a }
            $noRange = @($active | Where-Object { -not $ranges.ContainsKey([string]$_.fixId) })
            if ($noRange.Count -gt 0) {
                foreach ($e in $noRange) {
                    $state[[string]$e.fixId].compile = [ordered]@{ ok = $false; diagnostics = @('apply: the entry has no applicable change or target') }
                }
                $active = @($active | Where-Object { $ranges.ContainsKey([string]$_.fixId) })
                if ($active.Count -eq 0) { break }
                continue
            }

            $rounds++
            $pub = Invoke-MutFixPublish -Ctx $ctx -Path $patchedTestApp -Ruleset $ruleset -What 'publishing the patched test app'
            if ($pub.Success) {
                foreach ($e in $active) {
                    $state[[string]$e.fixId].compile = [ordered]@{ ok = $true; diagnostics = @() }
                }
                $published = $true
                break
            }

            $diags = Get-MutFixDiagnostics -Publish $pub
            $hit = @{}
            foreach ($d in $diags) {
                $norm = $d.File.Replace('\', '/').ToLower()
                $mapped = $false
                foreach ($e in $active) {
                    $r = $ranges[[string]$e.fixId]
                    if ($norm.EndsWith(([string]$r.file).ToLower()) -and $d.Line -ge $r.insertedStartLine -and $d.Line -le $r.insertedEndLine) {
                        if (-not $hit.ContainsKey([string]$e.fixId)) { $hit[[string]$e.fixId] = @() }
                        $hit[[string]$e.fixId] += $d.Text
                        $mapped = $true
                        break
                    }
                }
                if (-not $mapped) { $unmapped += $d.Text }
            }
            if ($hit.Count -eq 0) {
                $texts = @("unmapped compile failure: $($pub.ErrorMessage)") + @($diags | ForEach-Object { $_.Text })
                foreach ($e in $active) {
                    $state[[string]$e.fixId].compile = [ordered]@{ ok = $false; diagnostics = @($texts) }
                }
                $active = @()
                break
            }
            foreach ($k in $hit.Keys) {
                $state[$k].compile = [ordered]@{ ok = $false; diagnostics = @($hit[$k]) }
            }
            $active = @($active | Where-Object { -not $hit.ContainsKey([string]$_.fixId) })
        }
        if (-not $published) {
            foreach ($e in $active) {
                $state[[string]$e.fixId].compile = [ordered]@{ ok = $false; diagnostics = @("not published: compile still failing after $($script:FixMaxPublishRounds) rounds") }
            }
            $active = @()
        }
        foreach ($fix in $selected) {
            $s = $state[[string]$fix.fixId]
            if ($null -eq $s.verdict -and $null -ne $s.compile -and -not $s.compile.ok) {
                $s.verdict = 'compile-failed'
                $s.verifiedUtc = & $now
            }
        }

        # 4. Original, with activeMutantId = 0.
        $survivors = @()
        if ($published) {
            if ((Get-MutFixActive -Ctx $ctx) -ne 0) { Set-MutFixActive -Ctx $ctx -MutantId 0 }
            foreach ($fix in $active) {
                $s = $state[[string]$fix.fixId]
                $target = [pscustomobject]@{ CodeunitId = [int]$fix.target.codeunitId; Function = [string]$fix.target.procedure }
                $job = Invoke-MutFixJob -Ctx $ctx -Target $target -MutantId 0
                if ($job.Outcome -eq 'Pass') {
                    $s.original = [ordered]@{ result = 'Pass'; error = $null; durationMs = $job.DurationMs }
                    $survivors += $fix
                }
                elseif ($job.Outcome -eq 'EnvError') {
                    $s.original = [ordered]@{ result = $null; error = $job.Error; durationMs = $null }
                    $s.verdict = 'env-error'
                }
                else {
                    $s.original = [ordered]@{ result = 'Fail'; error = $job.Error; durationMs = $job.DurationMs }
                    $s.verdict = 'fails-on-original'
                }
                if ($null -ne $s.verdict) { $s.verifiedUtc = & $now }
            }

            # 5. Mutants.
            foreach ($fix in $survivors) {
                $s = $state[[string]$fix.fixId]
                $target = [pscustomobject]@{ CodeunitId = [int]$fix.target.codeunitId; Function = [string]$fix.target.procedure }
                $envError = $false
                $notKilled = $false
                foreach ($mid in @($fix.mutantIds | ForEach-Object { [int]$_ })) {
                    if ($envError) {
                        $s.mutants += [ordered]@{ mutantId = $mid; outcome = 'not-run'; error = $null; durationMs = $null }
                        continue
                    }
                    $job = Invoke-MutFixJob -Ctx $ctx -Target $target -MutantId $mid
                    if ($job.Outcome -eq 'Fail') {
                        $s.mutants += [ordered]@{ mutantId = $mid; outcome = 'killed'; error = $job.Error; durationMs = $job.DurationMs }
                    }
                    elseif ($job.Outcome -eq 'Timeout') {
                        $s.mutants += [ordered]@{ mutantId = $mid; outcome = 'timeout'; error = $job.Error; durationMs = $job.DurationMs }
                    }
                    elseif ($job.Outcome -eq 'Pass') {
                        $s.mutants += [ordered]@{ mutantId = $mid; outcome = 'survived'; error = $null; durationMs = $job.DurationMs }
                        $notKilled = $true
                    }
                    else {
                        $s.mutants += [ordered]@{ mutantId = $mid; outcome = 'not-run'; error = $job.Error; durationMs = $null }
                        $envError = $true
                    }
                }
                if ($envError) { $s.verdict = 'env-error' }
                elseif ($notKilled) { $s.verdict = 'not-killed' }
                else { $s.verdict = 'verified' }
                $s.verifiedUtc = & $now
            }
        }
    }
    catch {
        $mainError = $_
    }

    # 7. Restore: never leave a mutant active, republish the unpatched test app, confirm 0.
    $restoreError = $null
    if ($null -ne $ctx.Env -and $touched) {
        try { Set-MutFixActive -Ctx $ctx -MutantId 0 } catch { Write-MutFixLog "final deactivate failed: $($_.Exception.Message)" }
        try {
            $restored = Invoke-MutFixPublish -Ctx $ctx -Path $sourceTestApp -Ruleset $ruleset -What 'restoring the unpatched test app'
            if (-not $restored.Success) {
                throw "republishing the unpatched test app failed. Code: $($restored.Code); Message: $($restored.ErrorMessage)"
            }
            if ((Get-MutFixActive -Ctx $ctx) -ne 0) {
                Set-MutFixActive -Ctx $ctx -MutantId 0
                if ((Get-MutFixActive -Ctx $ctx) -ne 0) { throw 'activeMutantId is not 0 after the restore' }
            }
        }
        catch {
            $restoreError = "Invoke-MutFixVerify: restore failed: $($_.Exception.Message)"
        }
    }

    # An entry that was never reached because the run itself failed is an environment error.
    foreach ($fix in $selected) {
        $s = $state[[string]$fix.fixId]
        if ($null -eq $s.verdict) {
            $s.verdict = 'env-error'
            $s.verifiedUtc = & $now
            if ($null -eq $s.original -and $null -ne $mainError) {
                $s.original = [ordered]@{ result = $null; error = $mainError.Exception.Message; durationMs = $null }
            }
        }
    }

    # 8. Merge with an existing verified.json and write it.
    $entries = @()
    $mine = @{}
    foreach ($fix in $selected) { $mine[[string]$fix.fixId] = $true }
    if (Test-Path -LiteralPath $verifiedPath) {
        $old = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $verifiedPath -Raw)
        foreach ($oe in @($old.entries)) {
            if ($null -eq $oe -or $mine.ContainsKey([string]$oe.fixId)) { continue }
            # Windows PowerShell turns ISO date strings into DateTime on load; write them back as strings.
            $oe.verifiedUtc = ConvertTo-MutFixUtcString $oe.verifiedUtc
            $entries += $oe
        }
    }
    foreach ($fix in $selected) { $entries += [pscustomobject]$state[[string]$fix.fixId] }
    $entries = @($entries | Sort-Object -Property fixId)

    $doc = [pscustomobject][ordered]@{
        runNo               = $RunNo
        verifyRunNo         = (9000 + $RunNo)
        updatedUtc          = (& $now)
        environmentName     = [string]$Config.environmentName
        entries             = $entries
        unmappedDiagnostics = @($unmapped)
    }
    $verifiedDir = Split-Path -Parent $verifiedPath
    if (-not (Test-Path -LiteralPath $verifiedDir)) { New-Item -ItemType Directory -Force -Path $verifiedDir | Out-Null }
    [System.IO.File]::WriteAllText($verifiedPath, ($doc | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

    if ($null -ne $mainError) { throw $mainError }
    if ($null -ne $restoreError) { throw $restoreError }
    return $doc
}

function Export-MutFixDelivery {
    <#
        .SYNOPSIS
        §6.8.3 step 4. Applies only the `verified` entries of results/<N>-fixes.json to
        <workDir>/fix-verify/<N>/delivery/test-app, writes results/<N>-tests.patch against
        <workDir>/test-app (New-MutTestPatch) and results/<N>-verified.md. Pure file work.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$RunNo,
        [string]$RepoRoot,
        $Config
    )

    if ([string]::IsNullOrEmpty($RepoRoot)) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }
    if ($null -eq $Config) {
        $cfgPath = Join-Path $RepoRoot 'mutation.config.json'
        if (-not (Test-Path -LiteralPath $cfgPath)) { throw "Export-MutFixDelivery: no -Config given and $cfgPath not found" }
        $Config = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $cfgPath -Raw)
    }
    $workDir = [string]$Config.workDir
    if (-not [System.IO.Path]::IsPathRooted($workDir)) { $workDir = Join-Path $RepoRoot $workDir }
    $workDir = [System.IO.Path]::GetFullPath($workDir)
    $sourceTestApp = Join-Path $workDir 'test-app'
    $deliveryApp = Join-Path (Join-Path (Join-Path (Join-Path $workDir 'fix-verify') ([string]$RunNo)) 'delivery') 'test-app'
    $fixesPath = Join-Path $RepoRoot "results/$RunNo-fixes.json"
    $verifiedPath = Join-Path $RepoRoot "results/$RunNo-verified.json"
    $patchPath = Join-Path $RepoRoot "results/$RunNo-tests.patch"
    $mdPath = Join-Path $RepoRoot "results/$RunNo-verified.md"
    foreach ($p in @($fixesPath, $verifiedPath)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Export-MutFixDelivery: $p not found" }
    }

    $report = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $fixesPath -Raw)
    $verified = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $verifiedPath -Raw)
    $allFixes = @($report.fixes)
    $entries = @(@($verified.entries) | Sort-Object -Property fixId)

    $okIds = @($entries | Where-Object { $_.verdict -eq 'verified' } | ForEach-Object { [string]$_.fixId })
    $toApply = @($allFixes | Where-Object { $okIds -contains [string]$_.fixId })
    $missing = @($okIds | Where-Object { $id = $_; -not ($allFixes | Where-Object { [string]$_.fixId -eq $id }) })
    if ($missing.Count -gt 0) { throw "Export-MutFixDelivery: verified fix(es) not in fixes.json: $($missing -join ', ')" }

    Invoke-MutFixApply -SourcePath $sourceTestApp -DestinationPath $deliveryApp -Fixes @($toApply) | Out-Null
    New-MutTestPatch -OriginalPath $sourceTestApp -PatchedPath $deliveryApp -OutPath $patchPath

    # verified.md
    $verdicts = @('verified', 'compile-failed', 'fails-on-original', 'not-killed', 'env-error', 'skipped-equivalent')
    $nl = "`r`n"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Verified test fixes for run $RunNo$nl$nl")
    [void]$sb.Append("## Verdicts$nl$nl")
    foreach ($v in $verdicts) {
        $n = @($entries | Where-Object { $_.verdict -eq $v }).Count
        [void]$sb.Append("- ${v}: $n$nl")
    }
    [void]$sb.Append($nl + "## Entries$nl$nl")
    foreach ($e in $entries) {
        $mutants = @($e.mutants)
        $total = $mutants.Count
        $killed = @($mutants | Where-Object { $_.outcome -eq 'killed' -or $_.outcome -eq 'timeout' }).Count
        $rev = 0
        if ($e.PSObject.Properties['revision'] -and $null -ne $e.revision) { $rev = [int]$e.revision }
        [void]$sb.Append("- $($e.fixId): $($e.verdict), killed $killed/$total, revision $rev$nl")
    }

    $failed = @($entries | Where-Object { $_.verdict -ne 'verified' -and $_.verdict -ne 'skipped-equivalent' })
    [void]$sb.Append($nl + "## Not verified$nl$nl")
    if ($failed.Count -eq 0) { [void]$sb.Append("None.$nl") }
    foreach ($e in $failed) {
        [void]$sb.Append("### $($e.fixId): $($e.verdict)$nl$nl")
        if ($e.compile -and -not $e.compile.ok) {
            foreach ($d in @($e.compile.diagnostics)) { [void]$sb.Append("- compile: $d$nl") }
        }
        if ($e.original -and $e.original.result -eq 'Fail') {
            [void]$sb.Append("- original run: $($e.original.error)$nl")
        }
        $surv = @(@($e.mutants) | Where-Object { $_.outcome -eq 'survived' })
        foreach ($m in $surv) { [void]$sb.Append("- survived: $($m.mutantId)$nl") }
        foreach ($m in @(@($e.mutants) | Where-Object { $_.outcome -eq 'not-run' })) { [void]$sb.Append("- not run: $($m.mutantId)$nl") }
        if ($e.verdict -eq 'env-error') {
            if ($e.original -and $e.original.error -and $e.original.result -ne 'Fail') { [void]$sb.Append("- environment: $($e.original.error)$nl") }
            foreach ($m in @(@($e.mutants) | Where-Object { $_.error -and $_.outcome -ne 'killed' -and $_.outcome -ne 'survived' })) {
                [void]$sb.Append("- environment (mutant $($m.mutantId)): $($m.error)$nl")
            }
        }
        [void]$sb.Append($nl)
    }
    if (@($verified.unmappedDiagnostics).Count -gt 0) {
        [void]$sb.Append("## Unmapped compile diagnostics$nl$nl")
        foreach ($d in @($verified.unmappedDiagnostics)) { [void]$sb.Append("- $d$nl") }
        [void]$sb.Append($nl)
    }

    [void]$sb.Append("## Applying the patch$nl$nl")
    [void]$sb.Append("Patch: results/$RunNo-tests.patch ($($okIds.Count) verified entries). In the test-app root run:$nl$nl")
    [void]$sb.Append("    git apply -p1 <path-to>/$RunNo-tests.patch$nl$nl")
    [void]$sb.Append("Line numbers in the fixes come from the out/test-app snapshot (SPEC 6.7.5); procedures are located by name, so a drifted repository may still need a manual merge. After applying, re-run each changed test.$nl")

    [System.IO.File]::WriteAllText($mdPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function Invoke-MutFixApply, New-MutTestPatch, Invoke-MutFixVerify, Export-MutFixDelivery
