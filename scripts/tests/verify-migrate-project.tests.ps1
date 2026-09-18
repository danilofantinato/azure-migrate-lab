[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\verify-migrate-project.ps1')).Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "verify-migrate-project.ps1 has parse errors: $($parseErrors -join '; ')"
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($solutionName in @(
    'Servers-Assessment-ServerAssessment'
    'Servers-Discovery-ServerDiscovery'
    'Servers-Migration-ServerMigration'
)) {
    if (-not $scriptText.Contains($solutionName)) {
        throw "Project verification must require solution '$solutionName'."
    }
}
if (-not $scriptText.Contains("PSObject.Properties['outputs']") -or
    -not $scriptText.Contains("PSObject.Properties['azureMigrateProjectId']")) {
    throw 'Project verification must derive the project from deployment outputs.'
}
if (-not $scriptText.Contains('/solutions?api-version=2020-05-01')) {
    throw 'Project verification must list solutions through the documented API used by the quickstart.'
}
if (-not $scriptText.Contains("AllowedStatuses = @('Inactive', 'Active')")) {
    throw 'Discovery verification must allow the transition from Inactive to Active after registration.'
}
if (-not $scriptText.Contains('AZURE_MIGRATE_PROJECT_RESULT=')) {
    throw 'Project verification must emit a machine-readable result marker.'
}
if (-not $scriptText.Contains('Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE')) {
    throw 'Project verification results must support the setup result-file channel.'
}
if (-not $scriptText.Contains("[Alias('RequireDiscoveryActive')]")) {
    throw 'Project verification must preserve the previous discovery gate as a parameter alias.'
}
if (-not $scriptText.Contains('[switch]$RequireDiscoveryResources') -or
    -not $scriptText.Contains("Microsoft.OffAzure/ServerSites") -or
    -not $scriptText.Contains("Microsoft.Migrate/assessmentProjects")) {
    throw 'Project verification must require modern physical-discovery resources.'
}
if (-not $scriptText.Contains('[switch]$RequireDiscoveredServers') -or
    -not $scriptText.Contains('DiscoveredServerCount') -or
    -not $scriptText.Contains('/machines?api-version=2019-10-01')) {
    throw 'Project verification must expose a separate asynchronous discovered-server gate.'
}
if (-not $scriptText.Contains('[switch]$RequireMigrationResources') -or
    -not $scriptText.Contains("Microsoft.RecoveryServices/vaults") -or
    -not $scriptText.Contains('ProjectManagedIdentityEnabled') -or
    -not $scriptText.Contains('ExpectedMigrationLocation')) {
    throw 'Project verification must require project MSI and a directly inventoried vault in the configured migration region.'
}
foreach ($replicationProviderContract in @(
    '[switch]$RequireReplicationProvider'
    '/replicationFabrics?api-version=2025-08-01'
    '/replicationRecoveryServicesProviders?api-version=2025-08-01'
    "properties.customDetails.instanceType -eq 'InMageRcm'"
    "properties.connectionStatus -eq 'Connected'"
    'ReplicationProviders'
)) {
    if (-not $scriptText.Contains($replicationProviderContract)) {
        throw "Project verification is missing replication provider behavior: $replicationProviderContract"
    }
}
if ($scriptText -match '(?i)(registration|project)[-_ ]?key\s*=') {
    throw 'Project verification must not accept or store registration keys.'
}

$invokeAzureCliDefinition = $ast.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-AzureCliText'
    },
    $true
) | Select-Object -First 1
if ($null -eq $invokeAzureCliDefinition) {
    throw 'Invoke-AzureCliText was not found.'
}
$functionBodyText = $invokeAzureCliDefinition.Body.Extent.Text
Set-Item Function:\script:Invoke-AzureCliText -Value ([scriptblock]::Create(
    $functionBodyText.Substring(1, $functionBodyText.Length - 2)
))

$script:azureCallCount = 0
$script:sleepCount = 0
$script:azureMode = 'TransientThenSuccess'
function global:az {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

    $script:azureCallCount++
    if ($script:azureMode -eq 'TransientThenSuccess' -and $script:azureCallCount -lt 3) {
        $global:LASTEXITCODE = 1
        return 'ERROR: InternalServerError (500): Please try again.'
    }
    if ($script:azureMode -eq 'Permanent') {
        $global:LASTEXITCODE = 1
        return 'ERROR: AuthorizationFailed (403).'
    }
    $global:LASTEXITCODE = 0
    return '{"status":"ok"}'
}
function global:Start-Sleep {
    param([double]$Seconds)
    $script:sleepCount++
}

$retryResult = Invoke-AzureCliText `
    -Arguments @('rest', '--method', 'get') `
    -FailureMessage 'Transient request failed.' `
    -InitialRetryDelaySeconds 1
if ($retryResult -ne '{"status":"ok"}' -or $script:azureCallCount -ne 3 -or $script:sleepCount -ne 2) {
    throw 'Transient Azure failures were not retried to success as expected.'
}

$script:azureMode = 'Permanent'
$script:azureCallCount = 0
$script:sleepCount = 0
$permanentErrorFailedFast = $false
try {
    Invoke-AzureCliText `
        -Arguments @('rest', '--method', 'get') `
        -FailureMessage 'Permanent request failed.' | Out-Null
}
catch {
    $permanentErrorFailedFast = `
        $_.Exception.Message -match 'AuthorizationFailed' -and
        $script:azureCallCount -eq 1 -and
        $script:sleepCount -eq 0
}
if (-not $permanentErrorFailedFast) {
    throw 'Permanent Azure failures must fail without retrying.'
}

Remove-Item Function:\az -ErrorAction SilentlyContinue
Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
Remove-Variable azureCallCount, sleepCount, azureMode -Scope Script -ErrorAction SilentlyContinue

Write-Host 'verify-migrate-project tests passed.' -ForegroundColor Green
