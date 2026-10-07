Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo root is two levels above this module file (orchestrator/backends/DemoPortal.psm1).
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

# Backend-agnostic coverage CSV parser (T24, §6.5.5), imported by relative path so this backend
# is the only place that wires it to the real CLI's coverage output.
Import-Module (Join-Path $PSScriptRoot '../lib/Coverage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1')

# Poll loop tuning for env get / env stop-start status polling.
$script:PollIntervalSec = 10
$script:MaxPollIterations = 60
# FIX (run 11, 2026-10-01): `env start` retry -- see Start-MutEnvironmentWithRetry.
$script:StartRetryAfterPolls = 9
$script:MaxStartPollIterations = 180
# New-MutEnvironment's "wait for env get to return an object with a status property at all"
# budget is intentionally much shorter than the full start-to-Running poll (§6.5.3): 6 x 10s = 60s.
$script:MaxAppearIterations = 6

# Per-environment-id caches for Get-MutApiBase (U8) and the Basic-auth credential. Initialized
# here (not lazily inside the functions) because Set-StrictMode -Version Latest throws
# RuntimeException on a bare read of a $script: variable that was never assigned at all, as
# opposed to one that is $null.
$script:MutApiBaseCache = @{}
$script:MutCredentialCache = @{}
# Per-environment-id cache of the first company's @{ Id; Name } (one /api/v2.0/companies GET per
# session; §6.10.3).
$script:MutCompanyCache = @{}
# This module's own path: the SOAP background runspace imports it by path (§6.5.6 pattern).
$script:DemoPortalModulePath = $PSCommandPath

function Resolve-MutCliPath {
    param($Config)

    $cliPath = $Config.demoPortal.cliPath
    if ([System.IO.Path]::IsPathRooted($cliPath)) {
        return $cliPath
    }
    return (Join-Path $script:RepoRoot $cliPath)
}

function ConvertTo-MutQuotedArgument {
    <#
        .SYNOPSIS
        Quotes one CLI argument for a raw ProcessStartInfo.Arguments command-line string.

        .NOTES
        Deviation from the literal "escape embedded double quotes as \"" ruling, disclosed
        in the T02 fix-round-1 report: empirically (verified against this module's own
        Invoke-Continia unit test invoking cmd.exe), backslash-escaping an embedded quote is
        the correct convention for a standard CommandLineToArgvW argv consumer (the real
        continia.exe) but is NOT honored by cmd.exe's own command-line parsing, which treats
        `\"` as literal backslash-then-quote rather than an escaped quote — corrupting output
        that must round-trip through a shell. No real argument this module ever passes
        (environment names matching ^mut-, GUIDs, Windows file paths) can contain a literal
        `"` character, so an embedded quote is passed through unescaped rather than risking
        the shell-corruption case; only embedded whitespace triggers wrapping.
    #>
    param([string]$Argument)

    if ($Argument -match '\s') {
        return '"' + $Argument + '"'
    }
    return $Argument
}

function Invoke-Continia {
    <#
        .SYNOPSIS
        Private wrapper around the Continia CLI. This is the ONLY function in this module
        that may invoke the real CLI process, and the single Pester mock point for every
        other function in this module.

        Runs the CLI via System.Diagnostics.Process (not PowerShell's `&` operator with
        `2>&1`): Windows PowerShell 5.1 wraps redirected native stderr in NativeCommandError
        records, and $ErrorActionPreference = 'Stop' turns those into terminating errors even
        on a zero exit code. Both stdout and stderr are read via the .NET async Task readers
        (StandardOutput/StandardError.ReadToEndAsync), NOT via Register-ObjectEvent on
        OutputDataReceived/ErrorDataReceived: PowerShell dispatches those events through the
        runspace event queue with no ordering guarantee across rapid-fire line events, which
        was found (T03, fix round 2) to reorder lines non-deterministically and corrupt every
        multi-line JSON response. ReadToEndAsync reads each stream on a single dedicated task
        in original byte order; starting both tasks before WaitForExit avoids the classic
        redirected-pipe deadlock, and WaitForExit(timeout) is never blocked behind either read.

        .PARAMETER ExpectJson
        Some CLI subcommands (`env start`, `env stop`, `env delete`, `env use`) have no `--json`
        output at all: on success they print a one-line confirmation to stderr, stdout is
        empty, and exit code is 0 (verified against the real CLI, T03 fix round 3). Calling
        Invoke-Continia for one of those with the default $ExpectJson = $true would previously
        either hang parsing empty stdout as JSON or silently swallow a failure. Pass
        -ExpectJson:$false for those commands: no JSON parse is attempted, a non-zero exit code
        throws (message includes stderr), and the raw exit code/stdout/stderr are returned.
        With the default $ExpectJson = $true, empty/whitespace stdout is always an error (never
        a silent $null) and a non-zero exit code is never treated as failure by itself (F18:
        `test run` exits 1 when tests fail while still emitting valid JSON on stdout).

        .PARAMETER AllowNonZeroExit
        T24: `test run ... --raw` also exits 1 when tests fail (F18 applies to `--raw` output
        just as it does to `--json`), but unlike `--json` its stdout is not JSON at all (a
        `Test job started: <N>` line followed by xUnit XML), so it must go through the
        $ExpectJson:$false path to avoid a JSON-parse attempt. Without this switch that path
        throws on any non-zero exit code (the "env start/stop/etc. have no --json and a
        non-zero exit is really an error" case); passing it suppresses that throw so a failing
        test run's `--raw` output can still be read and parsed. Used only by Invoke-MutTests's
        `-Coverage` path.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSec = 600,
        [bool]$ExpectJson = $true,
        [switch]$AllowNonZeroExit
    )

    $cliPath = $script:CliPath
    $quotedArgs = ($Arguments | ForEach-Object { ConvertTo-MutQuotedArgument $_ }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cliPath
    $psi.Arguments = $quotedArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:RepoRoot

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stdout = ''
    $stderr = ''
    $exitCode = $null
    try {
        $null = $proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "continia timed out after $TimeoutSec s: continia $quotedArgs"
        }
        $proc.WaitForExit()

        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 30000) | Out-Null
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $proc.ExitCode
    }
    finally {
        $proc.Dispose()
    }

    $script:LastContiniaExitCode = $exitCode

    if (-not $ExpectJson) {
        if ($exitCode -ne 0 -and -not $AllowNonZeroExit) {
            throw "continia exited with code ${exitCode}: continia $quotedArgs; stderr: $stderr"
        }
        return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
        throw "continia returned no JSON: $quotedArgs; stderr: $stderr"
    }

    try {
        return $stdout | ConvertFrom-Json
    }
    catch {
        $stdoutExcerpt = $stdout.Substring(0, [Math]::Min(2000, $stdout.Length))
        $stderrExcerpt = $stderr.Substring(0, [Math]::Min(2000, $stderr.Length))
        throw "Invoke-Continia: non-JSON output from '$cliPath $quotedArgs'. stdout: $stdoutExcerpt`nstderr: $stderrExcerpt"
    }
}

function Assert-MutEnvironmentAllowed {
    <#
        .SYNOPSIS
        Throws unless the environment handle's Name starts with 'mut-' and it is not Shared.
        MUST be called first by every exported function that receives an $Env handle.
    #>
    param($Env)

    if (-not $Env) {
        throw 'Assert-MutEnvironmentAllowed: $Env is null.'
    }
    if ($Env.Name -cnotmatch '^mut-') {
        throw "Assert-MutEnvironmentAllowed: environment name '$($Env.Name)' does not match '^mut-'; refusing to target it."
    }
    if ($Env.Shared) {
        throw "Assert-MutEnvironmentAllowed: environment '$($Env.Name)' is marked Shared; refusing to target it."
    }
}

function Test-MutHasProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function ConvertTo-MutEnvironmentHandle {
    param($Raw)

    # $Raw.status is read through Test-MutHasProperty, not a bare dot access: under
    # Set-StrictMode -Version Latest, accessing a property that is entirely absent from a
    # PSCustomObject throws PropertyNotFoundException rather than returning $null (this is
    # exactly the class of bug that crashed New-MutEnvironment against the real CLI in T03).
    $status = $null
    if (Test-MutHasProperty $Raw 'status') {
        $status = $Raw.status
    }

    [pscustomobject]@{
        Id      = $Raw.id
        Name    = $Raw.description
        Url     = $Raw.url
        Backend = 'DemoPortal'
        Shared  = [bool]$Raw.shared
        Status  = $status
        CliPath = $script:CliPath
    }
}

function Get-MutEnvironment {
    <#
        .SYNOPSIS
        Looks up an existing DemoPortal environment by name (description).
        .OUTPUTS
        A handle [pscustomobject]@{Id;Name;Url;Backend;Shared;Status;CliPath}, or $null if not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $script:CliPath = Resolve-MutCliPath -Config $Config

    $list = Invoke-Continia -Arguments @('env', 'list', '--json')
    if (-not $list) {
        return $null
    }

    $match = $list | Where-Object { $_.description -eq $Name } | Select-Object -First 1
    if (-not $match) {
        return $null
    }

    return ConvertTo-MutEnvironmentHandle -Raw $match
}

function Start-MutEnvironmentWithRetry {
    <#
        .SYNOPSIS
        Private. FIX (run 11, 2026-10-01): issues `env start` and polls `env get` until the
        environment is Running, re-issuing the start whenever it has stayed Stopped for
        $script:StartRetryAfterPolls consecutive polls (~90 s). Gives up after
        $script:MaxStartPollIterations polls (~30 min).

        Twice on 2026-09-30 a start issued right after a stop completed never took effect: the
        environment stayed Stopped, and the container log said "Failed to move database ...
        Container marked as unhealthy due to database move failure" -- the new container's
        database attach racing the old one. A start issued minutes later worked. The single start
        plus a 600 s wait this replaces could never recover from that, and run 11 aborted on it.
        A Starting environment is left alone: that start did take.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    Invoke-Continia -Arguments @('env', 'start', $Id) -ExpectJson:$false | Out-Null
    $startCalls = 1
    $consecutiveStopped = 0
    $lastResponse = $null

    for ($i = 0; $i -lt $script:MaxStartPollIterations; $i++) {
        $env = Invoke-Continia -Arguments @('env', 'get', $Id, '--json')
        $lastResponse = $env
        $status = $null
        if (Test-MutHasProperty $env 'status') {
            $status = $env.status
        }
        if ($status -eq 'Running') {
            return $env
        }

        if ($status -eq 'Stopped') {
            $consecutiveStopped++
        }
        else {
            $consecutiveStopped = 0
        }
        if ($consecutiveStopped -ge $script:StartRetryAfterPolls) {
            $startCalls++
            Write-Warning "Start-MutEnvironmentWithRetry: environment '$Id' is still Stopped $($consecutiveStopped * $script:PollIntervalSec) s after env start; issuing env start again (call $startCalls). A start right after a stop can be lost while the previous container still holds the database."
            Invoke-Continia -Arguments @('env', 'start', $Id) -ExpectJson:$false | Out-Null
            $consecutiveStopped = 0
        }
        Start-Sleep -Seconds $script:PollIntervalSec
    }

    $lastJson = $lastResponse | ConvertTo-Json -Depth 10 -Compress
    throw "Start-MutEnvironmentWithRetry: environment '$Id' did not reach status 'Running' within $($script:MaxStartPollIterations * $script:PollIntervalSec) seconds after $startCalls env start call(s). Last response: $lastJson"
}

function Wait-MutEnvironmentStatus {
    <#
        .SYNOPSIS
        Polls `env get <id> --json` every 10s (max 60 iterations, i.e. up to 10 minutes) until
        the response's `status` equals $Status. A response missing the `status` property
        entirely (or $null) counts as "not yet ready" and is retried rather than treated as an
        error (T03 fix round 3: the CLI can return a transiently incomplete body immediately
        after `env create`/`env start`, and under Set-StrictMode a bare `.status` access on
        such a response is a hard crash rather than "not equal").
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    $lastResponse = $null
    for ($i = 0; $i -lt $script:MaxPollIterations; $i++) {
        $env = Invoke-Continia -Arguments @('env', 'get', $Id, '--json')
        $lastResponse = $env
        if ((Test-MutHasProperty $env 'status') -and $env.status -eq $Status) {
            return $env
        }
        Start-Sleep -Seconds $script:PollIntervalSec
    }

    $lastJson = $lastResponse | ConvertTo-Json -Depth 10 -Compress
    throw "Wait-MutEnvironmentStatus: environment '$Id' did not reach status '$Status' within $($script:MaxPollIterations * $script:PollIntervalSec) seconds. Last response: $lastJson"
}

