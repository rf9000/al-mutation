Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# §6.9.5: one orchestrator process at a time per work directory (= per environment).
# The lock is an OPEN FILE HANDLE on <workDir>/.environment.lock (CreateNew, FileShare.Read,
# DeleteOnClose). The OS closes the handle and deletes the file when the process ends for any
# reason, so a reused pid can never hold a lock.

$script:HeldLocks = @{}

function Get-MutEnvLockPath {
    param([Parameter(Mandatory = $true)][string]$WorkDir)
    return [System.IO.Path]::GetFullPath((Join-Path $WorkDir '.environment.lock'))
}

function ConvertFrom-MutEnvLockStream {
    <#
        .SYNOPSIS
        Private. Parses the lock document from a readable stream; $null when empty or unparsable.
        Does not dispose the stream.
    #>
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)
    try {
        $reader = New-Object System.IO.StreamReader($Stream, (New-Object System.Text.UTF8Encoding($false)), $true, 1024, $true)
        $text = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $doc = $text | ConvertFrom-Json
        if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['pid']) { return $null }
        $null = [int]$doc.pid
        return $doc
    }
    catch {
        return $null
    }
}

function Read-MutEnvLockHolder {
    <#
        .SYNOPSIS
        Private. Reads the lock document of a file held open by another process.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        return (ConvertFrom-MutEnvLockStream -Stream $stream)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Throw-MutEnvLockHeld {
    param([string]$Path)
    $holder = Read-MutEnvLockHolder -Path $Path
    if ($null -eq $holder) {
        throw "environment locked by unknown holder: $Path"
    }
    throw "environment locked by $($holder.owner) run $($holder.runNo) (pid $($holder.pid)) since $($holder.startedUtc): $Path"
}

function New-MutEnvLockStream {
    <#
        .SYNOPSIS
        Private. Atomically creates the lock file as an open DeleteOnClose handle and writes the
        document. Returns the stream, or $null when the file already exists / is held.
    #>
    param([string]$Path, [int]$RunNo, [string]$Owner)

    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::DeleteOnClose)
    }
    catch [System.IO.IOException] {
        return $null
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
        $stream.Flush()
    }
    catch {
        $stream.Dispose()
        throw
    }
    return $stream
}

function Enter-MutEnvLock {
    <#
        .SYNOPSIS
        Takes <WorkDir>/.environment.lock (§6.9.5) as an open handle. Throws `environment locked by
        <owner> run <runNo> (pid <pid>) since <startedUtc>: <path>` when another process holds it.
        A leftover file nobody holds is replaced after a warning.
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

    if ($script:HeldLocks.ContainsKey($path)) {
        Throw-MutEnvLockHeld -Path $path
    }

    $stream = New-MutEnvLockStream -Path $path -RunNo $RunNo -Owner $Owner
    if ($null -eq $stream) {
        # File exists. Try to open it exclusively: that fails while a holder has it open.
        $stale = $null
        try {
            $stale = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::DeleteOnClose)
        }
        catch [System.IO.FileNotFoundException] {
            $stale = $null
        }
        catch [System.IO.IOException] {
            Throw-MutEnvLockHeld -Path $path
        }

        if ($null -ne $stale) {
            try {
                $old = ConvertFrom-MutEnvLockStream -Stream $stale
            }
            finally {
                $stale.Dispose()   # DeleteOnClose removes the file
            }
            if ($null -ne $old) {
                Write-Warning "Enter-MutEnvLock: replacing stale lock of $($old.owner) run $($old.runNo) (pid $($old.pid), no longer holding it) since $($old.startedUtc): $path"
            }
            else {
                Write-Warning "Enter-MutEnvLock: replacing unreadable stale lock file: $path"
            }
        }

        $stream = New-MutEnvLockStream -Path $path -RunNo $RunNo -Owner $Owner
        if ($null -eq $stream) {
            Throw-MutEnvLockHeld -Path $path
        }
    }
    $script:HeldLocks[$path] = $stream
}

function Exit-MutEnvLock {
    <#
        .SYNOPSIS
        Closes this process's handle on <WorkDir>/.environment.lock, which deletes the file. No
        error when this process holds no lock.
    #>
    param([Parameter(Mandatory = $true)][string]$WorkDir)

    $path = Get-MutEnvLockPath -WorkDir $WorkDir
    if (-not $script:HeldLocks.ContainsKey($path)) { return }
    $stream = $script:HeldLocks[$path]
    $script:HeldLocks.Remove($path)
    $stream.Dispose()
}

Export-ModuleMember -Function Enter-MutEnvLock, Exit-MutEnvLock
