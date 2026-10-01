[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [switch]$IncludeLinkedMigrationResources,
    [switch]$RemoveResourceLocks,
    [switch]$KeepDeploymentHistory,
    [switch]$ResetLocalState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$configFilePath = if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    Join-Path $PSScriptRoot 'deploy-lab.local.json'
}
elseif ([IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
}
else {
    Join-Path $repositoryRoot $ConfigFile
}
$localStatePaths = @(
    (Join-Path $PSScriptRoot 'setup-lab.state.local.json')
    (Join-Path $repositoryRoot 'infra\main.json')
)
if ($ResetLocalState) {
    $localStatePaths += $configFilePath
}

function Invoke-AzureCliText {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $output = @(& az @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "$FailureMessage$([Environment]::NewLine)$details"
    }
    return ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
}

function Get-DeploymentOutputValue {
    param(
        [Parameter(Mandatory)][object]$Deployment,
        [Parameter(Mandatory)][string]$Name
    )

    $outputs = $Deployment.properties.PSObject.Properties['outputs']
    $output = if ($null -eq $outputs) { $null } else { $outputs.Value.PSObject.Properties[$Name] }
    if ($null -eq $output -or [string]::IsNullOrWhiteSpace([string]$output.Value.value)) {
        throw "Deployment output '$Name' is missing. Cleanup will not infer resource groups by prefix."
    }
    return [string]$output.Value.value
}

function Test-AzureResourceGroupExists {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $exists = Invoke-AzureCliText @(
        'group', 'exists',
        '--subscription', $SubscriptionId,
        '--name', $ResourceGroupName,
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not check whether resource group '$ResourceGroupName' exists."
    return [Convert]::ToBoolean($exists.Trim())
}

function Get-AzureResourceGroupLocks {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ResourceGroupId
    )

    $locksJson = Invoke-AzureCliText @(
        'lock', 'list',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--output', 'json',
        '--only-show-errors'
    ) "Could not inventory resource locks in '$ResourceGroupName'."
    $locks = @($locksJson | ConvertFrom-Json)
    foreach ($lock in $locks) {
        $lockId = [string]$lock.id
        $marker = '/providers/Microsoft.Authorization/locks/'
        $markerIndex = $lockId.LastIndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -lt 0) {
            throw "Unexpected Azure resource lock ID: $lockId"
        }
        $lockScope = $lockId.Substring(0, $markerIndex)
        if (
            -not $lockScope.Equals($ResourceGroupId, [StringComparison]::OrdinalIgnoreCase) -and
            -not $lockScope.StartsWith("$ResourceGroupId/", [StringComparison]::OrdinalIgnoreCase)
        ) {
            throw "Resource lock '$lockId' is outside the exact lab resource group scope."
        }
        [pscustomobject]@{
            Id = $lockId
            Name = [string]$lock.name
            Level = [string]$lock.level
            Scope = $lockScope
            SubscriptionId = $SubscriptionId
        }
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it before running this script.'
}
if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) {
    throw "Deployment configuration was not found: $configFilePath"
}

$configuration = Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json
foreach ($propertyName in 'SourceSubscriptionId', 'TargetSubscriptionId') {
    $property = $configuration.PSObject.Properties[$propertyName]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Deployment configuration is missing $propertyName."
    }
}
$sourceSubscriptionId = [string]$configuration.SourceSubscriptionId
$targetSubscriptionId = [string]$configuration.TargetSubscriptionId
$previousAzureExtensionDirectory = $env:AZURE_EXTENSION_DIR
$isolatedAzureExtensionDirectory = Join-Path $env:TEMP 'azure-migrate-lab-az-extensions'
New-Item -Path $isolatedAzureExtensionDirectory -ItemType Directory -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $isolatedAzureExtensionDirectory

