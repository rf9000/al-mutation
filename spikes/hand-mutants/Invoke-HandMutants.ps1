<#
    .SYNOPSIS
    T13 hand-mutant spike: applies the 20 hand-written mutants of docs/SPEC.md §6.6.5 one at a
    time to the AUT COPY under out/aut-original (never the read-only source, §4 item 1), deploys
    each mutated build to mut-spike-01, runs test codeunit 95155, and records Killed / Survived /
    Drift / CompileError per mutant.

    .DESCRIPTION
    Flow (§6.6.5, task T13 brief):
      1. Resolve config, ensure the environment is Running.
      2. Sync-MutAutCopy (mirrors the read-only AUT/test-app/rulesets into out/).
      3. Publish the AUT copy and the test-app copy (ruleset, -AllowDowngrade, 900s timeout).
      4. Baseline run of 95155 -- must pass (0 failures).
      5. For each of the 20 mutants in mutants.json, in id order:
         a. Locate the `find` text: check the given `line` first; if not there, search the
            whole file and require EXACTLY ONE occurrence; otherwise record Drift
            ("source drift: <id>") and move on. HM11-HM13/HM15 rely on this: their find text
            recurs elsewhere in the file, so an off-target line always drifts.
         b. Apply the edit to the copy only, Publish-MutApp, run 95155, classify
            Killed (any failure) / Survived (all pass) / CompileError (publish failed -- first
            diagnostic recorded), then restore the exact original bytes of the file in a
            `finally` block so a crash cannot leave a mutated copy behind.
         c. Write results.json after every mutant (crash safety).
      6. Republish the clean AUT copy and rerun 95155 to prove the baseline is green again.

    Never touches anything under the read-only AUT/test-app source trees -- all reads/writes in
    the per-mutant loop are against $sync.AutPath (a copy under out/). One test job at a time
    (no Start-Job / background jobs here, per guardrail #8). If the environment drops to Stopped
    mid-run, it is restarted with Start-MutEnvironment and the failed step is retried once.
#>
param(
    [string]$ConfigPath = 'mutation.config.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\lib\AutCopy.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force

function Write-MutLog {
    param([string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Output "[$ts] $Message"
}

function Get-MutFileTextInfo {
    <#
        .SYNOPSIS
        Reads a text file's raw bytes, detects a UTF-8 BOM, and decodes it into text. Returns
        @{ Text; Encoding } where Encoding is the exact System.Text.Encoding object to reuse on
        write-back (preserves BOM presence/absence).
    #>
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $encoding = New-Object System.Text.UTF8Encoding($hasBom)
    $offset = 0
    if ($hasBom) { $offset = 3 }
    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)

    return [pscustomobject]@{ Text = $text; Encoding = $encoding }
}

function Find-MutantLine {
    <#
        .SYNOPSIS
        Locates the 1-based line number containing $Find (a literal substring, not a regex).
        Checks $GivenLine first (any occurrence on that line wins outright, per §6.6.5 -- this
        is why HM11-HM13/HM15 must land on their exact given line). Otherwise scans every line
        of the file and requires EXACTLY ONE total occurrence across the whole file; returns
        $null (drift) on zero or more than one.
    #>
    param(
        [string[]]$Lines,
        [int]$GivenLine,
        [string]$Find
    )

    if ($GivenLine -ge 1 -and $GivenLine -le $Lines.Count -and $Lines[$GivenLine - 1].Contains($Find)) {
        return $GivenLine
    }

    $hits = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $searchStart = 0
        while (($searchStart = $line.IndexOf($Find, $searchStart, [System.StringComparison]::Ordinal)) -ge 0) {
            $hits += ($i + 1)
            $searchStart += [Math]::Max(1, $Find.Length)
        }
    }

    if ($hits.Count -eq 1) {
        return $hits[0]
    }
    return $null
}

function Invoke-MutWithEnvRecovery {
    <#
        .SYNOPSIS
        Runs $Action (a scriptblock referencing $script:EnvHandle by name). On failure, checks
        the environment's live status; if it is not Running, restarts it via Start-MutEnvironment
        (updating $script:EnvHandle) and retries $Action exactly once. Otherwise rethrows.
    #>
    param([scriptblock]$Action)

    try {
        return & $Action
    }
    catch {
        $originalError = $_
        Write-MutLog "Action failed: $($originalError.Exception.Message). Probing environment status..."
        $probe = $null
        try { $probe = Get-MutEnvironment -Name $script:Cfg.environmentName -Config $script:Cfg } catch { $probe = $null }

        if ($null -ne $probe -and $probe.Status -ne 'Running') {
            Write-MutLog "Environment status is '$($probe.Status)'; restarting via Start-MutEnvironment..."
            $script:EnvHandle = Start-MutEnvironment -Env $probe -Config $script:Cfg
            Write-MutLog 'Environment restarted; retrying the failed action once.'
            return & $Action
        }
        throw $originalError
    }
}

function Get-MutFirstDiagnostic {
    param($Diagnostics)
    $first = @($Diagnostics) | Select-Object -First 1
    if ($null -eq $first) { return 'publish failed; no diagnostics returned' }
    return ($first | ConvertTo-Json -Depth 6 -Compress)
}

# ============================================================================================
# Setup
# ============================================================================================

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}

Write-MutLog '=== T13 hand mutants (HM01-HM20) ==='
Write-MutLog "Config: $ConfigPath"

$script:Cfg = Get-MutConfig -Path $ConfigPath
$cfg = $script:Cfg

$script:EnvHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $script:EnvHandle) {
    throw "Invoke-HandMutants: environment '$($cfg.environmentName)' not found."
}
if ($script:EnvHandle.Status -ne 'Running') {
    Write-MutLog "Environment status '$($script:EnvHandle.Status)'; starting..."
    $script:EnvHandle = Start-MutEnvironment -Env $script:EnvHandle -Config $cfg
}
Write-MutLog "Environment: $($script:EnvHandle.Name) ($($script:EnvHandle.Id)), status Running."

