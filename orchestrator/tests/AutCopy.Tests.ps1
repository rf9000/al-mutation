Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/AutCopy.psm1" -Force

    function script:New-MutFixtureSourceTree {
        <#
            .SYNOPSIS
            Builds a small source tree with .al files, a nested subfolder, an .alpackages
            subfolder (symbol package stub), a .git subfolder, a .snapshots subfolder, and a
            built *.app file directly under the root -- one of each thing §6.5.2's robocopy
            invocation must exclude from the mirrored copy.
        #>
        param([string]$Root)

        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root 'Sub') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'Foo.Codeunit.al') -Value 'codeunit 1 "Foo" { }'
        Set-Content -Path (Join-Path $Root 'Sub/Bar.Codeunit.al') -Value 'codeunit 2 "Bar" { }'

        New-Item -ItemType Directory -Path (Join-Path $Root '.alpackages') -Force | Out-Null
        Set-Content -Path (Join-Path $Root '.alpackages/Some.Symbols.app') -Value 'symbols-stub'

        New-Item -ItemType Directory -Path (Join-Path $Root '.git') -Force | Out-Null
        Set-Content -Path (Join-Path $Root '.git/HEAD') -Value 'ref: refs/heads/main'

        New-Item -ItemType Directory -Path (Join-Path $Root '.snapshots') -Force | Out-Null
        Set-Content -Path (Join-Path $Root '.snapshots/old.snapshot') -Value 'snap-stub'

        Set-Content -Path (Join-Path $Root 'MyApp.app') -Value 'built-app-stub'
    }

    function script:New-MutTestConfig {
        param([string]$WorkDir, [string]$AutSource, [string]$TestAppSource, $Rulesets = $null)

        [pscustomobject]@{
            workDir  = $WorkDir
            aut      = [pscustomobject]@{ sourcePath = $AutSource }
            testApp  = [pscustomobject]@{ sourcePath = $TestAppSource }
            rulesets = $Rulesets
        }
    }
}

Describe 'Sync-MutAutCopy' {
    BeforeEach {
        $script:autSource = "$TestDrive/src/aut"
        $script:testAppSource = "$TestDrive/src/test-app"
        $script:workDir = "$TestDrive/out"
        New-MutFixtureSourceTree -Root $script:autSource
        New-MutFixtureSourceTree -Root $script:testAppSource
    }

    It 'mirrors .al files but excludes .alpackages, .git, .snapshots and *.app; returns the three paths' {
        $config = New-MutTestConfig -WorkDir $script:workDir -AutSource $script:autSource -TestAppSource $script:testAppSource

        $result = Sync-MutAutCopy -Config $config

        $result.AutPath | Should -Be (Join-Path $script:workDir 'aut-original')
        $result.TestAppPath | Should -Be (Join-Path $script:workDir 'test-app')
        $result.RulesetsPath | Should -BeNullOrEmpty

        Test-Path (Join-Path $result.AutPath 'Foo.Codeunit.al') | Should -Be $true
        Test-Path (Join-Path $result.AutPath 'Sub/Bar.Codeunit.al') | Should -Be $true
        Test-Path (Join-Path $result.AutPath '.alpackages') | Should -Be $false
        Test-Path (Join-Path $result.AutPath '.git') | Should -Be $false
        Test-Path (Join-Path $result.AutPath '.snapshots') | Should -Be $false
        Test-Path (Join-Path $result.AutPath 'MyApp.app') | Should -Be $false

        Test-Path (Join-Path $result.TestAppPath 'Foo.Codeunit.al') | Should -Be $true
        Test-Path (Join-Path $result.TestAppPath '.alpackages') | Should -Be $false
    }

    It 'is idempotent: a second run re-mirrors cleanly and reflects source changes made between runs' {
        $config = New-MutTestConfig -WorkDir $script:workDir -AutSource $script:autSource -TestAppSource $script:testAppSource

        Sync-MutAutCopy -Config $config | Out-Null

        # Mutate the source between runs to prove /MIR re-mirrors (adds+removes) rather than
        # merely no-op'ing on a second call.
        Set-Content -Path (Join-Path $script:autSource 'NewFile.Codeunit.al') -Value 'codeunit 3 "New" { }'
        Remove-Item -Path (Join-Path $script:autSource 'Foo.Codeunit.al') -Force

        { Sync-MutAutCopy -Config $config } | Should -Not -Throw
        $result2 = Sync-MutAutCopy -Config $config

        Test-Path (Join-Path $result2.AutPath 'NewFile.Codeunit.al') | Should -Be $true
        Test-Path (Join-Path $result2.AutPath 'Foo.Codeunit.al') | Should -Be $false
        Test-Path (Join-Path $result2.AutPath '.alpackages') | Should -Be $false
    }

    It 'leaves the source tree byte-for-byte unchanged (hash before/after, including the excluded files)' {
        $config = New-MutTestConfig -WorkDir $script:workDir -AutSource $script:autSource -TestAppSource $script:testAppSource

        $beforeFoo = (Get-FileHash -Path (Join-Path $script:autSource 'Foo.Codeunit.al')).Hash
        $beforeSub = (Get-FileHash -Path (Join-Path $script:autSource 'Sub/Bar.Codeunit.al')).Hash
        $beforePkg = (Get-FileHash -Path (Join-Path $script:autSource '.alpackages/Some.Symbols.app')).Hash
        $beforeApp = (Get-FileHash -Path (Join-Path $script:autSource 'MyApp.app')).Hash

        Sync-MutAutCopy -Config $config | Out-Null

        (Get-FileHash -Path (Join-Path $script:autSource 'Foo.Codeunit.al')).Hash | Should -Be $beforeFoo
        (Get-FileHash -Path (Join-Path $script:autSource 'Sub/Bar.Codeunit.al')).Hash | Should -Be $beforeSub
        (Get-FileHash -Path (Join-Path $script:autSource '.alpackages/Some.Symbols.app')).Hash | Should -Be $beforePkg
        (Get-FileHash -Path (Join-Path $script:autSource 'MyApp.app')).Hash | Should -Be $beforeApp
    }

    It 'mirrors rulesets when configured; RulesetsPath is $null when rulesets is $null' {
        $rulesetsSource = "$TestDrive/src/rulesets"
        New-Item -ItemType Directory -Path $rulesetsSource -Force | Out-Null
        Set-Content -Path (Join-Path $rulesetsSource '.cli-ruleset-localdeploy.json') -Value '{}'

        $config = New-MutTestConfig -WorkDir $script:workDir -AutSource $script:autSource -TestAppSource $script:testAppSource `
            -Rulesets ([pscustomobject]@{ sourcePath = $rulesetsSource; file = '.cli-ruleset-localdeploy.json' })

        $result = Sync-MutAutCopy -Config $config

        $result.RulesetsPath | Should -Be (Join-Path $script:workDir 'rulesets')
        Test-Path (Join-Path $result.RulesetsPath '.cli-ruleset-localdeploy.json') | Should -Be $true
    }

    It 'throws when robocopy reports a failure exit code (>= 8), e.g. a missing source directory' {
        $config = New-MutTestConfig -WorkDir $script:workDir -AutSource "$TestDrive/does-not-exist" -TestAppSource $script:testAppSource

        { Sync-MutAutCopy -Config $config } | Should -Throw
    }
}