function Wait-MutEnvironmentSettled {
    <#
        .SYNOPSIS
        Private. FIX (T27 fix round 1, finding 4a -- spike T09): a test job issued immediately
        after the environment's status became Running (via a real Stopped/Draft -> Running
        transition) was observed live to return total 0 tests discovered/run for a codeunit
        that DOES have tests -- "Running" alone does not guarantee the app/test-execution
        service is actually ready. Polls `env apps <id> --all --json` every
        $script:PollIntervalSec (10s) for up to 12 tries (120s) until it returns a non-empty app
        list, then waits a further fixed 30s. Called by Start-MutEnvironment (only on a real
        transition to Running) and by Reset-MutEnvironment (always, since it always
        stops-then-starts).

        FIX (T11b, spike U5, live 2026-09-16): the `env apps` poll + fixed 30s above was STILL
        not sufficient -- a `test run` issued right after it, on codeunit 50300 (which has
        tests), came back total 0 / passed 0 (no tests discovered). This adds a second,
        stronger probe: `test run <id> <ProbeCodeunitId> <ProbeFunction> --json --timeout 120`
        (via Invoke-Continia), up to 10 times 30s apart, until the response's
        `summary.total -gt 0`. The probe target comes from `$Config.demoPortal.settleProbe`
        (`{ codeunitId; functionName }`); when $Config is $null or carries no such key, the
        probe is skipped with a warning rather than silently treated as ready (callers that
        genuinely cannot supply a config, e.g. Reset-MutEnvironment without -Config, get the
        old apps-poll-only behavior, never a silent guarantee of readiness). An environment that
        never reports a positive total after all 10 attempts throws -- an unready environment
        must not silently continue and risk every subsequent mutant being lost.

        FIX (F3b IMPORTANT 2): that "throws" above is now conditional on $RequireProbe. Making
        the settle-and-probe unconditional (F3, finding I6) means Ensure-MutEnvironment's
        pre-baseline call (§6.5.4 step 2) now reaches this probe on every run, but both shipped
        configs point `settleProbe` at codeunit 95155 -- the AUT's OWN test codeunit, which does
        not exist until Publish-MutBaseline (step 3) installs the test app. A fresh environment,
        one whose test app was unpublished, or a `-SkipEnvironment` run now died here after
        ~10 attempts x 30s, before the baseline that would have made the probe target exist ever
        ran. $RequireProbe = $true (default) preserves the original hard-throw contract for
        every caller that does not pass it (Reset-MutEnvironment, and the mutant loop's
        Confirm-MutEnvironmentServing via Start-MutEnvironment, both of which run AFTER the
        baseline and must stay strict); Ensure-MutEnvironment/New-MutEnvironment pass
        -RequireProbe $false so a probe-target-not-found (or never-ready) result is a warning,
        not a fatal error, before the baseline has had a chance to make the target exist.

        .OUTPUTS
        [pscustomobject]@{ SettleDurationSec; SettleProbeAttempts; ProbeConfirmed } --
        SettleDurationSec is the total elapsed seconds (apps poll + the fixed 30s + the
        test-readiness probe, when run); SettleProbeAttempts is 0 when the probe was skipped
        entirely (no demoPortal.settleProbe in $Config). ProbeConfirmed is $true when no probe
        was configured (unchanged pre-F3 behaviour: nothing to confirm) or the probe reported
        `summary.total -gt 0`; $false only when $RequireProbe was explicitly $false and the
        probe never became ready (the one case that used to throw unconditionally).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        $Config,
        [bool]$RequireProbe = $true
    )

    $start = Get-Date
    $maxTries = 12

    for ($i = 0; $i -lt $maxTries; $i++) {
        $apps = Invoke-Continia -Arguments @('env', 'apps', $Id, '--all', '--json')
        if (@($apps).Count -gt 0) {
            break
        }
        Start-Sleep -Seconds $script:PollIntervalSec
    }

    Start-Sleep -Seconds 30

    $probeAttempts = 0
    $probeConfirmed = $true
    $hasProbeConfig = ($null -ne $Config) -and (Test-MutHasProperty $Config 'demoPortal') -and
        (Test-MutHasProperty $Config.demoPortal 'settleProbe') -and ($null -ne $Config.demoPortal.settleProbe)

    if ($hasProbeConfig) {
        $probe = $Config.demoPortal.settleProbe
        $maxProbeAttempts = 10
        $probeReady = $false

        for ($i = 0; $i -lt $maxProbeAttempts; $i++) {
            $probeAttempts++
            $probeResponse = Invoke-Continia -Arguments @('test', 'run', $Id, $probe.codeunitId, $probe.functionName, '--json', '--timeout', '120')
            if ((Test-MutHasProperty $probeResponse 'summary') -and (Test-MutHasProperty $probeResponse.summary 'total') -and ($probeResponse.summary.total -gt 0)) {
                $probeReady = $true
                break
            }
            if ($i -lt ($maxProbeAttempts - 1)) {
                Start-Sleep -Seconds 30
            }
        }

        $probeConfirmed = $probeReady
        if (-not $probeReady) {
            # FIX (F3b IMPORTANT 2): fatal only when the caller requires it (the default,
            # preserving every pre-existing caller's behaviour) -- see this function's own FIX
            # note above for why a pre-baseline caller must be able to opt out.
            if ($RequireProbe) {
                throw "Wait-MutEnvironmentSettled: test-readiness probe (codeunit $($probe.codeunitId), function $($probe.functionName)) never reported summary.total -gt 0 for environment '$Id' after $probeAttempts attempts; the environment may not be ready to run tests."
            }
            Write-Warning "Wait-MutEnvironmentSettled: test-readiness probe (codeunit $($probe.codeunitId), function $($probe.functionName)) never reported summary.total -gt 0 for environment '$Id' after $probeAttempts attempts; continuing without confirmed readiness (RequireProbe was not set for this call) -- the caller must not treat this environment as confirmed serving."
        }
    }
    else {
        Write-Warning "Wait-MutEnvironmentSettled: no demoPortal.settleProbe in config; skipping the test-readiness probe for environment '$Id'."
    }

    $settleDurationSec = ((Get-Date) - $start).TotalSeconds

    return [pscustomobject]@{ SettleDurationSec = $settleDurationSec; SettleProbeAttempts = $probeAttempts; ProbeConfirmed = $probeConfirmed }
}

function Wait-MutEnvironmentAppears {
    <#
        .SYNOPSIS
        Polls `env get <id> --json` every 10s (max 6 iterations, i.e. up to 60s) until the
        response is an object carrying a `status` property at all, regardless of its value.
        Used right after `env create`, whose immediate `env get` response can be transiently
        incomplete (T03 fix round 3).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $lastResponse = $null
    for ($i = 0; $i -lt $script:MaxAppearIterations; $i++) {
        $env = Invoke-Continia -Arguments @('env', 'get', $Id, '--json')
        $lastResponse = $env
        if (Test-MutHasProperty $env 'status') {
            return $env
        }
        Start-Sleep -Seconds $script:PollIntervalSec
    }

    $lastJson = $lastResponse | ConvertTo-Json -Depth 10 -Compress
    throw "Wait-MutEnvironmentAppears: environment '$Id' did not return a 'status' property within $($script:MaxAppearIterations * $script:PollIntervalSec) seconds. Last response: $lastJson"
}

