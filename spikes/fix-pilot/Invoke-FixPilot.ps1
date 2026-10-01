<#
    .SYNOPSIS
    Fix-loop PILOT (throwaway spike): applies 8 suggested test fixes of mutation run 15 to a COPY
    of the test app, publishes it, checks the changed tests pass on the unmutated AUT, then
    re-runs each covered mutant and checks it is now Killed.

    .DESCRIPTION
    1. Copy out/test-app -> out/fix-pilot/test-app (fresh). out/test-app and the read-only source
       trees are never modified.
    2. Apply the entries (add-assert / modify-test / new-test) to the copy. Procedures are located
       BY NAME with Get-MutTestProcedureIndex on the copy before any edit; edits per file are applied
       bottom-up; line endings and BOM are preserved.
    3. Ensure activeMutantId = 0, Publish-MutApp the copy. On compile errors: map each error line to
       the entry whose inserted lines contain it, drop those entries, re-apply, retry (max 3 rounds).
    4. Baseline on the original (activeMutantId 0): run each applied entry's target function.
    5. For each mutant of each baseline-passing entry: activate it (runNo 9015), run ONLY that
       function (client timeout 120 s), deactivate immediately (also in finally). Killed = test failed.
       A timeout counts as Killed but is reported separately. Strictly sequential.
    6. Restore: republish the unpatched out/test-app, confirm activeMutantId = 0.
    7. Write out/fix-pilot/results.json and print a summary.

    Only the environment named in mutation.config.json is ever touched.
#>
param(
    [string]$ConfigPath = 'mutation.config.json',
    [string]$FixesPath = 'results/15-fixes.json',
    [string[]]$FixIds = @('F020', 'F022', 'F027', 'F033', 'F041', 'F056', 'F060', 'F063'),
    [int]$MutantRunNo = 9015,
    [int]$JobTimeoutSec = 120,
    [switch]$ApplyOnly   # dry run: copy + apply, print ranges, no environment access
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\lib\References.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\lib\MutantLoop.psm1') -Force

$clock = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Log {
    param([string]$Message)
    Write-Output ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message)
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath = Join-Path $repoRoot $ConfigPath }
if (-not [System.IO.Path]::IsPathRooted($FixesPath)) { $FixesPath = Join-Path $repoRoot $FixesPath }

$cfg = Get-MutConfig -Path $ConfigPath
$workDir = $cfg.workDir
if (-not [System.IO.Path]::IsPathRooted($workDir)) { $workDir = Join-Path $repoRoot $workDir }
$workDir = [System.IO.Path]::GetFullPath($workDir)
$srcTestApp = Join-Path $workDir 'test-app'
$pilotDir = Join-Path $workDir 'fix-pilot'
$copyDir = Join-Path $pilotDir 'test-app'
$resultsPath = Join-Path $pilotDir 'results.json'
$ruleset = Join-Path (Join-Path $workDir 'rulesets') $cfg.rulesets.file
if (-not (Test-Path $ruleset)) { throw "ruleset not found: $ruleset" }
if (-not (Test-Path $srcTestApp)) { throw "out/test-app not found: $srcTestApp" }

$script:Cfg = $cfg
if (-not $ApplyOnly) {
$script:Env = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $script:Env) { throw "environment '$($cfg.environmentName)' not found" }
if ($script:Env.Status -ne 'Running') {
    Write-Log "Environment status '$($script:Env.Status)'; starting..."
    $script:Env = Start-MutEnvironment -Env $script:Env -Config $cfg -RequireProbe $false
}
Write-Log "Environment: $($script:Env.Name) ($($script:Env.Id))"
}

# ------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------

function Set-ActiveMutant {
    param([int]$MutantId, [int]$RunNo = 0)
    $body = @{ activeMutantId = $MutantId }
    if ($RunNo -gt 0) { $body['currentRunNo'] = $RunNo }
    Invoke-MutApi -Env $script:Env -Method 'PATCH' -Path 'mutationSetup(0)' -Body $body | Out-Null
}

