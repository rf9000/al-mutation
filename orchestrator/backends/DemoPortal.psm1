Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo root is two levels above this module file (orchestrator/backends/DemoPortal.psm1).
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Backend-agnostic coverage CSV parser (T24, §6.5.5), imported by relative path so this backend
# is the only place that wires it to the real CLI's coverage output.
Import-Module (Join-Path $PSScriptRoot '..\lib\Coverage.psm1') -Force

# Poll loop tuning for env get / env stop-start status polling.
$script:PollIntervalSec = 10
$script:MaxPollIterations = 60
# New-MutEnvironment's "wait for env get to return an object with a status property at all"
# budget is intentionally much shorter than the full start-to-Running poll (§6.5.3): 6 x 10s = 60s.
$script:MaxAppearIterations = 6

# Per-environment-id caches for Get-MutApiBase (U8) and the Basic-auth credential. Initialized
# here (not lazily inside the functions) because Set-StrictMode -Version Latest throws
# RuntimeException on a bare read of a $script: variable that was never assigned at all, as
# opposed to one that is $null.
$script:MutApiBaseCache = @{}
$script:MutCredentialCache = @{}

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

        .OUTPUTS
        [pscustomobject]@{ SettleDurationSec; SettleProbeAttempts } -- SettleDurationSec is the
        total elapsed seconds (apps poll + the fixed 30s + the test-readiness probe, when run);
        SettleProbeAttempts is 0 when the probe was skipped.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        $Config
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

        if (-not $probeReady) {
            throw "Wait-MutEnvironmentSettled: test-readiness probe (codeunit $($probe.codeunitId), function $($probe.functionName)) never reported summary.total -gt 0 for environment '$Id' after $probeAttempts attempts; the environment may not be ready to run tests."
        }
    }
    else {
        Write-Warning "Wait-MutEnvironmentSettled: no demoPortal.settleProbe in config; skipping the test-readiness probe for environment '$Id'."
    }

    $settleDurationSec = ((Get-Date) - $start).TotalSeconds

    return [pscustomobject]@{ SettleDurationSec = $settleDurationSec; SettleProbeAttempts = $probeAttempts }
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
        confirmation is on stderr, per T03 fix round 3) then polls to Running, then waits for
        the environment to settle (Wait-MutEnvironmentSettled, T27 fix round 1 finding 4a --
        only on this real transition, since only then is there anything to settle); then
        installs the Continia Core Internal Activation App and sets the workspace default env
        (`env use`) unconditionally, since those are safe to repeat.
        .OUTPUTS
        The handle with Status='Running', StartDurationSec, ActivationInstallDurationSec,
        SettleDurationSec, SettleProbeAttempts (0 for StartDurationSec/SettleDurationSec/
        SettleProbeAttempts when the environment was already Running and env
        start/poll/settle were skipped).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env,
        [Parameter(Mandatory = $true)]
        $Config
    )

    Assert-MutEnvironmentAllowed $Env

    $script:CliPath = Resolve-MutCliPath -Config $Config

    $current = Invoke-Continia -Arguments @('env', 'get', $Env.Id, '--json')

    $startDurationSec = 0
    $settleDurationSec = 0
    $settleProbeAttempts = 0
    $running = $current

    if (-not ((Test-MutHasProperty $current 'status') -and $current.status -eq 'Running')) {
        $startStart = Get-Date
        Invoke-Continia -Arguments @('env', 'start', $Env.Id) -ExpectJson:$false | Out-Null
        $running = Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Running'
        $startDurationSec = ((Get-Date) - $startStart).TotalSeconds

        $settled = Wait-MutEnvironmentSettled -Id $Env.Id -Config $Config
        $settleDurationSec = $settled.SettleDurationSec
        $settleProbeAttempts = $settled.SettleProbeAttempts
    }

    $activationStart = Get-Date
    Invoke-Continia -Arguments @('deps', 'install-by-id', $Env.Id, $Config.demoPortal.activationAppId, '--json') | Out-Null
    $activationInstallDurationSec = ((Get-Date) - $activationStart).TotalSeconds

    Invoke-Continia -Arguments @('env', 'use', $Env.Id) -ExpectJson:$false | Out-Null

    $handle = ConvertTo-MutEnvironmentHandle -Raw $running

    Add-Member -InputObject $handle -NotePropertyName 'StartDurationSec' -NotePropertyValue $startDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'ActivationInstallDurationSec' -NotePropertyValue $activationInstallDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'SettleDurationSec' -NotePropertyValue $settleDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'SettleProbeAttempts' -NotePropertyValue $settleProbeAttempts

    return $handle
}

function New-MutEnvironment {
    <#
        .SYNOPSIS
        Creates a fresh DemoPortal environment (env create), waits for it to become visible
        with a status at all (env get, up to 60s), then delegates starting/activating it to
        Start-MutEnvironment.
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
    $created = Invoke-Continia -Arguments @('env', 'create', '--name', $Name, '--profile', $Config.demoPortal.profileId, '--json')
    $envId = $created.id

    $appeared = Wait-MutEnvironmentAppears -Id $envId
    $createDurationSec = ((Get-Date) - $createStart).TotalSeconds

    $envHandle = ConvertTo-MutEnvironmentHandle -Raw $appeared
    $handle = Start-MutEnvironment -Env $envHandle -Config $Config

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

    Invoke-Continia -Arguments @('env', 'start', $Env.Id) -ExpectJson:$false | Out-Null
    Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Running' | Out-Null

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

function Get-MutCompanyId {
    <#
        .SYNOPSIS
        Returns the GUID id of the first company reported by `<apiBase>/api/v2.0/companies`.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    $apiBase = Get-MutApiBase -Env $Env
    $credential = Get-MutCredential -Env $Env
    $headers = Get-MutBasicAuthHeader -Credential $credential

    $response = Invoke-RestMethod -Uri "$apiBase/api/v2.0/companies" -Method Get -Headers $headers
    $companies = @($response.value)
    if ($companies.Count -eq 0) {
        throw "Get-MutCompanyId: environment '$($Env.Name)' has no companies."
    }

    return $companies[0].id
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

    $diagnostics = ConvertTo-MutDiagnosticList -Diagnostics $result.diagnostics

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

            $xmlStart = $response.StdOut.IndexOf('<')
            if ($xmlStart -ge 0) {
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

        foreach ($t in @($response.tests)) {
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
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='continia.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $PID })

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

Export-ModuleMember -Function Get-MutEnvironment, New-MutEnvironment, Start-MutEnvironment, Remove-MutEnvironment, Reset-MutEnvironment, Assert-MutEnvironmentAllowed, Get-MutApiBase, Get-MutCompanyId, Grant-MutPermissionSet, Invoke-MutApi, Install-MutDependencies, Compile-MutApp, Publish-MutApp, Publish-MutAppFile, Unpublish-MutApp, Invoke-MutTests, Get-MutCoverageRaw, Get-MutCoverage, Stop-MutBackendChildProcesses