function Start-MutEnvironment {
    <#
        .SYNOPSIS
        Idempotently ensures the environment is started and ready: refreshes status via
        `env get`; if not already Running, issues `env start` (no --json; stdout is empty,
        confirmation is on stderr, per T03 fix round 3) then polls to Running. Then, on EVERY
        call -- not only a real transition to Running -- waits for the environment to settle
        (Wait-MutEnvironmentSettled, T27 fix round 1 finding 4a), including its test-readiness
        probe; then installs the Continia Core Internal Activation App and sets the workspace
        default env (`env use`) unconditionally, since those are safe to repeat.

        FIX (F3, run 8, 2026-09-22 -- see .superpowers/sdd/tasks.json/brief-F3-readiness.md /
        finding I6): this settle-and-probe call used to run ONLY inside the "not already
        Running" branch, on the assumption that a `Running` status is proof the environment is
        serving. It is not: run 8 fired 46 test jobs in a row at an environment that reported
        Running but was not actually serving requests, and every one of them silently came back
        "no tests discovered" instead of a real result. The probe is comparatively cheap (its
        own apps-poll/fixed-delay/test-run cost, §6.5.3) next to the run time a false-negative
        empty result wastes, so it now always runs, regardless of whether `env start` was
        needed this call.
        FIX (F3b IMPORTANT 2): -RequireProbe (default $true) is forwarded to
        Wait-MutEnvironmentSettled -- see that function's own FIX note. Callers that run before
        the baseline can possibly have installed the probe's target test codeunit
        (Ensure-MutEnvironment, New-MutEnvironment) pass -RequireProbe $false; the mutant loop's
        Confirm-MutEnvironmentServing (MutantLoop.psm1), which only ever runs after the
        baseline, does not pass it and stays strict.

        .OUTPUTS
        The handle with Status='Running', StartDurationSec, ActivationInstallDurationSec,
        SettleDurationSec, SettleProbeAttempts, ProbeConfirmed. StartDurationSec is 0 when the
        environment was already Running and `env start`/the Running poll were skipped;
        SettleDurationSec/SettleProbeAttempts/ProbeConfirmed always reflect a real
        settle-and-probe call (see Wait-MutEnvironmentSettled's own OUTPUTS for ProbeConfirmed).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config,
        [bool]$RequireProbe = $true
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = Resolve-MutCliPath -Config $Config

    $current = Invoke-Continia -Arguments @('env', 'get', $Env.Id, '--json')

    $startDurationSec = 0
    $running = $current

    if (-not ((Test-MutHasProperty $current 'status') -and $current.status -eq 'Running')) {
        $startStart = Get-Date
        $running = Start-MutEnvironmentWithRetry -Id $Env.Id
        $startDurationSec = ((Get-Date) - $startStart).TotalSeconds
    }

    # FIX (F3, I6): unconditional -- see this function's own FIX note above. A `Running` status
    # alone is not proof of readiness; only this probe is.
    $settled = Wait-MutEnvironmentSettled -Id $Env.Id -Config $Config -RequireProbe $RequireProbe
    $settleDurationSec = $settled.SettleDurationSec
    $settleProbeAttempts = $settled.SettleProbeAttempts
    $probeConfirmed = $settled.ProbeConfirmed

    $activationStart = Get-Date
    Invoke-Continia -Arguments @('deps', 'install-by-id', $Env.Id, $Config.demoPortal.activationAppId, '--json') | Out-Null
    $activationInstallDurationSec = ((Get-Date) - $activationStart).TotalSeconds

    Invoke-Continia -Arguments @('env', 'use', $Env.Id) -ExpectJson:$false | Out-Null

    $handle = ConvertTo-MutEnvironmentHandle -Raw $running

    Add-Member -InputObject $handle -NotePropertyName 'StartDurationSec' -NotePropertyValue $startDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'ActivationInstallDurationSec' -NotePropertyValue $activationInstallDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'SettleDurationSec' -NotePropertyValue $settleDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'SettleProbeAttempts' -NotePropertyValue $settleProbeAttempts
    Add-Member -InputObject $handle -NotePropertyName 'ProbeConfirmed' -NotePropertyValue $probeConfirmed

    return $handle
}

function ConvertTo-MutBcVersion {
    <#
        .SYNOPSIS
        Private. A dotted BC version ('29.0', '29.0.0.0') as four ints, or $null when it is not
        one. Compared numerically: as strings, '9.0' would sort above '29.0'.
    #>
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parts = $Text.Trim().Split('.')
    if ($parts.Count -gt 4) { return $null }
    $numbers = New-Object 'System.Collections.Generic.List[int]'
    foreach ($part in $parts) {
        if ($part -notmatch '^\d+$') { return $null }
        $numbers.Add([int]$part)
    }
    while ($numbers.Count -lt 4) { $numbers.Add(0) }
    return , $numbers.ToArray()
}

function Compare-MutBcVersion {
    <# Private. Negative when $A < $B, 0 when equal, positive when $A > $B (four-int arrays). #>
    param([int[]]$A, [int[]]$B)

    for ($i = 0; $i -lt 4; $i++) {
        if ($A[$i] -ne $B[$i]) { return $A[$i] - $B[$i] }
    }
    return 0
}

function Get-MutRequiredBcVersion {
    <#
        .SYNOPSIS
        Private. The highest `application` or `platform` version declared by any app.json under
        aut.sourcePath and testApp.sourcePath (folders named .alpackages, .git or .snapshots
        skipped), in its original spelling; $null when none declares one.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $best = $null
    $bestParsed = $null
    foreach ($root in @([string]$Config.aut.sourcePath, [string]$Config.testApp.sourcePath)) {
        if ([string]::IsNullOrEmpty($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $root -Filter 'app.json' -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](\.alpackages|\.git|\.snapshots)[\\/]' })
        foreach ($file in $files) {
            try { $app = Read-MutTextFile -Path $file.FullName | ConvertFrom-Json } catch { continue }
            if ($null -eq $app) { continue }
            foreach ($key in @('application', 'platform')) {
                if ($null -eq $app.PSObject.Properties[$key]) { continue }
                $parsed = ConvertTo-MutBcVersion ([string]$app.$key)
                if ($null -eq $parsed) { continue }
                if ($null -eq $bestParsed -or (Compare-MutBcVersion $parsed $bestParsed) -gt 0) {
                    $best = [string]$app.$key
                    $bestParsed = $parsed
                }
            }
        }
    }
    return $best
}

function Resolve-MutProfileId {
    <#
        .SYNOPSIS
        Private. The DemoPortal profile for a new environment. demoPortal.profileId when set (an
        explicit pin). Otherwise derived like DevOpsCoder's env-provision stage: the BC version
        the apps require (Get-MutRequiredBcVersion), the lowest published profile version at
        least that high (env profiles versions), then the enabled profile of that version in
        demoPortal.localization ('base' by default) with the lowest id (env profiles list).
        A pinned profile once built BC 28.1 for a branch that needed 29.0.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $demo = $Config.demoPortal
    if ($null -ne $demo.PSObject.Properties['profileId'] -and -not [string]::IsNullOrWhiteSpace([string]$demo.profileId)) {
        return [string]$demo.profileId
    }

    $required = Get-MutRequiredBcVersion -Config $Config
    if ($null -eq $required) {
        throw "Resolve-MutProfileId: no app.json under aut.sourcePath or testApp.sourcePath declares 'application' or 'platform', so the BC version cannot be derived. Set demoPortal.profileId to pin a profile."
    }
    $requiredParsed = ConvertTo-MutBcVersion $required

    $versionsRaw = Invoke-Continia -Arguments @('env', 'profiles', 'versions', '--json')
    if ($null -ne $versionsRaw -and $null -ne $versionsRaw.PSObject.Properties['versions']) { $versionsRaw = $versionsRaw.versions }
    $available = @($versionsRaw | ForEach-Object { [string]$_ })
    $chosen = $null
    $chosenParsed = $null
    foreach ($version in $available) {
        $parsed = ConvertTo-MutBcVersion $version
        if ($null -eq $parsed -or (Compare-MutBcVersion $parsed $requiredParsed) -lt 0) { continue }
        if ($null -eq $chosenParsed -or (Compare-MutBcVersion $parsed $chosenParsed) -lt 0) {
            $chosen = $version
            $chosenParsed = $parsed
        }
    }
    if ($null -eq $chosen) {
        throw "Resolve-MutProfileId: no DemoPortal profile version is at least BC $required, which the app.json files require (available: $($available -join ', ')). Set demoPortal.profileId to pin a profile."
    }

    $localization = 'base'
    if ($null -ne $demo.PSObject.Properties['localization'] -and -not [string]::IsNullOrWhiteSpace([string]$demo.localization)) {
        $localization = [string]$demo.localization
    }

    $listRaw = Invoke-Continia -Arguments @('env', 'profiles', 'list', '--bc-version', $chosen, '--json')
    if ($null -ne $listRaw -and $null -ne $listRaw.PSObject.Properties['profiles']) { $listRaw = $listRaw.profiles }
    $rows = @($listRaw | ForEach-Object { $_ } | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty([string]$_.id) })
    $enabled = @($rows | Where-Object { $null -eq $_.PSObject.Properties['isEnabled'] -or $_.isEnabled -ne $false })
    # The rows' own bcVersion is re-checked against the chosen version: a list the server did not
    # filter must not hand back a lower version, or a higher one with a lower id.
    $fitting = @($enabled | Where-Object {
            $rowVersion = $null
            if ($null -ne $_.PSObject.Properties['bcVersion']) { $rowVersion = ConvertTo-MutBcVersion ([string]$_.bcVersion) }
            $null -ne $rowVersion -and (Compare-MutBcVersion $rowVersion $chosenParsed) -eq 0
        })
    $candidates = @($fitting | Where-Object { [string]::Equals([string]$_.localization, $localization, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($candidates.Count -eq 0) {
        $have = (@($fitting | ForEach-Object { [string]$_.localization }) | Sort-Object -Unique) -join ', '
        throw "Resolve-MutProfileId: BC $chosen publishes no enabled '$localization' profile (available localizations: $have). Set demoPortal.localization to one of those, or demoPortal.profileId to pin a profile."
    }
    # Ordinal order, not culture order, so the pick does not depend on the host.
    $ids = [string[]]@($candidates | ForEach-Object { [string]$_.id })
    [System.Array]::Sort($ids, [System.StringComparer]::Ordinal)
    if ($ids.Count -gt 1) {
        Write-Warning "Resolve-MutProfileId: BC $chosen publishes $($ids.Count) enabled '$localization' profiles ($($ids -join ', ')); taking the lowest id."
    }
    return $ids[0]
}

function New-MutEnvironment {
    <#
        .SYNOPSIS
        Creates a fresh DemoPortal environment (env create), waits for it to become visible
        with a status at all (env get, up to 60s), then delegates starting/activating it to
        Start-MutEnvironment.

        FIX (F3b IMPORTANT 2): always calls Start-MutEnvironment with -RequireProbe $false -- a
        brand-new environment is, by definition, always a pre-baseline caller (§6.5.4 step 2),
        so the probe target (the AUT's own test codeunit) cannot possibly exist yet. See
        Wait-MutEnvironmentSettled's own FIX note for the full hazard.

        .OUTPUTS
        A handle plus CreateDurationSec, StartDurationSec, ActivationInstallDurationSec.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Config
    )

    if ($Name -cnotmatch '^mut-') {
        throw "New-MutEnvironment: name '$Name' does not match '^mut-'; refusing to create it."
    }

    $script:CliPath = Resolve-MutCliPath -Config $Config

    $createStart = Get-Date
    $created = Invoke-Continia -Arguments @('env', 'create', '--name', $Name, '--profile', (Resolve-MutProfileId -Config $Config), '--json')
    $envId = $created.id

    $appeared = Wait-MutEnvironmentAppears -Id $envId
    $createDurationSec = ((Get-Date) - $createStart).TotalSeconds

    $envHandle = ConvertTo-MutEnvironmentHandle -Raw $appeared
    $handle = Start-MutEnvironment -Env $envHandle -Config $Config -RequireProbe $false

    Add-Member -InputObject $handle -NotePropertyName 'CreateDurationSec' -NotePropertyValue $createDurationSec

    return $handle
}

function Remove-MutEnvironment {
    <#
        .SYNOPSIS
        Deletes the environment (or stops it, when $Config.keepEnvironment is $true).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = Resolve-MutCliPath -Config $Config

    if ($Config.keepEnvironment) {
        Invoke-Continia -Arguments @('env', 'stop', $Env.Id) -ExpectJson:$false | Out-Null
    }
    else {
        Invoke-Continia -Arguments @('env', 'delete', $Env.Id) -ExpectJson:$false | Out-Null
    }
}

function Remove-MutRunEnvironment {
    <#
        .SYNOPSIS
        Deletes the environment named by $Config.environmentName, whatever keepEnvironment says:
        mutant-fixer keeps a per-PR environment through the run and the verify, then deletes it
        with this. Refuses a name not matching '^mut-' and a Shared environment.
        .OUTPUTS
        The deleted environment's name, or $null when it was already gone.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $name = [string]$Config.environmentName
    if ($name -cnotmatch '^mut-') {
        throw "Remove-MutRunEnvironment: environment name '$name' does not match '^mut-'; refusing to delete it."
    }

    $envHandle = Get-MutEnvironment -Name $name -Config $Config
    if ($null -eq $envHandle) {
        return $null
    }
    Assert-MutEnvironmentAllowed $envHandle
    Invoke-Continia -Arguments @('env', 'delete', $envHandle.Id) -ExpectJson:$false | Out-Null
    return $envHandle.Name
}

function Remove-MutOrphanEnvironments {
    <#
        .SYNOPSIS
        Deletes every environment whose name starts with $Prefix (case-sensitive), except $Keep
        and except Shared ones. $Prefix must start with 'mut-' and be longer than it, so a sweep
        can never reach the hand-made 'mut-spike-*' environments by accident. A failed delete is
        a warning and the sweep goes on; a failed listing throws.
        .OUTPUTS
        The names of the deleted environments.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [string]$Keep = '',
        [Parameter(Mandatory = $true)]$Config
    )

    if (-not $Prefix.StartsWith('mut-', [System.StringComparison]::Ordinal) -or $Prefix.Length -le 'mut-'.Length) {
        throw "Remove-MutOrphanEnvironments: prefix '$Prefix' must start with 'mut-' and name more than 'mut-' itself; refusing to sweep."
    }

    $script:CliPath = Resolve-MutCliPath -Config $Config
    $list = @(Invoke-Continia -Arguments @('env', 'list', '--json') | ForEach-Object { $_ })

    $deleted = @()
    foreach ($raw in $list) {
        $name = [string]$raw.description
        if (-not $name.StartsWith($Prefix, [System.StringComparison]::Ordinal) -or $name -ceq $Keep) {
            continue
        }
        $envHandle = ConvertTo-MutEnvironmentHandle -Raw $raw
        if ($envHandle.Shared) {
            continue
        }
        try {
            Invoke-Continia -Arguments @('env', 'delete', $envHandle.Id) -ExpectJson:$false | Out-Null
            $deleted += $name
        }
        catch {
            Write-Warning "Remove-MutOrphanEnvironments: deleting '$name' ($($envHandle.Id)) failed: $($_.Exception.Message)"
        }
    }
    return $deleted
}

function Reset-MutEnvironment {
    <#
        .SYNOPSIS
        Stops then starts the environment, polling for the Stopped and Running states, then
        waits for the environment to settle (Wait-MutEnvironmentSettled, T27 fix round 1 finding
        4a) before returning -- Reset-MutEnvironment always performs a real stop/start, so it
        always settles, unlike Start-MutEnvironment's own conditional check.

        .PARAMETER Config
        Optional (T11b, spike U5). Forwarded to Wait-MutEnvironmentSettled so its
        test-readiness probe can run using `$Config.demoPortal.settleProbe`. When omitted, the
        probe is skipped with a warning (see Wait-MutEnvironmentSettled) rather than treated as
        a guarantee of readiness -- callers that cannot supply a config keep the older
        apps-poll-only settle behavior.

        .OUTPUTS
        [pscustomobject]@{ DurationSec; SettleDurationSec; SettleProbeAttempts }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        $Config
    )

    Assert-MutEnvironmentAllowed $Env

    $start = Get-Date

    Invoke-Continia -Arguments @('env', 'stop', $Env.Id) -ExpectJson:$false | Out-Null
    Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Stopped' | Out-Null

    Start-MutEnvironmentWithRetry -Id $Env.Id | Out-Null

    $settled = Wait-MutEnvironmentSettled -Id $Env.Id -Config $Config

    $durationSec = ((Get-Date) - $start).TotalSeconds

    return [pscustomobject]@{ DurationSec = $durationSec; SettleDurationSec = $settled.SettleDurationSec; SettleProbeAttempts = $settled.SettleProbeAttempts }
}

function Get-MutCredential {
    <#
        .SYNOPSIS
        Returns a PSCredential for the environment's "Super User" (username "Rf"), read once
        per session from `env users <id> --json` and cached in a script-scoped hashtable keyed
        by environment id. Never written to output, files, the ledger, or console.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    if ($script:MutCredentialCache.ContainsKey($Env.Id)) {
        return $script:MutCredentialCache[$Env.Id]
    }

    $users = Invoke-Continia -Arguments @('env', 'users', $Env.Id, '--json')
    $superUser = $users | Where-Object { $_.description -eq 'Super User' } | Select-Object -First 1
    if (-not $superUser) {
        throw "Get-MutCredential: no user with description 'Super User' found for environment '$($Env.Name)'."
    }

    $securePassword = ConvertTo-SecureString -String $superUser.password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($superUser.username, $securePassword)

    $script:MutCredentialCache[$Env.Id] = $credential
    return $credential
}

function Get-MutBasicAuthHeader {
    <#
        .SYNOPSIS
        Builds a @{ Authorization = 'Basic <base64>' } header hashtable from a PSCredential.
        Credentials are encoded in-memory only; never logged.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $plainPassword = $Credential.GetNetworkCredential().Password
    $pair = '{0}:{1}' -f $Credential.UserName, $plainPassword
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $encoded = [Convert]::ToBase64String($bytes)

    return @{ Authorization = "Basic $encoded" }
}

function Get-MutApiBase {
    <#
        .SYNOPSIS
        U8: derives the BC web API base URL for the environment. Tries `$Env.Url`, then
        `$Env.Url` with '/BC' appended; the first candidate whose `/api/v2.0/companies` GET
        succeeds (2xx) with Basic auth wins. Result is cached per environment id. Throws with
        both attempted URLs if neither works.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    if ($script:MutApiBaseCache.ContainsKey($Env.Id)) {
        return $script:MutApiBaseCache[$Env.Id]
    }

    $credential = Get-MutCredential -Env $Env
    $headers = Get-MutBasicAuthHeader -Credential $credential

    $candidates = @($Env.Url, "$($Env.Url)/BC")
    foreach ($candidate in $candidates) {
        try {
            Invoke-RestMethod -Uri "$candidate/api/v2.0/companies" -Method Get -Headers $headers | Out-Null
            $script:MutApiBaseCache[$Env.Id] = $candidate
            return $candidate
        }
        catch {
            continue
        }
    }

    throw "Get-MutApiBase: no working API base found for environment '$($Env.Name)'. Tried: $($candidates -join ', ')"
}

function Get-MutCompanyInfo {
    <#
        .SYNOPSIS
        Private. The first company of `<apiBase>/api/v2.0/companies` as @{ Id; Name }, cached per
        environment id so a session makes one lookup (§6.10.3).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [string]$Caller = 'Get-MutCompanyInfo'
    )

    Assert-MutEnvironmentAllowed $Env

    if ($script:MutCompanyCache.ContainsKey($Env.Id)) {
        return $script:MutCompanyCache[$Env.Id]
    }

    $apiBase = Get-MutApiBase -Env $Env
    $credential = Get-MutCredential -Env $Env
    $headers = Get-MutBasicAuthHeader -Credential $credential

    $response = Invoke-RestMethod -Uri "$apiBase/api/v2.0/companies" -Method Get -Headers $headers
    $companies = @($response.value)
    if ($companies.Count -eq 0) {
        throw "${Caller}: environment '$($Env.Name)' has no companies."
    }

    $info = @{ Id = $companies[0].id; Name = $companies[0].name }
    $script:MutCompanyCache[$Env.Id] = $info
    return $info
}

function Get-MutCompanyId {
    <#
        .SYNOPSIS
        Returns the GUID id of the first company reported by `<apiBase>/api/v2.0/companies`
        (cached per environment id).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    return (Get-MutCompanyInfo -Env $Env -Caller 'Get-MutCompanyId').Id
}

function Get-MutCompanyName {
    <#
        .SYNOPSIS
        Returns the `name` of the first company (the SOAP web-service path takes the name, S7),
        cached per environment id together with Get-MutCompanyId.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    return (Get-MutCompanyInfo -Env $Env -Caller 'Get-MutCompanyName').Name
}

function Invoke-MutApi {
    <#
        .SYNOPSIS
        Calls the Mutation Core API pages. Path is relative to
        `<apiBase>/api/mutation/core/v1.0/companies(<companyId>)/`; a PATCH sends
        `If-Match: *`; the body (if any) is serialized with `ConvertTo-Json -Depth 10`.
        .OUTPUTS
        Parsed JSON (the raw object returned by Invoke-RestMethod).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        $Body
    )

    Assert-MutEnvironmentAllowed $Env

    $apiBase = Get-MutApiBase -Env $Env
    $companyId = Get-MutCompanyId -Env $Env
    $credential = Get-MutCredential -Env $Env
    $headers = Get-MutBasicAuthHeader -Credential $credential

    if ($Method -eq 'PATCH') {
        $headers['If-Match'] = '*'
    }

    $uri = "$apiBase/api/mutation/core/v1.0/companies($companyId)/$Path"

    $invokeArgs = @{
        Uri     = $uri
        Method  = $Method
        Headers = $headers
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $invokeArgs['Body'] = ($Body | ConvertTo-Json -Depth 10)
        $invokeArgs['ContentType'] = 'application/json'
    }

    return Invoke-RestMethod @invokeArgs
}

