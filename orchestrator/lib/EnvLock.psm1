Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# §6.9.5: one orchestrator process at a time per work directory (= per environment).
# The lock is <workDir>/.environment.lock, created atomically; a stale lock (dead pid or
# unparsable content) is replaced with a warning.

function Get-MutEnvLockPath {
    param([Parameter(Mandatory = $true)][string]$WorkDir)
    return (Join-Path $WorkDir '.environment.lock')
}

function Read-MutEnvLockFile {
    <#
        .SYNOPSIS
        Private. Returns the parsed lock document, or $null when the file cannot be read or parsed.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['pid']) { return $null }
        $null = [int]$doc.pid
        return $doc
    }
    catch {
        return $null
    }
}

function New-MutEnvLockFile {
    <#
        .SYNOPSIS
        Private. Atomically creates the lock file (FileMode.CreateNew). Returns $true on success,
        $false when the file already exists.
    #>
    param([string]$Path, [int]$RunNo, [string]$Owner)

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    }
    catch [System.IO.IOException] {
        if (Test-Path -LiteralPath $Path) { return $false }
        throw
    }
    try {
        $json = [ordered]@{
            pid        = $PID
            runNo      = $RunNo
            owner      = $Owner
            startedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } | ConvertTo-Json
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
    return $true
}

function Enter-MutEnvLock {
    <#
        .SYNOPSIS
        Takes <WorkDir>/.environment.lock (§6.9.5). Throws `environment locked by <owner> run
        <runNo> (pid <pid>) since <startedUtc>: <path>` when a live process holds it. A lock whose
        pid is dead, or that cannot be parsed, is replaced after a warning.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][int]$RunNo,
        [Parameter(Mandatory = $true)][string]$Owner
    )

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }
    $path = Get-MutEnvLockPath -WorkDir $WorkDir

    if (New-MutEnvLockFile -Path $path -RunNo $RunNo -Owner $Owner) { return }

    $holder = Read-MutEnvLockFile -Path $path
    if ($null -ne $holder) {
        $alive = $null -ne (Get-Process -Id ([int]$holder.pid) -ErrorAction SilentlyContinue)
        if ($alive) {
            throw "environment locked by $($holder.owner) run $($holder.runNo) (pid $($holder.pid)) since $($holder.startedUtc): $path"
        }
        Write-Warning "Enter-MutEnvLock: replacing stale lock of $($holder.owner) run $($holder.runNo) (pid $($holder.pid), not running) since $($holder.startedUtc): $path"
    }
    else {
        Write-Warning "Enter-MutEnvLock: replacing unreadable lock file: $path"
    }
    Remove-Item -LiteralPath $path -Force
    if (-not (New-MutEnvLockFile -Path $path -RunNo $RunNo -Owner $Owner)) {
        throw "environment locked: could not create $path (another process took it)"
    }
}

function Exit-MutEnvLock {
    <#
        .SYNOPSIS
        Deletes <WorkDir>/.environment.lock only when its pid is the current process. No error
        when the file is absent.
    #>
    param([Parameter(Mandatory = $true)][string]$WorkDir)

    $path = Get-MutEnvLockPath -WorkDir $WorkDir
    if (-not (Test-Path -LiteralPath $path)) { return }
    $holder = Read-MutEnvLockFile -Path $path
    if ($null -ne $holder -and [int]$holder.pid -eq $PID) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Enter-MutEnvLock, Exit-MutEnvLock