function Get-ActiveMutant {
    $r = Invoke-MutApi -Env $script:Env -Method 'GET' -Path 'mutationSetup(0)'
    if ($null -ne $r -and $r.PSObject.Properties['activeMutantId']) { return [int]$r.activeMutantId }
    if ($null -ne $r -and $r.PSObject.Properties['value']) {
        $v = @($r.value) | Select-Object -First 1
        if ($null -ne $v -and $v.PSObject.Properties['activeMutantId']) { return [int]$v.activeMutantId }
    }
    throw "Get-ActiveMutant: unexpected mutationSetup response: $($r | ConvertTo-Json -Depth 4 -Compress)"
}

function Invoke-OutageRecovery {
    # Wait-and-readiness loop in the spirit of Wait-MutOutageRecovery (private there, and its
    # Start-MutEnvironment probe targets codeunit 50400, which is NOT installed on mut-spike-02, so
    # it could never succeed here). Each poll: deactivate the mutant first, then require the
    # environment to be Running and the baseline probe test (95155 / first test) to execute.
    param([string]$Reason)
    Write-Log "Outage recovery: $Reason"
    $deadline = (Get-Date).AddMinutes(15)
    $probe = @([pscustomobject]@{ CodeunitId = 95155; Function = 'UpdatePlaceholderRows_EmptyInputs_BecomesNoMatchingAccounts' })
    while ($true) {
        try {
            Set-ActiveMutant -MutantId 0
            $h = Get-MutEnvironment -Name $script:Cfg.environmentName -Config $script:Cfg
            if ($null -ne $h -and $h.Status -ne 'Running') {
                $script:Env = Start-MutEnvironment -Env $h -Config $script:Cfg -RequireProbe $false
            }
            elseif ($null -ne $h) { $script:Env = $h }
            $r = Invoke-MutTests -Env $script:Env -Targets $probe -TimeoutSec 120
            if (($r.Passed + $r.Failed) -gt 0) { Write-Log 'Outage recovery: environment is serving.'; return }
        }
        catch { Write-Log "  recovery poll: $($_.Exception.Message)" }
        if ((Get-Date) -ge $deadline) { throw "environment did not return to serving within 15 min ($Reason)" }
        Start-Sleep -Seconds 30
    }
}

function Invoke-WithRecovery {
    # Runs $Action; on an exception that is not a plain timeout, waits for the environment and retries (max 2).
    param([scriptblock]$Action, [string]$What)
    $attempt = 0
    while ($true) {
        try { return (& $Action) }
        catch {
            $attempt++
            if ($attempt -gt 2) { throw }
            Write-Log "$What failed ($($_.Exception.Message)); waiting for the environment (attempt $attempt)."
            Invoke-OutageRecovery -Reason "$What : $($_.Exception.Message)"
        }
    }
}

function Read-TextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    $off = 0; if ($hasBom) { $off = 3 }
    [pscustomobject]@{ Text = $enc.GetString($bytes, $off, $bytes.Length - $off); Encoding = $enc }
}

function Copy-TestApp {
    if (Test-Path $copyDir) { Remove-Item -Recurse -Force $copyDir }
    New-Item -ItemType Directory -Force -Path $pilotDir | Out-Null
    Copy-Item -Recurse -Force -Path $srcTestApp -Destination $copyDir
}

function Split-AlCode {
    param([string]$Code)
    return @($Code -split "\r?\n")
}

