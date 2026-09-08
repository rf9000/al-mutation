Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Compile-MutApp is a backend function (DemoPortal.psm1). Schemata.psm1 calls it as a plain,
    # unqualified command resolved at run time -- it never imports a backend module itself. That
    # is what makes it mockable here: importing DemoPortal.psm1 puts a real Compile-MutApp into
    # the global function table, and `Mock -ModuleName Schemata Compile-MutApp` then injects a
    # proxy directly into Schemata's own module session state, which wins command resolution for
    # any unqualified call made by code running inside that module.
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/Schemata.psm1" -Force

    $script:envHandle = [pscustomobject]@{
        Id      = 'E1'
        Name    = 'mut-spike-01'
        Url     = 'https://demoportaldev.continiaonline.com/E1'
        Backend = 'DemoPortal'
        Shared  = $false
        CliPath = './.tools/fake-cli.exe'
    }

    function script:New-MutFakeConfig {
        param(
            [string]$WorkDir,
            [string]$PublishStrategy = 'same-version',
            [string]$AutVersion = '1.0.0.0',
            [object[]]$OnlyObjects = @(72918635),
            $Rulesets = $null
        )

        [pscustomobject]@{
            workDir   = $WorkDir
            aut       = [pscustomobject]@{ version = $AutVersion }
            coreApp   = [pscustomobject]@{ appId = 'c0a3e1a0-0000-0000-0000-000000000001'; version = '1.0.0.0' }
            generator = [pscustomobject]@{
                maxMutants   = 0
                seed         = 1
                onlyObjects  = $OnlyObjects
                operators    = @('REL', 'BOOL')
                includeBreak = $false
            }
            schemata  = [pscustomobject]@{ publishStrategy = $PublishStrategy }
            rulesets  = $Rulesets
        }
    }

    function script:New-MutFakeMutantsJson {
        <#
            .SYNOPSIS
            Five mutants (ids 1-5, stable keys "key1".."key5"); used as the fixed fake
            mutants.json body written by the mocked Invoke-MutGenerator on every call.
        #>
        $mutants = 1..5 | ForEach-Object {
            [pscustomobject]@{
                id           = $_
                stableKey    = "key$_"
                objectType   = 'codeunit'
                objectId     = 50200
                objectName   = 'MUT Fx Order Mgt'
                procedure    = 'SomeProc'
                line         = $_ + 10
                operator     = 'REL'
                original     = 'A >= B'
                mutated      = 'A > B'
                file         = 'F.Codeunit.al'
            }
        }
        return , $mutants
    }

    function script:New-MutFakeLineMapJson {
        <#
            .SYNOPSIS
            "F.Codeunit.al" lines 10-15 map to mutant ids 4 and 5, per the task brief's fixture.
        #>
        return [pscustomobject]@{
            'F.Codeunit.al' = @(
                [pscustomobject]@{ mutantIds = @(4, 5); startLine = 10; endLine = 15 }
            )
        }
    }

    function script:Register-MutFakeGenerator {
        <#
            .SYNOPSIS
            Mocks Invoke-MutGenerator (the private CLI mock point in Schemata.psm1) to write a
            fixed fake mutants.json/linemap.json into the --out directory on every call, and
            records every call's Arguments into $script:generatorCalls for assertions.
        #>
        $script:generatorCalls = @()
        Mock -ModuleName Schemata Invoke-MutGenerator {
            param($Arguments)
            $script:generatorCalls += , @($Arguments)

            $outIndex = [array]::IndexOf($Arguments, '--out')
            $outDir = $Arguments[$outIndex + 1]
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null

            (New-MutFakeMutantsJson) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $outDir 'mutants.json')
            (New-MutFakeLineMapJson) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $outDir 'linemap.json')
            Set-Content -Path (Join-Path $outDir 'skipped.json') -Value '[]'
        }
    }
}

