Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force
    Import-Module "$PSScriptRoot/../backends/Docker.psm1" -Force

    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    function Get-MutIsolationViolations {
        <#
            .SYNOPSIS
            Returns the subset of $Lines that contain a forbidden isolation string
            (continia, BcContainerHelper, docker; case-insensitive), skipping any line
            carrying the '# isolation-lint: allow' marker. Shared by the real Config.psm1
            check and the synthetic exemption-behavior test below.
        #>
        param([string[]]$Lines)

        $violations = @()
        foreach ($line in $Lines) {
            if ($line -match '#\s*isolation-lint:\s*allow') {
                continue
            }
            if ($line -match '(?i)continia|BcContainerHelper|docker') {
                $violations += $line
            }
        }
        return , $violations
    }

    function New-MutTestConfigFile {
        param([hashtable]$Overrides = @{})

        $config = [ordered]@{
            backend         = 'DemoPortal'
            environmentName = 'mut-spike-01'
            keepEnvironment = $true
            aut             = [ordered]@{ sourcePath = './fixtures/fixture-aut'; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
            testApp         = [ordered]@{ sourcePath = './fixtures/fixture-test'; appId = '9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e'; testCodeunits = @(50300) }
            rulesets        = $null
            coreApp         = [ordered]@{ path = './core-app'; appId = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b'; version = '1.0.0.0' }
            permissionSets  = @(@{ id = 'MUT Core All'; appId = '6f1d2c3a-8b4e-4d5f-9a6b-7c8d9e0f1a2b' })
            workDir         = './out'
            generator       = [ordered]@{ maxMutants = 0; onlyObjects = @(); seed = 1; operators = @('REL', 'BOOL'); includeBreak = $false }
            schemata        = [ordered]@{ publishStrategy = 'same-version' }
            timeouts        = [ordered]@{ perTestFactor = 5; minSeconds = 60; jobOverheadSeconds = 0 }
            demoPortal      = [ordered]@{ profileId = 'cc557829-71df-40ee-9516-98ca954d4b2f'; activationAppId = 'c3755ece-dab0-4d16-987d-040661f18522'; cliPath = './.tools/continia.exe'; settleProbe = [ordered]@{ codeunitId = 50300; functionName = 'IsLargeOrder_Twelve_IsTrue' } }
        }

        foreach ($key in $Overrides.Keys) {
            $config[$key] = $Overrides[$key]
        }

        $path = Join-Path $TestDrive ("config-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        return $path
    }
}

Describe 'Get-MutRepoRoot' {
    It 'returns the repo root (two levels above the module file)' {
        Get-MutRepoRoot | Should -Be $script:RepoRoot
    }
}

Describe 'Get-MutConfig' {
    It 'loads a valid config file and resolves relative paths to absolute' {
        $path = New-MutTestConfigFile
        $cfg = Get-MutConfig -Path $path

        [System.IO.Path]::IsPathRooted($cfg.coreApp.path) | Should -Be $true
        $cfg.coreApp.path | Should -Be (Join-Path $script:RepoRoot 'core-app')
        [System.IO.Path]::IsPathRooted($cfg.workDir) | Should -Be $true
        $cfg.workDir | Should -Be (Join-Path $script:RepoRoot 'out')
        [System.IO.Path]::IsPathRooted($cfg.aut.sourcePath) | Should -Be $true
        [System.IO.Path]::IsPathRooted($cfg.testApp.sourcePath) | Should -Be $true
        [System.IO.Path]::IsPathRooted($cfg.demoPortal.cliPath) | Should -Be $true
    }

    It 'loads a config file whose path contains wildcard characters (-LiteralPath)' {
        $src = New-MutTestConfigFile
        $dir = Join-Path $TestDrive 'cfg[1]'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'mutation[x].config.json'
        Copy-Item -LiteralPath $src -Destination $path

        $cfg = Get-MutConfig -Path $path

        $cfg.backend | Should -Be 'DemoPortal'
    }

    It 'leaves already-absolute paths untouched' {
        $absolute = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 'C:/GeneralDev/AL/somewhere' } else { '/opt/GeneralDev/AL/somewhere' }
        $overrides = @{ aut = @{ sourcePath = $absolute; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        $cfg = Get-MutConfig -Path $path

        $cfg.aut.sourcePath | Should -Be $absolute
    }

    It 'loads the real mutation.config.json without error' {
        { Get-MutConfig -Path (Join-Path $script:RepoRoot 'mutation.config.json') } | Should -Not -Throw
    }

    It 'loads the real mutation.fixture.config.json without error' {
        { Get-MutConfig -Path (Join-Path $script:RepoRoot 'mutation.fixture.config.json') } | Should -Not -Throw
    }

    It 'allows rulesets to be null' {
        $path = New-MutTestConfigFile
        $cfg = Get-MutConfig -Path $path
        $cfg.rulesets | Should -BeNullOrEmpty
    }

    It 'resolves rulesets.sourcePath when rulesets is present' {
        $overrides = @{ rulesets = @{ sourcePath = './somerulesets'; file = '.cli-ruleset-localdeploy.json' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        $cfg = Get-MutConfig -Path $path
        [System.IO.Path]::IsPathRooted($cfg.rulesets.sourcePath) | Should -Be $true
        $cfg.rulesets.file | Should -Be '.cli-ruleset-localdeploy.json'
    }

    It 'throws naming the missing key when backend is absent' {
        $overrides = @{ backend = $null }
        $path = New-MutTestConfigFile -Overrides $overrides
        # remove the key entirely rather than leaving it $null
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Remove('backend')
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

        { Get-MutConfig -Path $path } | Should -Throw '*backend*'
    }

    It 'throws when backend is not DemoPortal or Docker' {
        $overrides = @{ backend = 'Bogus' }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*backend*'
    }

    It "throws when environmentName does not match ^mut-" {
        $overrides = @{ environmentName = 'spike' }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*environmentName*'
    }

    It "throws for a case-variant of the mut- prefix (MUT-, Mut-, mUt-): the match must be case-sensitive" {
        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            $overrides = @{ environmentName = $badName }
            $path = New-MutTestConfigFile -Overrides $overrides
            { Get-MutConfig -Path $path } | Should -Throw '*environmentName*'
        }
    }

    It 'throws naming the key when testApp.testCodeunits is empty' {
        $overrides = @{ testApp = @{ sourcePath = './fixtures/fixture-test'; appId = '9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e'; testCodeunits = @() } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*testCodeunits*'
    }

    It 'throws when schemata.publishStrategy is invalid' {
        $overrides = @{ schemata = @{ publishStrategy = 'bogus-strategy' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*publishStrategy*'
    }

    It 'allows an empty permissionSets array' {
        $overrides = @{ permissionSets = @() }
        $path = New-MutTestConfigFile -Overrides $overrides
        $cfg = Get-MutConfig -Path $path
        @($cfg.permissionSets).Count | Should -Be 0
    }

    It 'throws naming the key when a permissionSets entry is missing appId' {
        $overrides = @{ permissionSets = @(@{ id = 'MUT Core All' }) }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*permissionSets*'
    }

    It 'throws naming the missing key when coreApp.appId is absent' {
        $overrides = @{ coreApp = @{ path = './core-app'; version = '1.0.0.0' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*coreApp.appId*'
    }

    It 'throws naming the missing key when generator is absent' {
        $overrides = @{ generator = $null }
        $path = New-MutTestConfigFile -Overrides $overrides
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Remove('generator')
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

        { Get-MutConfig -Path $path } | Should -Throw '*generator*'
    }

    It 'throws naming the missing key when timeouts.minSeconds is absent' {
        $overrides = @{ timeouts = @{ perTestFactor = 5; jobOverheadSeconds = 0 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*timeouts.minSeconds*'
    }

    It 'throws when timeouts.minSeconds is 0 (a zero budget marks every mutant Timeout)' {
        $overrides = @{ timeouts = @{ perTestFactor = 5; minSeconds = 0; jobOverheadSeconds = 0 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*timeouts.minSeconds*'
    }

    It 'throws when timeouts.minSeconds is negative' {
        $overrides = @{ timeouts = @{ perTestFactor = 5; minSeconds = -1; jobOverheadSeconds = 0 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*timeouts.minSeconds*'
    }

    It 'throws when timeouts.minSeconds is not a number' {
        $overrides = @{ timeouts = @{ perTestFactor = 5; minSeconds = 'soon'; jobOverheadSeconds = 0 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*timeouts.minSeconds*'
    }

    It 'throws when timeouts.perTestFactor is 0 or negative' {
        $overrides = @{ timeouts = @{ perTestFactor = 0; minSeconds = 60; jobOverheadSeconds = 0 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*timeouts.perTestFactor*'
    }

    It 'allows timeouts.jobOverheadSeconds to be 0 (both real configs ship it as 0)' {
        $overrides = @{ timeouts = @{ perTestFactor = 5; minSeconds = 60; jobOverheadSeconds = 0 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Not -Throw
    }

    It 'throws when timeouts.jobOverheadSeconds is negative' {
        $overrides = @{ timeouts = @{ perTestFactor = 5; minSeconds = 60; jobOverheadSeconds = -5 } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*timeouts.jobOverheadSeconds*'
    }

    It 'allows generator.maxMutants to be 0 (both real configs use 0 to mean "no cap")' {
        $overrides = @{ generator = @{ maxMutants = 0; onlyObjects = @(); seed = 1; operators = @('REL'); includeBreak = $false } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Not -Throw
    }

    It 'throws when generator.maxMutants is negative' {
        $overrides = @{ generator = @{ maxMutants = -1; onlyObjects = @(); seed = 1; operators = @('REL'); includeBreak = $false } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*generator.maxMutants*'
    }

    It 'throws when generator.maxMutants is not an integer' {
        $overrides = @{ generator = @{ maxMutants = 'lots'; onlyObjects = @(); seed = 1; operators = @('REL'); includeBreak = $false } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*generator.maxMutants*'
    }

    It 'throws when generator.seed is negative' {
        $overrides = @{ generator = @{ maxMutants = 0; onlyObjects = @(); seed = -1; operators = @('REL'); includeBreak = $false } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*generator.seed*'
    }

    It 'throws when workDir is nested inside aut.sourcePath (robocopy /MIR would prune files there)' {
        $autSrc = "$TestDrive/aut-src-$([guid]::NewGuid().ToString('N'))"
        $overrides = @{
            aut     = @{ sourcePath = $autSrc; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
            workDir = "$autSrc/out"
        }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*workDir*aut.sourcePath*'
    }

    It 'throws when workDir equals testApp.sourcePath exactly' {
        $testSrc = "$TestDrive/test-src-$([guid]::NewGuid().ToString('N'))"
        $overrides = @{
            testApp = @{ sourcePath = $testSrc; appId = '9c4a5f6d-be7b-4a8c-8d9e-0f1a2b3c4d5e'; testCodeunits = @(50300) }
            workDir = $testSrc
        }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*workDir*testApp.sourcePath*'
    }

    It 'throws when workDir is nested inside rulesets.sourcePath' {
        $rulesetsSrc = "$TestDrive/rulesets-src-$([guid]::NewGuid().ToString('N'))"
        $overrides = @{
            rulesets = @{ sourcePath = $rulesetsSrc; file = '.cli-ruleset-localdeploy.json' }
            workDir  = "$rulesetsSrc/nested/out"
        }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*workDir*rulesets.sourcePath*'
    }

    It 'does not throw for sibling paths that merely share a string prefix (e.g. .../out vs .../out2)' {
        $base = "$TestDrive/prefix-$([guid]::NewGuid().ToString('N'))"
        $overrides = @{
            aut     = @{ sourcePath = "$base/out2"; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
            workDir = "$base/out"
        }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Not -Throw
    }

    It 'throws when workDir is a directory junction whose real target lies inside aut.sourcePath (review fix round 1: a plain GetFullPath comparison alone is defeated by a reparse point)' -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        $autSrc = "$TestDrive/aut-src-junc-$([guid]::NewGuid().ToString('N'))"
        $autNested = Join-Path $autSrc 'nested'
        New-Item -ItemType Directory -Path $autNested -Force | Out-Null

        $junctionPath = "$TestDrive/workdir-junction-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Junction -Path $junctionPath -Target $autNested -Force | Out-Null

        try {
            $overrides = @{
                aut     = @{ sourcePath = $autSrc; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
                workDir = $junctionPath
            }
            $path = New-MutTestConfigFile -Overrides $overrides
            { Get-MutConfig -Path $path } | Should -Throw '*workDir*aut.sourcePath*'
        }
        finally {
            # No -Recurse: removes only the junction itself, never the real target's contents.
            Remove-Item -Path $junctionPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when workDir is LITERALLY nested inside aut.sourcePath even though workDir itself is a junction pointing somewhere else entirely (fix round 2: resolving BOTH operands past reparse points weakened the mirror case -- robocopy /MIR still targets the literal, nested path)' -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        $autSrc = "$TestDrive/aut-src-mirror-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $autSrc -Force | Out-Null

        $elsewhereReal = "$TestDrive/elsewhere-real-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $elsewhereReal -Force | Out-Null

        # workDir's own literal path IS inside aut.sourcePath, but workDir is itself a
        # junction whose real target is a completely unrelated directory.
        $workDirJunction = Join-Path $autSrc 'out'
        New-Item -ItemType Junction -Path $workDirJunction -Target $elsewhereReal -Force | Out-Null

        try {
            $overrides = @{
                aut     = @{ sourcePath = $autSrc; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
                workDir = $workDirJunction
            }
            $path = New-MutTestConfigFile -Overrides $overrides
            { Get-MutConfig -Path $path } | Should -Throw '*workDir*aut.sourcePath*'
        }
        finally {
            Remove-Item -Path $workDirJunction -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when generator.seed is not an integer' {
        $overrides = @{ generator = @{ maxMutants = 0; onlyObjects = @(); seed = 'random'; operators = @('REL'); includeBreak = $false } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*generator.seed*'
    }

    It 'throws naming the missing key when demoPortal.cliPath is absent and backend is DemoPortal' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.cliPath*'
    }

    It 'throws naming the missing key when demoPortal.settleProbe is absent and backend is DemoPortal' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y'; cliPath = './.tools/continia.exe' } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.settleProbe*'
    }

    It 'throws when demoPortal.settleProbe.codeunitId is not an integer' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y'; cliPath = './.tools/continia.exe'; settleProbe = @{ codeunitId = 'not-a-number'; functionName = 'IsLargeOrder_Twelve_IsTrue' } } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.settleProbe.codeunitId*'
    }

    It 'throws naming the missing key when demoPortal.settleProbe.functionName is absent' {
        $overrides = @{ demoPortal = @{ profileId = 'x'; activationAppId = 'y'; cliPath = './.tools/continia.exe'; settleProbe = @{ codeunitId = 50300 } } }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*demoPortal.settleProbe.functionName*'
    }
}

Describe 'Assert-MutNumberAtLeast / Assert-MutIntegerAtLeast (culture-invariant parsing, review fix round 1)' {
    <#
        .SYNOPSIS
        [double]::TryParse(string, ref double) -- the 2-argument overload used before this
        fix -- implicitly parses under NumberStyles.Float | NumberStyles.AllowThousands in the
        THREAD'S AMBIENT CULTURE. On a culture where "." is the digit-grouping separator and
        "," is the decimal separator (e.g. da-DK), "1.5" parses as 15, not 1.5: verified by
        direct experiment (`[double]::TryParse('1.5', [ref]$d)` under da-DK returns $true with
        $d -eq 15). Config values ship as JSON numbers today, which ConvertFrom-Json always
        renders culture-invariantly regardless of the JSON file's own text, so this was never
        an observed failure -- but a config that ever shipped a fractional value as a JSON
        STRING would silently validate against the wrong magnitude. These tests flip the
        thread's current culture to da-DK for the duration of one assertion (restored in
        `finally` even if the assertion throws) and prove a value that must fail correctly
        parsed (1.5, tested against a lower bound of 10) still fails rather than silently
        passing as 15.
    #>
    BeforeAll {
        Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
    }

    It 'rejects "1.5" against a lower bound of 10 under da-DK culture (2-arg TryParse would misparse it as 15 and wrongly pass)' {
        $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('da-DK')

            $obj = [pscustomobject]@{ value = '1.5' }
            {
                InModuleScope Config {
                    param($Obj)
                    Assert-MutNumberAtLeast -Object $Obj -Name 'value' -KeyPath 'test.value' -Minimum 10 -ExclusiveMinimum
                } -Parameters @{ Obj = $obj }
            } | Should -Throw '*test.value*greater than 10*'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
        }
    }

    It 'rejects "1.5" against a bound of 5 under da-DK culture (fix round 2: the previous version of this test used a bound of 1, which 15 -- the WRONG 2-arg-style parse -- also exceeds, so it passed for the wrong reason; a bound strictly between 1.5 and 15 is required to distinguish them)' {
        $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('da-DK')

            $obj = [pscustomobject]@{ value = '1.5' }
            {
                InModuleScope Config {
                    param($Obj)
                    Assert-MutNumberAtLeast -Object $Obj -Name 'value' -KeyPath 'test.value' -Minimum 5 -ExclusiveMinimum
                } -Parameters @{ Obj = $obj }
            } | Should -Throw '*test.value*greater than 5*'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
        }
    }

    It 'still rejects a non-integer string for Assert-MutIntegerAtLeast under da-DK culture (NOTE: this does not actually distinguish the fix -- the 2-arg int overload uses NumberStyles.Integer, which already disallows group separators, so "1.500" was rejected identically before this fix too; kept as a plain regression check, not evidence of the culture bug)' {
        $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('da-DK')

            $obj = [pscustomobject]@{ value = '1.500' }
            {
                InModuleScope Config {
                    param($Obj)
                    Assert-MutIntegerAtLeast -Object $Obj -Name 'value' -KeyPath 'test.value' -Minimum 0
                } -Parameters @{ Obj = $obj }
            } | Should -Throw '*test.value*integer*'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
        }
    }
}

Describe 'Resolve-MutFinalPath (drive-root handling, review fix round 2)' {
    <#
        .SYNOPSIS
        TrimEnd('\', '/') ran BEFORE the drive-root check, so a config value of "C:\" became
        "C:" -- which CreateFileW/the Win32 path APIs read as the legacy DOS "current
        directory on drive C:", not the actual root. Resolving that then returned the
        PROCESS'S CURRENT DIRECTORY on that drive instead of "C:\" itself, so a drive-root
        source/workDir value silently compared against the wrong path. Proven here by
        pointing the process's current directory somewhere that is provably NOT "C:\" and
        confirming Resolve-MutFinalPath('C:\') does not resolve to it.
    #>
    It 'resolves "C:\" to the drive root, not to the process current directory' -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        # [Environment]::CurrentDirectory, NOT Set-Location: PowerShell's own location and the
        # process's actual current directory (what CreateFileW's drive-relative resolution
        # reads) are two different things -- Set-Location alone does not move the latter,
        # verified by direct experiment.
        $originalCurrentDirectory = [Environment]::CurrentDirectory
        try {
            [Environment]::CurrentDirectory = $env:WINDIR

            $resolved = InModuleScope Config { Resolve-MutFinalPath -Path 'C:\' }

            $resolved | Should -Be 'C:'
            $resolved | Should -Not -Be $env:WINDIR.TrimEnd('\')
        }
        finally {
            [Environment]::CurrentDirectory = $originalCurrentDirectory
        }
    }

    It 'resolves "C:" (no trailing separator) the same way, not as drive-relative to the current directory' -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        $originalCurrentDirectory = [Environment]::CurrentDirectory
        try {
            [Environment]::CurrentDirectory = $env:WINDIR

            $resolved = InModuleScope Config { Resolve-MutFinalPath -Path 'C:' }

            $resolved | Should -Be 'C:'
            $resolved | Should -Not -Be $env:WINDIR.TrimEnd('\')
        }
        finally {
            [Environment]::CurrentDirectory = $originalCurrentDirectory
        }
    }
}

Describe 'Config.psm1 isolation' {
    It 'contains none of the forbidden strings (continia, BcContainerHelper, docker) outside the marked allow-line' {
        $path = "$PSScriptRoot/../lib/Config.psm1"
        $lines = Get-Content -Path $path
        $violations = Get-MutIsolationViolations -Lines $lines
        $violations | Should -BeNullOrEmpty
    }

    It 'flags an unmarked line containing a forbidden string but not a line carrying the allow marker' {
        $sample = @(
            "Set-StrictMode -Version Latest",
            "`$leak = 'docker is mentioned here with no marker'",
            "`$script:AllowedBackends = @('DemoPortal', 'Docker')  # isolation-lint: allow"
        )

        $violations = Get-MutIsolationViolations -Lines $sample

        $violations.Count | Should -Be 1
        $violations[0] | Should -Match 'no marker'
    }
}

Describe 'Docker backend' {
    It 'exports the same function names as DemoPortal' {
        $dockerNames = (Get-Command -All -Module Docker).Name | Sort-Object
        $demoNames = (Get-Command -All -Module DemoPortal).Name | Sort-Object
        $dockerNames | Should -Be $demoNames
    }

    It 'exports the same parameter names as DemoPortal for every function (T11b: Reset-MutEnvironment gained an optional -Config)' {
        $commonParams = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
        $demoNames = (Get-Command -All -Module DemoPortal).Name | Sort-Object
        foreach ($name in $demoNames) {
            $demoParams = (Get-Command -All -Module DemoPortal | Where-Object Name -eq $name).Parameters.Keys | Where-Object { $_ -notin $commonParams } | Sort-Object
            $dockerParams = (Get-Command -All -Module Docker | Where-Object Name -eq $name).Parameters.Keys | Where-Object { $_ -notin $commonParams } | Sort-Object
            $dockerParams | Should -Be $demoParams -Because "function '$name'"
        }
    }

    It 'throws NotImplementedException for every exported function' {
        $fakeEnv = [pscustomobject]@{ Id = 'E1'; Name = 'mut-spike-01'; Url = 'https://x/E1'; Backend = 'Docker'; Shared = $false; CliPath = 'C:/nowhere.exe' }
        $fakeConfig = [pscustomobject]@{ demoPortal = [pscustomobject]@{ cliPath = 'C:/nowhere.exe' } }

        foreach ($name in (Get-Command -All -Module Docker).Name) {
            $command = Get-Command $name -Module Docker -All
            $argCount = $command.Parameters.Count

            $callParams = @{}
            foreach ($p in $command.Parameters.Values) {
                if ($p.Name -in @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) {
                    continue
                }
                switch ($p.Name) {
                    'Env' { $callParams['Env'] = $fakeEnv }
                    'Config' { $callParams['Config'] = $fakeConfig }
                    'Name' { $callParams['Name'] = 'mut-spike-01' }
                    'Method' { $callParams['Method'] = 'GET' }
                    'Path' { $callParams['Path'] = 'x' }
                    'AppPath' { $callParams['AppPath'] = 'x' }
                    'AppFile' { $callParams['AppFile'] = 'x' }
                    'AppId' { $callParams['AppId'] = 'x' }
                    'PermissionSetId' { $callParams['PermissionSetId'] = 'x' }
                    'Targets' { $callParams['Targets'] = @([pscustomobject]@{ CodeunitId = 1; Function = $null }) }
                    'JobIds' { $callParams['JobIds'] = @('x') }
                    default { }
                }
            }

            { & $name @callParams } | Should -Throw -ExceptionType ([System.NotImplementedException])
        }
    }
}

Describe 'Get-MutConfig: coreAppTest (optional Mutation Core test app)' {
    It 'accepts a config that omits coreAppTest entirely' {
        $path = New-MutTestConfigFile
        $cfg = Get-MutConfig -Path $path
        $cfg.PSObject.Properties['coreAppTest'] | Should -BeNullOrEmpty
    }

    It 'resolves coreAppTest.path to an absolute path when present' {
        $path = New-MutTestConfigFile -Overrides @{
            coreAppTest = [ordered]@{ path = './core-app-test'; appId = '7a2e3d4b-9c5f-4e6a-8b7c-8d9e0f1a2b3c' }
        }
        $cfg = Get-MutConfig -Path $path
        [System.IO.Path]::IsPathRooted($cfg.coreAppTest.path) | Should -BeTrue
        $cfg.coreAppTest.path | Should -BeLike '*core-app-test'
    }

    It 'throws when coreAppTest is present but has no path' {
        $path = New-MutTestConfigFile -Overrides @{
            coreAppTest = [ordered]@{ appId = '7a2e3d4b-9c5f-4e6a-8b7c-8d9e0f1a2b3c' }
        }
        { Get-MutConfig -Path $path } | Should -Throw -ExpectedMessage "*coreAppTest.path*"
    }

    It 'throws when coreAppTest is present but has no appId' {
        $path = New-MutTestConfigFile -Overrides @{
            coreAppTest = [ordered]@{ path = './core-app-test' }
        }
        { Get-MutConfig -Path $path } | Should -Throw -ExpectedMessage "*coreAppTest.appId*"
    }
}

Describe 'Get-MutConfig: environment-variable expansion in paths' {
    AfterEach {
        Remove-Item Env:\MUT_TEST_AUT_ROOT -ErrorAction SilentlyContinue
    }

    It 'expands %VAR% in a sourcePath so a shipped config need not hard-code a drive layout' {
        $root = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 'C:/GeneralDev/AL/SomeCheckout' } else { '/opt/GeneralDev/AL/SomeCheckout' }
        $env:MUT_TEST_AUT_ROOT = $root
        $path = New-MutTestConfigFile -Overrides @{
            aut = [ordered]@{ sourcePath = '%MUT_TEST_AUT_ROOT%/base-application'; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
        }
        $cfg = Get-MutConfig -Path $path
        # An already-rooted path is returned as-is (see 'leaves already-absolute paths untouched'),
        # so expansion preserves whichever separators the config itself used.
        $cfg.aut.sourcePath | Should -Be "$root/base-application"
    }

    It 'throws naming the variable when it is not set, rather than leaving a literal %VAR% to fail later' {
        Remove-Item Env:\MUT_TEST_AUT_ROOT -ErrorAction SilentlyContinue
        $path = New-MutTestConfigFile -Overrides @{
            aut = [ordered]@{ sourcePath = '%MUT_TEST_AUT_ROOT%/base-application'; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
        }
        { Get-MutConfig -Path $path } | Should -Throw -ExpectedMessage "*MUT_TEST_AUT_ROOT*"
    }
}

Describe 'Get-MutConfig: onlyObjects scope is announced, not silent' {
    It 'warns naming the count and the object ids when the run is scoped' {
        $path = New-MutTestConfigFile -Overrides @{
            generator = [ordered]@{ maxMutants = 0; onlyObjects = @(72918635, 95110); seed = 1; operators = @('REL'); includeBreak = $false }
        }
        Get-MutConfig -Path $path -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings -join ' ') | Should -BeLike '*2 object(s)*'
        ($warnings -join ' ') | Should -BeLike '*72918635, 95110*'
    }

    It 'stays silent when onlyObjects is empty (whole AUT)' {
        $path = New-MutTestConfigFile
        Get-MutConfig -Path $path -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings | Where-Object { $_ -like '*onlyObjects*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-MutConfig testTransport and soap.batchSize (§6.10.4)' {
    It 'defaults testTransport to cli and soap.batchSize to 50 when absent' {
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile)
        $cfg.testTransport | Should -Be 'cli'
        $cfg.soap.batchSize | Should -Be 50
    }

    It 'accepts testTransport soap' {
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ testTransport = 'soap' })
        $cfg.testTransport | Should -Be 'soap'
    }

    It 'accepts testTransport cli explicitly' {
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ testTransport = 'cli' })
        $cfg.testTransport | Should -Be 'cli'
    }

    It 'rejects any other testTransport, naming the key' {
        { Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ testTransport = 'carrier-pigeon' }) } | Should -Throw '*testTransport*'
    }

    It 'rejects a null testTransport' {
        { Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ testTransport = $null }) } | Should -Throw '*testTransport*'
    }

    It 'reads a custom soap.batchSize' {
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ soap = @{ batchSize = 12 } })
        $cfg.soap.batchSize | Should -Be 12
    }

    It 'defaults soap.batchSize to 50 when soap is present without it' {
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ soap = @{} })
        $cfg.soap.batchSize | Should -Be 50
    }

    It 'rejects a soap.batchSize that is not a positive integer' {
        foreach ($bad in 0, -3, 2.5, 'many') {
            { Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ soap = @{ batchSize = $bad } }) } | Should -Throw '*soap.batchSize*'
        }
    }

    It 'rejects a soap value that is not an object, naming soap' {
        foreach ($bad in 5, 'text', $true) {
            { Get-MutConfig -Path (New-MutTestConfigFile -Overrides @{ soap = $bad }) } | Should -Throw '*soap*object*'
        }
    }

    It 'puts every shipped config on the soap transport (owner decision 2026-10-06, after runs 16/17)' {
        foreach ($name in 'mutation.config.json', 'mutation.fixture.config.json', 'mutation.u2.config.json') {
            (Get-MutConfig -Path (Join-Path $script:RepoRoot $name)).testTransport | Should -Be 'soap' -Because $name
        }
    }
}

Describe 'Platform helpers (Linux port)' {
    It 'Test-MutIsWindows matches the OS platform' {
        $expected = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
        Test-MutIsWindows | Should -Be $expected
    }

    It 'Get-MutPathComparison ignores case only on Windows' {
        $expected = if (Test-MutIsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        Get-MutPathComparison | Should -Be $expected
    }

    It 'Get-MutShellPath returns the executable of the running PowerShell host' {
        $shell = Get-MutShellPath
        Test-Path -LiteralPath $shell | Should -BeTrue
        [System.IO.Path]::GetFileNameWithoutExtension($shell) | Should -BeIn @('powershell', 'pwsh')
    }
}

Describe 'Paths on Linux (Linux port)' {
    BeforeAll {
        $script:OnLinux = [System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT
    }

    It 'Resolve-MutFinalPath keeps the root "/"' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        InModuleScope Config { Resolve-MutFinalPath -Path '/' } | Should -Be '/'
    }

    It 'throws when workDir is a symlink whose real target lies inside aut.sourcePath' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $autSrc = "$TestDrive/aut-src-link-$([guid]::NewGuid().ToString('N'))"
        $autNested = Join-Path $autSrc 'nested'
        New-Item -ItemType Directory -Path $autNested -Force | Out-Null
        $link = "$TestDrive/workdir-link-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType SymbolicLink -Path $link -Target $autNested | Out-Null

        $overrides = @{
            aut     = @{ sourcePath = $autSrc; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
            workDir = $link
        }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Throw '*workDir*aut.sourcePath*'
    }

    It 'does not treat a workDir that differs from aut.sourcePath only in case as inside it' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $base = "$TestDrive/case-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path "$base/CaseAut" -Force | Out-Null
        $overrides = @{
            aut     = @{ sourcePath = "$base/CaseAut"; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' }
            workDir = "$base/caseaut/out"
        }
        $path = New-MutTestConfigFile -Overrides $overrides
        { Get-MutConfig -Path $path } | Should -Not -Throw
    }
}

Describe 'Write-MutTextFile / Read-MutTextFile (Linux port)' {
    BeforeAll {
        # Built from code points so the test file's own encoding cannot change the text.
        $script:Nordic = 'Bank ' + [string][char]0x00E6 + [string][char]0x00F8 + [string][char]0x00E5 + ' ' + [string][char]0x00C6 + [string][char]0x00D8 + [string][char]0x00C5
    }

    It 'round-trips non-ASCII text' {
        $path = Join-Path $TestDrive 'roundtrip.json'
        Write-MutTextFile -Path $path -Text $script:Nordic
        Read-MutTextFile -Path $path | Should -BeExactly $script:Nordic
    }

    It 'writes UTF-8 without a BOM' {
        $path = Join-Path $TestDrive 'nobom.json'
        Write-MutTextFile -Path $path -Text $script:Nordic
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Not -Be 0xEF
        $bytes.Length | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($script:Nordic))
    }

    It 'reads a file that has a BOM without a leading U+FEFF' {
        $path = Join-Path $TestDrive 'bom.json'
        [System.IO.File]::WriteAllText($path, $script:Nordic, (New-Object System.Text.UTF8Encoding $true))
        $text = Read-MutTextFile -Path $path
        $text | Should -BeExactly $script:Nordic
    }

    It 'creates the parent folder when it is missing' {
        $path = Join-Path $TestDrive 'new-folder/sub/file.txt'
        Write-MutTextFile -Path $path -Text 'x'
        Read-MutTextFile -Path $path | Should -Be 'x'
    }
}

Describe 'Environment overrides MUT_WORK_DIR, MUT_CLI_PATH, MUT_RESULTS_DIR (Linux port)' {
    AfterEach {
        Remove-Item Env:\MUT_WORK_DIR, Env:\MUT_CLI_PATH, Env:\MUT_RESULTS_DIR -ErrorAction SilentlyContinue
    }

    It 'MUT_WORK_DIR replaces workDir' {
        $work = Join-Path $TestDrive 'env-work'
        $env:MUT_WORK_DIR = $work
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile)
        $cfg.workDir | Should -Be $work
    }

    It 'MUT_WORK_DIR relative to the repo root' {
        $env:MUT_WORK_DIR = 'env-relative-out'
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile)
        $cfg.workDir | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'env-relative-out')))
    }

    It 'MUT_WORK_DIR is checked against the source folders like workDir' {
        $autSrc = Join-Path $TestDrive ('env-aut-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $autSrc -Force | Out-Null
        $path = New-MutTestConfigFile -Overrides @{ aut = @{ sourcePath = $autSrc; appId = '8b3f4e5c-ad6a-4f7b-9c8d-9e0f1a2b3c4d'; version = '1.0.0.0' } }
        $env:MUT_WORK_DIR = Join-Path $autSrc 'out'
        { Get-MutConfig -Path $path } | Should -Throw '*workDir*aut.sourcePath*'
    }

    It 'MUT_CLI_PATH replaces demoPortal.cliPath' {
        $cli = Join-Path $TestDrive 'bin/continia-cli'
        $env:MUT_CLI_PATH = $cli
        $cfg = Get-MutConfig -Path (New-MutTestConfigFile)
        $cfg.demoPortal.cliPath | Should -Be $cli
    }

    It 'Get-MutResultsDir is <RepoRoot>/results without MUT_RESULTS_DIR' {
        Get-MutResultsDir | Should -Be (Join-Path $script:RepoRoot 'results')
        Get-MutResultsDir -RepoRoot (Join-Path $TestDrive 'other') | Should -Be (Join-Path (Join-Path $TestDrive 'other') 'results')
    }

    It 'Get-MutResultsDir is MUT_RESULTS_DIR when set, relative values against the repo root' {
        $env:MUT_RESULTS_DIR = Join-Path $TestDrive 'env-results'
        Get-MutResultsDir | Should -Be (Join-Path $TestDrive 'env-results')
        $env:MUT_RESULTS_DIR = 'rel-results'
        Get-MutResultsDir -RepoRoot (Join-Path $TestDrive 'r') | Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Join-Path $TestDrive 'r') 'rel-results')))
    }
}
