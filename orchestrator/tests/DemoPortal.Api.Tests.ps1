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

    $script:oneUserJson = @(
        [pscustomobject]@{ id = 'U1'; description = 'Super User'; fullName = 'Test User'; username = 'RF'; password = 'p@ss' }
    )

    # Get-MutApiBase / Get-MutCredential cache their result per environment id across calls
    # within a session (by design, to avoid re-probing/re-reading credentials); reset both
    # caches before every test so one test's successful probe doesn't mask another test's
    # fallback/failure scenario for the same $envHandle.Id. Defined here (inside BeforeAll,
    # not at file top level) because Pester 5's discovery/run split only re-executes BeforeAll
    # bodies during Run — a plain top-level `function` statement is discovery-only and is gone
    # by the time It/BeforeEach blocks execute.
    function script:Reset-MutApiCaches {
        InModuleScope DemoPortal {
            $script:MutApiBaseCache = @{}
            $script:MutCredentialCache = @{}
        }
    }
}

Describe 'Invoke-MutApi' {
    BeforeEach {
        Reset-MutApiCaches
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'users' } { $script:oneUserJson }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*api/v2.0/companies*' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'C1'; name = 'CRONUS' }) }
        }
    }

    It 'builds the mutationSetup URL under /api/mutation/core/v1.0/companies(<id>)/ for a GET and sends Basic auth' {
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*mutation/core/v1.0*' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ primaryKey = 0; activeMutantId = 0; currentRunNo = 0 }) }
        }

        $result = Invoke-MutApi -Env $envHandle -Method 'GET' -Path 'mutationSetup'

        $result.value[0].activeMutantId | Should -Be 0

        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter {
            $Uri -eq 'https://demoportaldev.continiaonline.com/E1/api/mutation/core/v1.0/companies(C1)/mutationSetup' -and
            $Method -eq 'GET' -and
            $Headers['Authorization'] -match '^Basic '
        } -Times 1
    }

    It 'sends If-Match: * on a PATCH and serializes the body with ConvertTo-Json' {
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*mutation/core/v1.0*' } {
            [pscustomobject]@{ activeMutantId = 7 }
        }

        Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{ activeMutantId = 7 } | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter {
            $Uri -eq 'https://demoportaldev.continiaonline.com/E1/api/mutation/core/v1.0/companies(C1)/mutationSetup(0)' -and
            $Method -eq 'PATCH' -and
            $Headers['If-Match'] -eq '*' -and
            $Body -eq (@{ activeMutantId = 7 } | ConvertTo-Json -Depth 10)
        } -Times 1
    }

    It 'does not send an If-Match header on a GET' {
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*mutation/core/v1.0*' } {
            [pscustomobject]@{ value = @() }
        }

        Invoke-MutApi -Env $envHandle -Method 'GET' -Path 'mutationSetup' | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter {
            $Uri -like '*mutationSetup*' -and (-not $Headers.ContainsKey('If-Match'))
        } -Times 1
    }

    It 'refuses an environment not named mut-*' {
        $badEnv = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        Mock -ModuleName DemoPortal Invoke-RestMethod { throw 'must not be called' }

        { Invoke-MutApi -Env $badEnv -Method 'GET' -Path 'mutationSetup' } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -Times 0
    }

    It 'refuses a case-variant of the mut- prefix (MUT-, Mut-, mUt-)' {
        Mock -ModuleName DemoPortal Invoke-RestMethod { throw 'must not be called' }

        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            $caseEnv = [pscustomobject]@{ Id = 'E1'; Name = $badName; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
            { Invoke-MutApi -Env $caseEnv -Method 'GET' -Path 'mutationSetup' } | Should -Throw "*does not match '^mut-'*"
        }
        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -Times 0
    }
}

