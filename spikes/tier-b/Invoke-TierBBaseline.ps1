<#
    .SYNOPSIS
    T12 Tier B baseline spike: syncs the real Continia Banking AUT/test-app/rulesets into
    working copies under out/ (Sync-MutAutCopy, §6.5.2), installs their dependencies, deploys
    both to the mut-spike-01 DemoPortal environment, runs test codeunits 95155 and 95913
    (§1.1), and records U7 (job overhead / codeunit durations) and U9 (coverage job-id field
    and CSV header) numbers. See docs/SPEC.md §6.5.2, §1.1, §4 item 1, §3 (U7/U9), §7.6.

    .DESCRIPTION
    Never targets the real AUT/test-app/rulesets folders with the CLI (F17, §4 item 1):
    Sync-MutAutCopy is the only function that reads them, and every deploy/test/coverage call
    below is against the copies under out/aut-original, out/test-app, out/rulesets.

    Deviation from the task brief, discovered live against the current Continia Banking
    checkout (recorded in docs/issues.md): codeunit 95913 "CTS-CB Test Auth Granted Acc" and
    file Authentication/TestAuthGrantedAcc.Codeunit.al do not exist in the current AUT/test-app
    source at all (AUT codeunit id 72918690 is currently "CTS-CB Line Date Import Def.", not
    "CTS-CB Auth Granted Acc. Mgt"; id 72918691 is unused). The single-method job used to
    measure U7's per-job overhead therefore falls back to the first [Test] procedure of
    Authentication/TestAuthShareDetect.Codeunit.al (codeunit 95155) when
    TestAuthGrantedAcc.Codeunit.al is absent from the synced copy, and codeunit 95913 is still
    attempted via Invoke-MutTests so its real failure is captured verbatim.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\lib\AutCopy.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force

function Get-MutFirstTestProcedure {
    <#
        .SYNOPSIS
        Returns the first `[Test]`-attributed procedure name in an AL file (the line
        immediately following the first line matching `^\s*\[Test\]\s*$`), or $null if the
        file does not exist or has no [Test] procedure.
    #>
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return $null
    }

    $lines = Get-Content -Path $Path
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[Test\]\s*$') {
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match '(?i)^\s*procedure\s+([A-Za-z0-9_]+)\s*\(') {
                    return $Matches[1]
                }
            }
        }
    }
    return $null
}

function ConvertTo-MutQuotedArgument {
    param([string]$Argument)

    if ($Argument -match '\s') {
        return '"' + $Argument + '"'
    }
    return $Argument
}

function Invoke-MutCliDirect {
    <#
        .SYNOPSIS
        Runs the CLI directly via System.Diagnostics.Process (never the `&` call operator with
        stream redirection): Windows PowerShell 5.1 wraps a native command's redirected stderr
        in a NativeCommandError record, and $ErrorActionPreference = 'Stop' turns those into a
        terminating error even on a zero exit code and even when the command succeeded (the
        exact pitfall already documented on DemoPortal.psm1's own Invoke-Continia). Used here
        instead of that module's private Invoke-Continia because this script needs the AUT
        deploy's own client-side timeout to be longer than Invoke-Continia's 600s default, and
        needs raw (non-JSON) human-mode output for the U9 coverage-job-id fallback probe.
        .OUTPUTS
        [pscustomobject]@{ ExitCode; StdOut; StdErr }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$CliPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSec = 1800
    )

    $quotedArgs = ($Arguments | ForEach-Object { ConvertTo-MutQuotedArgument $_ }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CliPath
    $psi.Arguments = $quotedArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        $null = $proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "Invoke-MutCliDirect: timed out after $TimeoutSec s: $CliPath $quotedArgs"
        }
        $proc.WaitForExit()

        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 30000) | Out-Null

        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdoutTask.Result
            StdErr   = $stderrTask.Result
        }
    }
    finally {
        $proc.Dispose()
    }
}

function Invoke-MutTimedAction {
    param([scriptblock]$Action)

    $start = Get-Date
    $result = & $Action
    $durationSec = ((Get-Date) - $start).TotalSeconds
    return [pscustomobject]@{ Result = $result; DurationSec = $durationSec }
}

Write-Output '=== T12 Tier B baseline ==='

