Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module "$PSScriptRoot/../backends/DemoPortal.psm1" -Force -WarningAction SilentlyContinue

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

    # Runs a block in the DemoPortal module's scope so private functions (Invoke-MutSoap, ...) can be
    # called, and so Mock -ModuleName DemoPortal applies to the calls the block makes.
    function script:Invoke-InModule {
        param([scriptblock]$Block, [object[]]$ArgumentList = @())
        & (Get-Module DemoPortal) $Block @ArgumentList
    }

    # Seeds the three per-environment caches so no CLI/API call is needed for credentials, base URL
    # and company name (Invoke-MutSoap's own tests mock only Invoke-WebRequest).
    function script:Initialize-SoapCaches {
        Invoke-InModule {
            $script:MutCredentialCache = @{ 'E1' = (New-Object System.Management.Automation.PSCredential('RF', (ConvertTo-SecureString 'sup3r-s3cret' -AsPlainText -Force))) }
            $script:MutApiBaseCache = @{ 'E1' = 'https://demoportaldev.continiaonline.com/E1' }
            $script:MutCompanyCache = @{ 'E1' = @{ Id = 'C1'; Name = 'CRONUS International Ltd.' } }
        }
    }

    function script:New-SoapOk {
        param([string]$ReturnValue)
        $escaped = [System.Security.SecurityElement]::Escape($ReturnValue)
        [pscustomobject]@{
            StatusCode = 200
            Content    = "<?xml version=`"1.0`" encoding=`"utf-8`"?><Soap:Envelope xmlns:Soap=`"http://schemas.xmlsoap.org/soap/envelope/`"><Soap:Body><RunTests_Result xmlns=`"urn:microsoft-dynamics-schemas/codeunit/MUTRunner`"><return_value>$escaped</return_value></RunTests_Result></Soap:Body></Soap:Envelope>"
        }
    }

    function script:New-WebException {
        param([System.Net.WebExceptionStatus]$Status, [string]$Message = 'localized message')
        [System.Net.WebException]::new($Message, $null, $Status, $null)
    }

    # Shapes returned by the (mocked) private Invoke-MutSoap.
    function script:New-SoapResult {
        param($Value = $null, [string]$Fault = $null, [switch]$TimedOut, [switch]$Dropped)
        $failed = ([bool]$Fault -or $TimedOut -or $Dropped)
        [pscustomobject]@{ Ok = (-not $failed); Value = $Value; Fault = $Fault; TimedOut = [bool]$TimedOut; Dropped = [bool]$Dropped; DurationMs = 5 }
    }

    function script:New-RunnerStateJson {
        param([string]$ServerNow = '2026-10-04T20:43:43.0700000Z', $Rows = @())
        ([pscustomobject]@{ serverNowUtc = $ServerNow; rows = @($Rows) } | ConvertTo-Json -Depth 10 -Compress)
    }

    function script:New-StateRow {
        param([string]$BatchId = 'B1', [int]$MutantId = 0, [string]$StartedAt = '', [int]$Done = 0, [bool]$Finished = $false, [int]$SessionId = 77, [int]$RunNo = 5)
        [pscustomobject]@{ batchId = $BatchId; sessionId = $SessionId; runNo = $RunNo; mutantId = $MutantId; mutantStartedAt = $StartedAt; mutantsDone = $Done; finished = $Finished }
    }
}

Describe 'Invoke-MutSoap' {
    BeforeEach {
        Initialize-SoapCaches
    }

    It 'POSTs a SOAP envelope to the escaped-company MUTRunner service URL with SOAPAction and Basic auth' {
        $resp = New-SoapOk -ReturnValue 'hello'
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ $resp }.GetNewClosure())

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunTests' -Arguments @{ codeunitIds = '95155' } } @($envHandle)

        $r.Ok | Should -BeTrue
        $r.Value | Should -Be 'hello'
        $r.Fault | Should -BeNullOrEmpty
        $r.TimedOut | Should -BeFalse
        $r.Dropped | Should -BeFalse
        $r.DurationMs | Should -BeGreaterOrEqual 0

        Should -Invoke -ModuleName DemoPortal Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://demoportaldev.continiaonline.com/E1/WS/CRONUS%20International%20Ltd./Codeunit/MUTRunner' -and
            $Method -eq 'Post' -and
            $Headers['SOAPAction'] -eq 'urn:microsoft-dynamics-schemas/codeunit/MUTRunner:RunTests' -and
            $Headers['Authorization'] -match '^Basic ' -and
            $ContentType -like 'text/xml*' -and
            $Body -like '*xmlns:x="urn:microsoft-dynamics-schemas/codeunit/MUTRunner"*<x:RunTests><x:codeunitIds>95155</x:codeunitIds></x:RunTests>*'
        }
    }

    It 'XML-escapes argument values' {
        $resp = New-SoapOk -ReturnValue 'x'
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ $resp }.GetNewClosure())

        Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunTests' -Arguments @{ codeunitIds = '95155|<95110>&"x"' } } @($envHandle) | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Body -like '*<x:codeunitIds>95155|&lt;95110&gt;&amp;&quot;x&quot;</x:codeunitIds>*'
        }
    }

    It 'sends the arguments in the order of an ordered dictionary (BC SOAP binds by sequence, not by name)' {
        $resp = New-SoapOk -ReturnValue 'x'
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ $resp }.GetNewClosure())

        Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunMutants' -Arguments ([ordered]@{ zeta = 'Z'; batchId = 'B'; alpha = 'A' }) } @($envHandle) | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Body -like '*<x:RunMutants><x:zeta>Z</x:zeta><x:batchId>B</x:batchId><x:alpha>A</x:alpha></x:RunMutants>*'
        }
    }

    It 'passes the client timeout to Invoke-WebRequest (default 600 s)' {
        $resp = New-SoapOk -ReturnValue 'x'
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ $resp }.GetNewClosure())

        Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} -TimeoutSec 42 } @($envHandle) | Out-Null
        Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle) | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 42 }
        Should -Invoke -ModuleName DemoPortal Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 600 }
    }

    It 'returns the XML-unescaped return_value text (JSON survives the round trip)' {
        $json = '{"a":"<b> & c","n":1}'
        $resp = New-SoapOk -ReturnValue $json
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ $resp }.GetNewClosure())

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunTests' -Arguments @{ codeunitIds = '1' } } @($envHandle)

        $r.Value | Should -Be $json
    }

    It 'returns Ok with a null Value when the response has no return_value' {
        Mock -ModuleName DemoPortal Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '<Envelope><Body><X_Result/></Body></Envelope>' } }

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'X' -Arguments @{} } @($envHandle)

        $r.Ok | Should -BeTrue
        $r.Value | Should -BeNullOrEmpty
    }

    It 'maps a SOAP fault (HTTP 500 with <faultstring>) to Fault, not a throw' {
        $record = [System.Management.Automation.ErrorRecord]::new((New-WebException -Status ProtocolError), 'WebCmdletWebResponseException', 'InvalidOperation', $null)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('<s:Fault><faultcode>s:Client</faultcode><faultstring xml:lang="en-US">Batch not found</faultstring></s:Fault>')
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $record }.GetNewClosure())
        Mock -ModuleName DemoPortal Get-MutWebFailure {
            [pscustomobject]@{ IsWebError = $true; Status = 'ProtocolError'; StatusCode = 500; Body = '<s:Fault><faultstring xml:lang="en-US">Batch not found</faultstring></s:Fault>' }
        }

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'StopRunner' -Arguments @{ batchId = 'b' } } @($envHandle)

        $r.Ok | Should -BeFalse
        $r.Fault | Should -Be 'Batch not found'
        $r.TimedOut | Should -BeFalse
        $r.Dropped | Should -BeFalse
    }

    It 'sets TimedOut on a client timeout (WebException Status Timeout)' {
        $thrown = New-WebException -Status Timeout
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunMutants' -Arguments @{ batchId = 'b' } -TimeoutSec 1 } @($envHandle)

        $r.Ok | Should -BeFalse
        $r.TimedOut | Should -BeTrue
        $r.Dropped | Should -BeFalse
        $r.Fault | Should -BeNullOrEmpty
    }

    It 'sets Dropped when the connection is closed before a response (<status>)' -ForEach @(
        @{ status = 'ConnectionClosed' }
        @{ status = 'KeepAliveFailure' }
        @{ status = 'ReceiveFailure' }
    ) {
        $thrown = New-WebException -Status ([System.Net.WebExceptionStatus]$status)
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunMutants' -Arguments @{ batchId = 'b' } } @($envHandle)

        $r.Ok | Should -BeFalse
        $r.Dropped | Should -BeTrue
        $r.TimedOut | Should -BeFalse
    }

    It 'throws on HTTP 503 (outage)' {
        $thrown = New-WebException -Status ProtocolError
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())
        Mock -ModuleName DemoPortal Get-MutWebFailure {
            [pscustomobject]@{ IsWebError = $true; Status = 'ProtocolError'; StatusCode = 503; Body = '' }
        }

        { Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle) } | Should -Throw '*503*'

        $caught = $null
        try { Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle) } catch { $caught = $_ }
        $caught.Exception.Data['MutSoapOutage'] | Should -BeTrue
    }

    It 'throws when there is no connection at all (<status>)' -ForEach @(
        @{ status = 'NameResolutionFailure' }
        @{ status = 'ConnectFailure' }
    ) {
        $thrown = New-WebException -Status ([System.Net.WebExceptionStatus]$status)
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())

        { Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle) } | Should -Throw "*$status*"
    }

    It 'maps a 5xx without a faultstring (<code> from a gateway) to Dropped, never to Fault' -ForEach @(
        @{ code = 500 }
        @{ code = 502 }
        @{ code = 504 }
    ) {
        $thrown = New-WebException -Status ProtocolError
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())
        $code2 = $code
        Mock -ModuleName DemoPortal Get-MutWebFailure ({ [pscustomobject]@{ IsWebError = $true; Status = 'ProtocolError'; StatusCode = $code2; Body = '<html>Bad Gateway</html>' } }.GetNewClosure())

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunMutants' -Arguments @{ batchId = 'b' } } @($envHandle)

        $r.Ok | Should -BeFalse
        $r.Dropped | Should -BeTrue
        $r.Fault | Should -BeNullOrEmpty
        $r.TimedOut | Should -BeFalse
    }

    It 'a 500 WITH a faultstring is still a Fault' {
        $thrown = New-WebException -Status ProtocolError
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())
        Mock -ModuleName DemoPortal Get-MutWebFailure { [pscustomobject]@{ IsWebError = $true; Status = 'ProtocolError'; StatusCode = 500; Body = '<faultstring>Error in codeunit</faultstring>' } }

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'RunMutants' -Arguments @{ batchId = 'b' } } @($envHandle)

        $r.Fault | Should -Be 'Error in codeunit'
        $r.Dropped | Should -BeFalse
    }

    It 'a 404 (service missing) is neither Ok, Fault nor Dropped, and carries HttpStatus' {
        $thrown = New-WebException -Status ProtocolError
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())
        Mock -ModuleName DemoPortal Get-MutWebFailure { [pscustomobject]@{ IsWebError = $true; Status = 'ProtocolError'; StatusCode = 404; Body = '' } }

        $r = Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle)

        $r.Ok | Should -BeFalse
        $r.Fault | Should -BeNullOrEmpty
        $r.Dropped | Should -BeFalse
        $r.TimedOut | Should -BeFalse
        $r.HttpStatus | Should -Be 404
    }

    It 'throws on HTTP <code> (a credential problem is not "service missing")' -ForEach @(
        @{ code = 401 }
        @{ code = 403 }
    ) {
        $thrown = New-WebException -Status ProtocolError
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())
        $code2 = $code
        Mock -ModuleName DemoPortal Get-MutWebFailure ({ [pscustomobject]@{ IsWebError = $true; Status = 'ProtocolError'; StatusCode = $code2; Body = '' } }.GetNewClosure())

        { Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle) } | Should -Throw "*HTTP $code*"
    }

    It 'throws on an unexpected non-web exception' {
        Mock -ModuleName DemoPortal Invoke-WebRequest { throw 'something else' }

        { Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle) } | Should -Throw '*something else*'
    }

    It 'never puts the password or the Authorization header into a thrown error' {
        $thrown = New-WebException -Status ConnectFailure
        Mock -ModuleName DemoPortal Invoke-WebRequest ({ throw $thrown }.GetNewClosure())

        $message = ''
        try { Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($envHandle) }
        catch { $message = $_ | Out-String }

        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match 'sup3r-s3cret'
        $message | Should -Not -Match 'Basic '
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-WebRequest { throw 'must not be called' }
        $bad = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }

        { Invoke-InModule { param($e) Invoke-MutSoap -Env $e -Operation 'GetRunnerState' -Arguments @{} } @($bad) } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-WebRequest -Times 0
    }
}

Describe 'Get-MutWebFailure' {
    It 'reads Status from a WebException and the body from ErrorDetails' {
        $ex = New-WebException -Status Timeout
        $record = [System.Management.Automation.ErrorRecord]::new($ex, 'x', 'InvalidOperation', $null)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('<faultstring>boom</faultstring>')

        $f = Invoke-InModule { param($r) Get-MutWebFailure -ErrorRecord $r } @($record)

        $f.IsWebError | Should -BeTrue
        $f.Status | Should -Be 'Timeout'
        $f.StatusCode | Should -BeNullOrEmpty
        $f.Body | Should -Be '<faultstring>boom</faultstring>'
    }

    It 'reports a non-web exception as IsWebError false' {
        $record = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('x'), 'x', 'InvalidOperation', $null)

        $f = Invoke-InModule { param($r) Get-MutWebFailure -ErrorRecord $r } @($record)

        $f.IsWebError | Should -BeFalse
        $f.Status | Should -BeNullOrEmpty
    }
}

Describe 'Get-MutRunnerState' {
    It 'parses serverNowUtc as UTC and each row, with an empty mutantStartedAt as $null' {
        $json = New-RunnerStateJson -Rows @(
            (New-StateRow -BatchId 'B1' -MutantId 12 -StartedAt '2026-10-04T20:43:40.5000000Z' -Done 3),
            (New-StateRow -BatchId 'B2' -MutantId 0 -StartedAt '' -Finished $true)
        )
        $result = New-SoapResult -Value $json
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())

        $state = Get-MutRunnerState -Env $envHandle

        $state.ServerNowUtc | Should -BeOfType [datetime]
        $state.ServerNowUtc.Kind | Should -Be 'Utc'
        $state.ServerNowUtc.ToString('o') | Should -Be '2026-10-04T20:43:43.0700000Z'
        @($state.Rows).Count | Should -Be 2
        $state.Rows[0].BatchId | Should -Be 'B1'
        $state.Rows[0].MutantId | Should -Be 12
        $state.Rows[0].MutantsDone | Should -Be 3
        $state.Rows[0].Finished | Should -BeFalse
        $state.Rows[0].MutantStartedAt.ToString('o') | Should -Be '2026-10-04T20:43:40.5000000Z'
        $state.Rows[1].MutantStartedAt | Should -BeNullOrEmpty
        $state.Rows[1].Finished | Should -BeTrue
        Should -Invoke -ModuleName DemoPortal Invoke-MutSoap -Times 1 -Exactly -ParameterFilter { $Operation -eq 'GetRunnerState' }
    }

    It 'returns an empty Rows array when there are no rows' {
        $result = New-SoapResult -Value (New-RunnerStateJson)
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())

        $state = Get-MutRunnerState -Env $envHandle

        @($state.Rows).Count | Should -Be 0
    }

    It 'calls GetRunnerState with a 30 s client timeout, not the 600 s default' {
        $result = New-SoapResult -Value (New-RunnerStateJson)
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())

        Get-MutRunnerState -Env $envHandle | Out-Null

        Should -Invoke -ModuleName DemoPortal Invoke-MutSoap -Times 1 -Exactly -ParameterFilter { $Operation -eq 'GetRunnerState' -and $TimeoutSec -eq 30 }
    }

    It 'throws when the call faults' {
        $result = New-SoapResult -Fault 'no such service'
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())

        { Get-MutRunnerState -Env $envHandle } | Should -Throw '*no such service*'
    }

    It 'parses datetimes with the invariant culture whatever the machine locale' {
        $json = New-RunnerStateJson -ServerNow '2026-10-04T20:43:43.0700000Z' -Rows @((New-StateRow -MutantId 1 -StartedAt '2026-10-04T20:43:42.0000000Z'))
        $result = New-SoapResult -Value $json
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('da-DK')
            $state = Get-MutRunnerState -Env $envHandle
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous }

        ($state.ServerNowUtc - $state.Rows[0].MutantStartedAt).TotalSeconds | Should -BeGreaterThan 1.0
        ($state.ServerNowUtc - $state.Rows[0].MutantStartedAt).TotalSeconds | Should -BeLessThan 1.2
    }
}

Describe 'Test-MutSoapRunner' {
    It 'is true when GetRunnerState answers without a fault' {
        $result = New-SoapResult -Value (New-RunnerStateJson)
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())
        Test-MutSoapRunner -Env $envHandle | Should -BeTrue
    }

    It 'is false on a fault (Mutation Core older than 1.1.0.0 or the service missing)' {
        $result = New-SoapResult -Fault 'HTTP 404'
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())
        Test-MutSoapRunner -Env $envHandle | Should -BeFalse
    }

    It 'is false on a timed-out call' {
        $result = New-SoapResult -TimedOut
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())
        Test-MutSoapRunner -Env $envHandle | Should -BeFalse
    }

    It 'lets an outage throw propagate (it is not "service missing")' {
        Mock -ModuleName DemoPortal Invoke-MutSoap { throw 'HTTP 503' }
        { Test-MutSoapRunner -Env $envHandle } | Should -Throw '*503*'
    }
}

Describe 'Stop-MutRunnerBatch' {
    BeforeEach {
        $script:soapCalls = [System.Collections.Generic.List[object]]::new()
        $script:healthResults = @()
        $script:healthIndex = 0
        $script:stopResult = New-SoapResult -Value 'stopped'
        $script:deleteResult = New-SoapResult -Value 'deleted'
        # The batch row as GetRunnerState shows it on the n-th call (default: a stopped runner, unchanged).
        $script:stateCallNo = 0
        $script:stopStateFn = { param($n) New-RunnerStateJson -Rows @((New-StateRow -BatchId 'B1' -MutantId 12 -StartedAt '2026-10-04T20:43:40.0000000Z' -Done 1)) }
        Mock -ModuleName DemoPortal Invoke-MutSoap {
            $script:soapCalls.Add([pscustomobject]@{ Operation = $Operation; Arguments = $Arguments; TimeoutSec = $TimeoutSec })
            switch ($Operation) {
                'StopRunner' { return $script:stopResult }
                'DeleteRunnerState' { return $script:deleteResult }
                'GetRunnerState' {
                    $script:stateCallNo++
                    return (New-SoapResult -Value (& $script:stopStateFn $script:stateCallNo))
                }
                'RunTests' {
                    $i = [math]::Min($script:healthIndex, $script:healthResults.Count - 1)
                    $script:healthIndex++
                    return $script:healthResults[$i]
                }
            }
        }
    }

    It 'calls StopRunner with the BatchId, then confirms with RunTests of the first covering codeunit failed = 0, then DeleteRunnerState' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":100,"tests":[]}'))

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155|95110' -PollIntervalSec 0.01 -ConfirmWindowSec 2

        $r.Confirmed | Should -BeTrue
        $ops = @($script:soapCalls | ForEach-Object { $_.Operation })
        $ops | Should -Be @('StopRunner', 'GetRunnerState', 'RunTests', 'GetRunnerState', 'DeleteRunnerState')
        $script:soapCalls[0].Arguments['batchId'] | Should -Be 'B1'
        $script:soapCalls[2].Arguments['codeunitIds'] | Should -Be '95155'
        $script:soapCalls[2].TimeoutSec | Should -Be 2
        $script:soapCalls[4].Arguments['batchId'] | Should -Be 'B1'
    }

    It 'gives StopRunner, GetRunnerState and DeleteRunnerState a 30 s client timeout' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":100,"tests":[]}'))

        Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 2 | Out-Null

        @($script:soapCalls | Where-Object { $_.Operation -ne 'RunTests' }).Count | Should -BeGreaterThan 2
        @($script:soapCalls | Where-Object { $_.Operation -ne 'RunTests' } | ForEach-Object { $_.TimeoutSec }) | ForEach-Object { $_ | Should -Be 30 }
    }

    It 'a health call with passed = 0 (no test ran) does not confirm the stop' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":0,"failed":0,"durationMs":1,"tests":[]}'))

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 0.3

        $r.Confirmed | Should -BeFalse
        @($script:soapCalls | Where-Object Operation -eq 'DeleteRunnerState').Count | Should -Be 0
    }

    It 'does not confirm while the row''s (mutantId, mutantsDone) moves after StopRunner (the runner is still alive)' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":1,"tests":[]}'))
        $script:stopStateFn = { param($n) New-RunnerStateJson -Rows @((New-StateRow -BatchId 'B1' -MutantId (12 + $n) -StartedAt '2026-10-04T20:43:40.0000000Z' -Done $n)) }

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 0.3

        $r.Confirmed | Should -BeFalse
        @($script:soapCalls | Where-Object Operation -eq 'DeleteRunnerState').Count | Should -Be 0
    }

    It 'does not confirm while the runner state cannot be read (no proof the row stopped moving)' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":1,"tests":[]}'))
        $script:stopStateFn = { param($n) throw 'state read failure' }

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 0.3

        $r.Confirmed | Should -BeFalse
        @($script:soapCalls | Where-Object Operation -eq 'DeleteRunnerState').Count | Should -Be 0
    }

    It 'confirms once the row has stopped moving, compared with the state read after the last move' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":1,"tests":[]}'))
        # Call 1 (right after StopRunner): mutant 12; call 2: the runner wrote one more mutant; then unchanged.
        $script:stopStateFn = {
            param($n)
            if ($n -eq 1) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId 'B1' -MutantId 12 -Done 1)) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId 'B1' -MutantId 13 -Done 2))
        }

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 2

        $r.Confirmed | Should -BeTrue
        @($script:soapCalls | Where-Object Operation -eq 'RunTests').Count | Should -Be 2
    }

    It 'gives each health call min(HealthTimeoutSec, remaining window) so the last call cannot overrun the window' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":1,"failed":1,"durationMs":1,"tests":[]}'))

        Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 1.5 -HealthTimeoutSec 30 | Out-Null
        $first = @($script:soapCalls | Where-Object Operation -eq 'RunTests')[0]
        $first.TimeoutSec | Should -BeLessOrEqual 2
        @($script:soapCalls | Where-Object Operation -eq 'RunTests' | ForEach-Object { $_.TimeoutSec }) | ForEach-Object { $_ | Should -BeLessOrEqual 2 }

        $script:soapCalls.Clear()
        Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 0.3 -HealthTimeoutSec 30 | Out-Null
        @($script:soapCalls | Where-Object Operation -eq 'RunTests' | ForEach-Object { $_.TimeoutSec }) | ForEach-Object { $_ | Should -Be 1 }
    }

    It 'an outage on StopRunner or a health call carries the BatchId on the original exception' {
        Mock -ModuleName DemoPortal Invoke-MutSoap { throw 'Invoke-MutSoap: RunTests failed: HTTP 503 (service unavailable).' }

        $caught = $null
        try { Stop-MutRunnerBatch -Env $envHandle -BatchId 'B7' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 1 }
        catch { $caught = $_ }

        $caught.Exception.Message | Should -BeLike '*503*'
        $caught.Exception.Data['BatchId'] | Should -Be 'B7'
    }

    It 'keeps polling while RunTests reports failures, times out or faults, and confirms later' {
        $script:healthResults = @(
            (New-SoapResult -Value '{"passed":1,"failed":1,"durationMs":100,"tests":[]}'),
            (New-SoapResult -TimedOut),
            (New-SoapResult -Fault 'locked'),
            (New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":100,"tests":[]}')
        )

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 5

        $r.Confirmed | Should -BeTrue
        @($script:soapCalls | Where-Object Operation -eq 'RunTests').Count | Should -Be 4
        @($script:soapCalls | Where-Object Operation -eq 'DeleteRunnerState').Count | Should -Be 1
    }

    It 'is not confirmed after the window, and never calls DeleteRunnerState' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":1,"failed":1,"durationMs":100,"tests":[]}'))

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 0.3

        $r.Confirmed | Should -BeFalse
        @($script:soapCalls | Where-Object Operation -eq 'DeleteRunnerState').Count | Should -Be 0
        @($script:soapCalls | Where-Object Operation -eq 'RunTests').Count | Should -BeGreaterThan 1
    }

    It 'still polls when StopRunner faults (the row already finished) and confirms by the health call' {
        $script:stopResult = New-SoapResult -Fault 'already finished'
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":1,"tests":[]}'))

        $r = Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.01 -ConfirmWindowSec 2

        $r.Confirmed | Should -BeTrue
    }

    It 'waits PollIntervalSec before each health call (the stop needs time to land)' {
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":1,"tests":[]}'))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-MutRunnerBatch -Env $envHandle -BatchId 'B1' -CodeunitIds '95155' -PollIntervalSec 0.4 -ConfirmWindowSec 5 | Out-Null
        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 0.35
    }

    It 'refuses an environment not named mut-*' {
        $bad = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        { Stop-MutRunnerBatch -Env $bad -BatchId 'B1' -CodeunitIds '95155' } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-MutSoap -Times 0
    }
}

Describe 'Invoke-MutMutantBatch' {
    BeforeEach {
        $script:soapCalls = [System.Collections.Generic.List[object]]::new()
        $script:startArgs = $null
        $script:batchId = $null
        $script:pollNo = 0
        $script:doneAtPoll = 1000
        $script:callResult = $null
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson }
        $script:stateThrowAtPoll = -1
        $script:healthResults = @((New-SoapResult -Value '{"passed":3,"failed":0,"durationMs":10,"tests":[]}'))
        $script:stopResult = New-SoapResult -Value 'stopped'
        $script:apiRows = @()
        $script:runspaceStopped = 0
        $fast = $script:fast

        Mock -ModuleName DemoPortal Start-MutSoapRunspace {
            $script:startArgs = [pscustomobject]@{ Operation = $Operation; Arguments = $Arguments; TimeoutSec = $TimeoutSec }
            $script:batchId = $Arguments['batchId']
            [pscustomobject]@{ Fake = $true }
        }
        $script:received = $false
        $script:waitCalls = 0
        $script:waitAfterReceive = 0
        $script:waitMs = @()
        $script:stateThrowFrom = -1
        $script:stateThrowOutage = $false
        $script:stopCalled = $false
        Mock -ModuleName DemoPortal Test-MutSoapRunspaceDone { $script:pollNo -ge $script:doneAtPoll }
        Mock -ModuleName DemoPortal Receive-MutSoapRunspace { $script:received = $true; $script:callResult }
        Mock -ModuleName DemoPortal Wait-MutSoapRunspace {
            $script:waitCalls++
            $script:waitMs += $TimeoutMs
            if ($script:received) { $script:waitAfterReceive++ }
            Start-Sleep -Milliseconds $TimeoutMs
        }
        Mock -ModuleName DemoPortal Stop-MutSoapRunspace { $script:runspaceStopped++ }
        Mock -ModuleName DemoPortal Invoke-MutSoap {
            $script:soapCalls.Add([pscustomobject]@{ Operation = $Operation; Arguments = $Arguments; TimeoutSec = $TimeoutSec })
            switch ($Operation) {
                'GetRunnerState' {
                    $script:pollNo++
                    if ($script:pollNo -eq $script:stateThrowAtPoll) { throw 'transient state poll failure' }
                    # stateThrowFrom: the batch's own polls fail; the stop's reads (after StopRunner) succeed.
                    if ($script:stateThrowFrom -gt 0 -and $script:pollNo -ge $script:stateThrowFrom -and -not $script:stopCalled) { $ex = [System.Exception]::new('state poll failure'); if ($script:stateThrowOutage) { $ex.Data['MutSoapOutage'] = $true }; throw $ex }
                    $json = & $script:stateFn $script:pollNo $script:batchId
                    return [pscustomobject]@{ Ok = $true; Value = $json; Fault = $null; TimedOut = $false; Dropped = $false; DurationMs = 1 }
                }
                'StopRunner' { $script:stopCalled = $true; return $script:stopResult }
                'DeleteRunnerState' { return [pscustomobject]@{ Ok = $true; Value = 'deleted'; Fault = $null; TimedOut = $false; Dropped = $false; DurationMs = 1 } }
                'RunTests' { return $script:healthResults[0] }
            }
        }
        Mock -ModuleName DemoPortal Invoke-MutApi { [pscustomobject]@{ value = @($script:apiRows) } }
    }

    BeforeAll {
        # Tiny timings so the poll/decision logic runs in milliseconds.
        $script:fast = @{ PollIntervalSec = 0.01; NoRowWindowSec = 0.3; FaultStallSec = 0.15; StopConfirmSec = 1; HealthTimeoutSec = 30; ReturnGraceSec = 0.3 }

        function script:New-ApiRow {
            param([int]$MutantId, [string]$Status = 'Killed', [string]$KillingTest = 'T:f', [int]$DurationMs = 7, [int]$RunNo = 5)
            [pscustomobject]@{ runNo = $RunNo; mutantId = $MutantId; status = $Status; killingTest = $KillingTest; durationMs = $DurationMs }
        }

        function script:Get-Ops { @($script:soapCalls | ForEach-Object { $_.Operation }) }
    }

    It 'starts RunMutants with a client GUID BatchId, the covering set, the id list, the run number and timeout count x budget + 60' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 0 -Done 3 -Finished $true)) }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Value '[]'

        Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155, 95110 -MutantIds 11, 12, 13 -RunNo 5 -MutantBudgetSec 30 @fast | Out-Null

        $script:startArgs.Operation | Should -Be 'RunMutants'
        $script:startArgs.Arguments['batchId'] | Should -Match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
        $script:startArgs.Arguments['codeunitIds'] | Should -Be '95155|95110'
        $script:startArgs.Arguments['mutantIds'] | Should -Be '11,12,13'
        $script:startArgs.Arguments['runNo'] | Should -Be 5
        $script:startArgs.TimeoutSec | Should -Be 150
    }

    It 'passes the RunMutants arguments as an ordered dictionary in the AL parameter order' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 1 -Finished $true)) }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Value '[]'

        Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @fast | Out-Null

        $script:startArgs.Arguments | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        @($script:startArgs.Arguments.Keys) | Should -Be @('batchId', 'codeunitIds', 'mutantIds', 'runNo')
    }

    It 'deletes the Finished row of THIS batch once the return value has been received' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 1 -Finished $true)) }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Value '[{"mutantId":11,"status":"Survived","killingTest":"","durationMs":5,"passed":1,"failed":0}]'

        Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @fast | Out-Null

        $deletes = @($script:soapCalls | Where-Object Operation -eq 'DeleteRunnerState')
        $deletes.Count | Should -Be 1
        $deletes[0].Arguments['batchId'] | Should -Be $script:batchId
        $deletes[0].TimeoutSec | Should -Be 30
    }

    It 'leaves the Finished row when the return value never arrived, and a failing delete does not fail the batch' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 1 -Finished $true)) }
        $script:doneAtPoll = 1000
        $script:apiRows = @((New-ApiRow -MutantId 11 -Status 'Survived' -KillingTest ''))

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @fast
        @($r.Results).Count | Should -Be 1
        Get-Ops | Should -Not -Contain 'DeleteRunnerState'

        $script:soapCalls.Clear()
        $script:pollNo = 0
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Value '[{"mutantId":11,"status":"Survived","killingTest":"","durationMs":5,"passed":1,"failed":0}]'
        Mock -ModuleName DemoPortal Invoke-MutSoap {
            if ($Operation -eq 'GetRunnerState') {
                return [pscustomobject]@{ Ok = $true; Value = (& $script:stateFn 1 $script:batchId); Fault = $null; TimedOut = $false; Dropped = $false; DurationMs = 1 }
            }
            throw 'Invoke-MutSoap: DeleteRunnerState failed: HTTP 503 (service unavailable).'
        }
        $r2 = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @fast
        @($r2.Results).Count | Should -Be 1
        $r2.Results[0].Status | Should -Be 'Survived'
    }

    It 'a finished batch returns the RunMutants entries as Results (including an Empty one), no hang, no stop' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 0 -Done 3 -Finished $true)) }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Value (@(
                [pscustomobject]@{ mutantId = 11; status = 'Killed'; killingTest = 'CU1:TestA'; durationMs = 120; passed = 2; failed = 1 }
                [pscustomobject]@{ mutantId = 12; status = 'Survived'; killingTest = ''; durationMs = 90; passed = 3; failed = 0 }
                [pscustomobject]@{ mutantId = 13; status = 'Empty'; killingTest = ''; durationMs = 1; passed = 0; failed = 0 }
            ) | ConvertTo-Json -Depth 5 -Compress)

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12, 13 -RunNo 5 -MutantBudgetSec 30 @fast

        @($r.Results).Count | Should -Be 3
        $r.Results[0].MutantId | Should -Be 11
        $r.Results[0].Status | Should -Be 'Killed'
        $r.Results[0].KillingTest | Should -Be 'CU1:TestA'
        $r.Results[0].DurationMs | Should -Be 120
        $r.Results[0].Passed | Should -Be 2
        $r.Results[0].Failed | Should -Be 1
        $r.Results[2].Status | Should -Be 'Empty'
        $r.HungMutantId | Should -BeNullOrEmpty
        $r.FaultMutantId | Should -BeNullOrEmpty
        $r.Fault | Should -BeNullOrEmpty
        $r.Stopped | Should -BeFalse
        Get-Ops | Should -Not -Contain 'StopRunner'
        Should -Invoke -ModuleName DemoPortal Invoke-MutApi -Times 0
        $script:runspaceStopped | Should -Be 1
    }

    It 'a single-entry RunMutants result is still an array' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Finished $true)) }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Value '[{"mutantId":11,"status":"Survived","killingTest":"","durationMs":5,"passed":1,"failed":0}]'

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @fast

        @($r.Results).Count | Should -Be 1
        $r.Results[0].MutantId | Should -Be 11
    }

    It 'does not declare a hang while a row has not started its first mutant (mutantStartedAt empty)' {
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 6) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 0 -StartedAt '')) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 2 -Finished $true))
        }
        $script:doneAtPoll = 6
        $script:callResult = New-SoapResult -Value '[]'

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.HungMutantId | Should -BeNullOrEmpty
        Get-Ops | Should -Not -Contain 'StopRunner'
    }

    It 'a mutant within its budget on the server clock is not a hang' {
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 3) { return New-RunnerStateJson -ServerNow '2026-10-04T20:43:40.0000000Z' -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:10.0000000Z')) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 2 -Finished $true))
        }
        $script:doneAtPoll = 3
        $script:callResult = New-SoapResult -Value '[]'

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.HungMutantId | Should -BeNullOrEmpty
        Get-Ops | Should -Not -Contain 'StopRunner'
    }

    It 'a hang on the server clock stops THIS batch, confirms, and returns the partial results without the hung mutant' {
        $script:stateFn = {
            param($poll, $batchId)
            New-RunnerStateJson -ServerNow '2026-10-04T20:44:11.0000000Z' -Rows @(
                (New-StateRow -BatchId 'OTHER' -MutantId 99 -StartedAt '2026-10-04T20:00:00.0000000Z'),
                (New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:40.0000000Z' -Done 1)
            )
        }
        # The hook already wrote a row for the hung mutant 12 (Killed before the hang); mutant 13 never ran.
        $script:apiRows = @((New-ApiRow -MutantId 11 -Status 'Survived' -KillingTest ''), (New-ApiRow -MutantId 12 -Status 'Killed'))

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12, 13 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.HungMutantId | Should -Be 12
        $r.FaultMutantId | Should -BeNullOrEmpty
        $r.Stopped | Should -BeTrue
        @($r.Results).Count | Should -Be 1
        $r.Results[0].MutantId | Should -Be 11
        $r.Results[0].Status | Should -Be 'Survived'
        @($r.Results | Where-Object MutantId -eq 12).Count | Should -Be 0

        $stop = @($script:soapCalls | Where-Object Operation -eq 'StopRunner')
        $stop.Count | Should -Be 1
        $stop[0].Arguments['batchId'] | Should -Be $script:batchId
        Get-Ops | Should -Contain 'DeleteRunnerState'
        Should -Invoke -ModuleName DemoPortal Invoke-MutApi -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Path -like 'mutantResults*runNo eq 5*' }
        $script:runspaceStopped | Should -Be 1
    }

    It 'uses the first covering codeunit as the health codeunit of the stop' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -ServerNow '2026-10-04T20:44:11.0000000Z' -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:40.0000000Z')) }

        Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95121, 95155 -MutantIds 12 -RunNo 5 -MutantBudgetSec 30 @fast | Out-Null

        $health = @($script:soapCalls | Where-Object Operation -eq 'RunTests')
        $health[0].Arguments['codeunitIds'] | Should -Be '95121'
    }

    It 'declares a hang when no row for this BatchId appears within the no-row window, blaming the first mutant' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId 'OTHER' -MutantId 0 -Finished $true)) }

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 21, 22 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.HungMutantId | Should -Be 21
        $r.Stopped | Should -BeTrue
        @($script:soapCalls | Where-Object Operation -eq 'StopRunner').Count | Should -Be 1
    }

    It 'declares a hang when the batch exceeds its client timeout even though the clock says the mutant is fresh' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -ServerNow '2026-10-04T20:43:41.0000000Z' -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:40.0000000Z' -Done 1)) }

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12 -RunNo 5 -MutantBudgetSec 30 -ClientTimeoutSec 0.2 @fast

        $r.HungMutantId | Should -Be 12
        $r.Stopped | Should -BeTrue
    }

    It 'a TimedOut or Dropped call is not an outage: polling continues until the row shows Finished' {
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 5) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:42.0000000Z' -Done 1)) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 2 -Finished $true))
        }
        $script:doneAtPoll = 2
        $script:callResult = New-SoapResult -Dropped
        $script:apiRows = @((New-ApiRow -MutantId 11 -Status 'Survived' -KillingTest ''), (New-ApiRow -MutantId 12 -Status 'Killed'))

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.Stopped | Should -BeFalse
        $r.HungMutantId | Should -BeNullOrEmpty
        $r.FaultMutantId | Should -BeNullOrEmpty
        Get-Ops | Should -Not -Contain 'StopRunner'
        $script:pollNo | Should -BeGreaterOrEqual 5
        @($r.Results).Count | Should -Be 2   # no return value, so Results come from mutantResults
        Should -Invoke -ModuleName DemoPortal Invoke-MutApi -Times 1 -Exactly
    }

    It 'a TimedOut call that never reaches Finished ends as a hang once the mutant exceeds its budget' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -ServerNow '2026-10-04T20:44:30.0000000Z' -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:40.0000000Z')) }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -TimedOut

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 12 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.HungMutantId | Should -Be 12
        $r.Stopped | Should -BeTrue
    }

    It 'a fault with the row unfinished and its mutant not advancing is reported as FaultMutantId, with the stop confirmed' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 13 -StartedAt '2026-10-04T20:43:42.0000000Z' -Done 2)) }
        $script:doneAtPoll = 2
        $script:callResult = New-SoapResult -Fault 'The call stack overflowed'
        $script:apiRows = @((New-ApiRow -MutantId 11 -Status 'Survived' -KillingTest ''), (New-ApiRow -MutantId 12 -Status 'Survived' -KillingTest ''), (New-ApiRow -MutantId 13 -Status 'Killed'))

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12, 13, 14 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.FaultMutantId | Should -Be 13
        $r.HungMutantId | Should -BeNullOrEmpty
        $r.Fault | Should -Be 'The call stack overflowed'
        $r.Stopped | Should -BeTrue
        @($r.Results | ForEach-Object { $_.MutantId }) | Should -Be @(11, 12)
        $stop = @($script:soapCalls | Where-Object Operation -eq 'StopRunner')
        $stop.Count | Should -Be 1
        $stop[0].Arguments['batchId'] | Should -Be $script:batchId
    }

    It 'a fault is not declared while the row is still advancing' {
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 8) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId (10 + $poll) -StartedAt '2026-10-04T20:43:42.0000000Z' -Done $poll)) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 8 -Finished $true))
        }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Fault 'late fault text'
        $s = $script:fast.Clone(); $s['PollIntervalSec'] = 0.04; $s['FaultStallSec'] = 0.2

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @s

        $r.FaultMutantId | Should -BeNullOrEmpty
        $r.Fault | Should -Be 'late fault text'
        $r.Stopped | Should -BeFalse
        Get-Ops | Should -Not -Contain 'StopRunner'
    }

    It 'throws RunnerStopFailed when the stop is not confirmed, and still releases the runspace' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -ServerNow '2026-10-04T20:44:11.0000000Z' -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:40.0000000Z')) }
        $script:healthResults = @((New-SoapResult -Value '{"passed":1,"failed":1,"durationMs":10,"tests":[]}'))
        $s = $script:fast.Clone(); $s['StopConfirmSec'] = 0.2

        { Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 12 -RunNo 5 -MutantBudgetSec 30 @s } | Should -Throw '*RunnerStopFailed*'

        Get-Ops | Should -Not -Contain 'DeleteRunnerState'
        $script:runspaceStopped | Should -Be 1
    }

    It 'survives a transient state-poll failure' {
        $script:stateThrowAtPoll = 2
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 4) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 0)) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 1 -Finished $true))
        }
        $script:doneAtPoll = 4
        $script:callResult = New-SoapResult -Value '[]'

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.HungMutantId | Should -BeNullOrEmpty
        $r.Stopped | Should -BeFalse
    }

    It 'propagates an outage thrown by the SOAP call itself and releases the runspace' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 0)) }
        $script:doneAtPoll = 1
        Mock -ModuleName DemoPortal Receive-MutSoapRunspace { throw 'Invoke-MutSoap: RunMutants failed: HTTP 503 (service unavailable).' }

        $caught = $null
        try { Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 @fast }
        catch { $caught = $_ }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -BeLike '*503*'
        $caught.Exception.Data['BatchId'] | Should -Be $script:batchId
        $script:runspaceStopped | Should -Be 1
    }

    It 'a failed state poll after the no-row window is not a hang once a row has been seen (no rule runs on a failed poll)' {
        $script:stateThrowAtPoll = 2
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 3) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:42.0000000Z' -Done 1)) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 2 -Finished $true))
        }
        $script:doneAtPoll = 3
        $script:callResult = New-SoapResult -Value '[]'
        $s = $script:fast.Clone(); $s['PollIntervalSec'] = 0.15; $s['NoRowWindowSec'] = 0.05

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12 -RunNo 5 -MutantBudgetSec 30 @s

        $r.HungMutantId | Should -BeNullOrEmpty
        $r.Stopped | Should -BeFalse
        Get-Ops | Should -Not -Contain 'StopRunner'
    }

    It 'an OUTAGE poll failure is retried while the call runs, and rethrown with the BatchId once the call has ended' {
        $script:stateThrowFrom = 2
        $script:stateThrowOutage = $true
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:42.0000000Z' -Done 1)) }
        $script:doneAtPoll = 4
        $script:callResult = New-SoapResult -Dropped

        $caught = $null
        try { Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12 -RunNo 5 -MutantBudgetSec 30 @fast }
        catch { $caught = $_ }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -BeLike '*state poll failure*'
        $caught.Exception.Data['BatchId'] | Should -Be $script:batchId
        $script:pollNo | Should -BeGreaterOrEqual 4
        Get-Ops | Should -Not -Contain 'StopRunner'
        $script:runspaceStopped | Should -Be 1
    }

    It 'a NON-outage poll failure after the call has ended is retried, and the batch then ends normally' {
        $script:stateThrowAtPoll = 3
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 5) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:42.0000000Z' -Done 1)) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 2 -Finished $true))
        }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Dropped
        $script:apiRows = @((New-ApiRow -MutantId 11 -Status 'Survived' -KillingTest ''), (New-ApiRow -MutantId 12 -Status 'Killed'))

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12 -RunNo 5 -MutantBudgetSec 30 @fast

        $r.HungMutantId | Should -BeNullOrEmpty
        $r.Stopped | Should -BeFalse
        @($r.Results).Count | Should -Be 2
        $script:pollNo | Should -BeGreaterOrEqual 5
        Get-Ops | Should -Not -Contain 'StopRunner'
    }

    It 'polls failing continuously past the client timeout is a hang of the last known mutant, then the stop runs' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:42.0000000Z' -Done 1)) }
        $script:doneAtPoll = 1
        $script:callResult = New-SoapResult -Dropped
        # Poll 1 succeeds and shows mutant 12; every later poll fails (not an outage).
        $script:stateThrowFrom = 2
        $s = $script:fast.Clone(); $s['PollIntervalSec'] = 0.02

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 11, 12, 13 -RunNo 5 -MutantBudgetSec 30 -ClientTimeoutSec 0.3 @s

        $r.HungMutantId | Should -Be 12
        $r.Stopped | Should -BeTrue
        @($script:soapCalls | Where-Object Operation -eq 'StopRunner').Count | Should -Be 1
    }

    It 'with no row ever seen, polls failing past the client timeout blame the first mutant' {
        $script:stateThrowFrom = 1
        $script:doneAtPoll = 1000
        $s = $script:fast.Clone(); $s['PollIntervalSec'] = 0.02

        $r = Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 21, 22 -RunNo 5 -MutantBudgetSec 30 -ClientTimeoutSec 0.3 @s

        $r.HungMutantId | Should -Be 21
        $r.Stopped | Should -BeTrue
    }

    It 'an outage during the stop carries the BatchId on the original exception' {
        $script:stateFn = { param($poll, $batchId) New-RunnerStateJson -ServerNow '2026-10-04T20:44:11.0000000Z' -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:40.0000000Z')) }
        $script:stopResult = $null
        Mock -ModuleName DemoPortal Invoke-MutSoap {
            if ($Operation -eq 'GetRunnerState') {
                $json = & $script:stateFn 1 $script:batchId
                return [pscustomobject]@{ Ok = $true; Value = $json; Fault = $null; TimedOut = $false; Dropped = $false; DurationMs = 1 }
            }
            throw 'Invoke-MutSoap: StopRunner failed: HTTP 503 (service unavailable).'
        }

        $caught = $null
        try { Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 12 -RunNo 5 -MutantBudgetSec 30 @fast }
        catch { $caught = $_ }

        $caught.Exception.Message | Should -BeLike '*503*'
        $caught.Exception.Data['BatchId'] | Should -Be $script:batchId
    }

    It 'waits on the runspace seam (not a blind sleep) while the call is running, and never after the call has been received' {
        $script:stateFn = {
            param($poll, $batchId)
            if ($poll -lt 4) { return New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -MutantId 12 -StartedAt '2026-10-04T20:43:42.0000000Z')) }
            New-RunnerStateJson -Rows @((New-StateRow -BatchId $batchId -Done 1 -Finished $true))
        }
        $script:doneAtPoll = 2
        $script:callResult = New-SoapResult -Dropped

        Invoke-MutMutantBatch -Env $envHandle -CodeunitIds 95155 -MutantIds 12 -RunNo 5 -MutantBudgetSec 30 @fast | Out-Null

        $script:waitCalls | Should -BeGreaterThan 0
        $script:waitMs | ForEach-Object { $_ | Should -Be 10 }
        $script:waitAfterReceive | Should -Be 0
    }

    It 'refuses an environment not named mut-*' {
        $bad = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        { Invoke-MutMutantBatch -Env $bad -CodeunitIds 95155 -MutantIds 11 -RunNo 5 -MutantBudgetSec 30 } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Start-MutSoapRunspace -Times 0
    }
}

Describe 'Stop-MutSoapRunspace' {
    BeforeAll {
        function script:New-FakeHandle {
            param([bool]$Completed, [bool]$StopCompletes = $true)
            $h = [pscustomobject]@{
                Async      = [pscustomobject]@{ IsCompleted = $Completed }
                PowerShell = [pscustomobject]@{ Disposed = 0; BeginStopCalls = 0; StopCompletes = $StopCompletes }
                Runspace   = [pscustomobject]@{ Disposed = 0; CloseAsyncCalls = 0 }
            }
            $h.PowerShell | Add-Member ScriptMethod Dispose { $this.Disposed++ }
            $h.PowerShell | Add-Member ScriptMethod BeginStop {
                param($cb, $state)
                $this.BeginStopCalls++
                $w = [pscustomobject]@{ Result = $this.StopCompletes }
                $w | Add-Member ScriptMethod WaitOne { param($ms) $this.Result }
                [pscustomobject]@{ AsyncWaitHandle = $w }
            }
            $h.Runspace | Add-Member ScriptMethod Dispose { $this.Disposed++ }
            $h.Runspace | Add-Member ScriptMethod CloseAsync { $this.CloseAsyncCalls++ }
            $h
        }
    }

    It 'disposes the PowerShell instance and the runspace of a completed call, without stopping it' {
        $h = New-FakeHandle -Completed $true
        Invoke-InModule { param($x) Stop-MutSoapRunspace -Handle $x } @($h)
        $h.PowerShell.Disposed | Should -Be 1
        $h.Runspace.Disposed | Should -Be 1
        $h.PowerShell.BeginStopCalls | Should -Be 0
    }

    It 'stops a still-running call asynchronously and disposes both once the stop completed' {
        $h = New-FakeHandle -Completed $false -StopCompletes $true
        Invoke-InModule { param($x) Stop-MutSoapRunspace -Handle $x -DisposeWaitSec 0.1 } @($h)
        $h.PowerShell.BeginStopCalls | Should -Be 1
        $h.PowerShell.Disposed | Should -Be 1
        $h.Runspace.Disposed | Should -Be 1
    }

    It 'does not dispose (Dispose would block) when the stop has not completed, and closes the runspace asynchronously' {
        $h = New-FakeHandle -Completed $false -StopCompletes $false
        Invoke-InModule { param($x) Stop-MutSoapRunspace -Handle $x -DisposeWaitSec 0.1 } @($h)
        $h.PowerShell.Disposed | Should -Be 0
        $h.Runspace.Disposed | Should -Be 0
        $h.Runspace.CloseAsyncCalls | Should -Be 1
    }
}

Describe 'Start-MutSoapRunspace wiring' {
    It 'knows the module path the background runspace imports (so a fresh runspace can load the backend)' {
        $path = Invoke-InModule { $script:DemoPortalModulePath }
        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeTrue
        (Split-Path $path -Leaf) | Should -Be 'DemoPortal.psm1'
    }

    It 'refuses an environment not named mut-* before opening any runspace' {
        $bad = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        { Invoke-InModule { param($e) Start-MutSoapRunspace -Env $e -Operation 'GetRunnerState' -Arguments @{} -TimeoutSec 5 } @($bad) } | Should -Throw "*does not match '^mut-'*"
    }
}

Describe 'Get-MutRunnerState failure classes' {
    It 'rethrows an outage exception from Invoke-MutSoap unchanged (marker kept)' {
        $outage = Invoke-InModule { New-MutOutageException -Message 'HTTP 503' }
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ throw $outage }.GetNewClosure())

        $caught = $null
        try { Get-MutRunnerState -Env $envHandle } catch { $caught = $_ }

        $caught.Exception.Data['MutSoapOutage'] | Should -BeTrue
    }

    It 'throws an error without the outage marker for a dropped, timed-out or faulted call' {
        $result = New-SoapResult -Dropped
        Mock -ModuleName DemoPortal Invoke-MutSoap ({ $result }.GetNewClosure())

        $caught = $null
        try { Get-MutRunnerState -Env $envHandle } catch { $caught = $_ }

        $caught.Exception.Message | Should -BeLike '*connection dropped*'
        $caught.Exception.Data.Contains('MutSoapOutage') | Should -BeFalse
        $caught.Exception.Data.Contains('MutSoapNonOutage') | Should -BeFalse
    }
}

Describe 'Remove-MutRunnerState' {
    It 'calls DeleteRunnerState with the BatchId (ordered arguments) and a 30 s timeout, returning its value' {
        $script:soapCalls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DemoPortal Invoke-MutSoap {
            $script:soapCalls.Add([pscustomobject]@{ Operation = $Operation; Arguments = $Arguments; TimeoutSec = $TimeoutSec })
            [pscustomobject]@{ Ok = $true; Value = 'deleted'; Fault = $null; TimedOut = $false; Dropped = $false; DurationMs = 1 }
        }

        $r = Remove-MutRunnerState -Env $envHandle -BatchId 'B9'

        $r | Should -Be 'deleted'
        $script:soapCalls.Count | Should -Be 1
        $script:soapCalls[0].Operation | Should -Be 'DeleteRunnerState'
        $script:soapCalls[0].Arguments | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        $script:soapCalls[0].Arguments['batchId'] | Should -Be 'B9'
        $script:soapCalls[0].TimeoutSec | Should -Be 30
    }

    It 'throws when DeleteRunnerState does not return a value' {
        Mock -ModuleName DemoPortal Invoke-MutSoap { [pscustomobject]@{ Ok = $false; Value = $null; Fault = 'boom'; TimedOut = $false; Dropped = $false; DurationMs = 1 } }
        { Remove-MutRunnerState -Env $envHandle -BatchId 'B9' } | Should -Throw '*boom*'
    }

    It 'refuses an environment not named mut-*' {
        Mock -ModuleName DemoPortal Invoke-MutSoap { }
        $bad = [pscustomobject]@{ Id = 'E1'; Name = 'fix-auth'; Url = 'https://x'; Backend = 'DemoPortal'; Shared = $false }
        { Remove-MutRunnerState -Env $bad -BatchId 'B9' } | Should -Throw "*does not match '^mut-'*"
        Should -Invoke -ModuleName DemoPortal Invoke-MutSoap -Times 0
    }
}

Describe 'Receive-MutSoapRunspace' {
    It 'returns the first result object' {
        $h = [pscustomobject]@{ Async = [pscustomobject]@{}; PowerShell = [pscustomobject]@{} }
        $h.PowerShell | Add-Member ScriptMethod EndInvoke { param($a) , @([pscustomobject]@{ Ok = $true; Value = 'v' }) }
        $r = Invoke-InModule { param($x) Receive-MutSoapRunspace -Handle $x } @($h)
        $r.Value | Should -Be 'v'
    }

    It 'throws, naming the runspace error records, when the runspace produced no output (setup failure, call never sent)' {
        $h = [pscustomobject]@{
            Async      = [pscustomobject]@{}
            PowerShell = [pscustomobject]@{ Streams = [pscustomobject]@{ Error = @('Import-Module: could not load DemoPortal', 'second problem') } }
        }
        $h.PowerShell | Add-Member ScriptMethod EndInvoke { param($a) , @() }

        { Invoke-InModule { param($x) Receive-MutSoapRunspace -Handle $x } @($h) } | Should -Throw '*no result*could not load DemoPortal*second problem*'
    }
}