Write-MutLog '--- Sync-MutAutCopy ---'
$sync = Sync-MutAutCopy -Config $cfg
Write-MutLog "AutPath      = $($sync.AutPath)"
Write-MutLog "TestAppPath  = $($sync.TestAppPath)"
Write-MutLog "RulesetsPath = $($sync.RulesetsPath)"

$rulesetFile = $null
if ($sync.RulesetsPath) {
    $rulesetFile = Join-Path $sync.RulesetsPath $cfg.rulesets.file
}
if (-not $rulesetFile -or -not (Test-Path $rulesetFile)) {
    throw "Invoke-HandMutants: ruleset file not found: '$rulesetFile'."
}
Write-MutLog "Ruleset: $rulesetFile"

$targetRelPath = 'Authentication\Codeunit\AuthShareDetection.Codeunit.al'
$targetFile = Join-Path $sync.AutPath $targetRelPath
if (-not (Test-Path $targetFile)) {
    throw "Invoke-HandMutants: target file not found in synced copy: '$targetFile'."
}

# --- Publish AUT copy + test app copy ---------------------------------------------------
Write-MutLog '--- Publish AUT copy ---'
$autPublish = Publish-MutApp -Env $script:EnvHandle -Path $sync.AutPath -Ruleset $rulesetFile -AllowDowngrade -TimeoutSec 900
Write-MutLog "AUT publish: Success=$($autPublish.Success), duration=$([Math]::Round($autPublish.DurationSec,1))s"
if (-not $autPublish.Success) {
    throw "Invoke-HandMutants: initial AUT publish failed. First diagnostic: $(Get-MutFirstDiagnostic $autPublish.Diagnostics)"
}

Write-MutLog '--- Publish test app copy ---'
$testAppPublish = Publish-MutApp -Env $script:EnvHandle -Path $sync.TestAppPath -Ruleset $rulesetFile -AllowDowngrade -TimeoutSec 900
Write-MutLog "Test app publish: Success=$($testAppPublish.Success), duration=$([Math]::Round($testAppPublish.DurationSec,1))s"
if (-not $testAppPublish.Success) {
    throw "Invoke-HandMutants: initial test app publish failed. First diagnostic: $(Get-MutFirstDiagnostic $testAppPublish.Diagnostics)"
}

