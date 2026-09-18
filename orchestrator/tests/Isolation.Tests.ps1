<#
    .SYNOPSIS
    §4 guardrail 6 / §8 acceptance item 3: orchestrator/Invoke-MutationRun.ps1 and
    orchestrator/lib/*.psm1 MUST NOT contain the strings 'continia', 'BcContainerHelper', or
    the name of the container-based backend module -- only orchestrator/backends/*.psm1 may.
    One exemption: the line in lib/Config.psm1 that lists the allowed backend names carries the
    marker comment '# isolation-lint: allow'; lines carrying that marker are excluded from the
    scan (T27 delivers that exclusion; the marker itself was already placed by an earlier task).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Backend isolation (§4 item 6, §8 acceptance item 3)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ScanTargets = @(
            (Join-Path $script:RepoRoot 'orchestrator\Invoke-MutationRun.ps1')
            (Join-Path $script:RepoRoot 'orchestrator\lib\*.psm1')
        )
        # The pattern is built from concatenated fragments so this test file itself never
        # contains the literal container-backend name as one word (it would otherwise be a false
        # positive if a future, broader scan ever included the tests folder).
        $script:ContainerBackendName = ('Doc' + 'ker')
        $script:Pattern = "continia|BcContainerHelper|$script:ContainerBackendName"
    }

    It 'the isolation-lint marker comment exists on at least one line of lib/Config.psm1 (sanity check for the exclusion below)' {
        $configPath = Join-Path $script:RepoRoot 'orchestrator\lib\Config.psm1'
        Test-Path $configPath | Should -Be $true

        $markerLines = @(Select-String -Path $configPath -Pattern 'isolation-lint: allow' -SimpleMatch)
        $markerLines.Count | Should -BeGreaterThan 0
    }

    It 'Select-String over Invoke-MutationRun.ps1 and lib/*.psm1 for continia, BcContainerHelper or the container backend name (case-insensitive), excluding isolation-lint: allow lines, returns nothing' {
        $matches = @(Select-String -Path $script:ScanTargets -Pattern $script:Pattern -CaseSensitive:$false -ErrorAction SilentlyContinue |
            Where-Object { $_.Line -notmatch 'isolation-lint: allow' })

        if ($matches.Count -gt 0) {
            $details = ($matches | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n"
            throw "Isolation violation(s) found:`n$details"
        }

        $matches.Count | Should -Be 0
    }

    It 'lib/Config.psm1 DOES contain the exempted backend-name line, proving the marker-based exclusion (not an empty file list) is what makes the scan pass' {
        $configPath = Join-Path $script:RepoRoot 'orchestrator\lib\Config.psm1'

        $rawMatches = @(Select-String -Path $configPath -Pattern $script:Pattern -CaseSensitive:$false)
        $rawMatches.Count | Should -BeGreaterThan 0

        $unexcluded = @($rawMatches | Where-Object { $_.Line -notmatch 'isolation-lint: allow' })
        $unexcluded.Count | Should -Be 0
    }

    It 'orchestrator/backends/*.psm1 is allowed to (and does) contain the container-backend name -- proving the scan is scoped, not that the name is absent from the repo' {
        $backendsDir = Join-Path $script:RepoRoot 'orchestrator\backends'
        Test-Path $backendsDir | Should -Be $true

        $backendMatches = @(Select-String -Path (Join-Path $backendsDir '*.psm1') -Pattern $script:ContainerBackendName -CaseSensitive:$false -ErrorAction SilentlyContinue)
        $backendMatches.Count | Should -BeGreaterThan 0
    }
}