$configPath = Join-Path $repoRoot 'mutation.config.json'
$cfg = Get-MutConfig -Path $configPath

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle) {
    throw "Invoke-TierBBaseline: environment '$($cfg.environmentName)' not found. Run spikes/Start-SpikeEnvironment.ps1 first."
}
if ($envHandle.Status -ne 'Running') {
    Write-Output "Environment status is '$($envHandle.Status)'; starting it..."
    $envHandle = Start-MutEnvironment -Env $envHandle -Config $cfg
}
Write-Output "Environment: $($envHandle.Name) ($($envHandle.Id)), status Running."

# --- Step: Sync-MutAutCopy (§6.5.2) -----------------------------------------------------
Write-Output ''
Write-Output '--- Sync-MutAutCopy ---'
$syncTimed = Invoke-MutTimedAction { Sync-MutAutCopy -Config $cfg }
$sync = $syncTimed.Result
Write-Output ("AutPath      = {0}" -f $sync.AutPath)
Write-Output ("TestAppPath  = {0}" -f $sync.TestAppPath)
Write-Output ("RulesetsPath = {0}" -f $sync.RulesetsPath)
Write-Output ("Sync duration: {0:N1}s" -f $syncTimed.DurationSec)

$rulesetFile = $null
if ($sync.RulesetsPath) {
    $rulesetFile = Join-Path $sync.RulesetsPath $cfg.rulesets.file
}

# --- Step: Install-MutDependencies -------------------------------------------------------
Write-Output ''
Write-Output '--- Install-MutDependencies ---'
$depsAutTimed = Invoke-MutTimedAction { Install-MutDependencies -Env $envHandle -AppPath $sync.AutPath }
Write-Output ("deps install (AUT): {0:N1}s" -f $depsAutTimed.DurationSec)

$depsTestAppTimed = Invoke-MutTimedAction { Install-MutDependencies -Env $envHandle -AppPath $sync.TestAppPath }
Write-Output ("deps install (test app): {0:N1}s" -f $depsTestAppTimed.DurationSec)

$depsInstallSec = $depsAutTimed.DurationSec + $depsTestAppTimed.DurationSec

# --- Step: deploy AUT -------------------------------------------------------------------
# Publish-MutApp (orchestrator/backends/DemoPortal.psm1) has no -TimeoutSec parameter; its
# Invoke-Continia call uses the default 600s process timeout. Per this task's brief, the AUT
# deploy (1,065 files) is run via the CLI directly with a generous timeout instead, so a slow
# compile cannot be killed mid-flight. Never pointed at the real AUT folder -- $sync.AutPath is
# the copy under out/.
Write-Output ''
Write-Output '--- Deploy AUT (direct CLI invocation; Publish-MutApp lacks -TimeoutSec) ---'
$cliPath = $cfg.demoPortal.cliPath
$autDeployArgs = @('deploy', $envHandle.Id, $sync.AutPath, '--json', '--allow-downgrade')
if ($rulesetFile) {
    $autDeployArgs += @('--ruleset', $rulesetFile)
}
Write-Output ("CLI: $cliPath " + ($autDeployArgs -join ' '))

$autDeployStart = Get-Date
$autDeployInvoke = Invoke-MutCliDirect -CliPath $cliPath -Arguments $autDeployArgs -TimeoutSec 1800
$autDeployExit = $autDeployInvoke.ExitCode
$autDeploySec = ((Get-Date) - $autDeployStart).TotalSeconds
Write-Output ("AUT deploy exit code: {0}; duration: {1:N1}s" -f $autDeployExit, $autDeploySec)

$autDeployJson = $autDeployInvoke.StdOut
$autDeployResult = $null
try {
    $autDeployResult = $autDeployJson | ConvertFrom-Json
}
catch {
    Write-Output 'AUT deploy: could not parse JSON output. Raw output follows:'
    Write-Output $autDeployJson
}

$autDeployRow = $null
if ($null -ne $autDeployResult) {
    $autDeployRow = @($autDeployResult) | Select-Object -First 1
}

$autDeploySuccess = $false
if ($null -ne $autDeployRow -and (Get-Member -InputObject $autDeployRow -Name 'published' -ErrorAction SilentlyContinue) -and $autDeployRow.published -eq $true) {
    $autDeploySuccess = $true
}
Write-Output ("AUT deploy success: {0}" -f $autDeploySuccess)