function Grant-MutPermissionSet {
    <#
        .SYNOPSIS
        Grants a permission set (role) to every user of the environment via the Automation API,
        idempotently: a user already holding a `userPermissions` row for that permission set
        (matched by BC's `roleId` field, verified live against mut-spike-01 — the field is NOT
        called `permissionSetId` in the actual `userPermissions` entity, despite that name being
        used loosely in the spec's prose; see docs/issues.md) is skipped.

        .OUTPUTS
        @{ Granted = [string[]] userNames just granted; AlreadyHad = [string[]] userNames that
        already held the set }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$PermissionSetId,
        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    Assert-MutEnvironmentAllowed $Env

    $apiBase = Get-MutApiBase -Env $Env
    $companyId = Get-MutCompanyId -Env $Env
    $credential = Get-MutCredential -Env $Env
    $headers = Get-MutBasicAuthHeader -Credential $credential

    $automationBase = "$apiBase/api/microsoft/automation/v2.0/companies($companyId)"

    $usersResponse = Invoke-RestMethod -Uri "$automationBase/users" -Method Get -Headers $headers
    $users = @($usersResponse.value)

    $granted = @()
    $alreadyHad = @()

    foreach ($user in $users) {
        $permsUri = "$automationBase/users($($user.userSecurityId))/userPermissions"
        $permsResponse = Invoke-RestMethod -Uri $permsUri -Method Get -Headers $headers
        $rows = @($permsResponse.value)

        $hasIt = $false
        foreach ($row in $rows) {
            if ($row.roleId -eq $PermissionSetId) {
                $hasIt = $true
                break
            }
        }

        if ($hasIt) {
            $alreadyHad += $user.userName
            continue
        }

        $body = @{ roleId = $PermissionSetId; appId = $AppId; scope = 'System' }
        Invoke-RestMethod -Uri $permsUri -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
        $granted += $user.userName
    }

    return [pscustomobject]@{ Granted = $granted; AlreadyHad = $alreadyHad }
}

function ConvertTo-MutDiagnosticList {
    <#
        .SYNOPSIS
        Maps a `diagnostics[]` array from `continia compile`/`deploy` (lowercase
        severity/code/file/line/column/message, F12) to
        [pscustomobject]@{Severity;Code;File;Line;Column;Message}. Tolerates $null (no
        diagnostics) and a single bare object (ConvertFrom-Json unwraps a one-element JSON
        array to a scalar) by wrapping in @() first.
    #>
    param($Diagnostics)

    $list = @()
    foreach ($d in @($Diagnostics)) {
        if ($null -eq $d) {
            continue
        }
        $list += [pscustomobject]@{
            Severity = $d.severity
            Code     = $d.code
            File     = $d.file
            Line     = $d.line
            Column   = $d.column
            Message  = $d.message
        }
    }
    # The unary comma forces $list itself (not each element) onto the output stream: a bare
    # `return $list` would have PowerShell enumerate the array and, for the common case of
    # exactly one diagnostic, silently unwrap it to a bare object instead of a 1-element array
    # (verified by direct experiment in this task) -- corrupting every caller's `.Count`/foreach.
    return , $list
}

function Test-MutIsCliRunLevelFailure {
    <#
        .SYNOPSIS
        M6: `continia compile`/`deploy`/`publish` return one of two shapes on failure --
        the normal per-app row (`error` is a plain string, alc's raw output) or, when the run
        cannot even reach the per-app loop, a single object `{success: false, error: {code,
        message}}` where `error` is itself an object. Detects the latter so callers can pull
        `Code`/`ErrorMessage` out of it instead of reading an absent array's first row and
        reporting Success=$false with nothing else (the defect behind three live
        investigations: a run failing with "publishing failed. Diagnostics:" and no further
        clue, root-caused only by re-running the CLI by hand to read error.code -- T13,
        docs/issues.md).
    #>
    param($Response)

    if (-not (Test-MutHasProperty $Response 'success')) {
        return $false
    }
    if ($Response.success -ne $false) {
        return $false
    }
    if (-not (Test-MutHasProperty $Response 'error')) {
        return $false
    }
    return Test-MutHasProperty $Response.error 'code'
}

function Install-MutDependencies {
    <#
        .SYNOPSIS
        `deps install <envId> <AppPath> --json` (F11: installs an app's runtime dependencies,
        e.g. the AUT's dependencies, onto the environment).
        .OUTPUTS
        The parsed JSON response, unmodified.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$AppPath
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = $Env.CliPath

    return Invoke-Continia -Arguments @('deps', 'install', $Env.Id, $AppPath, '--json')
}

function Compile-MutApp {
    <#
        .SYNOPSIS
        `compile <Path> --json [--ruleset <Ruleset>] --no-raw-output` (F12, §6.5.3). AppFile is
        the newest *.app directly under Path after the compile (Get-ChildItem -Filter *.app |
        Sort LastWriteTime -Desc | Select -First 1, per the task brief). Success requires both
        diagnosticCounts.error -eq 0 and an app file being present. TimeoutSec (default 900,
        T25) is forwarded to Invoke-Continia's own process-level timeout: the real AUT compiles
        in ~70s, but the schemata build (many more mutated files) needs headroom.

        M6: a run that cannot reach the per-app loop at all (e.g. symbol refresh failing before
        alc ever runs) returns a single object `{success: false, error: {code, message}}`
        instead of the normal row -- detected via Test-MutIsCliRunLevelFailure and mapped
        straight to Code/ErrorMessage rather than falling through to an empty Diagnostics list.
        On the normal row shape, the row's own `code`/`error` (a free-prose string, e.g. a
        BC-side "Extension compilation failed ... error AL0185: ..." dependent-recompile
        failure) are also always carried into Code/ErrorMessage, since diagnostics[] can be
        empty even though alc reported a real failure.
        .OUTPUTS
        [pscustomobject]@{ Success; Diagnostics; AppFile; DurationSec; Code; ErrorMessage }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Ruleset,
        [int]$TimeoutSec = 900
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = $Env.CliPath

    $arguments = @('compile', $Path, '--json')
    if ($PSBoundParameters.ContainsKey('Ruleset') -and $Ruleset) {
        $arguments += @('--ruleset', $Ruleset)
    }
    $arguments += '--no-raw-output'

    $start = Get-Date
    $result = Invoke-Continia -Arguments $arguments -TimeoutSec $TimeoutSec
    $durationSec = ((Get-Date) - $start).TotalSeconds

    if (Test-MutIsCliRunLevelFailure $result) {
        return [pscustomobject]@{
            Success      = $false
            Diagnostics  = @()
            AppFile      = $null
            DurationSec  = $durationSec
            Code         = $result.error.code
            ErrorMessage = $result.error.message
        }
    }

    $diagnosticsRaw = $null
    if (Test-MutHasProperty $result 'diagnostics') {
        $diagnosticsRaw = $result.diagnostics
    }
    $diagnostics = ConvertTo-MutDiagnosticList -Diagnostics $diagnosticsRaw

    $errorCount = 0
    if ((Test-MutHasProperty $result 'diagnosticCounts') -and (Test-MutHasProperty $result.diagnosticCounts 'error')) {
        $errorCount = $result.diagnosticCounts.error
    }

    $appFile = Get-ChildItem -Path $Path -Filter '*.app' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $appFilePath = $null
    if ($appFile) {
        $appFilePath = $appFile.FullName
    }

    $success = ($errorCount -eq 0) -and ($null -ne $appFilePath)

    $code = $null
    if (Test-MutHasProperty $result 'code') {
        $code = $result.code
    }

    $errorMessage = $null
    if (Test-MutHasProperty $result 'error') {
        $errorMessage = $result.error
    }

    return [pscustomobject]@{
        Success      = $success
        Diagnostics  = $diagnostics
        AppFile      = $appFilePath
        DurationSec  = $durationSec
        Code         = $code
        ErrorMessage = $errorMessage
    }
}

function Publish-MutApp {
    <#
        .SYNOPSIS
        `deploy <envId> <Path> --json [--ruleset <Ruleset>] [--allow-downgrade] [--sync-mode
        <SyncMode>]` (§6.5.3). Reads the first row of the returned JSON array (one row per app
        in the deploy run; this app is always the explicit target, so its row is first, per the
        task brief). TimeoutSec (default 900, T25) is forwarded to Invoke-Continia's own
        process-level timeout, same rationale as Compile-MutApp.

        M6: a run that cannot reach the per-app loop at all (e.g. a dependency-not-on-env or
        symbol-fetch-failed check firing before the array is ever built) returns a single
        object `{success: false, error: {code, message}}` instead of the array -- detected via
        Test-MutIsCliRunLevelFailure and mapped straight to Code/ErrorMessage, rather than
        reading an absent first row and reporting Success=$false with an empty Diagnostics list
        and no Code (the defect behind three live investigations, docs/issues.md T13). On the
        normal array path, the row's own `error` (free prose, e.g. a BC-side "Extension
        compilation failed ... error AL0185: ..." dependent-recompile failure) is always carried
        into ErrorMessage too, since diagnostics[] can be empty even when the row failed.
        .OUTPUTS
        [pscustomobject]@{ Success; Code; Diagnostics; DurationSec; ErrorMessage }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Ruleset,
        [switch]$AllowDowngrade,
        [string]$SyncMode,
        [int]$TimeoutSec = 900
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = $Env.CliPath

    $arguments = @('deploy', $Env.Id, $Path, '--json')
    if ($PSBoundParameters.ContainsKey('Ruleset') -and $Ruleset) {
        $arguments += @('--ruleset', $Ruleset)
    }
    if ($AllowDowngrade) {
        $arguments += '--allow-downgrade'
    }
    if ($PSBoundParameters.ContainsKey('SyncMode') -and $SyncMode) {
        $arguments += @('--sync-mode', $SyncMode)
    }

    $start = Get-Date
    $result = Invoke-Continia -Arguments $arguments -TimeoutSec $TimeoutSec
    $durationSec = ((Get-Date) - $start).TotalSeconds

    if (Test-MutIsCliRunLevelFailure $result) {
        return [pscustomobject]@{
            Success      = $false
            Code         = $result.error.code
            Diagnostics  = @()
            DurationSec  = $durationSec
            ErrorMessage = $result.error.message
        }
    }

    $row = @($result) | Select-Object -First 1

    if ($null -eq $row) {
        # An empty-array CLI response (no rows at all) is not the same as a row that reported
        # failure: without this branch, every Test-MutHasProperty guard below is false against a
        # $null $row and the function returns Success=$false with a null Code, ErrorMessage and
        # an empty Diagnostics list -- verbatim the empty-diagnostics shape M6 was written to
        # eliminate (Run.psm1's caller then throws "publishing aut-original failed. Code: ;
        # Message: ; Diagnostics: []", which names nothing actionable).
        return [pscustomobject]@{
            Success      = $false
            Code         = $null
            Diagnostics  = @()
            DurationSec  = $durationSec
            ErrorMessage = "Publish-MutApp: deploy returned no rows for '$Path' (empty array response)."
        }
    }

    $diagnostics = @()
    if (Test-MutHasProperty $row 'diagnostics') {
        $diagnostics = ConvertTo-MutDiagnosticList -Diagnostics $row.diagnostics
    }

    $code = $null
    if (Test-MutHasProperty $row 'code') {
        $code = $row.code
    }

    $errorMessage = $null
    if (Test-MutHasProperty $row 'error') {
        $errorMessage = $row.error
    }

    $success = (Test-MutHasProperty $row 'published') -and ($row.published -eq $true)

    return [pscustomobject]@{
        Success      = $success
        Code         = $code
        Diagnostics  = $diagnostics
        DurationSec  = $durationSec
        ErrorMessage = $errorMessage
    }
}

function Publish-MutAppFile {
    <#
        .SYNOPSIS
        `publish <envId> <AppFile> [--sync-mode <SyncMode>] --json` (§6.5.3): publishes a
        pre-built .app file directly (no compile step), e.g. the schemata build.

        M6: on failure, detects the same `{success: false, error: {code, message}}` run-level
        envelope (Test-MutIsCliRunLevelFailure) the array-shaped commands use and maps it to
        Code/ErrorMessage; a flat `code`/`error` on the response itself (mirroring a deploy
        row) is carried the same way, so a caller never sees a bare Success=$false with no
        indication of why.
        .OUTPUTS
        [pscustomobject]@{ Success; DurationSec; Code; ErrorMessage }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$AppFile,
        [string]$SyncMode
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = $Env.CliPath

    $arguments = @('publish', $Env.Id, $AppFile)
    if ($PSBoundParameters.ContainsKey('SyncMode') -and $SyncMode) {
        $arguments += @('--sync-mode', $SyncMode)
    }
    $arguments += '--json'

    $start = Get-Date
    $result = Invoke-Continia -Arguments $arguments
    $durationSec = ((Get-Date) - $start).TotalSeconds

    if (Test-MutIsCliRunLevelFailure $result) {
        return [pscustomobject]@{
            Success      = $false
            DurationSec  = $durationSec
            Code         = $result.error.code
            ErrorMessage = $result.error.message
        }
    }

    $success = (Test-MutHasProperty $result 'success') -and ($result.success -eq $true)

    $code = $null
    if (Test-MutHasProperty $result 'code') {
        $code = $result.code
    }

    $errorMessage = $null
    if (Test-MutHasProperty $result 'error') {
        $errorMessage = $result.error
    }

    return [pscustomobject]@{
        Success      = $success
        DurationSec  = $durationSec
        Code         = $code
        ErrorMessage = $errorMessage
    }
}

function Unpublish-MutApp {
    <#
        .SYNOPSIS
        `unpublish <envId> --app-id <AppId> [--app-version <Version>] --json` (§6.5.3), e.g. to
        remove the test app before republishing it (schemata.publishStrategy
        'unpublish-test-app', §6.5.4 step 5).
        .OUTPUTS
        [pscustomobject]@{ Success }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [string]$Version
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = $Env.CliPath

    $arguments = @('unpublish', $Env.Id, '--app-id', $AppId)
    if ($PSBoundParameters.ContainsKey('Version') -and $Version) {
        $arguments += @('--app-version', $Version)
    }
    $arguments += '--json'

    $result = Invoke-Continia -Arguments $arguments

    $success = (Test-MutHasProperty $result 'success') -and ($result.success -eq $true)

    return [pscustomobject]@{ Success = $success }
}

function ConvertTo-MutTestOutcome {
    <#
        .SYNOPSIS
        Normalizes a `test run --json` per-test `result` string ('Pass'/'Fail'/'Skip', per the
        continia-test skill) to the Tests[].Result values 'Pass'|'Fail'|'Skip'. Anything else
        (an undocumented value) passes through unchanged rather than being silently coerced.
    #>
    param([string]$Raw)

    switch ($Raw) {
        'Pass' { return 'Pass' }
        'Fail' { return 'Fail' }
        'Skip' { return 'Skip' }
        default { return $Raw }
    }
}

function ConvertTo-MutXunitTests {
    <#
        .SYNOPSIS
        Parses `test run ... --raw`'s xUnit XML body into the same Tests[] row shape as the
        --json path (§6.5.3, T24/U9): `<assemblies><assembly><collection><test name method time
        result>` with `<failure><message>` on failed tests. Selects `//test` nodes so the parse
        does not depend on the exact assembly/collection nesting.
        .OUTPUTS
        [pscustomobject[]] {Codeunit; Function; Result; DurationMs; Error}
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlDocument]$XmlDoc,
        [Parameter(Mandatory = $true)]
        $Target
    )

    $tests = @()
    foreach ($node in @($XmlDoc.SelectNodes('//test'))) {
        if ($null -eq $node) {
            continue
        }

        $function = $null
        if ($node.Attributes['method']) {
            $function = $node.Attributes['method'].Value
        }
        elseif ($node.Attributes['name']) {
            $function = $node.Attributes['name'].Value
        }

        $codeunit = "$($Target.CodeunitId)"
        if ($node.Attributes['type']) {
            $codeunit = $node.Attributes['type'].Value
        }

        $durationMs = 0
        if ($node.Attributes['time']) {
            $durationMs = [int][math]::Round([double]$node.Attributes['time'].Value * 1000)
        }

        $resultRaw = $null
        if ($node.Attributes['result']) {
            $resultRaw = $node.Attributes['result'].Value
        }

        $errorMessage = ''
        $failureMessageNode = $node.SelectSingleNode('failure/message')
        if ($null -ne $failureMessageNode) {
            $errorMessage = $failureMessageNode.InnerText
        }

        $tests += [pscustomobject]@{
            Codeunit   = $codeunit
            Function   = $function
            Result     = ConvertTo-MutTestOutcome -Raw $resultRaw
            DurationMs = $durationMs
            Error      = $errorMessage
        }
    }

    # See the identical note on ConvertTo-MutDiagnosticList: the unary comma keeps a 1-element
    # result an array instead of unwrapping it via pipeline enumeration.
    return , $tests
}

