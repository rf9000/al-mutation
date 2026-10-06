Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:ModulePath = (Resolve-Path "$PSScriptRoot/../lib/EnvLock.psm1").Path
    Import-Module $script:ModulePath -Force

    function script:Test-MutLockWritten {
            # The file exists before the holder has written its document; wait for content.
            param([string]$Path)
            try {
                $s = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try { return ($s.Length -gt 0) } finally { $s.Dispose() }
            } catch { return $false }
        }

    function script:Start-MutLockHolder {
        <#
            .SYNOPSIS
            Starts a child powershell that takes the lock through the module and sleeps. Returns the
            process once the lock file exists.
        #>
        param([string]$WorkDir, [int]$RunNo = 41, [string]$Owner = 'ChildOwner')

        $script = Join-Path $TestDrive ("holder-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
        @"
Import-Module '$($script:ModulePath)' -Force
Enter-MutEnvLock -WorkDir '$WorkDir' -RunNo $RunNo -Owner '$Owner'
Start-Sleep -Seconds 600
"@ | Set-Content -LiteralPath $script
        $startArgs = @{ FilePath = (Get-Process -Id $PID).Path; PassThru = $true; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) }
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $startArgs['WindowStyle'] = 'Hidden' }
        $p = Start-Process @startArgs
        $lock = Join-Path $WorkDir '.environment.lock'
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-MutLockWritten $lock) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not (Test-MutLockWritten $lock)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            throw 'child lock holder did not take the lock in time'
        }
        return $p
    }
}

Describe 'Enter-MutEnvLock / Exit-MutEnvLock' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ("work" + [guid]::NewGuid().ToString('N'))
        $script:LockPath = Join-Path $script:Work '.environment.lock'
        $script:Child = $null
    }

    AfterEach {
        if ($null -ne $script:Child) {
            Stop-Process -Id $script:Child.Id -Force -ErrorAction SilentlyContinue
            $script:Child.WaitForExit(10000) | Out-Null
        }
        Exit-MutEnvLock -WorkDir $script:Work
    }

    It 'creates the work dir and the lock file with pid, runNo, owner and startedUtc' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 5 -Owner 'Invoke-MutationRun.ps1'
        $stream = New-Object System.IO.FileStream($script:LockPath, 'Open', 'Read', 'ReadWrite, Delete')
        try { $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
        $doc = $text | ConvertFrom-Json
        $doc.pid | Should -Be $PID
        $doc.runNo | Should -Be 5
        $doc.owner | Should -Be 'Invoke-MutationRun.ps1'
        [string]$doc.startedUtc | Should -Not -BeNullOrEmpty
    }

    It 're-entry in the same process throws locked instead of sharing' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 5 -Owner 'Invoke-MutationRun.ps1'
        $err = $null
        try { Enter-MutEnvLock -WorkDir $script:Work -RunNo 6 -Owner 'Invoke-MutFixVerify.ps1' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike "environment locked by Invoke-MutationRun.ps1 run 5 (pid $PID) since *: $($script:LockPath)"
    }

    It 'throws naming owner, run and pid when another process holds the lock' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $script:Child = Start-MutLockHolder -WorkDir $script:Work -RunNo 41 -Owner 'ChildOwner'
        $err = $null
        try { Enter-MutEnvLock -WorkDir $script:Work -RunNo 6 -Owner 'Other' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike "environment locked by ChildOwner run 41 (pid $($script:Child.Id)) since *: $($script:LockPath)"
    }

    It 'killing the holder frees the lock: file is gone and Enter succeeds (pid-reuse proof)' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $script:Child = Start-MutLockHolder -WorkDir $script:Work
        { Enter-MutEnvLock -WorkDir $script:Work -RunNo 6 -Owner 'Other' } | Should -Throw '*environment locked by*'

        Stop-Process -Id $script:Child.Id -Force
        $script:Child.WaitForExit(10000) | Should -Be $true
        # Windows deletes the file when the killed holder's handle closes (DeleteOnClose). Linux
        # does not run DeleteOnClose on a kill; the file stays behind as a stale lock that the
        # next Enter replaces (EnvLock.psm1 stale path).
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            Test-Path -LiteralPath $script:LockPath | Should -Be $false
        }

        { Enter-MutEnvLock -WorkDir $script:Work -RunNo 6 -Owner 'Other' } | Should -Not -Throw
    }

    It 'replaces a stale leftover file nobody holds, with a warning naming the old holder' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $old = [ordered]@{ pid = 4242; runNo = 3; owner = 'OldOwner'; startedUtc = '2026-01-01T00:00:00Z' }
        $old | ConvertTo-Json | Set-Content -LiteralPath $script:LockPath
        $w = $null
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 7 -Owner 'New' -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -BeLike '*OldOwner*'
        { Enter-MutEnvLock -WorkDir $script:Work -RunNo 8 -Owner 'Third' } | Should -Throw '*New run 7*'
    }

    It 'replaces an unreadable stale file with a warning' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        Set-Content -LiteralPath $script:LockPath -Value 'not json {'
        $w = $null
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 8 -Owner 'New' -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should -BeGreaterThan 0
        { Enter-MutEnvLock -WorkDir $script:Work -RunNo 9 -Owner 'Third' } | Should -Throw '*New run 8*'
    }

    It 'Exit deletes the lock file' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 5 -Owner 'x'
        Exit-MutEnvLock -WorkDir $script:Work
        Test-Path -LiteralPath $script:LockPath | Should -Be $false
    }

    It 'Exit with nothing held does not fail' {
        { Exit-MutEnvLock -WorkDir $script:Work } | Should -Not -Throw
    }

    It 'Exit leaves a lock held by another process' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $script:Child = Start-MutLockHolder -WorkDir $script:Work
        Exit-MutEnvLock -WorkDir $script:Work
        Test-Path -LiteralPath $script:LockPath | Should -Be $true
    }

    It 'can be re-entered after Exit' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 1 -Owner 'a'
        Exit-MutEnvLock -WorkDir $script:Work
        { Enter-MutEnvLock -WorkDir $script:Work -RunNo 2 -Owner 'b' } | Should -Not -Throw
    }
}
