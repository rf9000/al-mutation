<#
    .SYNOPSIS
    T09 U4 spike: turns the ad-hoc T04b live check into a repeatable script. Verifies that
    `MUT Test Hooks` (via the IsolatedStorage mirror from T04b's experiment B) can read the
    active mutant under the DemoPortal test job's own restricted runtime, and that a failing
    test in codeunit 50301 ("MUT Fx U4 Spike Tests") causes the hooks to write exactly one
    `mutantResults` row: `{ runNo: 1, mutantId: 999, status: Killed,
    killingTest: 'MUT Fx U4 Spike Tests:U4_Failing' }`. See docs/SPEC.md §6.6.3, §5, U4 in §3,
    §7.6.

    .DESCRIPTION
    Never runs codeunit 50302 (guardrail: one test job at a time; 50302 is out of scope here).
    Only touches the `mut-spike-01` environment (id 30004698-209d-467c-96eb-9b412e9ee6ee).

    Steps:
      1. PATCH mutationSetup(0) { activeMutantId: 999, currentRunNo: 1 }.
      2. Invoke-MutTests on codeunit 50301 (TimeoutSec 300).
      3. GET mutantResults filtered to runNo eq 1 and mutantId eq 999; print the rows as JSON.
      4. PATCH mutationSetup(0) back to { activeMutantId: 0, currentRunNo: 0 } and confirm via
         a GET (mirrors T04b's own reset, which zeroed both fields, and leaves the environment
         ready for the next run rather than mid-run-1).
      5. Compute pass/fail: exactly one row with status Killed and
         killingTest 'MUT Fx U4 Spike Tests:U4_Failing'.
      6. DELETE the single spike row via its own key, `mutantResults(runNo=1,mutantId=999)`,
         falling back to `mutantResults(1,999)` if that key form is rejected. RunNo 1 is also
         the fixture acceptance run's own run number (§8), so this deletes ONLY the
         (runNo=1, mutantId=999) row by key -- never a bulk/filtered delete of every runNo=1
         row, which would destroy the fixture acceptance run's own rows.
      7. Exit 0 on pass (per step 5), exit 1 otherwise, printing what was found.

    Never prints credentials (Get-MutCredential / Get-MutBasicAuthHeader values are never
    written to output).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Import-Module (Join-Path $repoRoot 'orchestrator\lib\Config.psm1') -Force
Import-Module (Join-Path $repoRoot 'orchestrator\backends\DemoPortal.psm1') -Force

$RunNo = 1
$MutantId = 999
$ExpectedKillingTest = 'MUT Fx U4 Spike Tests:U4_Failing'
$TargetCodeunit = 50301

Write-Output '=== T09 U4 spike: runner events under the DemoPortal test job ==='

$configPath = Join-Path $repoRoot 'mutation.fixture.config.json'
$cfg = Get-MutConfig -Path $configPath

$envHandle = Get-MutEnvironment -Name $cfg.environmentName -Config $cfg
if ($null -eq $envHandle) {
    throw "Invoke-U4Spike: environment '$($cfg.environmentName)' not found."
}
if ($envHandle.Status -ne 'Running') {
    Write-Output "Environment status is '$($envHandle.Status)'; starting it..."
    $envHandle = Start-MutEnvironment -Env $envHandle -Config $cfg
}
Write-Output "Environment: $($envHandle.Name) ($($envHandle.Id)), status Running."

# --- Step 1: activate the spike mutant --------------------------------------------------
Write-Output ''
Write-Output "--- PATCH mutationSetup(0) { activeMutantId: $MutantId, currentRunNo: $RunNo } ---"
Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{
    activeMutantId = $MutantId
    currentRunNo   = $RunNo
} | Out-Null

$setupAfterActivate = Invoke-MutApi -Env $envHandle -Method 'GET' -Path 'mutationSetup(0)'
Write-Output ("Confirmed via GET: activeMutantId={0}, currentRunNo={1}" -f $setupAfterActivate.activeMutantId, $setupAfterActivate.currentRunNo)

# --- Step 2: run the target codeunit (never 50302) --------------------------------------
Write-Output ''
Write-Output "--- Invoke-MutTests: codeunit $TargetCodeunit (TimeoutSec 300) ---"
$testResult = Invoke-MutTests -Env $envHandle -Targets @([pscustomobject]@{ CodeunitId = $TargetCodeunit; Function = $null }) -TimeoutSec 300
Write-Output ("Test run: {0} passed, {1} failed" -f $testResult.Passed, $testResult.Failed)
foreach ($t in @($testResult.Tests)) {
    Write-Output ("  {0}:{1} -> {2}" -f $t.Codeunit, $t.Function, $t.Result)
}

# --- Step 3: GET the spike row and print as JSON -----------------------------------------
Write-Output ''
$filterPath = 'mutantResults?$filter=runNo eq {0} and mutantId eq {1}' -f $RunNo, $MutantId
Write-Output "--- GET $filterPath ---"
$queryResult = Invoke-MutApi -Env $envHandle -Method 'GET' -Path $filterPath
$rows = @($queryResult.value)
Write-Output ("Rows found: {0}" -f $rows.Count)
Write-Output ($rows | ConvertTo-Json -Depth 10)

# --- Step 4: reset setup, confirm via GET ------------------------------------------------
Write-Output ''
Write-Output '--- PATCH mutationSetup(0) back to { activeMutantId: 0, currentRunNo: 0 } ---'
Invoke-MutApi -Env $envHandle -Method 'PATCH' -Path 'mutationSetup(0)' -Body @{
    activeMutantId = 0
    currentRunNo   = 0
} | Out-Null

$setupAfterReset = Invoke-MutApi -Env $envHandle -Method 'GET' -Path 'mutationSetup(0)'
Write-Output ("Confirmed via GET: activeMutantId={0}, currentRunNo={1}" -f $setupAfterReset.activeMutantId, $setupAfterReset.currentRunNo)
if ($setupAfterReset.activeMutantId -ne 0) {
    Write-Output "WARNING: activeMutantId is not 0 after reset (got $($setupAfterReset.activeMutantId))."
}

# --- Step 5: compute pass/fail ------------------------------------------------------------
$pass = $false
if ($rows.Count -eq 1 -and $rows[0].status -eq 'Killed' -and $rows[0].killingTest -eq $ExpectedKillingTest) {
    $pass = $true
}

Write-Output ''
if ($pass) {
    Write-Output "RESULT: PASS -- exactly one row, status Killed, killingTest '$ExpectedKillingTest'."
}
else {
    Write-Output "RESULT: FAIL -- expected exactly one row with status Killed and killingTest '$ExpectedKillingTest'. Found:"
    Write-Output ($rows | ConvertTo-Json -Depth 10)
}

# --- Step 6: delete the spike row by its own key (never a bulk runNo filter delete) ------
Write-Output ''
Write-Output "--- DELETE the (runNo=$RunNo, mutantId=$MutantId) spike row ---"
$deleteKeyUsed = $null
if ($rows.Count -gt 0) {
    try {
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path ("mutantResults(runNo={0},mutantId={1})" -f $RunNo, $MutantId) | Out-Null
        $deleteKeyUsed = "mutantResults(runNo=$RunNo,mutantId=$MutantId)"
        Write-Output "DELETE succeeded with key form: $deleteKeyUsed"
    }
    catch {
        Write-Output "DELETE with key form 'mutantResults(runNo=$RunNo,mutantId=$MutantId)' was rejected: $($_.Exception.Message)"
        Write-Output "Retrying with key form 'mutantResults($RunNo,$MutantId)'..."
        Invoke-MutApi -Env $envHandle -Method 'DELETE' -Path ("mutantResults({0},{1})" -f $RunNo, $MutantId) | Out-Null
        $deleteKeyUsed = "mutantResults($RunNo,$MutantId)"
        Write-Output "DELETE succeeded with key form: $deleteKeyUsed"
    }

    $confirmDelete = Invoke-MutApi -Env $envHandle -Method 'GET' -Path $filterPath
    $rowsAfterDelete = @($confirmDelete.value)
    Write-Output ("Rows remaining for (runNo=$RunNo, mutantId=$MutantId) after delete: {0}" -f $rowsAfterDelete.Count)
}
else {
    Write-Output 'No rows to delete (0 rows were found by the earlier GET).'
}

Write-Output ''
Write-Output '=== Summary ==='
Write-Output ("Pass: {0}" -f $pass)
Write-Output ("Rows found (before delete): {0}" -f $rows.Count)
Write-Output ("Delete key form used: {0}" -f $deleteKeyUsed)
Write-Output ("Final activeMutantId: {0}" -f $setupAfterReset.activeMutantId)

if ($pass) {
    exit 0
}
else {
    exit 1
}
