Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force

    $script:envHandle = [pscustomobject]@{
        Id      = 'E1'
        Name    = 'mut-spike-01'
        Url     = 'https://demoportaldev.continiaonline.com/E1'
        Backend = 'DemoPortal'
        Shared  = $false
        Status  = 'Running'
        CliPath = './.tools/continia.exe'
    }
    $envHandle = $script:envHandle

    $script:badEnv = [pscustomobject]@{
        Id = 'E1'; Name = 'fix-auth-share-sibling-apply'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false
    }
    $badEnv = $script:badEnv

    function script:New-MutTestAppFile {
        param([string]$Dir, [string]$Name, [datetime]$LastWriteTime)
        $path = Join-Path $Dir $Name
        Set-Content -Path $path -Value 'binary-app-stub'
        (Get-Item $path).LastWriteTime = $LastWriteTime
        return $path
    }
}

Describe 'Install-MutDependencies' {
    It 'calls deps install <id> <AppPath> --json and returns the parsed JSON' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        $result = Install-MutDependencies -Env $envHandle -AppPath 'C:/out/aut-original'

        $result.success | Should -Be $true

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'deps' -and $Arguments[1] -eq 'install' -and $Arguments[2] -eq 'E1' -and
            $Arguments[3] -eq 'C:/out/aut-original' -and $Arguments -contains '--json'
        } -Times 1
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Install-MutDependencies -Env $badEnv -AppPath 'C:/out/aut-original' } | Should -Throw
    }
}

Describe 'Compile-MutApp' {
    It 'maps diagnostics to PascalCase properties and reports Success=$false when diagnosticCounts.error > 0' {
        $dir = "$TestDrive/compile-fail"
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-MutTestAppFile -Dir $dir -Name 'old.app' -LastWriteTime (Get-Date).AddMinutes(-10) | Out-Null
        $newest = New-MutTestAppFile -Dir $dir -Name 'new.app' -LastWriteTime (Get-Date)

        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                exitCode         = 1
                diagnosticCounts = [pscustomobject]@{ error = 2; warning = 0; info = 0 }
                diagnostics      = @(
                    [pscustomobject]@{ severity = 'error'; code = 'AA0139'; file = 'Foo.Codeunit.al'; line = 10; column = 5; message = 'Bad thing one.' }
                    [pscustomobject]@{ severity = 'error'; code = 'AA0137'; file = 'Bar.Codeunit.al'; line = 20; column = 1; message = 'Bad thing two.' }
                )
            }
        }

        $result = Compile-MutApp -Env $envHandle -Path $dir

        $result.Success | Should -Be $false
        $result.Diagnostics.Count | Should -Be 2
        $result.Diagnostics[0].Severity | Should -Be 'error'
        $result.Diagnostics[0].Code | Should -Be 'AA0139'
        $result.Diagnostics[0].File | Should -Be 'Foo.Codeunit.al'
        $result.Diagnostics[0].Line | Should -Be 10
        $result.Diagnostics[0].Column | Should -Be 5
        $result.Diagnostics[0].Message | Should -Be 'Bad thing one.'
        $result.Diagnostics[1].Code | Should -Be 'AA0137'
        $result.AppFile | Should -Be $newest
        $result.DurationSec | Should -Not -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'compile' -and $Arguments[1] -eq $dir -and $Arguments -contains '--json' -and
            $Arguments -contains '--no-raw-output' -and -not ($Arguments -contains '--ruleset')
        } -Times 1
    }

    It 'passes --ruleset only when given' {
        $dir = "$TestDrive/compile-ruleset"
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-MutTestAppFile -Dir $dir -Name 'x.app' -LastWriteTime (Get-Date) | Out-Null

        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ diagnosticCounts = [pscustomobject]@{ error = 0 }; diagnostics = @() }
        }

        Compile-MutApp -Env $envHandle -Path $dir -Ruleset 'C:/out/rulesets/.cli-ruleset-localdeploy.json' | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments -contains '--ruleset' -and ($Arguments[$Arguments.IndexOf('--ruleset') + 1]) -eq 'C:/out/rulesets/.cli-ruleset-localdeploy.json'
        } -Times 1
    }

    It 'reports Success=$true when diagnosticCounts.error is 0 and an app file exists' {
        $dir = "$TestDrive/compile-ok"
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-MutTestAppFile -Dir $dir -Name 'ok.app' -LastWriteTime (Get-Date) | Out-Null

        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ diagnosticCounts = [pscustomobject]@{ error = 0 }; diagnostics = @() }
        }

        $result = Compile-MutApp -Env $envHandle -Path $dir

        $result.Success | Should -Be $true
    }

    It 'reports Success=$false when diagnosticCounts.error is 0 but no app file was produced' {
        $dir = "$TestDrive/compile-no-app"
        New-Item -ItemType Directory -Path $dir | Out-Null

        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ diagnosticCounts = [pscustomobject]@{ error = 0 }; diagnostics = @() }
        }

        $result = Compile-MutApp -Env $envHandle -Path $dir

        $result.Success | Should -Be $false
        $result.AppFile | Should -BeNullOrEmpty
    }

    It 'returns Success=$false with Code and ErrorMessage from the single-object run-level failure shape (M6)' {
        $dir = "$TestDrive/compile-run-level-failure"
        New-Item -ItemType Directory -Path $dir | Out-Null

        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                success = $false
                error   = [pscustomobject]@{ code = 'symbol-fetch-failed'; message = 'dev-endpoint package failed validation (28.1.49838.50268)' }
            }
        }

        $result = Compile-MutApp -Env $envHandle -Path $dir

        $result.Success | Should -Be $false
        $result.Code | Should -Be 'symbol-fetch-failed'
        $result.ErrorMessage | Should -Be 'dev-endpoint package failed validation (28.1.49838.50268)'
        $result.Diagnostics.Count | Should -Be 0
        $result.AppFile | Should -BeNullOrEmpty
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Compile-MutApp -Env $badEnv -Path "$TestDrive/whatever" } | Should -Throw
    }

    It 'forwards TimeoutSec to Invoke-Continia, defaulting to 900' {
        $dir = "$TestDrive/compile-timeout-default"
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-MutTestAppFile -Dir $dir -Name 'x.app' -LastWriteTime (Get-Date) | Out-Null

        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ diagnosticCounts = [pscustomobject]@{ error = 0 }; diagnostics = @() }
        }

        Compile-MutApp -Env $envHandle -Path $dir | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $TimeoutSec -eq 900
        } -Times 1
    }

    It 'forwards an explicit TimeoutSec to Invoke-Continia' {
        $dir = "$TestDrive/compile-timeout-explicit"
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-MutTestAppFile -Dir $dir -Name 'x.app' -LastWriteTime (Get-Date) | Out-Null

        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{ diagnosticCounts = [pscustomobject]@{ error = 0 }; diagnostics = @() }
        }

        Compile-MutApp -Env $envHandle -Path $dir -TimeoutSec 120 | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $TimeoutSec -eq 120
        } -Times 1
    }
}