if (-not $autDeploySuccess) {
    Write-Output 'AUT deploy FAILED. Diagnostics (first 20):'
    $diags = @()
    if ($null -ne $autDeployRow -and (Get-Member -InputObject $autDeployRow -Name 'diagnostics' -ErrorAction SilentlyContinue)) {
        $diags = @($autDeployRow.diagnostics) | Select-Object -First 20
    }
    $diags | ConvertTo-Json -Depth 10 | Write-Output
    throw 'Invoke-TierBBaseline: AUT deploy failed. See diagnostics above and docs/issues.md.'
}

# --- Step: deploy test app ---------------------------------------------------------------
Write-Output ''
Write-Output '--- Deploy test app (Publish-MutApp) ---'
$testAppDeployTimed = Invoke-MutTimedAction {
    if ($rulesetFile) {
        Publish-MutApp -Env $envHandle -Path $sync.TestAppPath -Ruleset $rulesetFile -AllowDowngrade
    }
    else {
        Publish-MutApp -Env $envHandle -Path $sync.TestAppPath -AllowDowngrade
    }
}
$testAppDeployResult = $testAppDeployTimed.Result
$testAppDeploySec = $testAppDeployTimed.DurationSec
Write-Output ("Test app deploy success: {0}; duration: {1:N1}s" -f $testAppDeployResult.Success, $testAppDeploySec)
if (-not $testAppDeployResult.Success) {
    Write-Output 'Test app deploy FAILED. Diagnostics (first 20):'
    $testAppDeployResult.Diagnostics | Select-Object -First 20 | ConvertTo-Json -Depth 10 | Write-Output
    throw 'Invoke-TierBBaseline: test app deploy failed. See diagnostics above and docs/issues.md.'
}

# --- Step: single-method job (U7 job overhead) + raw JSON probe for a job id (U9) --------
Write-Output ''
Write-Output '--- Single-method job (U7 overhead) + raw job-id probe (U9) ---'

$grantedAccFile = Join-Path $sync.TestAppPath 'Authentication\TestAuthGrantedAcc.Codeunit.al'
$singleMethodCodeunit = 95913
$singleMethodProcedure = Get-MutFirstTestProcedure -Path $grantedAccFile
$singleMethodDeviationNote = $null

if ($null -eq $singleMethodProcedure) {
    $singleMethodDeviationNote = "TestAuthGrantedAcc.Codeunit.al (codeunit 95913) not found in the synced test-app copy; falling back to codeunit 95155's first [Test] procedure for the single-method U7 measurement."
    Write-Output $singleMethodDeviationNote
    $shareDetectFile = Join-Path $sync.TestAppPath 'Authentication\TestAuthShareDetect.Codeunit.al'
    $singleMethodCodeunit = 95155
    $singleMethodProcedure = Get-MutFirstTestProcedure -Path $shareDetectFile
    if ($null -eq $singleMethodProcedure) {
        throw 'Invoke-TierBBaseline: could not find a [Test] procedure in TestAuthShareDetect.Codeunit.al either.'
    }
}
Write-Output ("Single-method target: codeunit $singleMethodCodeunit, procedure $singleMethodProcedure")

$singleJobArgs = @('test', 'run', $envHandle.Id, $singleMethodCodeunit, $singleMethodProcedure, '--json', '--timeout', '120')
Write-Output ("CLI: $cliPath " + ($singleJobArgs -join ' '))
$singleJobStart = Get-Date
$singleJobInvoke = Invoke-MutCliDirect -CliPath $cliPath -Arguments $singleJobArgs -TimeoutSec 180
$singleJobExit = $singleJobInvoke.ExitCode
$singleMethodJobSec = ((Get-Date) - $singleJobStart).TotalSeconds
Write-Output ("Single-method job exit code: {0}; duration: {1:N1}s" -f $singleJobExit, $singleMethodJobSec)

$singleJobJson = $singleJobInvoke.StdOut
$singleJobResult = $null
try {
    $singleJobResult = $singleJobJson | ConvertFrom-Json
}
catch {
    Write-Output 'Single-method job: could not parse JSON. Raw output follows:'
    Write-Output $singleJobJson
}

