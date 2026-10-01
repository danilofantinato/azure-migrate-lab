[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\UnregisterApplianceFromAzure.ps1')).Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "UnregisterApplianceFromAzure.ps1 has parse errors: $($parseErrors -join '; ')"
}

foreach ($functionName in 'ConvertFrom-VaultArmId', 'Get-FirstPropertyValue', 'Read-ApplianceSettings', 'ConvertTo-ArmPath') {
    $functionAst = $ast.Find(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        },
        $true
    )
    if ($null -eq $functionAst) {
        throw "Required function was not found: $functionName"
    }
    Invoke-Expression $functionAst.Extent.Text
}

$subscriptionId = '11111111-2222-3333-4444-555555555555'
$vault = ConvertFrom-VaultArmId -VaultArmId (
    "/subscriptions/$subscriptionId/resourceGroups/rg-migrate/providers/" +
    'Microsoft.RecoveryServices/vaults/vault-migrate'
)
if (
    $vault.SubscriptionId -ne $subscriptionId -or
    $vault.ResourceGroup -ne 'rg-migrate' -or
    $vault.VaultName -ne 'vault-migrate'
) {
    throw 'Valid Recovery Services vault ARM ID was parsed incorrectly.'
}

$invalidIdRejected = $false
try {
    ConvertFrom-VaultArmId -VaultArmId (
        "/subscriptions/$subscriptionId/resourceGroups/rg-migrate/providers/" +
        'Microsoft.Storage/storageAccounts/not-a-vault'
    )
}
catch {
    $invalidIdRejected = $true
}
if (-not $invalidIdRejected) {
    throw 'Non-Recovery Services ARM ID must be rejected.'
}

$mixedCaseArmPath = ConvertTo-ArmPath -ResourceId (
    '/Subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/' +
    'rg-migrate/providers/Microsoft.RecoveryServices/vaults/vault-migrate'
)
if ($mixedCaseArmPath -notmatch '(?i)^/subscriptions/') {
    throw 'Mixed-case subscription resource ID was not normalized to an ARM path.'
}

$contextPath = [IO.Path]::GetTempFileName()
$context = @{
    DraName = 'test-dra'
    FabricId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    FabricName = 'test-fabric'
    VaultArmId = "/subscriptions/$subscriptionId/resourceGroups/rg-migrate/providers/" +
        'Microsoft.RecoveryServices/vaults/vault-migrate'
    ResourceLocation = 'westus2'
    ContainerUniqueName = 'test-container'
    MachineIdentifier = 'test-appliance'
}
try {
    $context | ConvertTo-Json | Set-Content -LiteralPath $contextPath
    $settings = Read-ApplianceSettings -ContextPath $contextPath
    if (
        $settings.DraName -ne 'test-dra' -or
        $settings.FabricId -ne 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -or
        $settings.SrsFabricName -ne 'test-fabric' -or
        $settings.SrsContainerName -ne 'test-container' -or
        $settings.AppliancesName -ne 'test-appliance'
    ) {
        throw 'Minimal appliance context was parsed incorrectly.'
    }
}
finally {
    Remove-Item -LiteralPath $contextPath -Force -ErrorAction SilentlyContinue
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($requiredText in @(
    '[string] $ApplianceContextPath'
    '-ContextPath $ApplianceContextPath'
    'function Get-ProtectedItems'
    'function ConvertTo-ArmPath'
    'Invoke-Arm -Method POST -Path "$rel/remove"'
    'replicationProtectedItems'
    '$protectedItems = @(Get-ProtectedItems -Container $container)'
    'if ($protectedItems.Count -gt 0)'
    'Complete or disable replication for every protected machine'
    '$originalSubscriptionId = [string]$account.id'
    'az account set --subscription $originalSubscriptionId'
    '$siblingCount = @('
    '$mappings = @(Get-List "$($container.id)/replicationProtectionContainerMappings")'
)) {
    if (-not $scriptText.Contains($requiredText)) {
        throw "Protected-item safety behavior is missing: $requiredText"
    }
}

$guardIndex = $scriptText.IndexOf('if ($protectedItems.Count -gt 0)')
$confirmationIndex = $scriptText.IndexOf('if (-not $Force)')
$deletionIndex = $scriptText.IndexOf('foreach ($m in $mappings) { Delete-Mapping')
if (
    $guardIndex -lt 0 -or
    $confirmationIndex -lt 0 -or
    $deletionIndex -lt 0 -or
    $guardIndex -gt $confirmationIndex -or
    $guardIndex -gt $deletionIndex
) {
    throw 'Protected-item guard must run before confirmation and deletion.'
}

Write-Host 'unregister-appliance tests passed.' -ForegroundColor Green
