<#
    .SYNOPSIS
    T11 U5 spike: can a running DemoPortal test job be stopped (client-side), and how long does
    a full `env stop` + `env start` (Reset-MutEnvironment) take? See docs/SPEC.md §6.6.4
    (normative), U5 in §3, §6.5.4 step 5, §7.6.

    .DESCRIPTION
    Codeunit 50302 "MUT Fx U5 Spike Tests" (`U5_InfiniteLoop`: `while true do Sleep(1000);`) is
    NOT part of the fixture baseline and is deliberately run exactly once, here, to probe
    cancellation behaviour. Only touches `mut-spike-01`
    (30004698-209d-467c-96eb-9b412e9ee6ee) -- the only environment this spike may touch.

    Steps:
      1. Ensure the environment is Running (Get-MutEnvironment / Start-MutEnvironment).
      2. Start `continia.exe test run <env> 50302 --timeout 30` via Start-Process (PassThru,
         NoNewWindow, stdout/stderr redirected to files) -- the CLI's own --timeout is a
         CLIENT-side wait (F9); it does not cancel the job on the BC server.
      3. Wait up to 60s for the process to exit on its own. Record whether it exited within that
         budget and what it printed. If it does not exit, kill it with Stop-Process and record
         that as a fact (not a failure) -- this is the whole point of the spike.
      4. `continia.exe env sessions <env> --json`: record whether a session still looks like it
         is running (count, raw rows) -- the infinite-loop AL session may still be alive on the
         BC server even after the CLI gave up client-side.
      5. Reset-MutEnvironment (env stop -> Stopped -> env start -> Running -> settle): record
         DurationSec and SettleDurationSec. This is the orchestrator's actual recovery path when
         a mutant hangs (§6.5.6 step 3).
      6. Invoke-MutTests on codeunit 50300 (the real fixture suite, TimeoutSec 300): expect 9/9
         pass, proving the environment is usable again after the reset.

    Never runs codeunit 50302 anywhere else. Never prints credentials.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force

Write-Output '=== T11 U5 spike: job cancellation and environment reset ==='

$configPath = Join-Path $repoRoot 'mutation.fixture.config.json'
$cfg = Get-MutConfig -Path $configPath
$cliPath = Join-Path $repoRoot '.tools\continia.exe'

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle) {
    throw "Invoke-U5Spike: environment '$($cfg.environmentName)' not found."
}
if ($envHandle.Status -ne 'Running') {
    Write-Output "Environment status is '$($envHandle.Status)'; starting it..."
    $envHandle = Start-MutEnvironment -Env $envHandle -Config $cfg
}
Write-Output "Environment: $($envHandle.Name) ($($envHandle.Id)), status Running."