function Invoke-ApplyEntries {
    <#
        Applies $Entries to the fresh copy. Returns @{ Applied = @{fixId = @{File; Start; End}};
        Failed = @{fixId = message} }. Procedures are located by name BEFORE any edit.
    #>
    param($Entries)

    $index = @(Get-MutTestProcedureIndex -TestAppPath $copyDir)
    $applied = @{}
    $failed = @{}
    $opsByFile = @{}

    foreach ($e in $Entries) {
        $fileEntry = $index | Where-Object { $_.File -eq $e.File } | Select-Object -First 1
        if ($null -eq $fileEntry) { $failed[$e.FixId] = "target file '$($e.File)' is not a test codeunit file in the copy"; continue }
        $full = Join-Path $copyDir ($e.File -replace '/', '\')
        if (-not $opsByFile.ContainsKey($full)) { $opsByFile[$full] = @() }
        $alLines = Split-AlCode $e.AlCode

        if ($e.Change -eq 'new-test') {
            $opsByFile[$full] += [pscustomobject]@{ Fix = $e.FixId; Kind = 'new'; Pos = [int]::MaxValue; Remove = 0; Lines = $alLines }
            continue
        }
        $proc = @($fileEntry.Procedures) | Where-Object { $_.Name -eq $e.Procedure } | Select-Object -First 1
        if ($null -eq $proc) { $failed[$e.FixId] = "procedure '$($e.Procedure)' not found in $($e.File)"; continue }

        if ($e.Change -eq 'add-assert') {
            $after = [int]$e.AfterLine
            if ($after -lt $proc.StartLine -or $after -ge $proc.EndLine) {
                $failed[$e.FixId] = "anchor.afterLine $after is outside procedure '$($e.Procedure)' (lines $($proc.StartLine)-$($proc.EndLine))"
                continue
            }
            $opsByFile[$full] += [pscustomobject]@{ Fix = $e.FixId; Kind = 'add'; Pos = $after; Remove = 0; Lines = $alLines }
        }
        elseif ($e.Change -eq 'modify-test') {
            $opsByFile[$full] += [pscustomobject]@{ Fix = $e.FixId; Kind = 'mod'; Pos = ($proc.StartLine - 1); Remove = ($proc.EndLine - $proc.StartLine + 1); Lines = $alLines }
        }
        else { $failed[$e.FixId] = "unknown change kind '$($e.Change)'" }
    }

    foreach ($full in @($opsByFile.Keys)) {
        $ops = @($opsByFile[$full])
        $info = Read-TextFile -Path $full
        $eol = "`n"; if ($info.Text.Contains("`r`n")) { $eol = "`r`n" }
        $list = New-Object 'System.Collections.Generic.List[string]'
        $list.AddRange([string[]]@([regex]::Split($info.Text, '\r?\n')))

        # position of the codeunit's final closing brace for new-test procedures
        $closeIdx = -1
        for ($i = $list.Count - 1; $i -ge 0; $i--) { if ($list[$i].Trim() -eq '}') { $closeIdx = $i; break } }

        $newOps = @($ops | Where-Object { $_.Kind -eq 'new' })
        $otherOps = @($ops | Where-Object { $_.Kind -ne 'new' })
        $all = @($otherOps)
        if ($newOps.Count -gt 0) {
            if ($closeIdx -lt 0) {
                foreach ($n in $newOps) { $failed[$n.Fix] = 'no closing brace found for the codeunit' }
            }
            else {
                $block = @(); $sub = @()
                foreach ($n in $newOps) {
                    $block += ''
                    $sub += [pscustomobject]@{ Fix = $n.Fix; Offset = $block.Count; Count = @($n.Lines).Count }
                    $block += @($n.Lines)
                }
                $all += [pscustomobject]@{ Fix = $null; Kind = 'newblock'; Pos = $closeIdx; Remove = 0; Lines = $block; Sub = $sub }
            }
        }

        # bottom-up application
        foreach ($op in @($all | Sort-Object -Property Pos -Descending)) {
            if ($op.Remove -gt 0) { $list.RemoveRange($op.Pos, $op.Remove) }
            $list.InsertRange($op.Pos, [string[]]@($op.Lines))
        }

        # final line ranges (ascending pass over the same ops)
        $delta = 0
        $relFile = $full.Substring($copyDir.Length).TrimStart('\', '/').Replace('\', '/')
        foreach ($op in @($all | Sort-Object -Property Pos)) {
            $firstLine = $op.Pos + $delta + 1
            if ($op.Kind -eq 'newblock') {
                foreach ($s in $op.Sub) {
                    $applied[$s.Fix] = @{ File = $relFile; Start = $firstLine + $s.Offset; End = $firstLine + $s.Offset + $s.Count - 1 }
                }
            }
            else {
                $applied[$op.Fix] = @{ File = $relFile; Start = $firstLine; End = $firstLine + @($op.Lines).Count - 1 }
            }
            $delta += (@($op.Lines).Count - $op.Remove)
        }

        [System.IO.File]::WriteAllText($full, ($list -join $eol), $info.Encoding)
    }

    return @{ Applied = $applied; Failed = $failed }
}

function Get-CompileDiagnostics {
    param($Publish)
    $out = @()
    foreach ($d in @($Publish.Diagnostics)) {
        if ($null -eq $d) { continue }
        if ("$($d.Severity)" -ne '' -and "$($d.Severity)".ToLower() -ne 'error') { continue }
        $out += [pscustomobject]@{ File = "$($d.File)"; Line = [int]$d.Line; Code = "$($d.Code)"; Message = "$($d.Message)" }
    }
    if ($out.Count -eq 0 -and $Publish.ErrorMessage) {
        foreach ($m in [regex]::Matches("$($Publish.ErrorMessage)", '(?m)(?<f>[^\r\n()]+\.al)\((?<l>\d+),\d+\):\s*error\s+(?<c>\w+):\s*(?<m>[^\r\n]*)')) {
            $out += [pscustomobject]@{ File = $m.Groups['f'].Value.Trim(); Line = [int]$m.Groups['l'].Value; Code = $m.Groups['c'].Value; Message = $m.Groups['m'].Value }
        }
    }
    return , $out
}

function Format-Diag {
    param($D)
    return ("{0}({1}): {2} {3}" -f $D.File, $D.Line, $D.Code, $D.Message)
}

# ------------------------------------------------------------------------------------------
# Load the entries
# ------------------------------------------------------------------------------------------

$parsed = ConvertFrom-Json -InputObject (Get-Content -Path $FixesPath -Raw)
$allFixes = @($parsed.fixes)
$entries = @()
foreach ($id in $FixIds) {
    $f = $allFixes | Where-Object { $_.fixId -eq $id } | Select-Object -First 1
    if ($null -eq $f) { throw "fix $id not found in $FixesPath" }
    $afterLine = $null
    if ($null -ne $f.anchor -and $f.anchor.PSObject.Properties['afterLine']) { $afterLine = $f.anchor.afterLine }
    $entries += [pscustomobject]@{
        FixId = $f.fixId; MutantIds = @($f.mutantIds | ForEach-Object { [int]$_ }); Change = $f.change
        CodeunitId = [int]$f.target.codeunitId; File = $f.target.file; Procedure = $f.target.procedure
        AfterLine = $afterLine; AlCode = $f.alCode
    }
}
Write-Log "Loaded $($entries.Count) entries: $(($entries | ForEach-Object { $_.FixId }) -join ', ')"

$state = @{}
foreach ($e in $entries) {
    $state[$e.FixId] = [ordered]@{
        fixId = $e.FixId; change = $e.Change; codeunitId = $e.CodeunitId; procedure = $e.Procedure
        mutantIds = $e.MutantIds; compileOk = $null; compileErrors = @(); applyError = $null
        passesOnOriginal = $null; baselineError = $null; baselineDurationMs = $null; mutants = @()
    }
}

function Save-Results {
    param($Extra)
    $doc = [ordered]@{
        runNo = 15; pilotMutantRunNo = $MutantRunNo; environment = $cfg.environmentName
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o'); wallClockSec = [math]::Round($clock.Elapsed.TotalSeconds, 0)
        entries = @($entries | ForEach-Object { $state[$_.FixId] })
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] } }
    New-Item -ItemType Directory -Force -Path $pilotDir | Out-Null
    ($doc | ConvertTo-Json -Depth 12) | Set-Content -Path $resultsPath -Encoding UTF8
}

