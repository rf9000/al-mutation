Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo root is two levels above this module file (orchestrator/backends/DemoPortal.psm1).
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Poll loop tuning for env get / env stop-start status polling.
$script:PollIntervalSec = 10
$script:MaxPollIterations = 60
# New-MutEnvironment's "wait for env get to return an object with a status property at all"
# budget is intentionally much shorter than the full start-to-Running poll (§6.5.3): 6 x 10s = 60s.
$script:MaxAppearIterations = 6

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
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSec = 600,
        [bool]$ExpectJson = $true
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
        if ($exitCode -ne 0) {
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
    if ($Env.Name -notmatch '^mut-') {
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
        confirmation is on stderr, per T03 fix round 3) then polls to Running; then installs
        the Continia Core Internal Activation App and sets the workspace default env
        (`env use`) unconditionally, since those are safe to repeat.
        .OUTPUTS
        The handle with Status='Running', StartDurationSec, ActivationInstallDurationSec (0 for
        StartDurationSec when the environment was already Running and env start/poll were
        skipped).
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
    $running = $current

    if (-not ((Test-MutHasProperty $current 'status') -and $current.status -eq 'Running')) {
        $startStart = Get-Date
        Invoke-Continia -Arguments @('env', 'start', $Env.Id) -ExpectJson:$false | Out-Null
        $running = Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Running'
        $startDurationSec = ((Get-Date) - $startStart).TotalSeconds
    }

    $activationStart = Get-Date
    Invoke-Continia -Arguments @('deps', 'install-by-id', $Env.Id, $Config.demoPortal.activationAppId, '--json') | Out-Null
    $activationInstallDurationSec = ((Get-Date) - $activationStart).TotalSeconds

    Invoke-Continia -Arguments @('env', 'use', $Env.Id) -ExpectJson:$false | Out-Null

    $handle = ConvertTo-MutEnvironmentHandle -Raw $running

    Add-Member -InputObject $handle -NotePropertyName 'StartDurationSec' -NotePropertyValue $startDurationSec
    Add-Member -InputObject $handle -NotePropertyName 'ActivationInstallDurationSec' -NotePropertyValue $activationInstallDurationSec

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

    if ($Name -notmatch '^mut-') {
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
        Stops then starts the environment, polling for the Stopped and Running states.
        .OUTPUTS
        [pscustomobject]@{ DurationSec }
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Env
    )

    Assert-MutEnvironmentAllowed $Env

    $start = Get-Date

    Invoke-Continia -Arguments @('env', 'stop', $Env.Id) -ExpectJson:$false | Out-Null
    Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Stopped' | Out-Null

    Invoke-Continia -Arguments @('env', 'start', $Env.Id) -ExpectJson:$false | Out-Null
    Wait-MutEnvironmentStatus -Id $Env.Id -Status 'Running' | Out-Null

    $durationSec = ((Get-Date) - $start).TotalSeconds

    return [pscustomobject]@{ DurationSec = $durationSec }
}

Export-ModuleMember -Function Get-MutEnvironment, New-MutEnvironment, Start-MutEnvironment, Remove-MutEnvironment, Reset-MutEnvironment, Assert-MutEnvironmentAllowed