function Invoke-RawContinia {
    <#
        Local, non-exported helper: runs .tools/continia.exe synchronously via Start-Process
        (redirected stdout/stderr go to temp files; avoids the PS 5.1 NativeCommandError issue
        that redirecting native stderr through `2>&1` causes under $ErrorActionPreference =
        'Stop', per DemoPortal.psm1's own Invoke-Continia comment). Returns
        @{ Exited; ExitCode; StdOut; StdErr }.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSec = 60
    )

    $tmpDir = Join-Path $repoRoot 'out\u5-u6-tmp'
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $outFile = Join-Path $tmpDir ("stdout-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    $errFile = Join-Path $tmpDir ("stderr-{0}.txt" -f ([guid]::NewGuid().ToString('N')))

    $proc = Start-Process -FilePath $cliPath -ArgumentList $Arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $exited = $proc.WaitForExit($TimeoutSec * 1000)
    $exitCode = $null
    if ($exited) {
        $exitCode = $proc.ExitCode
    }

    $stdout = ''
    $stderr = ''
    if (Test-Path $outFile) { $stdout = Get-Content -Path $outFile -Raw -ErrorAction SilentlyContinue }
    if (Test-Path $errFile) { $stderr = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue }

    return [pscustomobject]@{
        Exited   = $exited
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Process  = $proc
    }
}

# --- Step 2/3: start the U5_InfiniteLoop test run, wait up to 60s, then check ------------------
Write-Output ''
Write-Output "--- Start-Process: continia test run $($envHandle.Id) 50302 --timeout 30 ---"

$tmpDir = Join-Path $repoRoot 'out\u5-u6-tmp'
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$outFile = Join-Path $tmpDir 'u5-stdout.txt'
$errFile = Join-Path $tmpDir 'u5-stderr.txt'
Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue

$startTime = Get-Date
$u5Proc = Start-Process -FilePath $cliPath `
    -ArgumentList @('test', 'run', $envHandle.Id, '50302', '--timeout', '30') `
    -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile

Write-Output "Started continia.exe pid=$($u5Proc.Id) at $startTime; waiting up to 60s for it to exit..."
$cliExited = $u5Proc.WaitForExit(60000)
$waitElapsedSec = ((Get-Date) - $startTime).TotalSeconds

$cliStdOut = ''
$cliStdErr = ''
$cliExitCode = $null

if ($cliExited) {
    $cliExitCode = $u5Proc.ExitCode
    Write-Output ("CLI exited on its own after {0:N1}s (exit code {1})." -f $waitElapsedSec, $cliExitCode)
}
else {
    Write-Output ("CLI did NOT exit within 60s (client --timeout 30 did not end the process); killing it now.")
    try {
        Stop-Process -Id $u5Proc.Id -Force -ErrorAction Stop
        Write-Output "Stop-Process succeeded on pid=$($u5Proc.Id)."
    }
    catch {
        Write-Output "Stop-Process failed: $($_.Exception.Message)"
    }
}

Start-Sleep -Milliseconds 500
if (Test-Path $outFile) { $cliStdOut = Get-Content -Path $outFile -Raw -ErrorAction SilentlyContinue }
if (Test-Path $errFile) { $cliStdErr = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue }

Write-Output ''
Write-Output '--- CLI stdout ---'
Write-Output $cliStdOut
Write-Output '--- CLI stderr ---'
Write-Output $cliStdErr

# --- Step 4: check for lingering sessions ------------------------------------------------------
Write-Output ''
Write-Output "--- continia env sessions $($envHandle.Id) --json ---"
$sessionsResult = Invoke-RawContinia -Arguments @('env', 'sessions', $envHandle.Id, '--json') -TimeoutSec 30
Write-Output ("env sessions exited={0} exitCode={1}" -f $sessionsResult.Exited, $sessionsResult.ExitCode)
Write-Output $sessionsResult.StdOut

$sessions = @()
if ($sessionsResult.Exited -and -not [string]::IsNullOrWhiteSpace($sessionsResult.StdOut)) {
    try {
        # NOTE: `@($x | ConvertFrom-Json)` (wrapping the pipeline expression directly) was found
        # to nest a multi-element JSON array as a single element (Count 1) instead of enumerating
        # it -- assign the pipeline result to a variable first, then wrap that variable.
        $parsedSessions = $sessionsResult.StdOut | ConvertFrom-Json
        $sessions = @($parsedSessions)
    }
    catch {
        Write-Output "Could not parse env sessions JSON: $($_.Exception.Message)"
    }
}
$sessionCount = $sessions.Count
Write-Output ("Session count reported: {0}" -f $sessionCount)

# --- Step 5: Reset-MutEnvironment, time it ------------------------------------------------------
Write-Output ''
Write-Output '--- Reset-MutEnvironment (env stop -> Stopped -> env start -> Running -> settle) ---'
$resetResult = Reset-MutEnvironment -Env $envHandle
Write-Output ("Reset DurationSec={0:N2}  SettleDurationSec={1:N2}" -f $resetResult.DurationSec, $resetResult.SettleDurationSec)

# Refresh the handle post-reset (Reset-MutEnvironment operates by id; Get-MutEnvironment gives a
# handle with current status for the subsequent Invoke-MutTests call, matching Invoke-U4Spike's
# own pattern of re-fetching after any environment-state-changing call).
$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg

# --- Step 6: prove the environment works again --------------------------------------------------
Write-Output ''
Write-Output '--- Invoke-MutTests: codeunit 50300 (fixture suite, TimeoutSec 300) ---'
$suiteResult = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = 50300; Function = $null }) -TimeoutSec 300
Write-Output ("Suite after reset: {0} passed, {1} failed" -f $suiteResult.Passed, $suiteResult.Failed)
foreach ($t in @($suiteResult.Tests)) {
    Write-Output ("  {0}:{1} -> {2}" -f $t.Codeunit, $t.Function, $t.Result)
}

# --- Summary -------------------------------------------------------------------------------------
Write-Output ''
Write-Output '=== U5 summary ==='
Write-Output ("cliExitedOnClientTimeout: {0}" -f $cliExited)
Write-Output ("sessionVisibleAfter: count={0}" -f $sessionCount)
Write-Output ("resetDurationSec: {0:N2}" -f $resetResult.DurationSec)
Write-Output ("settleDurationSec: {0:N2}" -f $resetResult.SettleDurationSec)
Write-Output ("suiteAfterReset: {0}/{1} passed" -f $suiteResult.Passed, ($suiteResult.Passed + $suiteResult.Failed))

if ($suiteResult.Failed -gt 0 -or $suiteResult.Passed -ne 9) {
    Write-Output 'WARNING: fixture suite did not come back 9/9 after the reset.'
    exit 1
}

exit 0