Describe 'Build-MutSchemata: compile-error loop' {
    BeforeEach {
        $script:runDir = "$TestDrive/out/runs/$(New-Guid)"
        $script:config = New-MutFakeConfig -WorkDir "$TestDrive/out"
        Register-MutFakeGenerator
    }

    It 'excludes the mutant ids mapped from a compile-error diagnostic, then succeeds on the next iteration' {
        $script:callCount = 0
        Mock -ModuleName Schemata Compile-MutApp {
            $script:callCount++
            if ($script:callCount -eq 1) {
                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @(
                        [pscustomobject]@{ Severity = 'Error'; Code = 'AL0'; File = 'F.Codeunit.al'; Line = 12; Column = 1; Message = 'boom' }
                    )
                    AppFile     = $null
                    DurationSec = 1.0
                }
            }
            return [pscustomobject]@{
                Success     = $true
                Diagnostics = @()
                AppFile     = 'C:/fake/schemata.app'
                DurationSec = 1.0
            }
        }

        $result = Build-MutSchemata -Config $script:config -Env $script:envHandle -RunDir $script:runDir -RunNo 1

        $result.CompileErrorIds | Should -Be @(4, 5)
        $result.Iterations | Should -Be 2
        $result.AppFile | Should -Be 'C:/fake/schemata.app'
        $result.SchemataPath | Should -Be (Join-Path $script:runDir 'gen/aut-schemata')
        $result.Mutants.Count | Should -Be 5
        $result.ExcludeFile | Should -Not -BeNullOrEmpty
        $result.RunNo | Should -Be 1

        (Test-Path $result.ExcludeFile) | Should -Be $true
        $excludeContent = Get-Content -Path $result.ExcludeFile -Raw | ConvertFrom-Json
        @($excludeContent.stableKeys) | Sort-Object | Should -Be @('key4', 'key5')

        $script:generatorCalls.Count | Should -Be 2
        $script:generatorCalls[0] | Should -Not -Contain '--exclude-stable-keys'
        $script:generatorCalls[1] | Should -Contain '--exclude-stable-keys'
        $excludeIndex = [array]::IndexOf($script:generatorCalls[1], '--exclude-stable-keys')
        $script:generatorCalls[1][$excludeIndex + 1] | Should -Be $result.ExcludeFile

        Should -Invoke -ModuleName Schemata Compile-MutApp -Times 2
    }

    It 'throws when a compile diagnostic does not map to any linemap block' {
        Mock -ModuleName Schemata Compile-MutApp {
            [pscustomobject]@{
                Success     = $false
                Diagnostics = @(
                    [pscustomobject]@{ Severity = 'Error'; Code = 'AL0'; File = 'Unknown.Codeunit.al'; Line = 999; Column = 1; Message = 'unmapped' }
                )
                AppFile     = $null
                DurationSec = 1.0
            }
        }

        { Build-MutSchemata -Config $script:config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 } | Should -Throw
    }

    It 'throws immediately on a diagnostic with no File/Line (a compiler-level error unrelated to any mutant), without spinning through the iteration cap' {
        Mock -ModuleName Schemata Compile-MutApp {
            [pscustomobject]@{
                Success     = $false
                Diagnostics = @(
                    [pscustomobject]@{ Severity = 'Error'; Code = 'AL1022'; File = $null; Line = $null; Column = $null; Message = 'symbol missing' }
                )
                AppFile     = $null
                DurationSec = 1.0
            }
        }

        { Build-MutSchemata -Config $script:config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 } | Should -Throw '*AL1022*'

        Should -Invoke -ModuleName Schemata Compile-MutApp -Times 1
        $script:generatorCalls.Count | Should -Be 1
    }

    It 'throws after more than 10 iterations of compile failure, with the last compile diagnostics in the error' {
        Mock -ModuleName Schemata Compile-MutApp {
            [pscustomobject]@{
                Success     = $false
                Diagnostics = @(
                    [pscustomobject]@{ Severity = 'Error'; Code = 'AL0'; File = 'F.Codeunit.al'; Line = 12; Column = 1; Message = 'boom' }
                )
                AppFile     = $null
                DurationSec = 1.0
            }
        }

        { Build-MutSchemata -Config $script:config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 } | Should -Throw '*AL0*boom*'

        Should -Invoke -ModuleName Schemata Compile-MutApp -Times 10
        $script:generatorCalls.Count | Should -Be 10
    }
}

Describe 'Build-MutSchemata: generator flags' {
    BeforeEach {
        $script:runDir = "$TestDrive/out/runs/$(New-Guid)"
        Register-MutFakeGenerator
        Mock -ModuleName Schemata Compile-MutApp {
            [pscustomobject]@{ Success = $true; Diagnostics = @(); AppFile = 'C:/fake/schemata.app'; DurationSec = 1.0 }
        }
    }

    It 'adds --aut-version with the 4th version component bumped when publishStrategy is bump-build' {
        $config = New-MutFakeConfig -WorkDir "$TestDrive/out" -PublishStrategy 'bump-build' -AutVersion '1.0.0.0'

        Build-MutSchemata -Config $config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 | Out-Null

        $args0 = $script:generatorCalls[0]
        $args0 | Should -Contain '--aut-version'
        $idx = [array]::IndexOf($args0, '--aut-version')
        $args0[$idx + 1] | Should -Be '1.0.0.1'
    }

    It 'omits --only-objects when generator.onlyObjects is empty' {
        $config = New-MutFakeConfig -WorkDir "$TestDrive/out" -OnlyObjects @()

        Build-MutSchemata -Config $config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 | Out-Null

        $script:generatorCalls[0] | Should -Not -Contain '--only-objects'
    }

    It 'passes --only-objects as a comma list when non-empty' {
        $config = New-MutFakeConfig -WorkDir "$TestDrive/out" -OnlyObjects @(111, 222)

        Build-MutSchemata -Config $config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 | Out-Null

        $args0 = $script:generatorCalls[0]
        $args0 | Should -Contain '--only-objects'
        $idx = [array]::IndexOf($args0, '--only-objects')
        $args0[$idx + 1] | Should -Be '111,222'
    }

    It 'does not add --aut-version when publishStrategy is same-version' {
        $config = New-MutFakeConfig -WorkDir "$TestDrive/out" -PublishStrategy 'same-version'

        Build-MutSchemata -Config $config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 | Out-Null

        $script:generatorCalls[0] | Should -Not -Contain '--aut-version'
    }

    It 'omits --ruleset from the compile call when config.rulesets is null' {
        $config = New-MutFakeConfig -WorkDir "$TestDrive/out" -Rulesets $null

        Build-MutSchemata -Config $config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 | Out-Null

        Should -Invoke -ModuleName Schemata Compile-MutApp -ParameterFilter {
            -not $Ruleset
        } -Times 1
    }

    It 'passes the resolved ruleset file to Compile-MutApp when config.rulesets is set' {
        $config = New-MutFakeConfig -WorkDir "$TestDrive/out" -Rulesets ([pscustomobject]@{ sourcePath = 'C:/x'; file = '.cli-ruleset-localdeploy.json' })

        Build-MutSchemata -Config $config -Env $script:envHandle -RunDir $script:runDir -RunNo 1 | Out-Null

        Should -Invoke -ModuleName Schemata Compile-MutApp -ParameterFilter {
            $Ruleset -eq (Join-Path "$TestDrive/out/rulesets" '.cli-ruleset-localdeploy.json')
        } -Times 1
    }
}