# --- Baseline run of 95155 ---------------------------------------------------------------
Write-MutLog '--- Baseline run (codeunit 95155) ---'
$baselineTargets = @([pscustomobject]@{ CodeunitId = 95155; Function = $null })
$baseline = Invoke-MutTests -Env $script:EnvHandle -Targets $baselineTargets -TimeoutSec 600
Write-MutLog "Baseline: passed=$($baseline.Passed) failed=$($baseline.Failed)"
if ($baseline.Failed -ne 0) {
    throw "Invoke-HandMutants: baseline run of 95155 has $($baseline.Failed) failing test(s); aborting before mutating anything."
}
if ($baseline.Passed -ne 13) {
    Write-MutLog "WARNING: baseline passed count is $($baseline.Passed), not the 13 recorded by T12 (suite may have drifted -- AUT is a moving target, §1.1). Continuing since 0 failures."
}

$originalBytes = [System.IO.File]::ReadAllBytes($targetFile)
$originalHash = (Get-FileHash -Path $targetFile -Algorithm SHA256).Hash
Write-MutLog "Pristine copy hash (SHA256): $originalHash"

# ============================================================================================
# Mutant loop
# ============================================================================================

$mutantsPath = Join-Path $PSScriptRoot 'mutants.json'
$resultsPath = Join-Path $PSScriptRoot 'results.json'
$mutants = @(Get-Content -Path $mutantsPath -Raw | ConvertFrom-Json)

Write-MutLog "Loaded $($mutants.Count) mutants from $mutantsPath"

$results = @()

for ($idx = 0; $idx -lt $mutants.Count; $idx++) {
    $m = $mutants[$idx]
    Write-MutLog "=== $($m.id) ($($idx + 1)/$($mutants.Count)) operator=$($m.operator) line=$($m.line) ==="
    $mutantStart = Get-Date

    $status = $null
    $note = $null
    $failedTests = @()
    $mutatedLineNumber = $null

    try {
        $info = Get-MutFileTextInfo -Path $targetFile
        $lines = $info.Text -split "`n"
        $lineNo = Find-MutantLine -Lines $lines -GivenLine ([int]$m.line) -Find $m.find

        if ($null -eq $lineNo) {
            $status = 'Drift'
            $note = "source drift: $($m.id)"
            Write-MutLog $note
        }
        else {
            $mutatedLineNumber = $lineNo
            $originalLineText = $lines[$lineNo - 1]
            $lines[$lineNo - 1] = $originalLineText.Replace($m.find, $m.replace)
            $mutatedText = ($lines -join "`n")
            [System.IO.File]::WriteAllText($targetFile, $mutatedText, $info.Encoding)
            Write-MutLog "Applied at line $lineNo (given line $($m.line)): '$($m.find)' -> '$($m.replace)'"

            try {
                $publish = Invoke-MutWithEnvRecovery {
                    Publish-MutApp -Env $script:EnvHandle -Path $sync.AutPath -Ruleset $rulesetFile -AllowDowngrade -TimeoutSec 900
                }
                Write-MutLog "Publish: Success=$($publish.Success), duration=$([Math]::Round($publish.DurationSec,1))s"

                if (-not $publish.Success) {
                    $status = 'CompileError'
                    $note = Get-MutFirstDiagnostic $publish.Diagnostics
                    Write-MutLog "CompileError: $note"
                }
                else {
                    $testResult = Invoke-MutWithEnvRecovery {
                        Invoke-MutTests -Env $script:EnvHandle -Targets $baselineTargets -TimeoutSec 600
                    }
                    Write-MutLog "Test run: passed=$($testResult.Passed) failed=$($testResult.Failed)"

                    if ($testResult.Failed -gt 0) {
                        $status = 'Killed'
                        $failedTests = @($testResult.Tests | Where-Object { $_.Result -eq 'Fail' } | ForEach-Object { "$($_.Codeunit):$($_.Function)" })
                    }
                    else {
                        $status = 'Survived'
                    }
                }
            }
            catch {
                $status = 'CompileError'
                $note = "exception during publish/test: $($_.Exception.Message)"
                Write-MutLog $note
            }
        }
    }
    catch {
        $status = 'CompileError'
        $note = "unexpected exception locating/applying mutant: $($_.Exception.Message)"
        Write-MutLog $note
    }
    finally {
        # Crash-safety: ALWAYS restore the exact original bytes, whether this mutant succeeded,
        # drifted, or threw.
        [System.IO.File]::WriteAllBytes($targetFile, $originalBytes)
        $restoredHash = (Get-FileHash -Path $targetFile -Algorithm SHA256).Hash
        if ($restoredHash -ne $originalHash) {
            Write-MutLog "WARNING: restored file hash ($restoredHash) does not match pristine hash ($originalHash) after $($m.id)!"
        }
    }

    $seconds = [Math]::Round(((Get-Date) - $mutantStart).TotalSeconds, 1)

    $results += [pscustomobject]@{
        id           = $m.id
        operator     = $m.operator
        file         = $m.file
        line         = $m.line
        matchedLine  = $mutatedLineNumber
        status       = $status
        seconds      = $seconds
        failedTests  = $failedTests
        note         = $note
    }

    # Write results.json after EVERY mutant (crash safety).
    $results | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8
    Write-MutLog "$($m.id): $status ($seconds s). results.json updated."
}