try {
    & az account show --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        & az login
        if ($LASTEXITCODE -ne 0) {
            throw 'Azure sign-in failed.'
        }
    }

    $deploymentJson = Invoke-AzureCliText @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--output', 'json',
        '--only-show-errors'
    ) "Could not read subscription deployment '$DeploymentName'. Cleanup requires its exact outputs."
    $deployment = $deploymentJson | ConvertFrom-Json
    $sourceResourceGroupId = Get-DeploymentOutputValue -Deployment $deployment -Name 'sourceResourceGroupId'
    $targetResourceGroupId = Get-DeploymentOutputValue -Deployment $deployment -Name 'targetResourceGroupId'
    $projectId = Get-DeploymentOutputValue -Deployment $deployment -Name 'azureMigrateProjectId'
    $sourceResourceGroupName = ($sourceResourceGroupId -split '/')[-1]
    $targetResourceGroupName = ($targetResourceGroupId -split '/')[-1]
    $deploymentSuffix = ($sourceResourceGroupName -split '-')[-1]
    $sourceResourceGroupExists = Test-AzureResourceGroupExists `
        -SubscriptionId $sourceSubscriptionId `
        -ResourceGroupName $sourceResourceGroupName
    $targetResourceGroupExists = Test-AzureResourceGroupExists `
        -SubscriptionId $targetSubscriptionId `
        -ResourceGroupName $targetResourceGroupName

    foreach ($resourceGroupName in $sourceResourceGroupName, $targetResourceGroupName) {
        if ($resourceGroupName -ieq 'NetworkWatcherRG') {
            throw 'Cleanup refuses to delete NetworkWatcherRG.'
        }
    }
    if ($sourceResourceGroupId -notmatch "(?i)^/subscriptions/$([regex]::Escape($sourceSubscriptionId))/resourceGroups/") {
        throw 'Source resource group output does not belong to the configured source subscription.'
    }
    if ($targetResourceGroupId -notmatch "(?i)^/subscriptions/$([regex]::Escape($targetSubscriptionId))/resourceGroups/") {
        throw 'Target resource group output does not belong to the configured target subscription.'
    }

    $resourceLocks = @()
    if ($sourceResourceGroupExists) {
        $resourceLocks += @(
            Get-AzureResourceGroupLocks `
                -SubscriptionId $sourceSubscriptionId `
                -ResourceGroupName $sourceResourceGroupName `
                -ResourceGroupId $sourceResourceGroupId
        )
    }
    if ($targetResourceGroupExists) {
        $resourceLocks += @(
            Get-AzureResourceGroupLocks `
                -SubscriptionId $targetSubscriptionId `
                -ResourceGroupName $targetResourceGroupName `
                -ResourceGroupId $targetResourceGroupId
        )
    }

    $deploymentHistoryMap = @{}
    if (-not $KeepDeploymentHistory) {
        $nestedDeploymentIdsText = Invoke-AzureCliText @(
            'deployment', 'operation', 'sub', 'list',
            '--subscription', $targetSubscriptionId,
            '--name', $DeploymentName,
            '--query', "[?properties.targetResource.resourceType=='Microsoft.Resources/deployments'].properties.targetResource.id",
            '--output', 'tsv',
            '--only-show-errors'
        ) "Could not inventory nested deployment history for '$DeploymentName'."
        $nestedDeploymentIds = @(
            $nestedDeploymentIdsText -split '\r?\n' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        foreach ($nestedDeploymentId in $nestedDeploymentIds) {
            if ($nestedDeploymentId -match '(?i)^/subscriptions/(?<subscriptionId>[0-9a-f-]+)/providers/Microsoft\.Resources/deployments/(?<name>[^/]+)$') {
                $entry = [pscustomobject]@{
                    SubscriptionId = $Matches.subscriptionId
                    Name = $Matches.name
                    Kind = 'Nested'
                }
                $deploymentHistoryMap["$($entry.SubscriptionId)/$($entry.Name)".ToLowerInvariant()] = $entry
            }
        }

        $expectedNestedDeployments = @(
            [pscustomobject]@{ SubscriptionId = $sourceSubscriptionId; Name = "source-$deploymentSuffix"; Kind = 'Nested' }
            [pscustomobject]@{ SubscriptionId = $targetSubscriptionId; Name = "target-$deploymentSuffix"; Kind = 'Nested' }
        )
        foreach ($expectedDeployment in $expectedNestedDeployments) {
            & az deployment sub show `
                --subscription $expectedDeployment.SubscriptionId `
                --name $expectedDeployment.Name `
                --output none `
                --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0) {
                $deploymentHistoryMap["$($expectedDeployment.SubscriptionId)/$($expectedDeployment.Name)".ToLowerInvariant()] = $expectedDeployment
            }
        }

        $knownTargetDeploymentNames = @(
            $DeploymentName
            "$DeploymentName-validation"
            "$DeploymentName-preview"
            "$DeploymentName-option-validation"
            "$DeploymentName-option-preview"
        )
        $targetDeploymentInventoryJson = Invoke-AzureCliText @(
            'deployment', 'sub', 'list',
            '--subscription', $targetSubscriptionId,
            '--output', 'json',
            '--only-show-errors'
        ) 'Could not inventory target subscription deployment history.'
        foreach ($targetDeployment in @($targetDeploymentInventoryJson | ConvertFrom-Json)) {
            if ([string]$targetDeployment.name -in $knownTargetDeploymentNames) {
                $entry = [pscustomobject]@{
                    SubscriptionId = $targetSubscriptionId
                    Name = [string]$targetDeployment.name
                    Kind = if ([string]$targetDeployment.name -eq $DeploymentName) { 'Root' } else { 'Auxiliary' }
                }
                $deploymentHistoryMap["$($entry.SubscriptionId)/$($entry.Name)".ToLowerInvariant()] = $entry
            }
        }
    }
    $deploymentHistory = @($deploymentHistoryMap.Values)

    $linkedResourceIds = @()
    if (
        $IncludeLinkedMigrationResources -and
        $targetResourceGroupExists -and
        -not [string]::IsNullOrWhiteSpace($projectId)
    ) {
        $solutionsJson = Invoke-AzureCliText @(
            'rest', '--method', 'get',
            '--url', "https://management.azure.com${projectId}/solutions?api-version=2020-05-01",
            '--output', 'json',
            '--only-show-errors'
        ) 'Could not inventory Azure Migrate solution-linked resources.'
        $linkedResourceIds = @(
            [regex]::Matches(
                $solutionsJson,
                '(?i)/subscriptions/[0-9a-f-]+/resourceGroups/[^/"\\]+/providers/Microsoft\.(?:RecoveryServices/vaults|Storage/storageAccounts)/[^/"\\]+'
            ) |
                ForEach-Object { $_.Value } |
                Where-Object {
                    $_ -match "(?i)^/subscriptions/$([regex]::Escape($targetSubscriptionId))/" -and
                    -not $_.StartsWith("$targetResourceGroupId/", [StringComparison]::OrdinalIgnoreCase)
                } |
                Sort-Object -Unique
        )
    }

    Write-Host 'Cleanup inventory' -ForegroundColor Cyan
    Write-Host "Source resource group: $sourceResourceGroupId (exists: $sourceResourceGroupExists)"
    Write-Host "Target resource group: $targetResourceGroupId (exists: $targetResourceGroupExists)"
    if ($IncludeLinkedMigrationResources) {
        if ($linkedResourceIds.Count -eq 0) {
            Write-Host 'External solution-linked resources: none found'
        }
        else {
            Write-Host 'External solution-linked resources:'
            foreach ($resourceId in $linkedResourceIds) {
                Write-Host "- $resourceId"
            }
        }
    }
    else {
        Write-Host 'External solution-linked resources: excluded; use -IncludeLinkedMigrationResources to inventory and remove them.'
    }
    if ($resourceLocks.Count -eq 0) {
        Write-Host 'Resource locks: none found'
    }
    else {
        Write-Host "Resource locks ($(if ($RemoveResourceLocks) { 'selected for removal' } else { 'retained' })):"
        foreach ($resourceLock in $resourceLocks) {
            Write-Host "- $($resourceLock.Id) [$($resourceLock.Level)]"
        }
    }
    if ($KeepDeploymentHistory) {
        Write-Host 'Subscription deployment history: retained by -KeepDeploymentHistory.'
    }
    elseif ($deploymentHistory.Count -eq 0) {
        Write-Host 'Subscription deployment history: no matching records found.'
    }
    else {
        Write-Host 'Subscription deployment history:'
        foreach ($historyEntry in $deploymentHistory | Sort-Object SubscriptionId, Name) {
            Write-Host "- $($historyEntry.SubscriptionId)/$($historyEntry.Name) [$($historyEntry.Kind)]"
        }
    }
    if ($ResetLocalState) {
        Write-Host 'Local state files:'
        foreach ($localStatePath in $localStatePaths) {
            Write-Host "- $localStatePath (exists: $(Test-Path -LiteralPath $localStatePath -PathType Leaf))"
        }
    }

    if ($WhatIfPreference) {
        $result = [ordered]@{
            Status = 'Previewed'
            SourceResourceGroupId = $sourceResourceGroupId
            TargetResourceGroupId = $targetResourceGroupId
            LinkedResourceIds = $linkedResourceIds
            ResourceLocks = $resourceLocks
            DeploymentHistory = $deploymentHistory
            LocalStatePaths = if ($ResetLocalState) { $localStatePaths } else { @() }
        } | ConvertTo-Json -Depth 4 -Compress
        Write-Output "AZURE_MIGRATE_REMOVAL_RESULT=$result"
        return
    }

    if ($resourceLocks.Count -gt 0 -and -not $RemoveResourceLocks) {
        throw 'Lab-scoped resource locks block cleanup. Review the inventory and rerun with -RemoveResourceLocks to delete only those exact lock IDs.'
    }

    $confirmation = (Read-Host 'Type DELETE LAB to permanently delete the inventoried resources').Trim()
    if ($confirmation -cne 'DELETE LAB') {
        throw 'Cleanup was not approved. No resources were deleted.'
    }

    foreach ($resourceId in $linkedResourceIds) {
        if ($PSCmdlet.ShouldProcess($resourceId, 'Delete solution-linked resource')) {
            Invoke-AzureCliText @(
                'resource', 'delete',
                '--subscription', $targetSubscriptionId,
                '--ids', $resourceId,
                '--only-show-errors'
            ) "Could not delete solution-linked resource '$resourceId'." | Out-Null
        }
    }
    foreach ($resourceLock in $resourceLocks) {
        if ($PSCmdlet.ShouldProcess($resourceLock.Id, 'Delete lab-scoped resource lock')) {
            Invoke-AzureCliText @(
                'lock', 'delete',
                '--subscription', $resourceLock.SubscriptionId,
                '--ids', $resourceLock.Id,
                '--only-show-errors'
            ) "Could not delete resource lock '$($resourceLock.Id)'." | Out-Null
        }
    }
    if ($sourceResourceGroupExists -and $PSCmdlet.ShouldProcess($sourceResourceGroupId, 'Delete source resource group')) {
        Invoke-AzureCliText @(
            'group', 'delete',
            '--subscription', $sourceSubscriptionId,
            '--name', $sourceResourceGroupName,
            '--yes',
            '--only-show-errors'
        ) "Could not delete source resource group '$sourceResourceGroupName'." | Out-Null
    }
    if ($targetResourceGroupExists -and $PSCmdlet.ShouldProcess($targetResourceGroupId, 'Delete target resource group')) {
        Invoke-AzureCliText @(
            'group', 'delete',
            '--subscription', $targetSubscriptionId,
            '--name', $targetResourceGroupName,
            '--yes',
            '--only-show-errors'
        ) "Could not delete target resource group '$targetResourceGroupName'." | Out-Null
    }

    $orderedDeploymentHistory = @(
        $deploymentHistory | Sort-Object `
            @{ Expression = { if ($_.Kind -eq 'Root') { 1 } else { 0 } }; Ascending = $true }, `
            SubscriptionId, `
            Name
    )
    foreach ($historyEntry in $orderedDeploymentHistory) {
        $historyId = "/subscriptions/$($historyEntry.SubscriptionId)/providers/Microsoft.Resources/deployments/$($historyEntry.Name)"
        if ($PSCmdlet.ShouldProcess($historyId, 'Delete subscription deployment history')) {
            Invoke-AzureCliText @(
                'deployment', 'sub', 'delete',
                '--subscription', $historyEntry.SubscriptionId,
                '--name', $historyEntry.Name,
                '--only-show-errors'
            ) "Could not delete subscription deployment history '$($historyEntry.Name)'." | Out-Null
        }
    }
    if ($ResetLocalState) {
        foreach ($localStatePath in $localStatePaths) {
            if (
                (Test-Path -LiteralPath $localStatePath -PathType Leaf) -and
                $PSCmdlet.ShouldProcess($localStatePath, 'Delete local lab state')
            ) {
                Remove-Item -LiteralPath $localStatePath -Force
            }
        }
    }

    $result = [ordered]@{
        Status = 'Deleted'
        SourceResourceGroupId = $sourceResourceGroupId
        TargetResourceGroupId = $targetResourceGroupId
        LinkedResourceIds = $linkedResourceIds
        ResourceLocks = $resourceLocks
        DeploymentHistory = $deploymentHistory
        LocalStatePaths = if ($ResetLocalState) { $localStatePaths } else { @() }
    } | ConvertTo-Json -Depth 4 -Compress
    Write-Output "AZURE_MIGRATE_REMOVAL_RESULT=$result"
    Write-Host 'Lab resource deletion completed.' -ForegroundColor Green
}
finally {
    if ([string]::IsNullOrWhiteSpace($previousAzureExtensionDirectory)) {
        Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory
    }
}