$jobIdField = 'not exposed by test run --json'
if ($null -ne $singleJobResult) {
    $propNames = @($singleJobResult.PSObject.Properties | ForEach-Object { $_.Name })
    Write-Output ("Single-method job top-level JSON properties: {0}" -f ($propNames -join ', '))
    $idLikeProps = @($propNames | Where-Object { $_ -match '(?i)jobid|^id$|runid|testjobid' })
    if ($idLikeProps.Count -gt 0) {
        $jobIdField = $idLikeProps[0]
        Write-Output ("Job id field found: '$jobIdField' = $($singleJobResult.$jobIdField)")
    }
    else {
        Write-Output 'No id-like top-level property found in test run --json output.'
    }
}

# --- Step: whole-codeunit runs (95155, 95913) --------------------------------------------
Write-Output ''
Write-Output '--- Whole-codeunit test runs ---'

$results = @{}
foreach ($codeunitId in @(95155, 95913)) {
    Write-Output ("Running codeunit $codeunitId ...")
    try {
        $timed = Invoke-MutTimedAction {
            Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = $codeunitId; Function = $null }) -TimeoutSec 300
        }
        $results[$codeunitId] = [pscustomobject]@{
            Success     = $true
            DurationSec = $timed.DurationSec
            Passed      = $timed.Result.Passed
            Failed      = $timed.Result.Failed
            Tests       = $timed.Result.Tests
            JobIds      = $timed.Result.JobIds
            Error       = $null
        }
        Write-Output ("codeunit $codeunitId : {0} passed, {1} failed, {2:N1}s" -f $timed.Result.Passed, $timed.Result.Failed, $timed.DurationSec)
    }
    catch {
        $results[$codeunitId] = [pscustomobject]@{
            Success     = $false
            DurationSec = $null
            Passed      = 0
            Failed      = 0
            Tests       = @()
            JobIds      = @()
            Error       = $_.Exception.Message
        }
        Write-Output ("codeunit $codeunitId : FAILED to run: $($_.Exception.Message)")
    }
}

# --- Step: coverage (U9) -------------------------------------------------------------------
Write-Output ''
Write-Output '--- Coverage (U9) ---'

$allJobIds = @()
foreach ($codeunitId in @(95155, 95913)) {
    $allJobIds += @($results[$codeunitId].JobIds)
}
$allJobIds = @($allJobIds | Where-Object { $_ })

$csvHeaderLine = 'unavailable'
$coverageOutcomeNote = $null

if ($allJobIds.Count -gt 0) {
    Write-Output ("JobIds collected from test runs: {0}" -f ($allJobIds -join ', '))
    $csvDocs = Get-MutCoverageRaw -Env $envHandle -JobIds $allJobIds
    if ($csvDocs.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($csvDocs[0])) {
        $csvLines = $csvDocs[0] -split "`r`n|`n"
        $first200 = $csvLines | Select-Object -First 200
        $coverageDir = Join-Path $repoRoot 'fixtures\coverage'
        if (-not (Test-Path $coverageDir)) {
            New-Item -ItemType Directory -Path $coverageDir -Force | Out-Null
        }
        $samplePath = Join-Path $coverageDir 'sample.csv'
        $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
        $content = ($first200 -join "`n") + "`n"
        [System.IO.File]::WriteAllText($samplePath, $content, $noBomUtf8)
        $csvHeaderLine = $csvLines[0]
        Write-Output "Saved fixtures/coverage/sample.csv ($($first200.Count) lines)."
        Write-Output ("CSV header: $csvHeaderLine")
    }
    else {
        $coverageOutcomeNote = 'Get-MutCoverageRaw returned no CSV content for the collected job ids.'
        Write-Output $coverageOutcomeNote
    }
}
else {
    Write-Output 'No job ids exposed by test run --json (JobIds empty on every run). Attempting the human-mode fallback probe.'
    $probeArgs = @('test', 'run', $envHandle.Id, $singleMethodCodeunit, $singleMethodProcedure, '--timeout', '120')
    Write-Output ("CLI (human mode): $cliPath " + ($probeArgs -join ' '))
    $probeInvoke = Invoke-MutCliDirect -CliPath $cliPath -Arguments $probeArgs -TimeoutSec 180
    $probeText = $probeInvoke.StdOut + "`n" + $probeInvoke.StdErr
    Write-Output $probeText
    if ($probeText -match '(?i)Test job started:\s*(\d+)') {
        $probeJobId = $Matches[1]
        Write-Output "Human-mode output exposes a job number: $probeJobId. Probing test coverage with it."
        $coverageProbeInvoke = Invoke-MutCliDirect -CliPath $cliPath -Arguments @('test', 'coverage', $envHandle.Id, $probeJobId, '--json') -TimeoutSec 120
        $coverageProbeText = $coverageProbeInvoke.StdOut
        try {
            $coverageProbeResult = $coverageProbeText | ConvertFrom-Json
            if ($coverageProbeResult -and $coverageProbeResult.csv) {
                $csvLines = $coverageProbeResult.csv -split "`r`n|`n"
                $first200 = $csvLines | Select-Object -First 200
                $coverageDir = Join-Path $repoRoot 'fixtures\coverage'
                if (-not (Test-Path $coverageDir)) {
                    New-Item -ItemType Directory -Path $coverageDir -Force | Out-Null
                }
                $samplePath = Join-Path $coverageDir 'sample.csv'
                $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
                $content = ($first200 -join "`n") + "`n"
                [System.IO.File]::WriteAllText($samplePath, $content, $noBomUtf8)
                $csvHeaderLine = $csvLines[0]
                $jobIdField = 'job id only available in human-mode output ("Test job started: N"), not in --json'
                Write-Output "Saved fixtures/coverage/sample.csv via human-mode job id fallback."
                Write-Output ("CSV header: $csvHeaderLine")
            }
            else {
                $coverageOutcomeNote = 'test coverage --json with the human-mode job number returned no csv field.'
                Write-Output $coverageOutcomeNote
            }
        }
        catch {
            $coverageOutcomeNote = "test coverage --json with the human-mode job number did not return parseable JSON: $coverageProbeText"
            Write-Output $coverageOutcomeNote
        }
    }
    else {
        $coverageOutcomeNote = 'job id not exposed by test run --json, and human-mode output did not contain a "Test job started: N" line either.'
        Write-Output $coverageOutcomeNote
    }
}

