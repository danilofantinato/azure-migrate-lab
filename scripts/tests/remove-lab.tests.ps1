[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\remove-lab.ps1')).Path
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "remove-lab.ps1 has parse errors: $($parseErrors -join '; ')"
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($requiredText in @(
    "Get-DeploymentOutputValue -Deployment `$deployment -Name 'sourceResourceGroupId'"
    "Get-DeploymentOutputValue -Deployment `$deployment -Name 'targetResourceGroupId'"
    "Get-DeploymentOutputValue -Deployment `$deployment -Name 'azureMigrateProjectId'"
    "if (`$resourceGroupName -ieq 'NetworkWatcherRG')"
    "Type DELETE LAB to permanently delete the inventoried resources"
    '[switch]$IncludeLinkedMigrationResources'
    '[switch]$RemoveResourceLocks'
    '[switch]$KeepDeploymentHistory'
    '[switch]$ResetLocalState'
    "'deployment', 'operation', 'sub', 'list'"
    "'deployment', 'sub', 'delete'"
    'DeploymentHistory = $deploymentHistory'
    'function Test-AzureResourceGroupExists'
    'function Get-AzureResourceGroupLocks'
    "'lock', 'list'"
    "'lock', 'delete'"
    'ResourceLocks = $resourceLocks'
    'rerun with -RemoveResourceLocks'
    '$sourceResourceGroupExists -and $PSCmdlet.ShouldProcess'
    '$targetResourceGroupExists -and $PSCmdlet.ShouldProcess'
    "if (`$_.Kind -eq 'Root') { 1 } else { 0 }"
    '"source-$deploymentSuffix"'
    '"target-$deploymentSuffix"'
    "Join-Path `$PSScriptRoot 'setup-lab.state.local.json'"
    "Join-Path `$repositoryRoot 'infra\main.json'"
    '$localStatePaths += $configFilePath'
    "`$PSCmdlet.ShouldProcess(`$localStatePath, 'Delete local lab state')"
    'AZURE_MIGRATE_REMOVAL_RESULT='
    '$PSCmdlet.ShouldProcess'
)) {
    if (-not $scriptText.Contains($requiredText)) {
        throw "Cleanup safety behavior is missing: $requiredText"
    }
}
if ($scriptText -match "(?i)starts_with\(name") {
    throw 'Cleanup must not discover resource groups by broad prefix matching.'
}
if (-not $scriptText.Contains("Status = 'Previewed'") -or -not $scriptText.Contains("Status = 'Deleted'")) {
    throw 'Cleanup must distinguish preview from deletion.'
}

Write-Host 'remove-lab tests passed.' -ForegroundColor Green
