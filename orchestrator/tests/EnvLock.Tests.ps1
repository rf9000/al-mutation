Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/EnvLock.psm1" -Force
}

Describe 'Enter-MutEnvLock / Exit-MutEnvLock' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ("work" + [guid]::NewGuid().ToString('N'))
        $script:LockPath = Join-Path $script:Work '.environment.lock'
    }

    It 'creates the work dir and the lock file with pid, runNo, owner and startedUtc' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 5 -Owner 'Invoke-MutationRun.ps1'
        $doc = Get-Content -LiteralPath $script:LockPath -Raw | ConvertFrom-Json
        $doc.pid | Should -Be $PID
        $doc.runNo | Should -Be 5
        $doc.owner | Should -Be 'Invoke-MutationRun.ps1'
        [string]$doc.startedUtc | Should -Not -BeNullOrEmpty
    }

    It 'throws naming the holder when the lock belongs to a live process' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 5 -Owner 'Invoke-MutationRun.ps1'
        $err = $null
        try { Enter-MutEnvLock -WorkDir $script:Work -RunNo 6 -Owner 'Invoke-MutFixVerify.ps1' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike "environment locked by Invoke-MutationRun.ps1 run 5 (pid $PID) since *: $($script:LockPath)"
    }

    It 'replaces a lock whose pid is not alive, with a warning naming the old holder' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $dead = [ordered]@{ pid = 2147483000; runNo = 3; owner = 'OldOwner'; startedUtc = '2026-01-01T00:00:00Z' }
        $dead | ConvertTo-Json | Set-Content -LiteralPath $script:LockPath
        $w = $null
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 7 -Owner 'New' -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -BeLike '*OldOwner*'
        (Get-Content -LiteralPath $script:LockPath -Raw | ConvertFrom-Json).runNo | Should -Be 7
    }

    It 'replaces an unparsable lock file with a warning' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        Set-Content -LiteralPath $script:LockPath -Value 'not json {'
        $w = $null
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 8 -Owner 'New' -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should -BeGreaterThan 0
        (Get-Content -LiteralPath $script:LockPath -Raw | ConvertFrom-Json).runNo | Should -Be 8
    }

    It 'Exit removes the lock when it is held by this process' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 5 -Owner 'x'
        Exit-MutEnvLock -WorkDir $script:Work
        Test-Path -LiteralPath $script:LockPath | Should -Be $false
    }

    It 'Exit leaves a lock held by another pid' {
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        ([ordered]@{ pid = 2147483000; runNo = 3; owner = 'Other'; startedUtc = '2026-01-01T00:00:00Z' } | ConvertTo-Json) | Set-Content -LiteralPath $script:LockPath
        Exit-MutEnvLock -WorkDir $script:Work
        Test-Path -LiteralPath $script:LockPath | Should -Be $true
    }

    It 'Exit does not fail when there is no lock or no work dir' {
        { Exit-MutEnvLock -WorkDir $script:Work } | Should -Not -Throw
    }

    It 'can be re-entered after Exit' {
        Enter-MutEnvLock -WorkDir $script:Work -RunNo 1 -Owner 'a'
        Exit-MutEnvLock -WorkDir $script:Work
        { Enter-MutEnvLock -WorkDir $script:Work -RunNo 2 -Owner 'b' } | Should -Not -Throw
    }
}