# ============================================================================================
# Final: republish clean AUT, rerun baseline
# ============================================================================================

Write-MutLog '--- Final: republish clean AUT copy and rerun baseline ---'
$finalPublish = Invoke-MutWithEnvRecovery {
    Publish-MutApp -Env $script:EnvHandle -Path $sync.AutPath -Ruleset $rulesetFile -AllowDowngrade -TimeoutSec 900
}
Write-MutLog "Final AUT publish: Success=$($finalPublish.Success), duration=$([Math]::Round($finalPublish.DurationSec,1))s"
if (-not $finalPublish.Success) {
    throw "Invoke-HandMutants: final clean-AUT publish failed. First diagnostic: $(Get-MutFirstDiagnostic $finalPublish.Diagnostics)"
}

$finalBaseline = Invoke-MutWithEnvRecovery {
    Invoke-MutTests -Env $script:EnvHandle -Targets $baselineTargets -TimeoutSec 600
}
Write-MutLog "Final baseline: passed=$($finalBaseline.Passed) failed=$($finalBaseline.Failed)"
if ($finalBaseline.Failed -ne 0) {
    throw "Invoke-HandMutants: final baseline run of 95155 has $($finalBaseline.Failed) failing test(s) after restoring the clean AUT -- copy may not be fully restored."
}

$finalHash = (Get-FileHash -Path $targetFile -Algorithm SHA256).Hash
Write-MutLog "Final copy hash (SHA256): $finalHash (pristine was $originalHash; match=$($finalHash -eq $originalHash))"

# ============================================================================================
# Summary
# ============================================================================================

$killed = @($results | Where-Object { $_.status -eq 'Killed' }).Count
$survived = @($results | Where-Object { $_.status -eq 'Survived' }).Count
$drift = @($results | Where-Object { $_.status -eq 'Drift' }).Count
$compileError = @($results | Where-Object { $_.status -eq 'CompileError' }).Count
$total = $results.Count
$killRate = if ($total -gt 0) { [Math]::Round(($killed / $total) * 100, 1) } else { 0 }

Write-MutLog ''
Write-MutLog '=== Summary ==='
Write-MutLog "Total: $total"
Write-MutLog "Killed: $killed"
Write-MutLog "Survived: $survived"
Write-MutLog "Drift: $drift"
Write-MutLog "CompileError: $compileError"
Write-MutLog "Kill rate: $killRate% ($killed / $total)"
Write-MutLog "Gate G0 rule (>= 18 of 20 killed -> no-go, suite already strong): $(if ($killed -ge 18) { 'MET (no-go)' } else { 'not met' })"
Write-MutLog "results.json: $resultsPath"
Write-MutLog 'Done.'