Describe 'Publish-MutApp' {
    BeforeEach {
        $script:dir = "$TestDrive/publish-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:dir | Out-Null
    }

    It 'passes neither --allow-downgrade nor --ruleset when neither is given' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @([pscustomobject]@{ app = 'X'; compiled = $true; published = $true; code = $null })
        }

        Publish-MutApp -Env $envHandle -Path $script:dir | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'deploy' -and $Arguments[1] -eq 'E1' -and $Arguments[2] -eq $script:dir -and
            $Arguments -contains '--json' -and
            -not ($Arguments -contains '--allow-downgrade') -and
            -not ($Arguments -contains '--ruleset')
        } -Times 1
    }

    It 'passes --allow-downgrade only when the switch is set and --ruleset only when given' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @([pscustomobject]@{ app = 'X'; compiled = $true; published = $true; code = $null })
        }

        Publish-MutApp -Env $envHandle -Path $script:dir -Ruleset 'C:/out/rulesets/.cli-ruleset-localdeploy.json' -AllowDowngrade -SyncMode 'ForceSync' | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments -contains '--allow-downgrade' -and
            $Arguments -contains '--ruleset' -and ($Arguments[$Arguments.IndexOf('--ruleset') + 1]) -eq 'C:/out/rulesets/.cli-ruleset-localdeploy.json' -and
            $Arguments -contains '--sync-mode' -and ($Arguments[$Arguments.IndexOf('--sync-mode') + 1]) -eq 'ForceSync'
        } -Times 1
    }

    It 'reads the first row of the returned array: Success from published, Code from code, Diagnostics mapped' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @(
                [pscustomobject]@{
                    app         = 'Continia Software_AUT'
                    compiled    = $true
                    published   = $true
                    code        = $null
                    diagnostics = @([pscustomobject]@{ severity = 'warning'; code = 'AA0470'; file = 'A.al'; line = 1; column = 1; message = 'warn' })
                }
                [pscustomobject]@{ app = 'Second_App'; compiled = $true; published = $true; code = $null }
            )
        }

        $result = Publish-MutApp -Env $envHandle -Path $script:dir

        $result.Success | Should -Be $true
        $result.Code | Should -BeNullOrEmpty
        $result.Diagnostics.Count | Should -Be 1
        $result.Diagnostics[0].Code | Should -Be 'AA0470'
        $result.DurationSec | Should -Not -BeNullOrEmpty
    }

    It 'reports Success=$false with the row Code when publish fails' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @([pscustomobject]@{ app = 'X'; compiled = $false; published = $false; code = 'compile-failed' })
        }

        $result = Publish-MutApp -Env $envHandle -Path $script:dir

        $result.Success | Should -Be $false
        $result.Code | Should -Be 'compile-failed'
    }

    It 'returns Success=$false with Code and ErrorMessage from the single-object run-level failure shape (M6)' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                success = $false
                error   = [pscustomobject]@{ code = 'symbol-fetch-failed'; message = 'dev-endpoint package failed validation (28.1.49838.50268)' }
            }
        }

        $result = Publish-MutApp -Env $envHandle -Path $script:dir

        $result.Success | Should -Be $false
        $result.Code | Should -Be 'symbol-fetch-failed'
        $result.ErrorMessage | Should -Be 'dev-endpoint package failed validation (28.1.49838.50268)'
        $result.Diagnostics.Count | Should -Be 0
    }

    It 'carries the row-level error string into ErrorMessage on the array path even with empty diagnostics (M6)' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @([pscustomobject]@{
                app         = 'X'
                compiled    = $true
                published   = $false
                code        = 'publish-failed'
                diagnostics = @()
                error       = "Extension compilation failed ... error AL0185: Codeunit 'Assert' is missing"
            })
        }

        $result = Publish-MutApp -Env $envHandle -Path $script:dir

        $result.Success | Should -Be $false
        $result.Code | Should -Be 'publish-failed'
        $result.Diagnostics.Count | Should -Be 0
        $result.ErrorMessage | Should -Be "Extension compilation failed ... error AL0185: Codeunit 'Assert' is missing"
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Publish-MutApp -Env $badEnv -Path $script:dir } | Should -Throw
    }

    It 'forwards TimeoutSec to Invoke-Continia, defaulting to 900' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @([pscustomobject]@{ app = 'X'; compiled = $true; published = $true; code = $null })
        }

        Publish-MutApp -Env $envHandle -Path $script:dir | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $TimeoutSec -eq 900
        } -Times 1
    }

    It 'forwards an explicit TimeoutSec to Invoke-Continia' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            @([pscustomobject]@{ app = 'X'; compiled = $true; published = $true; code = $null })
        }

        Publish-MutApp -Env $envHandle -Path $script:dir -TimeoutSec 300 | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $TimeoutSec -eq 300
        } -Times 1
    }
}