$extra = @{}
$restored = $false

if ($ApplyOnly) {
    Copy-TestApp
    $res = Invoke-ApplyEntries -Entries $entries
    foreach ($k in $res.Applied.Keys) { Write-Output ("{0}: {1} lines {2}-{3}" -f $k, $res.Applied[$k].File, $res.Applied[$k].Start, $res.Applied[$k].End) }
    foreach ($k in $res.Failed.Keys) { Write-Output ("{0}: FAILED {1}" -f $k, $res.Failed[$k]) }
    return
}

try {
    # --------------------------------------------------------------------------------------
    # 3. Apply + publish with compile-error feedback
    # --------------------------------------------------------------------------------------
    $startMutant = Get-ActiveMutant
    Write-Log "activeMutantId before publish: $startMutant"
    if ($startMutant -ne 0) { Set-ActiveMutant -MutantId 0; Write-Log 'PATCHed activeMutantId to 0.' }
    $extra['activeMutantIdAtStart'] = $startMutant

    $active = @($entries)
    $published = $false
    $ranges = @{}
    for ($round = 1; $round -le 3 -and $active.Count -gt 0; $round++) {
        Write-Log "=== Compile round $round with $($active.Count) entries: $(($active | ForEach-Object { $_.FixId }) -join ', ') ==="
        Copy-TestApp
        $res = Invoke-ApplyEntries -Entries $active
        foreach ($k in @($res.Failed.Keys)) {
            $state[$k].applyError = $res.Failed[$k]; $state[$k].compileOk = $false
            $state[$k].compileErrors = @("apply: $($res.Failed[$k])")
            Write-Log "$k not applied: $($res.Failed[$k])"
        }
        $active = @($active | Where-Object { -not $res.Failed.ContainsKey($_.FixId) })
        $ranges = $res.Applied
        if ($active.Count -eq 0) { break }

        $pub = Invoke-WithRecovery -What 'Publish test-app copy' -Action {
            Publish-MutApp -Env $script:Env -Path $copyDir -Ruleset $ruleset -AllowDowngrade -TimeoutSec 900
        }
        Write-Log "Publish: Success=$($pub.Success) duration=$([math]::Round($pub.DurationSec,1))s"
        if ($pub.Success) {
            foreach ($e in $active) { $state[$e.FixId].compileOk = $true }
            $published = $true
            break
        }

        $diags = Get-CompileDiagnostics -Publish $pub
        Write-Log "Compile failed: $($diags.Count) error diagnostics; ErrorMessage: $($pub.ErrorMessage)"
        $hit = @{}
        $unmapped = @()
        foreach ($d in $diags) {
            Write-Log ("  " + (Format-Diag $d))
            $normFile = $d.File.Replace('\', '/')
            $mapped = $false
            foreach ($e in $active) {
                $r = $ranges[$e.FixId]
                if ($null -eq $r) { continue }
                if (($normFile.ToLower().EndsWith($r.File.ToLower())) -and $d.Line -ge $r.Start -and $d.Line -le $r.End) {
                    if (-not $hit.ContainsKey($e.FixId)) { $hit[$e.FixId] = @() }
                    $hit[$e.FixId] += (Format-Diag $d); $mapped = $true; break
                }
            }
            if (-not $mapped) { $unmapped += (Format-Diag $d) }
        }
        if ($hit.Count -eq 0) {
            $msg = @("unmapped compile failure: $($pub.ErrorMessage)") + $unmapped
            foreach ($e in $active) { $state[$e.FixId].compileOk = $false; $state[$e.FixId].compileErrors = $msg }
            $active = @()
            break
        }
        foreach ($k in $hit.Keys) { $state[$k].compileOk = $false; $state[$k].compileErrors = @($hit[$k]) }
        if ($unmapped.Count -gt 0) { $extra["unmappedDiagnosticsRound$round"] = $unmapped }
        $active = @($active | Where-Object { -not $hit.ContainsKey($_.FixId) })
    }
    if (-not $published) {
        foreach ($e in $active) {
            if ($null -eq $state[$e.FixId].compileOk) {
                $state[$e.FixId].compileOk = $false
                $state[$e.FixId].compileErrors = @('not published: compile still failing after 3 rounds')
            }
        }
        $active = @()
    }
    Save-Results -Extra $extra

    # --------------------------------------------------------------------------------------
    # 4. Baseline on the original
    # --------------------------------------------------------------------------------------
    $baselineOk = @()
    if ($published) {
        if ((Get-ActiveMutant) -ne 0) { Set-ActiveMutant -MutantId 0 }
        foreach ($e in $active) {
            Write-Log "=== Baseline $($e.FixId): $($e.CodeunitId) / $($e.Procedure) ==="
            $targets = @([pscustomobject]@{ CodeunitId = $e.CodeunitId; Function = $e.Procedure })
            $r = $null; $err = $null
            for ($try = 1; $try -le 3; $try++) {
                try {
                    $r = Invoke-MutTests -Env $script:Env -Targets $targets -TimeoutSec $JobTimeoutSec
                    $err = $null
                    if (($r.Passed + $r.Failed) -gt 0) { break }
                    $err = 'empty result (0 tests executed)'
                }
                catch { $err = $_.Exception.Message; $r = $null }
                Write-Log "  baseline attempt $try problem: $err"
                if ($try -lt 3) { Invoke-OutageRecovery -Reason "baseline $($e.FixId): $err" }
            }
            if ($null -eq $r -or ($r.Passed + $r.Failed) -eq 0) {
                $state[$e.FixId].passesOnOriginal = $false
                $state[$e.FixId].baselineError = "no usable result: $err"
            }
            else {
                $t = @($r.Tests) | Select-Object -First 1
                $state[$e.FixId].baselineDurationMs = $r.DurationMs
                if ($r.Failed -eq 0) { $state[$e.FixId].passesOnOriginal = $true; $baselineOk += $e }
                else {
                    $state[$e.FixId].passesOnOriginal = $false
                    $failedTest = @($r.Tests) | Where-Object { $_.Result -eq 'Fail' } | Select-Object -First 1
                    $state[$e.FixId].baselineError = "$($failedTest.Error)"
                }
            }
            Write-Log "  $($e.FixId) passesOnOriginal=$($state[$e.FixId].passesOnOriginal) $($state[$e.FixId].baselineError)"
            Save-Results -Extra $extra
        }

        # ----------------------------------------------------------------------------------
        # 5. Mutants
        # ----------------------------------------------------------------------------------
        foreach ($e in $baselineOk) {
            foreach ($mid in $e.MutantIds) {
                Write-Log "=== $($e.FixId) mutant $mid ==="
                $targets = @([pscustomobject]@{ CodeunitId = $e.CodeunitId; Function = $e.Procedure })
                $row = [ordered]@{ mutantId = $mid; status = 'error'; error = $null; durationSec = $null; attempts = 0 }
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $timedOutOnce = $false
                for ($try = 1; $try -le 4; $try++) {
                    $row.attempts = $try
                    $outcome = $null; $problem = $null
                    try {
                        try {
                            Set-ActiveMutant -MutantId $mid -RunNo $MutantRunNo
                            $outcome = Invoke-MutTests -Env $script:Env -Targets $targets -TimeoutSec $JobTimeoutSec
                        }
                        finally {
                            try { Set-ActiveMutant -MutantId 0 -RunNo $MutantRunNo }
                            catch { Write-Log "  WARNING: could not deactivate mutant: $($_.Exception.Message)"; Invoke-OutageRecovery -Reason 'deactivate after mutant run' }
                        }
                    }
                    catch { $problem = $_.Exception.Message }

                    if ($null -ne $problem) {
                        if ($problem -match 'timed out') {
                            if ($timedOutOnce) { $row.status = 'timeout'; $row.error = $problem; break }
                            $timedOutOnce = $true
                            Write-Log "  timeout ($problem); stopping runaway session and re-running once to confirm."
                            try { & (Get-Module MutantLoop) { param($en) Stop-MutRunawayTestSessions -Env $en -MutantId 0 } $script:Env | Out-Null } catch { Write-Log "  stop sessions failed: $($_.Exception.Message)" }
                            Start-Sleep -Seconds 20
                            continue
                        }
                        Write-Log "  attempt $try error: $problem"
                        $row.error = $problem
                        Invoke-OutageRecovery -Reason "mutant $mid : $problem"
                        continue
                    }
                    if (($outcome.Passed + $outcome.Failed) -eq 0) {
                        Write-Log "  attempt ${try}: empty result (0 tests); recovering and retrying."
                        $row.error = 'empty result (0 tests executed)'
                        Start-Sleep -Seconds 30
                        continue
                    }
                    if ($outcome.Failed -gt 0) {
                        $ft = @($outcome.Tests) | Where-Object { $_.Result -eq 'Fail' } | Select-Object -First 1
                        $row.status = 'killed'; $row.error = "$($ft.Error)"
                    }
                    else { $row.status = 'survived'; $row.error = $null }
                    break
                }
                $row.durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Write-Log "  mutant $mid : $($row.status) ($($row.durationSec)s) $($row.error)"
                $state[$e.FixId].mutants += [pscustomobject]$row
                Save-Results -Extra $extra
            }
        }
    }
}
finally {
    # Never leave a mutant active.
    try { Set-ActiveMutant -MutantId 0 } catch { Write-Log "WARNING: final deactivate failed: $($_.Exception.Message)" }

    # ----------------------------------------------------------------------------------
    # 6. Restore the unpatched test app
    # ----------------------------------------------------------------------------------
    try {
        Write-Log '=== Restore: republish unpatched out/test-app ==='
        $rp = Invoke-WithRecovery -What 'Restore publish' -Action {
            Publish-MutApp -Env $script:Env -Path $srcTestApp -Ruleset $ruleset -AllowDowngrade -TimeoutSec 900
        }
        $extra['restorePublishSuccess'] = $rp.Success
        Write-Log "Restore publish: Success=$($rp.Success)"
        $extra['restoreActiveMutantId'] = Get-ActiveMutant
        Write-Log "activeMutantId after restore: $($extra['restoreActiveMutantId'])"
        $restored = [bool]$rp.Success -and ($extra['restoreActiveMutantId'] -eq 0)
    }
    catch { Write-Log "RESTORE FAILED: $($_.Exception.Message)"; $extra['restoreError'] = $_.Exception.Message }
    $extra['restored'] = $restored
    Save-Results -Extra $extra
}

# ------------------------------------------------------------------------------------------
# 7. Summary
# ------------------------------------------------------------------------------------------
Write-Output ''
Write-Output ('{0,-6} {1,-10} {2,-9} {3,-14}' -f 'Fix', 'compileOk', 'passOrig', 'killed/total')
foreach ($e in $entries) {
    $s = $state[$e.FixId]
    $ms = @($s.mutants)
    $k = @($ms | Where-Object { $_.status -eq 'killed' -or $_.status -eq 'timeout' }).Count
    $to = @($ms | Where-Object { $_.status -eq 'timeout' }).Count
    $txt = "$k/$(@($s.mutantIds).Count)"
    if ($to -gt 0) { $txt += " ($to timeout)" }
    Write-Output ('{0,-6} {1,-10} {2,-9} {3,-14}' -f $e.FixId, $s.compileOk, $s.passesOnOriginal, $txt)
}
Write-Output ("Wall clock: {0:N1} min; restored={1}; results: {2}" -f ($clock.Elapsed.TotalMinutes), $restored, $resultsPath)
