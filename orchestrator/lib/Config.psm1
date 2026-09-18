Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The allowed backend names (§6.5.1). This is the one line in this module permitted to name
# the alternate backend, per §4 guardrail 6; the isolation lint (T27) exempts lines carrying
# the marker comment below.
$script:AllowedBackends = @('DemoPortal', 'Docker')  # isolation-lint: allow

$script:AllowedPublishStrategies = @('same-version', 'bump-build', 'unpublish-test-app')

# Review fix round 1: [System.IO.Path]::GetFullPath does NOT resolve reparse points
# (directory junctions/symlinks), so Assert-MutWorkDirOutsideSources' containment check was
# defeated by a junction -- workDir pointing at a junction into one of the source trees
# compared as an unrelated path even though robocopy /MIR would actually write (and prune)
# inside the real target. GetFinalPathNameByHandleW is the correct way to resolve the true
# target; .NET Framework (Windows PowerShell 5.1's runtime) has no managed API for it, hence
# this small P/Invoke helper. Loaded once per session.
if (-not ('MutFinalPathNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MutFinalPathNative
{
    // The documented dwDesiredAccess for a handle that will only be passed to
    // GetFinalPathNameByHandle is 0 (query metadata only, no read/write access requested) --
    // review fix round 2. Requesting GENERIC_READ made CreateFileW fail (and
    // Resolve-MutFinalPath silently fall back to the unresolved path, reverting to pre-fix
    // behaviour) for a directory the caller can traverse but not read.
    private const uint FILE_SHARE_READ = 0x1;
    private const uint FILE_SHARE_WRITE = 0x2;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_NAME_NORMALIZED = 0x0;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
        uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint GetFinalPathNameByHandleW(
        IntPtr hFile, StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    // Resolves $path (a path that must exist: a file or a directory) to its final,
    // reparse-point-free absolute path. Throws Win32Exception on failure.
    public static string GetFinalPath(string path)
    {
        IntPtr handle = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle == new IntPtr(-1))
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try
        {
            var sb = new StringBuilder(4096);
            uint result = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, FILE_NAME_NORMALIZED);
            if (result == 0 || result >= sb.Capacity)
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            string resolved = sb.ToString();
            if (resolved.StartsWith(@"\\?\") && !resolved.StartsWith(@"\\?\UNC\"))
            {
                resolved = resolved.Substring(4);
            }
            return resolved;
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
'@ -Language CSharp
}

function Get-MutRepoRoot {
    <#
        .SYNOPSIS
        Returns the repo root: two levels above this module file
        (orchestrator/lib/Config.psm1 -> repo root).
    #>
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Test-MutHasProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-MutRequiredKey {
    <#
        .SYNOPSIS
        Throws unless $Object has a non-null property named $Name. $KeyPath is the full
        dotted key path used in the error message (e.g. 'aut.sourcePath').
    #>
    param($Object, [string]$Name, [string]$KeyPath)

    if (-not (Test-MutHasProperty $Object $Name)) {
        throw "Get-MutConfig: config is missing required key '$KeyPath'."
    }
    if ($null -eq $Object.$Name) {
        throw "Get-MutConfig: config key '$KeyPath' must not be null."
    }
}

function Assert-MutNonEmptyString {
    param($Object, [string]$Name, [string]$KeyPath)

    Assert-MutRequiredKey $Object $Name $KeyPath
    if ([string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
        throw "Get-MutConfig: config key '$KeyPath' must be a non-empty string."
    }
}

function Assert-MutNumberAtLeast {
    <#
        .SYNOPSIS
        Throws unless $Object.$Name is present, parses as a number, and is at least $Minimum
        ($ExclusiveMinimum makes the bound strict: value > $Minimum rather than value >=
        $Minimum). Presence-only validation previously let e.g. `timeouts.minSeconds = 0`
        through: `Get-MutTimeoutBudget` then computes a budget of 0, `WaitOne(0)` returns
        false immediately, and every mutant is marked Timeout -- each one triggering a full
        environment reset plus settle.
    #>
    param($Object, [string]$Name, [string]$KeyPath, [double]$Minimum, [switch]$ExclusiveMinimum)

    Assert-MutRequiredKey $Object $Name $KeyPath

    # InvariantCulture, not the ambient culture: on e.g. a da-DK machine, "." is the digit
    # GROUPING separator and "," is the decimal separator, so a config shipping a fractional
    # value as a JSON STRING (e.g. "5.5") would parse to 55 instead of throwing or reading as
    # 5.5. Values ship as JSON numbers today, which ConvertFrom-Json always renders
    # culture-invariantly, so this is a hardening measure against a config that ever ships one
    # as a string, not a fix for an observed failure.
    $parsed = 0.0
    if (-not [double]::TryParse([string]$Object.$Name, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        throw "Get-MutConfig: config key '$KeyPath' must be a number. Got '$($Object.$Name)'."
    }

    if ($ExclusiveMinimum) {
        if ($parsed -le $Minimum) {
            throw "Get-MutConfig: config key '$KeyPath' must be greater than $Minimum. Got '$($Object.$Name)'."
        }
    }
    elseif ($parsed -lt $Minimum) {
        throw "Get-MutConfig: config key '$KeyPath' must be at least $Minimum. Got '$($Object.$Name)'."
    }
}

function Assert-MutIntegerAtLeast {
    <#
        .SYNOPSIS
        Throws unless $Object.$Name is present, parses as an integer, and is at least
        $Minimum.
    #>
    param($Object, [string]$Name, [string]$KeyPath, [int]$Minimum)

    Assert-MutRequiredKey $Object $Name $KeyPath

    # InvariantCulture, same rationale as Assert-MutNumberAtLeast.
    $parsed = 0
    if (-not [int]::TryParse([string]$Object.$Name, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        throw "Get-MutConfig: config key '$KeyPath' must be an integer. Got '$($Object.$Name)'."
    }

    if ($parsed -lt $Minimum) {
        throw "Get-MutConfig: config key '$KeyPath' must be at least $Minimum. Got '$($Object.$Name)'."
    }
}

function Resolve-MutConfigPath {
    <#
        .SYNOPSIS
        Resolves a possibly-relative path against $RepoRoot into an absolute path. An
        already-absolute path is returned unchanged.
    #>
    param([string]$RepoRoot, [string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return $Path
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepoRoot, $Path))
}

function Resolve-MutFinalPath {
    <#
        .SYNOPSIS
        Private. Resolves $Path (already made absolute by the caller) to its final,
        reparse-point-free form via GetFinalPathNameByHandleW, so a directory junction or
        symlink anywhere in $Path's ancestry compares equal to its real target rather than as
        an unrelated path (review fix round 1). GetFinalPathNameByHandleW requires something
        to actually exist at the path it is given; workDir in particular commonly does not
        exist yet at config-validation time (Sync-MutAutCopy creates it later), so this walks
        up to the nearest existing ancestor, resolves THAT, and re-appends the non-existent
        tail segments unchanged (a non-existent tail cannot itself be a reparse point).
        Falls back to the plain, unresolved $Path on any native-call failure (e.g. a drive
        that is not reachable in a sandboxed test) or when nothing on the path exists at all,
        rather than throwing -- config loading must not crash over a filesystem quirk here.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = $Path.TrimEnd('\', '/')

    # A bare drive letter ("C:", with no trailing separator) is NOT the drive root as far as
    # CreateFileW/the Win32 path APIs are concerned: it is the legacy DOS "current directory on
    # drive C:" reference. Trimming the trailing separator off an actual root path (e.g. the
    # config value "C:\") would silently turn it into that drive-relative form -- resolving to
    # the process's current directory instead of the real root, and comparing the wrong thing
    # (review fix round 2). Guard this BEFORE the trim is allowed to stand.
    if ($full -match '^[A-Za-z]:$') {
        $full += '\'
    }

    $tailParts = @()
    $ancestor = $full
    while ($ancestor -and -not (Test-Path -LiteralPath $ancestor)) {
        $parent = [System.IO.Path]::GetDirectoryName($ancestor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $ancestor) {
            $ancestor = $null
            break
        }
        $tailParts = @([System.IO.Path]::GetFileName($ancestor)) + $tailParts
        $ancestor = $parent
    }

    if (-not $ancestor -or -not (Test-Path -LiteralPath $ancestor)) {
        return $full
    }

    try {
        $resolvedAncestor = [MutFinalPathNative]::GetFinalPath($ancestor).TrimEnd('\', '/')
    }
    catch {
        return $full
    }

    if ($tailParts.Count -eq 0) {
        return $resolvedAncestor
    }
    return (Join-Path $resolvedAncestor ($tailParts -join '\')).TrimEnd('\', '/')
}

function Assert-MutWorkDirOutsideSources {
    <#
        .SYNOPSIS
        §4 guardrail 1 enforcement: workDir must not be, or lie inside, aut.sourcePath,
        testApp.sourcePath or rulesets.sourcePath (when configured). Sync-MutAutCopy
        (AutCopy.psm1) computes robocopy destinations as `Join-Path workDir <name>`, and
        robocopy /MIR PRUNES extra files at the destination side; a workDir nested inside one
        of these source trees would make that destination a subdirectory of the source tree
        itself, so /MIR would delete files inside it -- worst case, inside the read-only AUT
        repo. No current config does this, but this is enforcement rather than mere
        observation of that guardrail. Paths are resolved to absolute (against $RepoRoot when
        relative) before comparing, since one key may be relative while another is absolute in
        the same config (§6.5.1's own example config does exactly that: aut.sourcePath is
        absolute, workDir is `./out`).

        Checked BOTH as literal (plain GetFullPath) paths AND past any reparse point
        (Resolve-MutFinalPath): a plain comparison alone is defeated by a directory junction
        pointing workDir into a source tree (review fix round 1), but resolving BOTH operands
        past reparse points and comparing ONLY that -- review fix round 1's mistake --
        weakens the mirror case: a workDir that is LITERALLY nested inside aut.sourcePath but
        is itself a junction pointing somewhere else entirely would then compare as unrelated
        and pass, when robocopy /MIR still targets the literal, nested destination path (the
        junction's OWN location, not its target) and would still prune there. Either
        comparison flags the config; both run.
    #>
    param($Config, [string]$RepoRoot)

    $workDirLiteral = [System.IO.Path]::GetFullPath((Resolve-MutConfigPath -RepoRoot $RepoRoot -Path $Config.workDir)).TrimEnd('\', '/')
    $workDirResolved = Resolve-MutFinalPath -Path $workDirLiteral

    $sources = @(
        [pscustomobject]@{ KeyPath = 'aut.sourcePath'; Path = $Config.aut.sourcePath }
        [pscustomobject]@{ KeyPath = 'testApp.sourcePath'; Path = $Config.testApp.sourcePath }
    )
    if ((Test-MutHasProperty $Config 'rulesets') -and ($null -ne $Config.rulesets)) {
        $sources += [pscustomobject]@{ KeyPath = 'rulesets.sourcePath'; Path = $Config.rulesets.sourcePath }
    }

    foreach ($source in $sources) {
        $sourceLiteral = [System.IO.Path]::GetFullPath((Resolve-MutConfigPath -RepoRoot $RepoRoot -Path $source.Path)).TrimEnd('\', '/')
        $sourceResolved = Resolve-MutFinalPath -Path $sourceLiteral

        $isContained = {
            param($WorkDir, $Source)
            $WorkDir.Equals($Source, [System.StringComparison]::OrdinalIgnoreCase) -or
                $WorkDir.StartsWith($Source + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
        }

        if ((& $isContained $workDirLiteral $sourceLiteral) -or (& $isContained $workDirResolved $sourceResolved)) {
            throw "Get-MutConfig: config key 'workDir' ('$($Config.workDir)') must not be, or lie inside, '$($source.KeyPath)' ('$($source.Path)') -- Sync-MutAutCopy's robocopy /MIR would prune files there."
        }
    }
}

function Assert-MutConfigShape {
    <#
        .SYNOPSIS
        Validates every required key of §6.5.1's config schema, throwing a message naming
        the first missing or invalid key found.
    #>
    param($Config, [string]$RepoRoot = (Get-MutRepoRoot))

    Assert-MutNonEmptyString $Config 'backend' 'backend'
    if ($script:AllowedBackends -notcontains $Config.backend) {
        throw "Get-MutConfig: config key 'backend' must be one of: $($script:AllowedBackends -join ', '). Got '$($Config.backend)'."
    }

    Assert-MutNonEmptyString $Config 'environmentName' 'environmentName'
    if ($Config.environmentName -cnotmatch '^mut-') {
        throw "Get-MutConfig: config key 'environmentName' ('$($Config.environmentName)') must match '^mut-'."
    }

    Assert-MutRequiredKey $Config 'aut' 'aut'
    Assert-MutNonEmptyString $Config.aut 'sourcePath' 'aut.sourcePath'
    Assert-MutNonEmptyString $Config.aut 'appId' 'aut.appId'
    Assert-MutNonEmptyString $Config.aut 'version' 'aut.version'

    Assert-MutRequiredKey $Config 'testApp' 'testApp'
    Assert-MutNonEmptyString $Config.testApp 'sourcePath' 'testApp.sourcePath'
    Assert-MutNonEmptyString $Config.testApp 'appId' 'testApp.appId'
    Assert-MutRequiredKey $Config.testApp 'testCodeunits' 'testApp.testCodeunits'
    $testCodeunits = @($Config.testApp.testCodeunits)
    if ($testCodeunits.Count -eq 0) {
        throw "Get-MutConfig: config key 'testApp.testCodeunits' must be a non-empty array of integers."
    }
    foreach ($id in $testCodeunits) {
        $parsedId = 0
        if (-not [int]::TryParse([string]$id, [ref]$parsedId)) {
            throw "Get-MutConfig: config key 'testApp.testCodeunits' must contain only integers; found '$id'."
        }
    }

    if (Test-MutHasProperty $Config 'rulesets') {
        if ($null -ne $Config.rulesets) {
            Assert-MutNonEmptyString $Config.rulesets 'sourcePath' 'rulesets.sourcePath'
            Assert-MutNonEmptyString $Config.rulesets 'file' 'rulesets.file'
        }
    }

    Assert-MutRequiredKey $Config 'coreApp' 'coreApp'
    Assert-MutNonEmptyString $Config.coreApp 'path' 'coreApp.path'
    Assert-MutNonEmptyString $Config.coreApp 'appId' 'coreApp.appId'
    Assert-MutNonEmptyString $Config.coreApp 'version' 'coreApp.version'

    Assert-MutRequiredKey $Config 'workDir' 'workDir'
    if ([string]::IsNullOrWhiteSpace([string]$Config.workDir)) {
        throw "Get-MutConfig: config key 'workDir' must be a non-empty string."
    }
    Assert-MutWorkDirOutsideSources -Config $Config -RepoRoot $RepoRoot

    Assert-MutRequiredKey $Config 'generator' 'generator'
    # maxMutants = 0 means "no cap" (§6.4.9: both mutation.config.json and
    # mutation.fixture.config.json ship it as 0), so 0 is valid; negative and non-integer
    # values are not.
    Assert-MutIntegerAtLeast $Config.generator 'maxMutants' 'generator.maxMutants' -Minimum 0
    Assert-MutRequiredKey $Config.generator 'onlyObjects' 'generator.onlyObjects'
    Assert-MutIntegerAtLeast $Config.generator 'seed' 'generator.seed' -Minimum 0
    Assert-MutRequiredKey $Config.generator 'operators' 'generator.operators'
    Assert-MutRequiredKey $Config.generator 'includeBreak' 'generator.includeBreak'

    Assert-MutRequiredKey $Config 'schemata' 'schemata'
    Assert-MutNonEmptyString $Config.schemata 'publishStrategy' 'schemata.publishStrategy'
    if ($script:AllowedPublishStrategies -notcontains $Config.schemata.publishStrategy) {
        throw "Get-MutConfig: config key 'schemata.publishStrategy' must be one of: $($script:AllowedPublishStrategies -join ', '). Got '$($Config.schemata.publishStrategy)'."
    }

    Assert-MutRequiredKey $Config 'timeouts' 'timeouts'
    # perTestFactor and minSeconds must be strictly positive: either one at 0 collapses
    # Get-MutTimeoutBudget's per-mutant budget to 0, WaitOne(0) returns false immediately, and
    # every mutant is marked Timeout. jobOverheadSeconds legitimately ships as 0 in both real
    # configs, so it only needs to be non-negative.
    Assert-MutNumberAtLeast $Config.timeouts 'perTestFactor' 'timeouts.perTestFactor' -Minimum 0 -ExclusiveMinimum
    Assert-MutNumberAtLeast $Config.timeouts 'minSeconds' 'timeouts.minSeconds' -Minimum 0 -ExclusiveMinimum
    Assert-MutNumberAtLeast $Config.timeouts 'jobOverheadSeconds' 'timeouts.jobOverheadSeconds' -Minimum 0

    if ($Config.backend -eq 'DemoPortal') {
        Assert-MutRequiredKey $Config 'demoPortal' 'demoPortal'
        Assert-MutNonEmptyString $Config.demoPortal 'profileId' 'demoPortal.profileId'
        Assert-MutNonEmptyString $Config.demoPortal 'activationAppId' 'demoPortal.activationAppId'
        Assert-MutNonEmptyString $Config.demoPortal 'cliPath' 'demoPortal.cliPath'

        # T11b (spike U5): the test-readiness probe target for Wait-MutEnvironmentSettled.
        Assert-MutRequiredKey $Config.demoPortal 'settleProbe' 'demoPortal.settleProbe'
        Assert-MutRequiredKey $Config.demoPortal.settleProbe 'codeunitId' 'demoPortal.settleProbe.codeunitId'
        $parsedProbeCodeunitId = 0
        if (-not [int]::TryParse([string]$Config.demoPortal.settleProbe.codeunitId, [ref]$parsedProbeCodeunitId)) {
            throw "Get-MutConfig: config key 'demoPortal.settleProbe.codeunitId' must be an integer."
        }
        Assert-MutNonEmptyString $Config.demoPortal.settleProbe 'functionName' 'demoPortal.settleProbe.functionName'
    }

    Assert-MutRequiredKey $Config 'permissionSets' 'permissionSets'
    $index = 0
    foreach ($set in @($Config.permissionSets)) {
        Assert-MutNonEmptyString $set 'id' "permissionSets[$index].id"
        Assert-MutNonEmptyString $set 'appId' "permissionSets[$index].appId"
        $index++
    }
}

function Get-MutConfig {
    <#
        .SYNOPSIS
        Loads, validates and returns the run configuration (§6.5.1). Relative paths
        (coreApp.path, workDir, aut.sourcePath, testApp.sourcePath, rulesets.sourcePath,
        demoPortal.cliPath) are resolved to absolute paths against the repo root; already
        absolute paths are left unchanged.
        .OUTPUTS
        PSCustomObject: the parsed config with resolved paths.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Get-MutConfig: config file not found: '$Path'."
    }

    $raw = Get-Content -Path $Path -Raw
    $config = $raw | ConvertFrom-Json

    Assert-MutConfigShape $config

    $repoRoot = Get-MutRepoRoot

    $config.coreApp.path = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.coreApp.path
    $config.workDir = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.workDir
    $config.aut.sourcePath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.aut.sourcePath
    $config.testApp.sourcePath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.testApp.sourcePath

    if ((Test-MutHasProperty $config 'rulesets') -and ($null -ne $config.rulesets)) {
        $config.rulesets.sourcePath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.rulesets.sourcePath
    }

    if ($config.backend -eq 'DemoPortal') {
        $config.demoPortal.cliPath = Resolve-MutConfigPath -RepoRoot $repoRoot -Path $config.demoPortal.cliPath
    }

    return $config
}

Export-ModuleMember -Function Get-MutConfig, Get-MutRepoRoot
