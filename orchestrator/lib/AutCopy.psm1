Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-MutHasProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Invoke-MutRobocopyMirror {
    <#
        .SYNOPSIS
        Mirrors $Source into $Destination via `robocopy <src> <dst> /MIR /XD .alpackages
        .snapshots .git /XF *.app /NFL /NDL /NJH /NJS` (§6.5.2). $Source is never written to:
        robocopy's source side of a /MIR is read-only for this call.

        .NOTES
        Robocopy's own exit-code convention packs several non-error bit flags (files copied,
        extra files present at the destination and removed, mismatched files, etc.) into
        0-7; only 8+ signals an actual failure category (access denied, source not found, ...).
        Invoked here via the call operator with no stdout/stderr redirection and the exit code
        read from $LASTEXITCODE, NOT via a wrapper that would let
        $ErrorActionPreference = 'Stop' turn robocopy's normal non-zero-but-successful exit
        code into a terminating error.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    & robocopy $Source $Destination /MIR /XD .alpackages .snapshots .git /XF *.app /NFL /NDL /NJH /NJS | Out-Null
    $code = $LASTEXITCODE

    if ($code -ge 8) {
        throw "Sync-MutAutCopy: robocopy failed mirroring '$Source' -> '$Destination' with exit code $code (codes 0-7 are success, 8+ is failure)."
    }

    return $Destination
}

function Sync-MutAutCopy {
    <#
        .SYNOPSIS
        Mirrors the read-only AUT source (`$Config.aut.sourcePath`), test app source
        (`$Config.testApp.sourcePath`) and, if configured, the rulesets folder
        (`$Config.rulesets.sourcePath`) into working copies under `$Config.workDir`
        (§6.5.2/§6.5.4 step 2): `<workDir>/aut-original`, `<workDir>/test-app`,
        `<workDir>/rulesets`. This is the ONLY function in the orchestrator that reads the real
        AUT/test-app/rulesets source trees, and it never writes to them -- every robocopy call
        mirrors FROM the configured source path INTO a path under workDir, never the reverse.
        Config paths are assumed already resolved to absolute paths (Get-MutConfig, §6.5.1).

        .OUTPUTS
        [pscustomobject]@{ AutPath; TestAppPath; RulesetsPath } -- RulesetsPath is $null when
        $Config.rulesets is absent or $null.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $workDir = $Config.workDir
    if (-not (Test-Path -Path $workDir)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    $autPath = Join-Path $workDir 'aut-original'
    $testAppPath = Join-Path $workDir 'test-app'

    Invoke-MutRobocopyMirror -Source $Config.aut.sourcePath -Destination $autPath | Out-Null
    Invoke-MutRobocopyMirror -Source $Config.testApp.sourcePath -Destination $testAppPath | Out-Null

    $rulesetsPath = $null
    if ((Test-MutHasProperty $Config 'rulesets') -and ($null -ne $Config.rulesets)) {
        $rulesetsPath = Join-Path $workDir 'rulesets'
        Invoke-MutRobocopyMirror -Source $Config.rulesets.sourcePath -Destination $rulesetsPath | Out-Null
    }

    return [pscustomobject]@{
        AutPath      = $autPath
        TestAppPath  = $testAppPath
        RulesetsPath = $rulesetsPath
    }
}

Export-ModuleMember -Function Sync-MutAutCopy