# --- Summary ---------------------------------------------------------------------------
Write-Output ''
Write-Output '=== Summary ==='
Write-Output ("depsInstallSec (AUT): {0:N1}" -f $depsAutTimed.DurationSec)
Write-Output ("depsInstallSec (test app): {0:N1}" -f $depsTestAppTimed.DurationSec)
Write-Output ("depsInstallSec (total): {0:N1}" -f $depsInstallSec)
Write-Output ("autDeploySec: {0:N1}" -f $autDeploySec)
Write-Output ("testAppDeploySec: {0:N1}" -f $testAppDeploySec)
Write-Output ("singleMethodJobSec: {0:N1} (codeunit $singleMethodCodeunit, procedure $singleMethodProcedure)" -f $singleMethodJobSec)
foreach ($codeunitId in @(95155, 95913)) {
    $r = $results[$codeunitId]
    if ($r.Success) {
        Write-Output ("codeunit $codeunitId : {0} passed / {1} failed, {2:N1}s" -f $r.Passed, $r.Failed, $r.DurationSec)
        foreach ($t in @($r.Tests) | Where-Object { $_.Result -eq 'Fail' }) {
            Write-Output ("  FAILED: $($t.Function) -- $($t.Error)")
        }
    }
    else {
        Write-Output ("codeunit $codeunitId : run FAILED -- $($r.Error)")
    }
}
Write-Output ("jobIdField: $jobIdField")
Write-Output ("csvHeaderLine: $csvHeaderLine")

# Emit a single machine-readable summary object for the caller to persist to
# docs/spike-baseline.md without re-parsing console text.
$summary = [pscustomobject]@{
    DepsInstallAutSec      = $depsAutTimed.DurationSec
    DepsInstallTestAppSec  = $depsTestAppTimed.DurationSec
    DepsInstallTotalSec    = $depsInstallSec
    AutDeploySec           = $autDeploySec
    TestAppDeploySec       = $testAppDeploySec
    SingleMethodCodeunit   = $singleMethodCodeunit
    SingleMethodProcedure  = $singleMethodProcedure
    SingleMethodJobSec     = $singleMethodJobSec
    SingleMethodDeviation  = $singleMethodDeviationNote
    Codeunit95155          = $results[95155]
    Codeunit95913          = $results[95913]
    JobIdField             = $jobIdField
    CsvHeaderLine          = $csvHeaderLine
    CoverageOutcomeNote    = $coverageOutcomeNote
}

$summaryPath = Join-Path $repoRoot 'out\tier-b-baseline-summary.json'
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Output ''
Write-Output "Full summary written to $summaryPath"