Describe 'Get-MutApiBase' {
    BeforeEach {
        Reset-MutApiCaches
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'users' } { $script:oneUserJson }
    }

    It 'returns $Env.Url when it answers 200 for /api/v2.0/companies' {
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://demoportaldev.continiaonline.com/E1/api/v2.0/companies' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'C1' }) }
        }

        $base = Get-MutApiBase -Env $envHandle
        $base | Should -Be 'https://demoportaldev.continiaonline.com/E1'
    }

    It 'falls back to $Env.Url + /BC when the plain URL fails' {
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://demoportaldev.continiaonline.com/E1/api/v2.0/companies' } {
            throw 'boom (404)'
        }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://demoportaldev.continiaonline.com/E1/BC/api/v2.0/companies' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'C1' }) }
        }

        $base = Get-MutApiBase -Env $envHandle
        $base | Should -Be 'https://demoportaldev.continiaonline.com/E1/BC'
    }

    It 'throws listing both attempted URLs when neither candidate works' {
        Mock -ModuleName DemoPortal Invoke-RestMethod { throw 'boom (404)' }

        { Get-MutApiBase -Env $envHandle } | Should -Throw '*https://demoportaldev.continiaonline.com/E1*https://demoportaldev.continiaonline.com/E1/BC*'
    }
}

Describe 'Get-MutCompanyId' {
    BeforeEach {
        Reset-MutApiCaches
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'users' } { $script:oneUserJson }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*api/v2.0/companies*' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'C1'; name = 'First' }, [pscustomobject]@{ id = 'C2'; name = 'Second' }) }
        }
    }

    It 'returns the id of the first company' {
        Get-MutCompanyId -Env $envHandle | Should -Be 'C1'
    }
}

Describe 'Grant-MutPermissionSet' {
    BeforeEach {
        Reset-MutApiCaches
        Mock -ModuleName DemoPortal Invoke-Continia -ParameterFilter { $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'users' } { $script:oneUserJson }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*api/v2.0/companies*' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'C1'; name = 'CRONUS' }) }
        }
    }

    It 'grants the permission set to a user who lacks it' {
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*automation/v2.0*/users' -and $Method -eq 'GET' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ userSecurityId = 'U1'; userName = 'RF' }) }
        }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*userPermissions' -and $Method -eq 'GET' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ roleId = 'SUPER'; appId = '00000000-0000-0000-0000-000000000000' }) }
        }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*userPermissions' -and $Method -eq 'POST' } {
            [pscustomobject]@{ roleId = 'MUT CORE ALL'; appId = 'APP1' }
        }

        $result = Grant-MutPermissionSet -Env $envHandle -PermissionSetId 'MUT Core All' -AppId 'APP1'

        $result.Granted | Should -Contain 'RF'
        $result.AlreadyHad | Should -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter {
            $Uri -like '*userPermissions' -and $Method -eq 'POST' -and
            $Body -eq (@{ roleId = 'MUT Core All'; appId = 'APP1'; scope = 'System' } | ConvertTo-Json -Depth 10)
        } -Times 1
    }

    It 'skips a user who already has the permission set (idempotent)' {
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*automation/v2.0*/users' -and $Method -eq 'GET' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ userSecurityId = 'U1'; userName = 'RF' }) }
        }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*userPermissions' -and $Method -eq 'GET' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ roleId = 'MUT Core All'; appId = 'APP1' }) }
        }
        Mock -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*userPermissions' -and $Method -eq 'POST' } { throw 'must not POST' }

        $result = Grant-MutPermissionSet -Env $envHandle -PermissionSetId 'MUT Core All' -AppId 'APP1'

        $result.AlreadyHad | Should -Contain 'RF'
        $result.Granted | Should -BeNullOrEmpty

        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -ParameterFilter { $Uri -like '*userPermissions' -and $Method -eq 'POST' } -Times 0
    }

    It 'refuses an environment not named mut-*' {
        $badEnv = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        Mock -ModuleName DemoPortal Invoke-RestMethod { throw 'must not be called' }

        { Grant-MutPermissionSet -Env $badEnv -PermissionSetId 'MUT Core All' -AppId 'APP1' } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -Times 0
    }

    It 'refuses a case-variant of the mut- prefix (MUT-, Mut-, mUt-)' {
        Mock -ModuleName DemoPortal Invoke-RestMethod { throw 'must not be called' }

        foreach ($badName in @('MUT-prod', 'Mut-prod', 'mUt-prod')) {
            $caseEnv = [pscustomobject]@{ Id = 'E1'; Name = $badName; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
            { Grant-MutPermissionSet -Env $caseEnv -PermissionSetId 'MUT Core All' -AppId 'APP1' } | Should -Throw "*does not match '^mut-'*"
        }
        Should -Invoke -ModuleName DemoPortal Invoke-RestMethod -Times 0
    }
}