function Get-MutTestJobId {
    <#
        .SYNOPSIS
        Extracts the job id from `test run ... --raw`'s leading `Test job started: <N>` line
        (U9, answered 2026-09-08). Searches $StdOut then $StdErr (the line's stream is not
        pinned by the spec); returns $null when neither carries it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$StdOut,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$StdErr
    )

    foreach ($stream in @($StdOut, $StdErr)) {
        if ([string]::IsNullOrEmpty($stream)) {
            continue
        }
        $match = [regex]::Match($stream, '(?m)^Test job started:\s*(\d+)')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }
    return $null
}

function Invoke-MutTests {
    <#
        .SYNOPSIS
        Runs one `test run <envId> <CodeunitId> [<Function>] ... --timeout <TimeoutSec>` per
        DISTINCT (CodeunitId, Function) pair in $Targets (first-seen order), strictly
        sequentially in a plain foreach (F7, F9, guardrail #8: never two DemoPortal test jobs at
        once — no Start-Job/background job is used here). $TimeoutSec is passed to the CLI's
        own `--timeout` and, with a 60s margin added, to Invoke-Continia's process-level
        -TimeoutSec so the wrapper does not kill the process before the CLI's own client-side
        wait would give up.

        Without -Coverage: `--json` (unchanged from T08). Per F18, `test run` exits 1 when
        tests fail while still emitting valid JSON on stdout; Invoke-Continia's default
        -ExpectJson path never treats a non-zero exit code as failure by itself, so a failing
        test run here does not throw. A job id (U9: field name unconfirmed for --json) is read
        from a `jobId` property first, then an `id` property; a target whose response carries
        neither contributes nothing to JobIds.

        With -Coverage (U9, answered 2026-09-08): `--json` does not expose the job id needed by
        `test coverage`, so this runs `--raw` instead via `-ExpectJson:$false -AllowNonZeroExit`
        (F18 applies to `--raw` too: it also exits 1 on test failure, but its stdout is not
        JSON, so -AllowNonZeroExit is required to read it rather than throw). stdout is the
        line `Test job started: <N>` (searched via Get-MutTestJobId, which also checks stderr)
        followed by xUnit XML; the XML is parsed via `[xml]` cast of the text starting at
        stdout's first '<' and converted to Tests rows by ConvertTo-MutXunitTests.
        .OUTPUTS
        [pscustomobject]@{ Passed; Failed; Tests; DurationMs; JobIds }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [object[]]$Targets,
        [int]$TimeoutSec = 120,
        [switch]$Coverage
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = $Env.CliPath

    $seenKeys = New-Object System.Collections.Generic.HashSet[string]
    $distinctTargets = @()
    foreach ($target in $Targets) {
        $function = $null
        if ((Test-MutHasProperty $target 'Function') -and $target.Function) {
            $function = $target.Function
        }
        $key = '{0}|{1}' -f $target.CodeunitId, $function
        if ($seenKeys.Add($key)) {
            $distinctTargets += [pscustomobject]@{ CodeunitId = $target.CodeunitId; Function = $function }
        }
    }

    $totalPassed = 0
    $totalFailed = 0
    $totalDurationMs = 0
    $tests = @()
    $jobIds = @()

    foreach ($target in $distinctTargets) {
        $arguments = @('test', 'run', $Env.Id, $target.CodeunitId)
        if ($target.Function) {
            $arguments += $target.Function
        }

        if ($Coverage) {
            $arguments += @('--raw', '--timeout', $TimeoutSec)

            $response = Invoke-Continia -Arguments $arguments -TimeoutSec ($TimeoutSec + 60) -ExpectJson:$false -AllowNonZeroExit

            $jobId = Get-MutTestJobId -StdOut $response.StdOut -StdErr $response.StdErr
            if ($jobId) {
                $jobIds += $jobId
            }

            # F18: `test run --raw` exits 0 when every test passed and 1 when at least one
            # failed, in both cases with valid xUnit XML on stdout -- so 0 and 1 are the only
            # expected exit codes here. Any other exit code, OR stdout with no parseable XML
            # at all (whatever the exit code), must NOT silently fall through to a clean
            # Passed=0/Failed=0 result: that shape is indistinguishable from "this codeunit
            # genuinely has zero tests" and lets a real CLI-level failure masquerade as a
            # passing baseline (the class of bug U5/T09 and the baseline retry guard at
            # MutantLoop.psm1:593 were written to catch; this call site had no equivalent
            # guard). Surface the exit code and stderr so the caller sees a real failure
            # instead.
            $xmlStart = $response.StdOut.IndexOf('<')
            $hasUnexpectedExitCode = ($response.ExitCode -ne 0) -and ($response.ExitCode -ne 1)
            if ($xmlStart -lt 0 -or $hasUnexpectedExitCode) {
                throw "Invoke-MutTests: coverage run for codeunit $($target.CodeunitId) produced no parseable xUnit XML on stdout, or exited with an unexpected code (ExitCode=$($response.ExitCode); only 0 and 1 are expected). StdOut: $($response.StdOut); StdErr: $($response.StdErr)"
            }

            [xml]$xmlDoc = $response.StdOut.Substring($xmlStart)
            foreach ($t in (ConvertTo-MutXunitTests -XmlDoc $xmlDoc -Target $target)) {
                $tests += $t
                if ($t.Result -eq 'Pass') {
                    $totalPassed++
                }
                elseif ($t.Result -eq 'Fail') {
                    $totalFailed++
                }
                $totalDurationMs += $t.DurationMs
            }

            continue
        }

        $arguments += @('--json', '--timeout', $TimeoutSec)

        $response = Invoke-Continia -Arguments $arguments -TimeoutSec ($TimeoutSec + 60)

        $codeunitName = $null
        if ((Test-MutHasProperty $response 'summary')) {
            if (Test-MutHasProperty $response.summary 'codeunitName') {
                $codeunitName = $response.summary.codeunitName
            }
            if (Test-MutHasProperty $response.summary 'passed') {
                $totalPassed += $response.summary.passed
            }
            if (Test-MutHasProperty $response.summary 'failed') {
                $totalFailed += $response.summary.failed
            }
            if (Test-MutHasProperty $response.summary 'durationSeconds') {
                $totalDurationMs += [int][math]::Round($response.summary.durationSeconds * 1000)
            }
        }

        $responseTests = $null
        if (Test-MutHasProperty $response 'tests') {
            $responseTests = $response.tests
        }
        foreach ($t in @($responseTests)) {
            if ($null -eq $t) {
                continue
            }
            $durationMs = 0
            if (Test-MutHasProperty $t 'durationSeconds') {
                $durationMs = [int][math]::Round($t.durationSeconds * 1000)
            }
            $errorMessage = $null
            if (Test-MutHasProperty $t 'errorMessage') {
                $errorMessage = $t.errorMessage
            }
            $tests += [pscustomobject]@{
                Codeunit   = $codeunitName
                Function   = $t.name
                Result     = ConvertTo-MutTestOutcome -Raw $t.result
                DurationMs = $durationMs
                Error      = $errorMessage
            }
        }

        if (Test-MutHasProperty $response 'jobId') {
            $jobIds += $response.jobId
        }
        elseif (Test-MutHasProperty $response 'id') {
            $jobIds += $response.id
        }
    }

    return [pscustomobject]@{
        Passed     = $totalPassed
        Failed     = $totalFailed
        Tests      = $tests
        DurationMs = $totalDurationMs
        JobIds     = $jobIds
    }
}

function Get-MutCoverageRaw {
    <#
        .SYNOPSIS
        `test coverage <envId> <jobId> --json` per job id (F8), sequentially. Job ids that are
        null or empty are skipped (a target whose test run produced no job id, per Invoke-MutTests).
        .OUTPUTS
        [string[]] of the `csv` field from each response, one per non-empty job id, in order.
        Parsing this CSV into structured rows is Get-MutCoverage / ConvertFrom-MutCoverageCsv,
        added by T24 (not this task).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$JobIds
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = $Env.CliPath

    $csvDocuments = @()
    foreach ($jobId in $JobIds) {
        if ([string]::IsNullOrEmpty($jobId)) {
            continue
        }
        $response = Invoke-Continia -Arguments @('test', 'coverage', $Env.Id, $jobId, '--json')
        $csvDocuments += [string]$response.csv
    }

    # See the comment on ConvertTo-MutDiagnosticList: a bare `return [string[]]$csvDocuments`
    # would unwrap a 1-element array to a bare string via pipeline enumeration; the unary comma
    # keeps it an array regardless of how many (non-skipped) job ids were passed.
    return , [string[]]$csvDocuments
}

function Get-MutCliChildProcesses {
    <#
        .SYNOPSIS
        Private. Direct child processes of this session ($PID) whose executable is the
        configured CLI ($script:CliPath; `continia.exe` when unset). Returns objects with
        ProcessId. Windows: Win32_Process through CIM. Linux: /proc/<pid>/stat, whose second
        field is the executable name cut to 15 characters and whose fourth is the parent pid.
    #>
    $cliName = 'continia.exe'
    if (-not [string]::IsNullOrEmpty($script:CliPath)) {
        $cliName = [System.IO.Path]::GetFileName(($script:CliPath -replace '\\', '/'))
    }

    if (Test-MutIsWindows) {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name='$cliName'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ParentProcessId -eq $PID })
    }

    $comm = $cliName
    if ($comm.Length -gt 15) {
        $comm = $comm.Substring(0, 15)
    }
    $children = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^\d+$') {
            continue
        }
        try {
            $stat = [System.IO.File]::ReadAllText((Join-Path $dir.FullName 'stat'))
        }
        catch {
            continue
        }
        # "<pid> (<comm>) <state> <ppid> ...": comm may contain spaces and parentheses, so split
        # on the LAST ')'.
        $open = $stat.IndexOf('(')
        $close = $stat.LastIndexOf(')')
        if ($open -lt 0 -or $close -lt $open) {
            continue
        }
        $name = $stat.Substring($open + 1, $close - $open - 1)
        $rest = $stat.Substring($close + 1).Trim().Split(' ')
        if ($rest.Count -lt 2 -or $name -cne $comm -or $rest[1] -ne [string]$PID) {
            continue
        }
        $children += [pscustomobject]@{ ProcessId = [int]$dir.Name; ParentProcessId = $PID }
    }
    return $children
}

