Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The entry scripts must refuse to start when another process holds the environment lock, and must
# do so before any environment/backend call. The lock holder is a child process; the scripts under
# test run as further child processes with a config whose workDir is the locked temp folder. The
# lock check sits between config loading and the pipeline/verify call (reviewed in the scripts), so
# these runs never reach the backend.

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:ModulePath = (Resolve-Path "$PSScriptRoot/../lib/EnvLock.psm1").Path

    function script:Test-MutLockWritten {
            # The file exists before the holder has written its document; wait for content.
            param([string]$Path)
            try {
                $s = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try { return ($s.Length -gt 0) } finally { $s.Dispose() }
            } catch { return $false }
        }
}

Describe 'entry scripts honour the environment lock' {
    BeforeAll {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("mutlock-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

        $cfg = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'mutation.fixture.config.json') -Raw | ConvertFrom-Json
        $cfg.workDir = $script:Work
        $script:Cfg = Join-Path $script:Work 'config.json'
        # config lives next to (not inside) the lock; workDir only holds the lock file and this config
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Cfg -Encoding UTF8

        $holder = Join-Path $script:Work 'holder.ps1'
        @"
Import-Module '$($script:ModulePath)' -Force
Enter-MutEnvLock -WorkDir '$($script:Work)' -RunNo 41 -Owner 'ChildOwner'
Start-Sleep -Seconds 600
"@ | Set-Content -LiteralPath $holder
        $startArgs = @{ FilePath = (Get-Process -Id $PID).Path; PassThru = $true; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holder) }
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $startArgs['WindowStyle'] = 'Hidden' }
        $script:Child = Start-Process @startArgs
        $lock = Join-Path $script:Work '.environment.lock'
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-MutLockWritten $lock) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not (Test-MutLockWritten $lock)) { throw 'child lock holder did not take the lock in time' }
    }

    AfterAll {
        if ($null -ne $script:Child) {
            Stop-Process -Id $script:Child.Id -Force -ErrorAction SilentlyContinue
            $script:Child.WaitForExit(10000) | Out-Null
        }
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '<name> exits 1 with "environment locked by" and never creates run output' -ForEach @(
        @{ name = 'Invoke-MutationRun.ps1' }
        @{ name = 'Invoke-MutFixVerify.ps1' }
    ) {
        $script = Join-Path $script:RepoRoot "orchestrator/$name"
        $out = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $script -ConfigPath $script:Cfg -RunNo 777 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -BeLike '*environment locked by ChildOwner run 41*'
        # nothing but the lock, config and holder may exist in the work dir: no aut-original copy etc.
        @(Get-ChildItem -LiteralPath $script:Work -Force | Where-Object { $_.Name -notin '.environment.lock', 'config.json', 'holder.ps1' }).Count | Should -Be 0
    }
}
