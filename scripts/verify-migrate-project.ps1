[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [Alias('RequireDiscoveryActive')]
    [switch]$RequireDiscoveryResources,
    [switch]$RequireDiscoveredServers,
    [switch]$RequireMigrationResources,
    [switch]$RequireReplicationProvider
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

function Invoke-AzureCliText {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage,
        [ValidateRange(1, 10)][int]$MaximumAttempts = 4,
        [ValidateRange(1, 30)][int]$InitialRetryDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $output = @(& az @Arguments 2>&1)
        if ($LASTEXITCODE -eq 0) {
            return ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        }

        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        $isTransient = $details -match '(?i)InternalServerError|Internal Server Error|TooManyRequests|ServiceUnavailable|BadGateway|GatewayTimeout|temporarily unavailable|timed?\s*out|\b429\b|\b50[0234]\b'
        if (-not $isTransient -or $attempt -eq $MaximumAttempts) {
            throw "$FailureMessage$([Environment]::NewLine)$details"
        }

        $delaySeconds = [Math]::Min(30, $InitialRetryDelaySeconds * [Math]::Pow(2, $attempt - 1))
        Write-Warning "Transient Azure error on attempt $attempt/$MaximumAttempts. Retrying in $delaySeconds seconds."
        Start-Sleep -Seconds $delaySeconds
    }
}

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][string]$Context
    )

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "$Context is missing $PropertyName."
    }
    return [string]$property.Value
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it before running this script.'
}
if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) {
    throw "Deployment configuration was not found: $configFilePath"
}