function Stop-MutBackendChildProcesses {
    <#
        .SYNOPSIS
        FIX (T27 fix round 1, finding 2 -- task review, controller ruling): force-stops every
        `continia.exe` process that is a direct child of THIS session (ParentProcessId -eq
        $PID). Used by MutantLoop.psm1's Invoke-MutTestsWithBudget as the last resort after a
        budget-plus-grace timeout, when the background runspace running Invoke-Continia's
        synchronous Process.WaitForExit never got the chance to return on its own. Lives here
        (in backends/, not lib/) so lib/*.psm1 stays free of the words
        continia/docker/BcContainerHelper (§4 item 6); MutantLoop.psm1 calls this as a plain,
        unqualified command.

        .PARAMETER Env
        Only used for Assert-MutEnvironmentAllowed's guard, matching every other exported
        function in this module -- the process filter itself is by name and parent process id,
        not per-environment (a wedged continia.exe child belongs to THIS process, not to any
        particular environment id).

        .OUTPUTS
        [int] the number of processes stopped.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    $stopped = 0
    $processes = @(Get-MutCliChildProcesses)

    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            $stopped++
        }
        catch {
            # Best-effort: a process that already exited between the query and the stop is not
            # an error condition here.
        }
    }

    return $stopped
}

function Get-MutCoverage {
    <#
        .SYNOPSIS
        `Get-MutCoverageRaw` then `ConvertFrom-MutCoverageCsv` (§6.5.5, from the backend-agnostic
        lib/Coverage.psm1) per document; merges rows across jobs by summing Hits for identical
        (ObjectType, ObjectId, LineNo), keeping the LineType of the first row seen for that key
        (§6.5.3 Get-MutCoverage: "finishes T08", T24).
        .OUTPUTS
        [pscustomobject[]] {ObjectType; ObjectId; LineType; LineNo; Hits}
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$JobIds
    )

    Assert-MutEnvironmentAllowed $Env

    $csvDocuments = Get-MutCoverageRaw -Env $Env -JobIds $JobIds

    $merged = [ordered]@{}
    foreach ($csv in $csvDocuments) {
        foreach ($row in (ConvertFrom-MutCoverageCsv -Csv $csv)) {
            $key = '{0}|{1}|{2}' -f $row.ObjectType, $row.ObjectId, $row.LineNo
            if ($merged.Contains($key)) {
                $merged[$key].Hits += $row.Hits
            }
            else {
                $merged[$key] = [pscustomobject]@{
                    ObjectType = $row.ObjectType
                    ObjectId   = $row.ObjectId
                    LineType   = $row.LineType
                    LineNo     = $row.LineNo
                    Hits       = $row.Hits
                }
            }
        }
    }

    # See the comment on ConvertTo-MutDiagnosticList: the unary comma keeps a 1-element result
    # an array instead of unwrapping it via pipeline enumeration.
    return , [pscustomobject[]]@($merged.Values)
}

# ======================================================================================
# SOAP test transport (§6.10.3): the mutant loop's per-mutant calls go to the MUTRunner web
# service instead of DemoPortal test jobs.
# ======================================================================================

$script:MutRunnerNamespace = 'urn:microsoft-dynamics-schemas/codeunit/MUTRunner'
# Client timeout of the bookkeeping operations (GetRunnerState, StopRunner, DeleteRunnerState):
# they answer in well under a second, so the 600 s default must not hold up a stop or a poll.
$script:MutSoapShortTimeoutSec = 30

function ConvertFrom-MutPwsh7WebException {
    <#
        .SYNOPSIS
        Private. Maps a PowerShell 7 web exception to the WebExceptionStatus name and HTTP status
        that Windows PowerShell 5.1's WebException would give for the same failure:
        HttpResponseException -> ProtocolError + status code; HttpRequestException ->
        NameResolutionFailure, ConnectFailure, ConnectionClosed or ReceiveFailure;
        TaskCanceledException / OperationCanceledException (the -TimeoutSec elapsed) -> Timeout.
        Returns $null for any other exception.
    #>
    param([System.Exception]$Exception)

    $typeName = $Exception.GetType().FullName
    if ($typeName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
        $code = $null
        if ($null -ne $Exception.Response) {
            try { $code = [int]$Exception.Response.StatusCode } catch { }
        }
        return [pscustomobject]@{ Status = 'ProtocolError'; StatusCode = $code }
    }
    if ($typeName -in @('System.Threading.Tasks.TaskCanceledException', 'System.OperationCanceledException')) {
        return [pscustomobject]@{ Status = 'Timeout'; StatusCode = $null }
    }
    if ($typeName -ne 'System.Net.Http.HttpRequestException') {
        return $null
    }

    # .NET 8 (PowerShell 7.4) says what went wrong in HttpRequestError; older runtimes only
    # through the inner SocketException.
    $requestError = $null
    if ($null -ne $Exception.PSObject.Properties['HttpRequestError']) {
        $requestError = [string]$Exception.HttpRequestError
    }
    switch ($requestError) {
        'NameResolutionError' { return [pscustomobject]@{ Status = 'NameResolutionFailure'; StatusCode = $null } }
        'ConnectionError' { return [pscustomobject]@{ Status = 'ConnectFailure'; StatusCode = $null } }
        'ProxyTunnelError' { return [pscustomobject]@{ Status = 'ConnectFailure'; StatusCode = $null } }
        'ResponseEnded' { return [pscustomobject]@{ Status = 'ConnectionClosed'; StatusCode = $null } }
    }
    $inner = $Exception.InnerException
    while ($null -ne $inner) {
        if ($inner -is [System.Net.Sockets.SocketException]) {
            switch ([string]$inner.SocketErrorCode) {
                { $_ -in @('HostNotFound', 'NoData', 'TryAgain') } { return [pscustomobject]@{ Status = 'NameResolutionFailure'; StatusCode = $null } }
                { $_ -in @('ConnectionRefused', 'NetworkUnreachable', 'HostUnreachable', 'TimedOut') } { return [pscustomobject]@{ Status = 'ConnectFailure'; StatusCode = $null } }
            }
        }
        $inner = $inner.InnerException
    }
    return [pscustomobject]@{ Status = 'ReceiveFailure'; StatusCode = $null }
}

function Get-MutWebFailure {
    <#
        .SYNOPSIS
        Private. Reduces a caught Invoke-WebRequest ErrorRecord to @{ IsWebError; Status;
        StatusCode; Body }. Status is the WebExceptionStatus name (never message text: messages
        are localized), StatusCode the HTTP status of the response when there is one, Body the
        response body (read from the response stream, else from ErrorDetails, where PowerShell
        5.1 puts it after it has consumed the stream). Never touches request headers, so no
        credential can leak through it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    $isWebError = $exception -is [System.Net.WebException]
    $status = $null
    $statusCode = $null
    $body = $null

    if (-not $isWebError) {
        # PowerShell 7: Invoke-WebRequest throws HttpResponseException, HttpRequestException or
        # TaskCanceledException instead of WebException. Matched by type name so Windows
        # PowerShell 5.1, which lacks these types, never has to load them.
        $pwsh7 = ConvertFrom-MutPwsh7WebException -Exception $exception
        if ($null -ne $pwsh7) {
            $isWebError = $true
            $status = $pwsh7.Status
            $statusCode = $pwsh7.StatusCode
        }
    }
    elseif ($isWebError) {
        $status = [string]$exception.Status
        $response = $exception.Response
        if ($null -ne $response) {
            try { $statusCode = [int]$response.StatusCode } catch { }
            try {
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
                try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            catch { }
        }
    }

    if ([string]::IsNullOrEmpty($body) -and $null -ne $ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    }

    return [pscustomobject]@{ IsWebError = $isWebError; Status = $status; StatusCode = $statusCode; Body = $body }
}

function New-MutOutageException {
    <#
        .SYNOPSIS
        Private. An exception for an outage (HTTP 503 or no connection at all), marked with
        Data['MutSoapOutage'] = $true so callers can tell it from a dropped, timed-out or faulted
        call without parsing message text.
    #>
    param([Parameter(Mandatory = $true)][string]$Message)

    $exception = [System.Exception]::new($Message)
    $exception.Data['MutSoapOutage'] = $true
    return $exception
}

function Test-MutOutageError {
    <# Private. $true when an ErrorRecord's exception was raised by New-MutOutageException. #>
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    return [bool]$ErrorRecord.Exception.Data.Contains('MutSoapOutage')
}

function Invoke-MutSoap {
    <#
        .SYNOPSIS
        Private, and the single Pester mock point for SOAP (§6.10.3). POSTs one operation to
        `<apiBase>/WS/<escaped company name>/Codeunit/MUTRunner` with `SOAPAction:
        <namespace>:<Operation>`, Basic auth and XML-escaped arguments. The arguments are sent in
        the dictionary's own key order: BC SOAP binds parameters by sequence, so callers pass an
        [ordered] dictionary in the AL parameter order.

        .OUTPUTS
        @{ Ok; Value; Fault; TimedOut; Dropped; DurationMs; HttpStatus }. Value is the
        `return_value` text.
        Fault is the `faultstring` of a SOAP fault. TimedOut: the client timeout fired
        (WebException Status Timeout). Dropped: the connection closed before a response
        (ConnectionClosed / KeepAliveFailure / ReceiveFailure / SendFailure / PipelineFailure).
        HttpStatus is the HTTP status of a failed response (500 with a SOAP fault, 404 when the
        service is missing); $null on success and when no response arrived. Throws on HTTP 503 or no connection at all (DNS /
        connect failure), which the caller's outage wait (§6.5.6) handles; on HTTP 401/403
        (credentials or permissions rejected); and on an exception that is not a web error.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        [System.Collections.IDictionary]$Arguments = ([ordered]@{}),
        [int]$TimeoutSec = 600
    )

    Assert-MutEnvironmentAllowed $Env

    $apiBase = Get-MutApiBase -Env $Env
    $company = Get-MutCompanyName -Env $Env
    $credential = Get-MutCredential -Env $Env
    $headers = Get-MutBasicAuthHeader -Credential $credential

    $namespace = $script:MutRunnerNamespace
    $argumentXml = (@($Arguments.Keys) | ForEach-Object {
            '<x:{0}>{1}</x:{0}>' -f $_, [System.Security.SecurityElement]::Escape([string]$Arguments[$_])
        }) -join ''
    $body = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:x="{0}"><s:Body><x:{1}>{2}</x:{1}></s:Body></s:Envelope>' -f $namespace, $Operation, $argumentXml
    $headers['SOAPAction'] = '{0}:{1}' -f $namespace, $Operation
    $uri = '{0}/WS/{1}/Codeunit/MUTRunner' -f $apiBase, [uri]::EscapeDataString($company)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $failure = $null
    $caught = $null
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'text/xml; charset=utf-8' -Body $body -UseBasicParsing -TimeoutSec $TimeoutSec
    }
    catch {
        $caught = $_
        $failure = Get-MutWebFailure -ErrorRecord $_
    }

    $result = @{ Ok = $false; Value = $null; Fault = $null; TimedOut = $false; Dropped = $false; DurationMs = 0; HttpStatus = $null }

    if ($null -ne $failure) {
        if (-not $failure.IsWebError) {
            throw "Invoke-MutSoap: $Operation failed: $($caught.Exception.Message)"
        }
        if ($failure.StatusCode -eq 503) {
            throw (New-MutOutageException -Message "Invoke-MutSoap: $Operation failed: HTTP 503 (service unavailable).")
        }
        if ($failure.StatusCode -in @(401, 403)) {
            throw "Invoke-MutSoap: $Operation failed: HTTP $($failure.StatusCode) (credentials or permissions rejected)."
        }
        $result.HttpStatus = $failure.StatusCode
        $faultText = $null
        if ($failure.Body -and $failure.Body -match '<faultstring[^>]*>([^<]*)<') {
            $faultText = $Matches[1]
        }
        if ($null -ne $faultText) {
            # Only a parsed SOAP faultstring is a Fault (it feeds the batch's fault rule).
            $result.Fault = $faultText
        }
        elseif ($failure.StatusCode -ge 500) {
            # A 5xx without a faultstring (502/504 from a gateway) says nothing about the runner:
            # a drop, never a Fault.
            $result.Dropped = $true
        }
        else {
            switch ($failure.Status) {
                'Timeout' { $result.TimedOut = $true }
                { $_ -in @('ConnectionClosed', 'KeepAliveFailure', 'ReceiveFailure', 'SendFailure', 'PipelineFailure') } { $result.Dropped = $true }
                { $_ -in @('NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure') } {
                    throw (New-MutOutageException -Message "Invoke-MutSoap: $Operation failed: no connection ($($failure.Status)).")
                }
                default { }
            }
        }
        $result.DurationMs = [int]$stopwatch.ElapsedMilliseconds
        return [pscustomobject]$result
    }

    [xml]$xml = $response.Content
    $fault = $xml.SelectSingleNode("//*[local-name()='faultstring']")
    if ($null -ne $fault) {
        $result.Fault = $fault.InnerText
    }
    else {
        $value = $xml.SelectSingleNode("//*[local-name()='return_value']")
        $result.Ok = $true
        if ($null -ne $value) {
            $result.Value = $value.InnerText
        }
    }
    $result.DurationMs = [int]$stopwatch.ElapsedMilliseconds
    return [pscustomobject]$result
}


function ConvertFrom-MutIsoUtc {
    <#
        .SYNOPSIS
        Private. Parses an ISO-8601 UTC string from AL's Format(<DateTime>, 0, 9) (for example
        2026-10-04T20:43:43.0700000Z) to a UTC [datetime]. Invariant culture: this machine's
        Danish locale must not change the result. An empty or null string (a runner row that has
        not started its first mutant) is $null. PowerShell 7's ConvertFrom-Json already turns
        such a string into a [datetime]; that value is taken as is (converted to UTC), because
        casting it back to [string] would format it in the local culture and drop the fraction.
    #>
    param([AllowNull()]$Text)

    if ($Text -is [datetime]) {
        if ($Text.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Text, [System.DateTimeKind]::Utc)
        }
        return $Text.ToUniversalTime()
    }
    $Text = [string]$Text
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    return [datetime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
}

function Get-MutRunnerState {
    <#
        .SYNOPSIS
        `GetRunnerState`, parsed (§6.10.2/§6.10.3).
        .OUTPUTS
        @{ ServerNowUtc (UTC datetime); Rows = @( @{ BatchId; SessionId; RunNo; MutantId;
        MutantStartedAt (UTC datetime, or $null when the row has not started its first mutant);
        MutantsDone; Finished; StopRequested } ) }. Throws when the call does not return a value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    $call = Invoke-MutSoap -Env $Env -Operation 'GetRunnerState' -Arguments ([ordered]@{}) -TimeoutSec $script:MutSoapShortTimeoutSec
    if (-not $call.Ok -or [string]::IsNullOrWhiteSpace($call.Value)) {
        $reason = 'no value returned'
        if ($call.Fault) { $reason = $call.Fault }
        elseif ($call.TimedOut) { $reason = 'timed out' }
        elseif ($call.Dropped) { $reason = 'connection dropped' }
        throw [System.InvalidOperationException]::new("Get-MutRunnerState: GetRunnerState failed: $reason")
    }

    $parsed = $call.Value | ConvertFrom-Json
    $rows = @()
    foreach ($row in @($parsed.rows | ForEach-Object { $_ })) {
        $rows += [pscustomobject]@{
            BatchId         = [string]$row.batchId
            SessionId       = [int]$row.sessionId
            RunNo           = [int]$row.runNo
            MutantId        = [int]$row.mutantId
            MutantStartedAt = ConvertFrom-MutIsoUtc -Text $row.mutantStartedAt
            MutantsDone     = [int]$row.mutantsDone
            Finished        = [bool]$row.finished
            StopRequested   = (Test-MutHasProperty $row 'stopRequested') -and [bool]$row.stopRequested
        }
    }

    return [pscustomobject]@{
        ServerNowUtc = ConvertFrom-MutIsoUtc -Text $parsed.serverNowUtc
        Rows         = $rows
    }
}

function Test-MutSoapRunner {
    <#
        .SYNOPSIS
        $true when the MUTRunner service answers GetRunnerState without a fault; $false when it
        faults, times out or drops (Mutation Core older than 1.1.0.0, or the service is missing).
        It does not tell 1.1.0.0 from the required 1.1.1.0 (the stop-requested guard, §6.10.2).
        An outage (HTTP 503, no connection) still throws, so it is not reported as "missing".
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    $call = Invoke-MutSoap -Env $Env -Operation 'GetRunnerState' -Arguments ([ordered]@{}) -TimeoutSec $script:MutSoapShortTimeoutSec
    return [bool]($call.Ok -and -not [string]::IsNullOrWhiteSpace($call.Value))
}

function Test-MutHealthyRunTests {
    <# Private. $true when a RunTests call returned a value with failed = 0 and passed > 0 (some test really ran). #>
    param([Parameter(Mandatory = $true)]$Call)

    if (-not $Call.Ok -or [string]::IsNullOrWhiteSpace($Call.Value)) {
        return $false
    }
    $parsed = $null
    try { $parsed = $Call.Value | ConvertFrom-Json } catch { return $false }
    if ($null -eq $parsed -or -not (Test-MutHasProperty $parsed 'failed') -or -not (Test-MutHasProperty $parsed 'passed')) {
        return $false
    }
    return ([int]$parsed.failed -eq 0) -and ([int]$parsed.passed -gt 0)
}

function Get-MutRunnerBatchKey {
    <#
        .SYNOPSIS
        Private. The progress key '<Mutant Id>/<Mutants Done>' of one batch's runner row, 'none'
        when the row does not exist, or $null when GetRunnerState failed without an outage (no
        information). An outage throws.
    #>
    param(
        [Parameter(Mandatory = $true)]$Env,
        [Parameter(Mandatory = $true)][string]$BatchId
    )

    try {
        $state = Get-MutRunnerState -Env $Env
    }
    catch {
        if (Test-MutOutageError -ErrorRecord $_) { throw }
        return $null
    }
    $own = @($state.Rows | Where-Object { $_.BatchId -eq $BatchId })
    if ($own.Count -eq 0) {
        return 'none'
    }
    return '{0}/{1}' -f $own[0].MutantId, $own[0].MutantsDone
}

function Remove-MutRunnerState {
    <#
        .SYNOPSIS
        `DeleteRunnerState` for one BatchId (§6.10.3): deletes that runner row and its test suite.
        Called by the loop after a successful reset that followed an unconfirmed stop (the reset
        ended the runner, the row is left unfinished). Returns the operation's value (`deleted` or
        `not found`); throws when the call returns none.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$BatchId
    )

    Assert-MutEnvironmentAllowed $Env

    $call = Invoke-MutSoap -Env $Env -Operation 'DeleteRunnerState' -Arguments ([ordered]@{ batchId = $BatchId }) -TimeoutSec $script:MutSoapShortTimeoutSec
    if (-not $call.Ok -or [string]::IsNullOrWhiteSpace($call.Value)) {
        $reason = 'no value returned'
        if ($call.Fault) { $reason = $call.Fault }
        elseif ($call.TimedOut) { $reason = 'timed out' }
        elseif ($call.Dropped) { $reason = 'connection dropped' }
        throw "Remove-MutRunnerState: DeleteRunnerState of batch $BatchId failed: $reason"
    }
    return [string]$call.Value
}

function Stop-MutRunnerBatch {
    <#
        .SYNOPSIS
        Stops a runner batch by BatchId and confirms the environment is healthy again (§6.10.3).
        Calls StopRunner, then every PollIntervalSec (default 5) for up to ConfirmWindowSec
        (default 120) runs RunTests of a health codeunit, the first codeunit of the batch's
        covering set (-CodeunitIds, `95155|95110` style). Confirmed is true when such a RunTests
        answers with failed = 0 and passed > 0 within HealthTimeoutSec (default 30), AND the
        batch row's (Mutant Id, Mutants Done) read right after it equals the previous read (the
        first read is taken right after StopRunner): a runner still writing moves it. RunTests
        clears the active mutant first. DeleteRunnerState is called only after confirmation.
        StopRunner, GetRunnerState and DeleteRunnerState use a 30 s client timeout.

        A StopRunner fault is not fatal: the row may already have finished (or not exist). The
        health call is what confirms. The first health call comes one PollIntervalSec after
        StopRunner, since the session needs a moment to end.

        .PARAMETER CodeunitIds
        The batch's covering set. Required: it names the health codeunit, and the runner row does
        not carry it. (An orphan batch's caller passes any test codeunit of the app, for example
        the settle-probe codeunit.)
        .OUTPUTS
        @{ Confirmed; Attempts }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$BatchId,
        [Parameter(Mandatory = $true)]
        [string]$CodeunitIds,
        [double]$PollIntervalSec = 5,
        [double]$ConfirmWindowSec = 120,
        [int]$HealthTimeoutSec = 30
    )

    Assert-MutEnvironmentAllowed $Env

    $healthCodeunits = @($CodeunitIds -split '[|,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $healthCodeunit = $null
    if ($healthCodeunits.Count -gt 0) { $healthCodeunit = $healthCodeunits[0] }
    if (-not $healthCodeunit) {
        throw 'Stop-MutRunnerBatch: -CodeunitIds names no health codeunit.'
    }

    try {
        Invoke-MutSoap -Env $Env -Operation 'StopRunner' -Arguments ([ordered]@{ batchId = $BatchId }) -TimeoutSec $script:MutSoapShortTimeoutSec | Out-Null
        # The row's progress right after the stop: a runner that is still alive moves it.
        $baseKey = Get-MutRunnerBatchKey -Env $Env -BatchId $BatchId

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $attempts = 0
        while ($stopwatch.Elapsed.TotalSeconds -lt $ConfirmWindowSec) {
            Start-Sleep -Milliseconds ([int][math]::Round($PollIntervalSec * 1000))
            $remaining = $ConfirmWindowSec - $stopwatch.Elapsed.TotalSeconds
            if ($remaining -le 0) {
                break
            }
            $attempts++

            # The last health call must not overrun the confirmation window.
            $healthTimeout = [int][math]::Max(1, [math]::Min($HealthTimeoutSec, [math]::Ceiling($remaining)))
            $health = Invoke-MutSoap -Env $Env -Operation 'RunTests' -Arguments ([ordered]@{ codeunitIds = $healthCodeunit }) -TimeoutSec $healthTimeout
            if (-not (Test-MutHealthyRunTests -Call $health)) {
                continue
            }
            # Healthy, but the runner must also have stopped writing: its row's (Mutant Id,
            # Mutants Done) unchanged since the last read. A move restarts the comparison.
            $key = Get-MutRunnerBatchKey -Env $Env -BatchId $BatchId
            if ($null -eq $key) {
                continue
            }
            if ($null -eq $baseKey -or $key -ne $baseKey) {
                $baseKey = $key
                continue
            }
            Invoke-MutSoap -Env $Env -Operation 'DeleteRunnerState' -Arguments ([ordered]@{ batchId = $BatchId }) -TimeoutSec $script:MutSoapShortTimeoutSec | Out-Null
            return [pscustomobject]@{ Confirmed = $true; Attempts = $attempts }
        }
    }
    catch {
        # An outage here leaves the runner of this batch possibly live: name it, and rethrow the
        # ORIGINAL exception (the outage wait classifies on it).
        if (-not $_.Exception.Data.Contains('BatchId')) {
            $_.Exception.Data['BatchId'] = $BatchId
        }
        throw
    }

    return [pscustomobject]@{ Confirmed = $false; Attempts = $attempts }
}

function Start-MutSoapRunspace {
    <#
        .SYNOPSIS
        Private. Starts one MUTRunner SOAP call on a background runspace (the §6.5.6 runspace
        pattern of Invoke-MutTestsWithBudget: a PowerShell instance on another thread of THIS
        process), so the caller can keep polling on its own thread. The runspace imports this
        module by path and is seeded with the credential, API base and company that the calling
        thread already resolved: its own module instance has no CLI path and must never need the
        CLI. Together with Test-/Receive-/Stop-MutSoapRunspace this is the one seam Pester mocks
        to test Invoke-MutMutantBatch without a real runspace.
        .OUTPUTS
        An opaque handle for the other three functions.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Arguments,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSec
    )

    Assert-MutEnvironmentAllowed $Env

    $credential = Get-MutCredential -Env $Env
    $apiBase = Get-MutApiBase -Env $Env
    $companyInfo = Get-MutCompanyInfo -Env $Env -Caller 'Start-MutSoapRunspace'

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [System.Management.Automation.PowerShell]::Create()
    $powershell.Runspace = $runspace

    [void]$powershell.AddScript({
            param($ModulePath, $JobEnv, $JobCredential, $JobApiBase, $JobCompany, $JobOperation, $JobArguments, $JobTimeoutSec)
            $module = Import-Module $ModulePath -Force -PassThru -WarningAction SilentlyContinue
            & $module {
                param($e, $c, $b, $company, $op, $a, $t)
                $script:CliPath = $e.CliPath
                $script:MutCredentialCache[$e.Id] = $c
                $script:MutApiBaseCache[$e.Id] = $b
                $script:MutCompanyCache[$e.Id] = $company
                Invoke-MutSoap -Env $e -Operation $op -Arguments $a -TimeoutSec $t
            } $JobEnv $JobCredential $JobApiBase $JobCompany $JobOperation $JobArguments $JobTimeoutSec
        })
    [void]$powershell.AddArgument($script:DemoPortalModulePath)
    [void]$powershell.AddArgument($Env)
    [void]$powershell.AddArgument($credential)
    [void]$powershell.AddArgument($apiBase)
    [void]$powershell.AddArgument($companyInfo)
    [void]$powershell.AddArgument($Operation)
    [void]$powershell.AddArgument($Arguments)
    [void]$powershell.AddArgument($TimeoutSec)

    $async = $powershell.BeginInvoke()
    return [pscustomobject]@{ PowerShell = $powershell; Runspace = $runspace; Async = $async }
}

function Test-MutSoapRunspaceDone {
    <# Private. $true once the background call has returned (or failed). #>
    param([Parameter(Mandatory = $true)]$Handle)

    return [bool]$Handle.Async.IsCompleted
}

function Receive-MutSoapRunspace {
    <#
        .SYNOPSIS
        Private. Collects a finished background call: its Invoke-MutSoap result object. A throw
        inside the runspace (HTTP 503, no connection) is rethrown here, so the caller's outage
        handling (§6.5.6) sees it exactly as if it had made the call itself.
    #>
    param([Parameter(Mandatory = $true)]$Handle)

    $output = $null
    try {
        $output = $Handle.PowerShell.EndInvoke($Handle.Async)
    }
    catch {
        $inner = $_.Exception
        if ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
        throw $inner
    }

    $items = @($output)
    if ($items.Count -eq 0) {
        # Invoke-MutSoap always returns an object, so no output means the runspace never got that
        # far (for example Import-Module failed and the error only landed in Streams.Error): the
        # call was never sent. Fail loudly with the first error records.
        $errorText = ''
        try {
            $errorText = (@($Handle.PowerShell.Streams.Error | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join '; ')
        }
        catch { }
        throw "Receive-MutSoapRunspace: the background call produced no result (runspace setup failure?). $errorText"
    }
    return $items[0]
}

function Wait-MutSoapRunspace {
    <#
        .SYNOPSIS
        Private. Waits up to TimeoutMs for the background call to complete, returning as soon as
        it does (so a finished batch is noticed immediately, not at the next poll). Mockable seam.
    #>
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)][int]$TimeoutMs
    )

    [void]$Handle.Async.AsyncWaitHandle.WaitOne($TimeoutMs)
}

function Stop-MutSoapRunspace {
    <#
        .SYNOPSIS
        Private. Releases the background runspace and disposes the PowerShell instance and the
        runspace. A completed call is disposed at once. A call still running (stuck in a hung
        server session) is stopped with the asynchronous BeginStop and waited for at most
        DisposeWaitSec; disposed only if the stop completed in that time (Dispose blocks on a
        pipeline that has not stopped), otherwise it is left to CloseAsync and the finalizer.
        Never throws and never blocks longer than DisposeWaitSec.
    #>
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [double]$DisposeWaitSec = 2
    )

    $safeToDispose = $false
    try {
        if ($Handle.Async.IsCompleted) {
            $safeToDispose = $true
        }
        else {
            $stopAsync = $Handle.PowerShell.BeginStop($null, $null)
            $safeToDispose = [bool]$stopAsync.AsyncWaitHandle.WaitOne([int][math]::Round($DisposeWaitSec * 1000))
        }
    }
    catch { }

    if ($safeToDispose) {
        try { $Handle.PowerShell.Dispose() } catch { }
        try { $Handle.Runspace.Dispose() } catch { }
    }
    else {
        try { $Handle.Runspace.CloseAsync() } catch { }
    }
}

function ConvertTo-MutBatchResult {
    <# Private. Normalizes one RunMutants entry or one mutantResults API row to the Results shape. #>
    param([Parameter(Mandatory = $true)]$Entry)

    $get = {
        param($name, $default)
        if (Test-MutHasProperty $Entry $name) { return $Entry.$name }
        return $default
    }
    return [pscustomobject]@{
        MutantId    = [int](& $get 'mutantId' 0)
        Status      = [string](& $get 'status' '')
        KillingTest = [string](& $get 'killingTest' '')
        DurationMs  = [int](& $get 'durationMs' 0)
        Passed      = & $get 'passed' $null
        Failed      = & $get 'failed' $null
    }
}

function Invoke-MutMutantBatch {
    <#
        .SYNOPSIS
        Runs one batch of mutants through the MUTRunner `RunMutants` operation with a hang
        watchdog (§6.10.3). RunMutants runs on a background runspace with client timeout
        MutantIds.Count x MutantBudgetSec + 60 s (-ClientTimeoutSec overrides it, for tests);
        this thread polls Get-MutRunnerState every PollIntervalSec (default 5).

        Hang rules: (1) the row of THIS BatchId has a non-zero Mutant Id whose age on the
        SERVER clock (ServerNowUtc - MutantStartedAt) exceeds MutantBudgetSec; an empty
        MutantStartedAt (first mutant not started yet) is not a hang on that basis alone;
        (2) no row for this BatchId within NoRowWindowSec (default 60), or the batch exceeds its
        client timeout. A hang calls Stop-MutRunnerBatch (with this BatchId); an unconfirmed stop
        throws RunnerStopFailed.

        Fault rule: the call returned a SOAP fault, the row is unfinished and its (Mutant Id,
        Mutants Done) has not advanced for FaultStallSec (default 10): that mutant is
        FaultMutantId, and the runner is stopped the same way.

        The batch has ended only when its row shows Finished = true, the call returned a value
        (the runner sets Finished before returning), or a stop was confirmed. A TimedOut or
        Dropped call is not an outage and not an end: polling continues. A throw out of the call
        itself (HTTP 503, no connection) propagates, for the caller's outage wait.

        Results come from the call's return value when it finished with one, otherwise from GET
        mutantResults for the batch's mutant ids (rows committed before a hang, S6). The hung or
        fault mutant is never in Results. A batch whose row was seen Finished and whose return
        value arrived deletes its row (DeleteRunnerState, best effort).

        .OUTPUTS
        @{ Results = @( @{ MutantId; Status; KillingTest; DurationMs; Passed; Failed } );
        HungMutantId; FaultMutantId; Fault; Stopped } (ids and Fault are $null when not
        applicable; Stopped is $true when a stop was needed and confirmed).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        [int[]]$CodeunitIds,
        [Parameter(Mandatory = $true)]
        [int[]]$MutantIds,
        [Parameter(Mandatory = $true)]
        [int]$RunNo,
        [Parameter(Mandatory = $true)]
        [int]$MutantBudgetSec,
        [double]$PollIntervalSec = 5,
        [double]$NoRowWindowSec = 60,
        [double]$FaultStallSec = 10,
        [double]$StopConfirmSec = 120,
        [int]$HealthTimeoutSec = 30,
        [double]$ClientTimeoutSec = 0,
        [double]$ReturnGraceSec = 10
    )

    Assert-MutEnvironmentAllowed $Env

    $ids = @($MutantIds | ForEach-Object { [int]$_ })
    if ($ids.Count -eq 0) {
        throw 'Invoke-MutMutantBatch: -MutantIds is empty.'
    }
    $coveringSet = ($CodeunitIds | ForEach-Object { [string]$_ }) -join '|'
    $batchId = [guid]::NewGuid().ToString()

    $clientTimeout = $ClientTimeoutSec
    if ($clientTimeout -le 0) {
        $clientTimeout = ($ids.Count * $MutantBudgetSec) + 60
    }

    # AL parameter order: RunMutants(BatchId, CodeunitIds, MutantIds, RunNo).
    $handle = Start-MutSoapRunspace -Env $Env -Operation 'RunMutants' -TimeoutSec ([int][math]::Ceiling($clientTimeout)) -Arguments ([ordered]@{
            batchId     = $batchId
            codeunitIds = $coveringSet
            mutantIds   = ($ids -join ',')
            runNo       = $RunNo
        })

    $call = $null
    $hungMutantId = $null
    $faultMutantId = $null
    $stopped = $false
    $finishedSeen = $false

    try {
    try {
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $progress = [System.Diagnostics.Stopwatch]::StartNew()
        $progressKey = $null
        $ended = $false
        $rowSeen = $false
        $lastCurrent = $ids[0]

        while (-not $ended) {
            if ($null -eq $call -and (Test-MutSoapRunspaceDone -Handle $handle)) {
                $call = Receive-MutSoapRunspace -Handle $handle
            }

            $row = $null
            $serverNow = $null
            $pollError = $null
            try {
                $state = Get-MutRunnerState -Env $Env
                $serverNow = $state.ServerNowUtc
                # Not @(...)[0]: under StrictMode an index past the end of an empty array throws.
                $own = @($state.Rows | Where-Object { $_.BatchId -eq $batchId })
                if ($own.Count -gt 0) { $row = $own[0] }
            }
            catch {
                $pollError = $_
            }

            if ($null -ne $pollError) {
                # A failed poll is no information: skip every rule this iteration and keep the
                # last row and progress key as they were. A call that returned a value has ended
                # the batch regardless. Only an OUTAGE (HTTP 503 / no connection), and only once
                # the call itself has ended, is rethrown for the caller's outage wait; any other
                # failure (a dropped or faulted GetRunnerState, say) is retried on the next poll.
                # The retries are bounded by the batch's client-timeout clock: past it, the last
                # known mutant is treated as hung (rule 2) and the runner is stopped.
                if ($null -ne $call -and $call.Ok -and -not [string]::IsNullOrWhiteSpace($call.Value)) {
                    $ended = $true
                    continue
                }
                if ($null -ne $call -and (Test-MutOutageError -ErrorRecord $pollError)) {
                    throw $pollError
                }
                if ($clock.Elapsed.TotalSeconds -gt $clientTimeout) {
                    $hungMutantId = $lastCurrent
                    break
                }
                if ($null -eq $call) {
                    Wait-MutSoapRunspace -Handle $handle -TimeoutMs ([int][math]::Round($PollIntervalSec * 1000))
                }
                else {
                    Start-Sleep -Milliseconds ([int][math]::Round($PollIntervalSec * 1000))
                }
                continue
            }
            if ($null -ne $row) {
                $rowSeen = $true
            }

            if ($null -ne $row -and $row.Finished) {
                $finishedSeen = $true
                $ended = $true
                continue
            }
            if ($null -ne $call -and $call.Ok -and -not [string]::IsNullOrWhiteSpace($call.Value)) {
                $ended = $true
                continue
            }

            # The candidate culprit if this batch has to be abandoned now.
            $current = $ids[0]
            if ($null -ne $row) {
                if ($row.MutantId -ne 0) {
                    $current = $row.MutantId
                }
                elseif ($row.MutantsDone -lt $ids.Count) {
                    $current = $ids[$row.MutantsDone]
                }
            }

            $lastCurrent = $current

            # Rule 1: one mutant has been running longer than its budget, on the server clock.
            if ($null -ne $row -and $row.MutantId -ne 0 -and $null -ne $row.MutantStartedAt -and $null -ne $serverNow) {
                if (($serverNow - $row.MutantStartedAt).TotalSeconds -gt $MutantBudgetSec) {
                    $hungMutantId = $row.MutantId
                    break
                }
            }
            # Rule 2: no row at all within the window, or the whole batch ran past its client timeout.
            if (-not $rowSeen -and $clock.Elapsed.TotalSeconds -gt $NoRowWindowSec) {
                $hungMutantId = $current
                break
            }
            if ($clock.Elapsed.TotalSeconds -gt $clientTimeout) {
                $hungMutantId = $current
                break
            }

            # Fault rule: the call faulted, the row is unfinished and no longer advancing.
            $key = 'none'
            if ($null -ne $row) {
                $key = '{0}/{1}' -f $row.MutantId, $row.MutantsDone
            }
            if ($key -ne $progressKey) {
                $progressKey = $key
                $progress.Restart()
            }
            if ($null -ne $call -and $call.Fault -and $progress.Elapsed.TotalSeconds -ge $FaultStallSec) {
                $faultMutantId = $current
                break
            }

            if ($null -eq $call) {
                Wait-MutSoapRunspace -Handle $handle -TimeoutMs ([int][math]::Round($PollIntervalSec * 1000))
            }
            else {
                Start-Sleep -Milliseconds ([int][math]::Round($PollIntervalSec * 1000))
            }
        }

        if ($null -eq $hungMutantId -and $null -eq $faultMutantId -and $null -eq $call) {
            # The row shows Finished a moment before the call's return value arrives. The value
            # also carries the Empty entries (no row is written for them), so wait briefly for it.
            $grace = [System.Diagnostics.Stopwatch]::StartNew()
            while ($grace.Elapsed.TotalSeconds -lt $ReturnGraceSec -and -not (Test-MutSoapRunspaceDone -Handle $handle)) {
                Start-Sleep -Milliseconds 50
            }
            if (Test-MutSoapRunspaceDone -Handle $handle) {
                $call = Receive-MutSoapRunspace -Handle $handle
            }
        }

        if ($null -ne $hungMutantId -or $null -ne $faultMutantId) {
            $stop = Stop-MutRunnerBatch -Env $Env -BatchId $batchId -CodeunitIds $coveringSet -PollIntervalSec $PollIntervalSec -ConfirmWindowSec $StopConfirmSec -HealthTimeoutSec $HealthTimeoutSec
            if (-not $stop.Confirmed) {
                throw "RunnerStopFailed: the runner of batch $batchId was not confirmed stopped within $StopConfirmSec s (mutant $(@($hungMutantId, $faultMutantId | Where-Object { $null -ne $_ })[0]))."
            }
            $stopped = $true
        }
    }
    finally {
        Stop-MutSoapRunspace -Handle $handle
    }

    $excluded = @(@($hungMutantId, $faultMutantId) | Where-Object { $null -ne $_ })

    $results = @()
    if ($null -ne $call -and $call.Ok -and -not [string]::IsNullOrWhiteSpace($call.Value) -and $excluded.Count -eq 0) {
        foreach ($entry in @($call.Value | ConvertFrom-Json | ForEach-Object { $_ })) {
            $results += ConvertTo-MutBatchResult -Entry $entry
        }
        if ($finishedSeen) {
            # The batch is over and its results are in hand: its Finished row has no further use.
            # Best effort: a row left behind is harmless (Finished rows are never stopped).
            try {
                Invoke-MutSoap -Env $Env -Operation 'DeleteRunnerState' -Arguments ([ordered]@{ batchId = $batchId }) -TimeoutSec $script:MutSoapShortTimeoutSec | Out-Null
            }
            catch {
                Write-Verbose "Invoke-MutMutantBatch: deleting the Finished row of batch $batchId failed: $($_.Exception.Message)"
            }
        }
    }
    else {
        $response = Invoke-MutApi -Env $Env -Method 'GET' -Path ('mutantResults?$filter=runNo eq {0}' -f $RunNo)
        $rowsById = @{}
        if ($null -ne $response -and (Test-MutHasProperty $response 'value')) {
            foreach ($apiRow in @($response.value)) {
                $rowsById[[int]$apiRow.mutantId] = $apiRow
            }
        }
        foreach ($id in $ids) {
            if ($excluded -contains $id) {
                continue
            }
            if ($rowsById.ContainsKey($id)) {
                $results += ConvertTo-MutBatchResult -Entry $rowsById[$id]
            }
        }
    }

    $fault = $null
    if ($null -ne $call -and $call.Fault) {
        $fault = $call.Fault
    }

    return [pscustomobject]@{
        Results       = $results
        HungMutantId  = $hungMutantId
        FaultMutantId = $faultMutantId
        Fault         = $fault
        Stopped       = $stopped
    }
    }
    catch {
        # Every exception leaving here after RunMutants started names the batch whose runner may
        # still be live (T42 re-runs the orphan sweep after the outage wait). The ORIGINAL
        # exception is rethrown, never wrapped.
        if (-not $_.Exception.Data.Contains('BatchId')) {
            $_.Exception.Data['BatchId'] = $batchId
        }
        throw
    }
}

Export-ModuleMember -Function Get-MutEnvironment, New-MutEnvironment, Start-MutEnvironment, Remove-MutEnvironment, Remove-MutRunEnvironment, Remove-MutOrphanEnvironments, Reset-MutEnvironment, Assert-MutEnvironmentAllowed, Get-MutApiBase, Get-MutCompanyId, Get-MutCompanyName, Get-MutRunnerState, Stop-MutRunnerBatch, Remove-MutRunnerState, Invoke-MutMutantBatch, Test-MutSoapRunner, Grant-MutPermissionSet, Invoke-MutApi, Install-MutDependencies, Compile-MutApp, Publish-MutApp, Publish-MutAppFile, Unpublish-MutApp, Invoke-MutTests, Get-MutCoverageRaw, Get-MutCoverage, Stop-MutBackendChildProcesses