Describe 'Publish-MutAppFile' {
    It 'calls publish <id> <appFile> --json and maps Success from the response' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        $result = Publish-MutAppFile -Env $envHandle -AppFile 'C:/out/schemata.app'

        $result.Success | Should -Be $true
        $result.DurationSec | Should -Not -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'publish' -and $Arguments[1] -eq 'E1' -and $Arguments[2] -eq 'C:/out/schemata.app' -and
            $Arguments -contains '--json' -and -not ($Arguments -contains '--sync-mode')
        } -Times 1
    }

    It 'passes --sync-mode only when given' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        Publish-MutAppFile -Env $envHandle -AppFile 'C:/out/schemata.app' -SyncMode 'ForceSync' | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments -contains '--sync-mode' -and ($Arguments[$Arguments.IndexOf('--sync-mode') + 1]) -eq 'ForceSync'
        } -Times 1
    }

    It 'reports Success=$false when the response has success=$false' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $false } }

        (Publish-MutAppFile -Env $envHandle -AppFile 'C:/out/schemata.app').Success | Should -Be $false
    }

    It 'returns Success=$false with Code and ErrorMessage from the single-object run-level failure shape (M6)' {
        Mock -ModuleName DemoPortal Invoke-Continia {
            [pscustomobject]@{
                success = $false
                error   = [pscustomobject]@{ code = 'app-lock-held'; message = 'the file is locked by another process' }
            }
        }

        $result = Publish-MutAppFile -Env $envHandle -AppFile 'C:/out/schemata.app'

        $result.Success | Should -Be $false
        $result.Code | Should -Be 'app-lock-held'
        $result.ErrorMessage | Should -Be 'the file is locked by another process'
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Publish-MutAppFile -Env $badEnv -AppFile 'C:/out/schemata.app' } | Should -Throw
    }
}

Describe 'Unpublish-MutApp' {
    It 'calls unpublish <id> --app-id <AppId> --json and maps Success' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        $result = Unpublish-MutApp -Env $envHandle -AppId '02b81fad-90fa-4cdc-a414-5bda25e96db0'

        $result.Success | Should -Be $true

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments[0] -eq 'unpublish' -and $Arguments[1] -eq 'E1' -and
            $Arguments -contains '--app-id' -and ($Arguments[$Arguments.IndexOf('--app-id') + 1]) -eq '02b81fad-90fa-4cdc-a414-5bda25e96db0' -and
            $Arguments -contains '--json' -and -not ($Arguments -contains '--app-version')
        } -Times 1
    }

    It 'passes --app-version only when given' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $true } }

        Unpublish-MutApp -Env $envHandle -AppId '02b81fad-90fa-4cdc-a414-5bda25e96db0' -Version '28.5.0.0' | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-Continia -ParameterFilter {
            $Arguments -contains '--app-version' -and ($Arguments[$Arguments.IndexOf('--app-version') + 1]) -eq '28.5.0.0'
        } -Times 1
    }

    It 'reports Success=$false when the response has success=$false' {
        Mock -ModuleName DemoPortal Invoke-Continia { [pscustomobject]@{ success = $false } }

        (Unpublish-MutApp -Env $envHandle -AppId '02b81fad-90fa-4cdc-a414-5bda25e96db0').Success | Should -Be $false
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-Continia { throw 'must not be called' }

        { Unpublish-MutApp -Env $badEnv -AppId 'x' } | Should -Throw
    }
}