$configuration = Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json
$targetSubscriptionId = Get-RequiredPropertyValue `
    -InputObject $configuration `
    -PropertyName 'TargetSubscriptionId' `
    -Context 'Deployment configuration'
$expectedMigrationLocation = Get-RequiredPropertyValue `
    -InputObject $configuration `
    -PropertyName 'TargetLocation' `
    -Context 'Deployment configuration'
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
    ) "Could not read subscription deployment '$DeploymentName'. Deploy the lab first."
    $deployment = $deploymentJson | ConvertFrom-Json
    $outputsProperty = $deployment.properties.PSObject.Properties['outputs']
    if ($null -eq $outputsProperty) {
        throw "Subscription deployment '$DeploymentName' has no outputs."
    }
    $projectIdOutput = $outputsProperty.Value.PSObject.Properties['azureMigrateProjectId']
    if ($null -eq $projectIdOutput -or [string]::IsNullOrWhiteSpace([string]$projectIdOutput.Value.value)) {
        throw "Subscription deployment '$DeploymentName' does not expose azureMigrateProjectId. Redeploy the current Bicep template."
    }
    $projectId = [string]$projectIdOutput.Value.value
    $projectResourceGroupName = ($projectId -split '/')[4]
    $projectName = ($projectId -split '/')[-1]

    $projectJson = Invoke-AzureCliText @(
        'rest', '--method', 'get',
        '--url', "https://management.azure.com${projectId}?api-version=2020-05-01",
        '--output', 'json',
        '--only-show-errors'
    ) "Could not read Azure Migrate project '$projectName'."
    $project = $projectJson | ConvertFrom-Json

    $solutionsJson = Invoke-AzureCliText @(
        'rest', '--method', 'get',
        '--url', "https://management.azure.com${projectId}/solutions?api-version=2020-05-01",
        '--output', 'json',
        '--only-show-errors'
    ) "Could not list solutions for Azure Migrate project '$projectName'."
    $solutionsResponse = $solutionsJson | ConvertFrom-Json
    $solutions = @($solutionsResponse.value)
    $resourceInventoryJson = Invoke-AzureCliText @(
        'resource', 'list',
        '--subscription', $targetSubscriptionId,
        '--resource-group', $projectResourceGroupName,
        '--output', 'json',
        '--only-show-errors'
    ) "Could not inventory discovery resources in '$projectResourceGroupName'."
    $resourceInventory = @($resourceInventoryJson | ConvertFrom-Json)
    $expectedSolutions = @(
        [pscustomobject]@{
            Name = 'Servers-Assessment-ServerAssessment'
            Tool = 'ServerAssessment'
            Purpose = 'Assessment'
            Goal = 'Servers'
            AllowedStatuses = @('Active')
        }
        [pscustomobject]@{
            Name = 'Servers-Discovery-ServerDiscovery'
            Tool = 'ServerDiscovery'
            Purpose = 'Discovery'
            Goal = 'Servers'
            AllowedStatuses = @('Inactive', 'Active')
        }
        [pscustomobject]@{
            Name = 'Servers-Migration-ServerMigration'
            Tool = 'ServerMigration'
            Purpose = 'Migration'
            Goal = 'Servers'
            AllowedStatuses = @('Active')
        }
    )

    $issues = [Collections.Generic.List[string]]::new()
    $provisioningStateProperty = $project.properties.PSObject.Properties['provisioningState']
    $provisioningState = if ($null -eq $provisioningStateProperty) { 'Unknown' } else { [string]$provisioningStateProperty.Value }
    if ($provisioningState -ne 'Succeeded') {
        $issues.Add("Project provisioning state is '$provisioningState', expected 'Succeeded'.")
    }

    $solutionResults = foreach ($expected in $expectedSolutions) {
        $solution = $solutions | Where-Object { $_.name -eq $expected.Name } | Select-Object -First 1
        $solutionIssues = [Collections.Generic.List[string]]::new()
        if ($null -eq $solution) {
            $solutionIssues.Add('Solution is missing.')
            $actualStatus = 'Missing'
        }
        else {
            foreach ($propertyName in 'Tool', 'Purpose', 'Goal') {
                $actualValue = [string]$solution.properties.$propertyName
                $expectedValue = [string]$expected.$propertyName
                if ($actualValue -ne $expectedValue) {
                    $solutionIssues.Add("$propertyName is '$actualValue', expected '$expectedValue'.")
                }
            }
            $actualStatus = [string]$solution.properties.status
            if ($actualStatus -notin $expected.AllowedStatuses) {
                $solutionIssues.Add("Status is '$actualStatus', expected one of: $($expected.AllowedStatuses -join ', ').")
            }
        }
        foreach ($solutionIssue in $solutionIssues) {
            $issues.Add("$($expected.Name): $solutionIssue")
        }
        [pscustomobject]@{
            Name = $expected.Name
            Status = $actualStatus
            Valid = $solutionIssues.Count -eq 0
        }
    }

    $assessmentProjects = @(
        $resourceInventory | Where-Object { $_.type -ieq 'Microsoft.Migrate/assessmentProjects' }
    )
    $physicalServerSites = @(
        $resourceInventory | Where-Object { $_.type -ieq 'Microsoft.OffAzure/ServerSites' }
    )
    $discoveryResourcesReady = $assessmentProjects.Count -gt 0 -and $physicalServerSites.Count -gt 0
    if ($RequireDiscoveryResources -and -not $discoveryResourcesReady) {
        $issues.Add('Physical discovery resources are incomplete. Generate the project key and register the appliance, then retry.')
    }

    $serversSummaryProperty = $project.properties.summary.PSObject.Properties['servers']
    $discoveredCount = if (
        $null -eq $serversSummaryProperty -or
        $null -eq $serversSummaryProperty.Value.PSObject.Properties['discoveredCount']
    ) {
        0
    }
    else {
        [int]$serversSummaryProperty.Value.discoveredCount
    }
    if ($discoveredCount -lt 1) {
        $assessmentMachineCount = 0
        foreach ($assessmentProject in $assessmentProjects) {
            try {
                $machinesJson = Invoke-AzureCliText @(
                    'rest', '--method', 'get',
                    '--url', "https://management.azure.com$($assessmentProject.id)/machines?api-version=2019-10-01",
                    '--output', 'json',
                    '--only-show-errors'
                ) "Could not list discovered machines in assessment project '$($assessmentProject.name)'."
                $assessmentMachineCount += @((($machinesJson | ConvertFrom-Json).value)).Count
            }
            catch {
                Write-Warning $_.Exception.Message
            }
        }
        $discoveredCount = [Math]::Max($discoveredCount, $assessmentMachineCount)
    }
    if ($RequireDiscoveredServers -and $discoveredCount -lt 1) {
        $issues.Add('Azure Migrate has not reported any discovered servers yet. Wait for discovery ingestion, then retry.')
    }

    $migrationSolution = $solutions |
        Where-Object { $_.name -eq 'Servers-Migration-ServerMigration' } |
        Select-Object -First 1
    $migrationSolutionJson = if ($null -eq $migrationSolution) {
        ''
    }
    else {
        $migrationSolution | ConvertTo-Json -Depth 20 -Compress
    }
    $linkedResourceIds = @(
        [regex]::Matches(
            $migrationSolutionJson,
            '(?i)/subscriptions/[0-9a-f-]+/resourceGroups/[^/"\\]+/providers/Microsoft\.(?:RecoveryServices/vaults|Storage/storageAccounts)/[^/"\\]+'
        ) | ForEach-Object { $_.Value } | Sort-Object -Unique
    )
    $recoveryServicesVaults = @(
        $resourceInventory | Where-Object { $_.type -ieq 'Microsoft.RecoveryServices/vaults' }
    )
    $linkedResourceIds = @(
        $linkedResourceIds
        $recoveryServicesVaults | ForEach-Object { $_.id }
    ) | Sort-Object -Unique
    $identityProperty = $project.PSObject.Properties['identity']
    $identityTypeProperty = if ($null -eq $identityProperty) {
        $null
    }
    else {
        $identityProperty.Value.PSObject.Properties['type']
    }
    $projectManagedIdentityEnabled = `
        $null -ne $identityTypeProperty -and `
        [string]$identityTypeProperty.Value -match 'SystemAssigned'
    $migrationVaultsInExpectedRegion = @(
        $recoveryServicesVaults | Where-Object { $_.location -ieq $expectedMigrationLocation }
    )
    $replicationProviders = [Collections.Generic.List[object]]::new()
    if ($RequireReplicationProvider) {
        foreach ($vault in $migrationVaultsInExpectedRegion) {
            $fabricsJson = Invoke-AzureCliText @(
                'rest', '--method', 'get',
                '--url', "https://management.azure.com$($vault.id)/replicationFabrics?api-version=2025-08-01",
                '--output', 'json',
                '--only-show-errors'
            ) "Could not list Site Recovery fabrics in vault '$($vault.name)'."
            $fabrics = @(($fabricsJson | ConvertFrom-Json).value) |
                Where-Object { $_.properties.customDetails.instanceType -eq 'InMageRcm' }
            foreach ($fabric in $fabrics) {
                $providersJson = Invoke-AzureCliText @(
                    'rest', '--method', 'get',
                    '--url', "https://management.azure.com$($fabric.id)/replicationRecoveryServicesProviders?api-version=2025-08-01",
                    '--output', 'json',
                    '--only-show-errors'
                ) "Could not list registered providers for fabric '$($fabric.name)'."
                foreach ($provider in @(($providersJson | ConvertFrom-Json).value)) {
                    if ($provider.properties.connectionStatus -eq 'Connected') {
                        $replicationProviders.Add([pscustomobject]@{
                            Name = [string]$provider.name
                            ConnectionStatus = [string]$provider.properties.connectionStatus
                            LastHeartbeat = [string]$provider.properties.lastHeartbeat
                            FabricName = [string]$fabric.name
                            FabricHealth = [string]$fabric.properties.health
                        })
                    }
                }
            }
        }
        if ($replicationProviders.Count -eq 0) {
            $issues.Add('No connected InMageRcm replication provider was found in the migration Recovery Services vault.')
        }
    }
    $migrationResourcesCreated = `
        $projectManagedIdentityEnabled -and `
        $migrationVaultsInExpectedRegion.Count -gt 0
    if ($RequireMigrationResources -and -not $projectManagedIdentityEnabled) {
        $issues.Add('Azure Migrate project system-assigned managed identity is not enabled.')
    }
    if ($RequireMigrationResources -and $recoveryServicesVaults.Count -eq 0) {
        $issues.Add('No Recovery Services vault was found in the Azure Migrate project resource group. Generate the replication appliance key, then retry.')
    }
    if (
        $RequireMigrationResources -and
        $recoveryServicesVaults.Count -gt 0 -and
        $migrationVaultsInExpectedRegion.Count -eq 0
    ) {
        $actualVaultRegions = @($recoveryServicesVaults.location | Sort-Object -Unique) -join ', '
        $issues.Add("Recovery Services vault region '$actualVaultRegions' does not match configured migration target '$expectedMigrationLocation'.")
    }

    $portalUrl = "https://portal.azure.com/#resource${projectId}/overview"
    $result = [ordered]@{
        Status = if ($issues.Count -eq 0) { 'Ready' } else { 'Incomplete' }
        ProjectId = $projectId
        ProjectName = $projectName
        ResourceGroupName = $projectResourceGroupName
        ProvisioningState = $provisioningState
        PortalUrl = $portalUrl
        DiscoveryResourcesReady = $discoveryResourcesReady
        AssessmentProjectNames = @($assessmentProjects | ForEach-Object { $_.name })
        PhysicalServerSiteNames = @($physicalServerSites | ForEach-Object { $_.name })
        DiscoveredServerCount = $discoveredCount
        ProjectManagedIdentityEnabled = $projectManagedIdentityEnabled
        MigrationResourcesCreated = $migrationResourcesCreated
        ExpectedMigrationLocation = $expectedMigrationLocation
        RecoveryServicesVaults = @(
            $recoveryServicesVaults | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.name
                    Location = $_.location
                    Id = $_.id
                }
            }
        )
        LinkedResourceIds = $linkedResourceIds
        ReplicationProviders = @($replicationProviders)
        Solutions = @($solutionResults)
        Issues = @($issues)
    }
    $resultJson = $result | ConvertTo-Json -Depth 5 -Compress
    $resultLine = "AZURE_MIGRATE_PROJECT_RESULT=$resultJson"
    Write-Output $resultLine
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_MIGRATE_LAB_RESULT_FILE)) {
        Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE -Value $resultLine -Encoding utf8NoBOM
    }

    if ($issues.Count -gt 0) {
        throw "Azure Migrate project verification failed: $($issues -join '; ')"
    }

    Write-Host "Azure Migrate project: $projectName" -ForegroundColor Cyan
    Write-Host "Provisioning state: $provisioningState" -ForegroundColor Green
    foreach ($solutionResult in $solutionResults) {
        Write-Host "Solution $($solutionResult.Name): $($solutionResult.Status)" -ForegroundColor Green
    }
    Write-Host "Portal: $portalUrl" -ForegroundColor Green
}
finally {
    if ([string]::IsNullOrWhiteSpace($previousAzureExtensionDirectory)) {
        Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory
    }
}
