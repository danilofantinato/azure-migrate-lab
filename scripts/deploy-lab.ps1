[CmdletBinding()]
param(
    [string]$SourceSubscriptionId,
    [string]$TargetSubscriptionId,
    [string]$AdminSourceCidr,
    [string]$SourceLocation,
    [string]$TargetLocation,
    [string]$NamePrefix,
    [string]$AdminUsername,
    [string]$DiscoveryApplianceVmSize,
    [string]$ReplicationApplianceVmSize,
    [string]$HyperVHostVmSize,
    [string]$WindowsSourceVmSize,
    [string]$LinuxSourceVmSize,
    [bool]$AutoSelectVmSizes = $true,
    [Nullable[bool]]$AutoShutdownEnabled,
    [string]$AutoShutdownTime,
    [string]$AutoShutdownTimeZone,
    [Nullable[bool]]$DeployTargetNatGateway,
    [Nullable[bool]]$DeployAzureMigrateProject,
    [string]$ConfigFile,
    [switch]$Reconfigure,
    [switch]$WhatIfOnly,
    [switch]$ApproveDeployment,
    [switch]$SkipProviderRegistration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$templateFile = Join-Path $repositoryRoot 'infra\main.bicep'
$parameterFile = Join-Path $repositoryRoot 'infra\main.bicepparam'
$configFilePath = if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    Join-Path $PSScriptRoot 'deploy-lab.local.json'
}
elseif ([IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
}
else {
    Join-Path $repositoryRoot $ConfigFile
}
$cacheableParameterNames = @(
    'SourceSubscriptionId'
    'TargetSubscriptionId'
    'AdminSourceCidr'
    'SourceLocation'
    'TargetLocation'
    'NamePrefix'
    'AdminUsername'
    'DiscoveryApplianceVmSize'
    'ReplicationApplianceVmSize'
    'HyperVHostVmSize'
    'WindowsSourceVmSize'
    'LinuxSourceVmSize'
    'AutoShutdownEnabled'
    'AutoShutdownTime'
    'AutoShutdownTimeZone'
    'DeployTargetNatGateway'
    'DeployAzureMigrateProject'
)
$explicitParameterNames = @($PSBoundParameters.Keys)
$script:vmSizesSelectedInteractively = $false
$disallowedAzureWindowsPasswords = @(
    'abc@123'
    'P@$$w0rd'
    'P@ssw0rd'
    'P@ssword123'
    'Pa$$word'
    'pass@word1'
    'Password!'
    'Password1'
    'Password22'
    'iloveyou!'
)
$fallbackComputeProfiles = @(
    [pscustomobject]@{
        Name = 'Dasv7'
        DiscoveryApplianceVmSize = 'Standard_D8as_v7'
        ReplicationApplianceVmSize = 'Standard_D16as_v7'
        HyperVHostVmSize = 'Standard_D16as_v7'
        WindowsSourceVmSize = 'Standard_D2as_v7'
        LinuxSourceVmSize = 'Standard_D2as_v7'
    }
    [pscustomobject]@{
        Name = 'Dasv6'
        DiscoveryApplianceVmSize = 'Standard_D8as_v6'
        ReplicationApplianceVmSize = 'Standard_D16as_v6'
        HyperVHostVmSize = 'Standard_D16s_v6'
        WindowsSourceVmSize = 'Standard_D2as_v6'
        LinuxSourceVmSize = 'Standard_D2as_v6'
    }
    [pscustomobject]@{
        Name = 'Dasv5'
        DiscoveryApplianceVmSize = 'Standard_D8as_v5'
        ReplicationApplianceVmSize = 'Standard_D16as_v5'
        HyperVHostVmSize = 'Standard_D16s_v5'
        WindowsSourceVmSize = 'Standard_D2as_v5'
        LinuxSourceVmSize = 'Standard_D2as_v5'
    }
)

function Write-DeploymentPhase {
    param([Parameter(Mandatory)][string]$Message)

    $timestamp = [DateTime]::Now.ToString('HH:mm:ss')
    Write-Host ''
    Write-Host "[$timestamp] $Message" -ForegroundColor Cyan
}

function Write-DeploymentDetail {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray
    )

    $timestamp = [DateTime]::Now.ToString('HH:mm:ss')
    Write-Host "[$timestamp]   $Message" -ForegroundColor $ForegroundColor
}

function Assert-AzureWindowsAdminPassword {
    param([Parameter(Mandatory)][string]$Password)

    if ($Password.Length -lt 8 -or $Password.Length -gt 123) {
        throw 'The Windows administrator password must contain 8-123 characters.'
    }

    $characterClassCount = 0
    if ($Password -cmatch '[a-z]') { $characterClassCount++ }
    if ($Password -cmatch '[A-Z]') { $characterClassCount++ }
    if ($Password -match '[0-9]') { $characterClassCount++ }
    if ($Password -match '[^a-zA-Z0-9]') { $characterClassCount++ }
    if ($characterClassCount -lt 3) {
        throw 'The Windows administrator password must contain at least three of: lowercase, uppercase, number, and special character.'
    }
    if ($disallowedAzureWindowsPasswords -icontains $Password) {
        throw 'The Windows administrator password is explicitly disallowed by Azure.'
    }
}

function New-AzureWindowsAdminPassword {
    param([ValidateRange(16, 123)][int]$Length = 24)

    $characterSets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ'
        'abcdefghijkmnopqrstuvwxyz'
        '23456789'
    )
    $characters = [Collections.Generic.List[char]]::new()
    foreach ($characterSet in $characterSets) {
        $characters.Add($characterSet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($characterSet.Length)])
    }
    $allCharacters = $characterSets -join ''
    while ($characters.Count -lt $Length) {
        $characters.Add($allCharacters[[Security.Cryptography.RandomNumberGenerator]::GetInt32($allCharacters.Length)])
    }
    for ($index = $characters.Count - 1; $index -gt 0; $index--) {
        $swapIndex = [Security.Cryptography.RandomNumberGenerator]::GetInt32($index + 1)
        $temporaryCharacter = $characters[$index]
        $characters[$index] = $characters[$swapIndex]
        $characters[$swapIndex] = $temporaryCharacter
    }

    $password = -join $characters
    Assert-AzureWindowsAdminPassword -Password $password
    return $password
}

function Confirm-TemporaryPasswordStored {
    param([Parameter(Mandatory)][string]$Password)

    Write-Host ''
    Write-Host 'Generated temporary Windows administrator and Linux root password:' -ForegroundColor Yellow
    Write-Host $Password -ForegroundColor Yellow
    Write-Host 'This lab-only shared password is displayed once and is not saved by the script.'
    $confirmation = (Read-Host 'Store it securely, then type READY to continue').Trim()
    if ($confirmation -cne 'READY') {
        throw 'Deployment cancelled before Azure changes because the temporary password was not acknowledged.'
    }
}

function Read-DeploymentConfirmation {
    Write-Host ''
    Write-Host 'ACTION REQUIRED: Azure Resource Manager preview completed.' -ForegroundColor Yellow
    Write-Host 'Type DEPLOY to create the billable resources, or CANCEL to pause without making changes.'
    Write-Host 'Pressing Enter alone does not select either action.'

    while ($true) {
        $confirmation = (Read-Host 'Deployment confirmation [DEPLOY/CANCEL]').Trim()
        if ($confirmation -ceq 'DEPLOY') {
            return 'Deploy'
        }
        if ($confirmation -ceq 'CANCEL') {
            return 'Cancel'
        }
        Write-Warning 'Enter DEPLOY or CANCEL explicitly.'
    }
}

function Write-DeploymentResult {
    param([Parameter(Mandatory)][ValidateSet('Cancelled', 'Previewed', 'Deployed')][string]$Status)

    $result = [ordered]@{
        Status = $Status
        DeploymentName = 'azure-migrate-lab'
        TargetSubscriptionId = $TargetSubscriptionId
        ConfigurationPath = $configFilePath
    } | ConvertTo-Json -Compress
    $resultLine = "AZURE_MIGRATE_DEPLOYMENT_RESULT=$result"
    Write-Output $resultLine
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_MIGRATE_LAB_RESULT_FILE)) {
        Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE -Value $resultLine -Encoding utf8NoBOM
    }
}

function Read-RequiredValue {
    param([Parameter(Mandatory)][string]$Prompt)

    $value = (Read-Host $Prompt).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Prompt is required."
    }
    return $value
}

function Read-ValueWithDefault {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$DefaultValue
    )

    $value = (Read-Host "$Prompt [$DefaultValue]").Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }
    return $value
}

function Read-BoolWithDefault {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][bool]$DefaultValue
    )

    $choiceLabel = if ($DefaultValue) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $choice = (Read-Host "$Prompt [$choiceLabel]").Trim()
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $DefaultValue
        }
        if ($choice -match '^(?i:y|yes)$') {
            return $true
        }
        if ($choice -match '^(?i:n|no)$') {
            return $false
        }
        Write-Warning 'Enter Y or N.'
    }
}

function Assert-SubscriptionId {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    $parsedId = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsedId)) {
        throw "$Name must be a valid subscription GUID."
    }
}

function Assert-Ipv4Cidr {
    param([Parameter(Mandatory)][string]$Value)

    $parts = $Value.Split('/')
    $parsedAddress = $null
    $prefixLength = 0
    $validAddress = $parts.Count -eq 2 -and
        [Net.IPAddress]::TryParse($parts[0], [ref]$parsedAddress) -and
        $parsedAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
    $validPrefix = $parts.Count -eq 2 -and
        [int]::TryParse($parts[1], [ref]$prefixLength) -and
        $prefixLength -ge 0 -and
        $prefixLength -le 32

    if (-not ($validAddress -and $validPrefix)) {
        throw 'Administrator CIDR must be valid IPv4 CIDR notation, for example 203.0.113.10/32.'
    }
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Ensure-AzureProviderRegistered {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$EnvironmentLabel
    )

    $registrationState = & az provider show `
        --subscription $SubscriptionId `
        --namespace $Namespace `
        --query registrationState `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read registration state for $Namespace in the $EnvironmentLabel subscription."
    }

    if ($registrationState -eq 'Registered') {
        Write-DeploymentDetail "$EnvironmentLabel provider ${Namespace}: Registered."
        return
    }

    if ($registrationState -eq 'Registering') {
        Write-DeploymentDetail "$EnvironmentLabel provider ${Namespace}: Registering; waiting." Yellow
    }
    else {
        Write-DeploymentDetail "$EnvironmentLabel provider ${Namespace}: $registrationState; registering." Yellow
    }
    Invoke-AzureCli @(
        'provider', 'register',
        '--subscription', $SubscriptionId,
        '--namespace', $Namespace,
        '--wait',
        '--only-show-errors'
    ) "Failed to register $Namespace in the $EnvironmentLabel subscription."

    $registrationState = & az provider show `
        --subscription $SubscriptionId `
        --namespace $Namespace `
        --query registrationState `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or $registrationState -ne 'Registered') {
        throw "$Namespace did not reach Registered state in the $EnvironmentLabel subscription. Current state: $registrationState"
    }
    Write-DeploymentDetail "$EnvironmentLabel provider ${Namespace}: Registered." Green
}

function Ensure-AzureFeatureRegistered {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$FeatureName,
        [Parameter(Mandatory)][string]$EnvironmentLabel,
        [ValidateRange(1, 120)][int]$MaximumAttempts = 60
    )

    $registrationState = & az feature show `
        --subscription $SubscriptionId `
        --namespace $Namespace `
        --name $FeatureName `
        --query properties.state `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read feature state for $Namespace/$FeatureName in the $EnvironmentLabel subscription."
    }

    if ($registrationState -notin @('Registered', 'Registering', 'Pending')) {
        Write-DeploymentDetail "$EnvironmentLabel feature $Namespace/${FeatureName}: $registrationState; registering." Yellow
        Invoke-AzureCli @(
            'feature', 'register',
            '--subscription', $SubscriptionId,
            '--namespace', $Namespace,
            '--name', $FeatureName,
            '--only-show-errors'
        ) "Failed to register feature $Namespace/$FeatureName in the $EnvironmentLabel subscription."
        $registrationState = 'Registering'
    }

    foreach ($attempt in 1..$MaximumAttempts) {
        if ($registrationState -eq 'Registered') {
            break
        }
        if ($registrationState -eq 'Pending') {
            throw "Feature $Namespace/$FeatureName requires Microsoft approval in the $EnvironmentLabel subscription. Open an Azure support request, then resume setup after the feature reaches Registered."
        }
        if ($attempt -lt $MaximumAttempts) {
            Write-DeploymentDetail "$EnvironmentLabel feature $Namespace/${FeatureName}: $registrationState; waiting." Yellow
            Start-Sleep -Seconds 10
        }
        $registrationState = & az feature show `
            --subscription $SubscriptionId `
            --namespace $Namespace `
            --name $FeatureName `
            --query properties.state `
            --output tsv `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Could not refresh feature state for $Namespace/$FeatureName in the $EnvironmentLabel subscription."
        }
    }
    if ($registrationState -ne 'Registered') {
        throw "Feature $Namespace/$FeatureName did not reach Registered state in the $EnvironmentLabel subscription. Current state: $registrationState"
    }

    Invoke-AzureCli @(
        'provider', 'register',
        '--subscription', $SubscriptionId,
        '--namespace', $Namespace,
        '--wait',
        '--only-show-errors'
    ) "Failed to propagate feature $Namespace/$FeatureName through provider $Namespace in the $EnvironmentLabel subscription."
    Write-DeploymentDetail "$EnvironmentLabel feature $Namespace/${FeatureName}: Registered and propagated." Green
}

function Import-LocalConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read local configuration '$Path': $($_.Exception.Message)"
    }
}

function Save-LocalConfiguration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Configuration
    )

    $Configuration |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $Path -Encoding utf8
    Write-Host "Saved non-secret settings to $Path" -ForegroundColor Green
}

function Get-CurrentConfiguration {
    return [ordered]@{
        SourceSubscriptionId = $SourceSubscriptionId
        TargetSubscriptionId = $TargetSubscriptionId
        AdminSourceCidr = $AdminSourceCidr
        SourceLocation = $SourceLocation
        TargetLocation = $TargetLocation
        NamePrefix = $NamePrefix
        AdminUsername = $AdminUsername
        DiscoveryApplianceVmSize = $DiscoveryApplianceVmSize
        ReplicationApplianceVmSize = $ReplicationApplianceVmSize
        HyperVHostVmSize = $HyperVHostVmSize
        WindowsSourceVmSize = $WindowsSourceVmSize
        LinuxSourceVmSize = $LinuxSourceVmSize
        AutoShutdownEnabled = [bool]$AutoShutdownEnabled
        AutoShutdownTime = $AutoShutdownTime
        AutoShutdownTimeZone = $AutoShutdownTimeZone
        DeployTargetNatGateway = [bool]$DeployTargetNatGateway
        DeployAzureMigrateProject = [bool]$DeployAzureMigrateProject
    }
}

function Show-CurrentConfiguration {
    Write-Host ''
    Write-Host 'Effective non-secret deployment settings:' -ForegroundColor Cyan
    [pscustomobject](Get-CurrentConfiguration) | Format-List | Out-Host
}

function Edit-CurrentConfiguration {
    $script:SourceSubscriptionId = Read-ValueWithDefault 'Source subscription ID' $SourceSubscriptionId
    $script:TargetSubscriptionId = Read-ValueWithDefault 'Target subscription ID' $TargetSubscriptionId
    $script:AdminSourceCidr = Read-ValueWithDefault 'Administrator public IPv4 CIDR' $AdminSourceCidr
    $script:SourceLocation = Read-ValueWithDefault 'Simulated source Azure region' $SourceLocation
    $script:TargetLocation = Read-ValueWithDefault 'Migration target and Azure Migrate region' $TargetLocation
    $script:NamePrefix = Read-ValueWithDefault 'Resource name prefix' $NamePrefix
    $script:AdminUsername = Read-ValueWithDefault 'VM administrator username' $AdminUsername
    $script:vmSizesSelectedInteractively = $true
    $script:DiscoveryApplianceVmSize = Read-ValueWithDefault 'Discovery appliance VM size' $DiscoveryApplianceVmSize
    $script:ReplicationApplianceVmSize = Read-ValueWithDefault 'Replication appliance VM size' $ReplicationApplianceVmSize
    $script:HyperVHostVmSize = Read-ValueWithDefault 'Nested Hyper-V host VM size' $HyperVHostVmSize
    $script:WindowsSourceVmSize = Read-ValueWithDefault 'Expected migrated Windows target VM size' $WindowsSourceVmSize
    $script:LinuxSourceVmSize = Read-ValueWithDefault 'Expected migrated Linux target VM size' $LinuxSourceVmSize
    $script:AutoShutdownEnabled = Read-BoolWithDefault 'Enable automatic VM shutdown' ([bool]$AutoShutdownEnabled)
    $script:AutoShutdownTime = Read-ValueWithDefault 'Automatic shutdown time in HHmm format' $AutoShutdownTime
    $script:AutoShutdownTimeZone = Read-ValueWithDefault 'Automatic shutdown time zone' $AutoShutdownTimeZone
    $script:DeployTargetNatGateway = Read-BoolWithDefault 'Deploy target NAT Gateway' ([bool]$DeployTargetNatGateway)
    $script:DeployAzureMigrateProject = Read-BoolWithDefault 'Deploy Azure Migrate project' ([bool]$DeployAzureMigrateProject)
}

function Read-SavedConfigurationAction {
    while ($true) {
        $choice = (Read-Host 'Saved settings: [U]se, [C]hange, or [Q]uit [U]').Trim()
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -match '^(?i:u|use)$') {
            return 'Use'
        }
        if ($choice -match '^(?i:c|change|edit)$') {
            return 'Change'
        }
        if ($choice -match '^(?i:q|quit|exit)$') {
            return 'Quit'
        }
        Write-Warning 'Enter U, C, or Q.'
    }
}

function Get-AzureCliJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $json = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
    $jsonText = $json -join [Environment]::NewLine
    return $jsonText | ConvertFrom-Json
}

function Test-AzureMigrateProjectLocation {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location
    )

    $resourceTypes = @(Get-AzureCliJson @(
        'provider', 'show',
        '--subscription', $SubscriptionId,
        '--namespace', 'Microsoft.Migrate',
        '--query', 'resourceTypes[].{resourceType:resourceType,locations:locations}',
        '--output', 'json',
        '--only-show-errors'
    ) 'Could not read supported Azure Migrate project locations.')
    $projectResourceType = $resourceTypes |
        Where-Object { $_.resourceType -ieq 'migrateProjects' } |
        Select-Object -First 1
    $supportedDisplayNames = if ($null -eq $projectResourceType) {
        @()
    }
    else {
        @($projectResourceType.locations)
    }
    if ($supportedDisplayNames.Count -eq 0) {
        throw 'Microsoft.Migrate provider metadata did not return any migrateProjects locations.'
    }
    $normalizedLocation = ($Location -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    $supportedNames = @(
        $supportedDisplayNames |
            ForEach-Object { ($_ -replace '[^a-zA-Z0-9]', '').ToLowerInvariant() }
    )
    if ($supportedNames -notcontains $normalizedLocation) {
        $choices = ($supportedNames | Sort-Object -Unique) -join ', '
        throw "Azure Migrate projects are not available in '$Location'. Choose a supported metadata region, such as 'westus2'. Supported region names: $choices"
    }

    Write-DeploymentDetail "Azure Migrate project support: PASS in $Location." Green
}

function Get-VmSkuCapabilityValue {
    param(
        [Parameter(Mandatory)][object]$Sku,
        [Parameter(Mandatory)][string]$Name
    )

    $capabilitiesProperty = $Sku.PSObject.Properties['capabilities']
    if ($null -eq $capabilitiesProperty) {
        return $null
    }
    $capability = @($capabilitiesProperty.Value) |
        Where-Object {
            $null -ne $_ -and
            $null -ne $_.PSObject.Properties['name'] -and
            $_.PSObject.Properties['name'].Value -ieq $Name
        } |
        Select-Object -First 1
    if ($null -eq $capability) {
        return $null
    }
    $valueProperty = $capability.PSObject.Properties['value']
    if ($null -eq $valueProperty) {
        return $null
    }
    return $valueProperty.Value
}

function Test-VmSkuSupportsNestedVirtualization {
    param(
        [Parameter(Mandatory)][string]$SkuName,
        [AllowNull()][string]$CapabilityValue
    )

    if (-not [string]::IsNullOrWhiteSpace($CapabilityValue)) {
        return $CapabilityValue -match '^(?i:true)$'
    }

    return $SkuName -match '^Standard_D\d+as_v7$' -or
        $SkuName -match '^Standard_D\d+s_v6$' -or
        $SkuName -match '^Standard_D\d+s_v5$'
}

function Get-ComputeOptionAssessment {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][object[]]$RequestedVirtualMachines
    )

    $issues = [Collections.Generic.List[string]]::new()
    Write-DeploymentDetail "Inspecting VM SKUs in $Location for subscription $SubscriptionId."
    $skuCatalog = @(Get-AzureCliJson @(
        'vm', 'list-skus',
        '--subscription', $SubscriptionId,
        '--location', $Location,
        '--resource-type', 'virtualMachines',
        '--all',
        '--output', 'json',
        '--only-show-errors'
    ) "Could not list subscription-aware VM SKU availability in '$Location'.")

    $resolvedVirtualMachines = [Collections.Generic.List[object]]::new()
    foreach ($request in $RequestedVirtualMachines) {
        $sku = $skuCatalog |
            Where-Object { $_.name -ieq $request.Size } |
            Select-Object -First 1
        if ($null -eq $sku) {
            $issues.Add("$($request.Role): $($request.Size) is not published in $Location")
            Write-DeploymentDetail "$($request.Role): $($request.Size) is not published." Yellow
            continue
        }

        $restrictionsProperty = $sku.PSObject.Properties['restrictions']
        $locationRestrictions = @()
        if ($null -ne $restrictionsProperty) {
            $locationRestrictions = @($restrictionsProperty.Value | Where-Object {
                $null -ne $_ -and
                $null -ne $_.PSObject.Properties['type'] -and
                $_.PSObject.Properties['type'].Value -ieq 'Location'
            })
        }
        if ($locationRestrictions.Count -gt 0) {
            $reasonCodes = @(
                $locationRestrictions |
                    ForEach-Object { $_.PSObject.Properties['reasonCode'].Value } |
                    Sort-Object -Unique
            )
            $issues.Add("$($request.Role): $($request.Size) is restricted ($($reasonCodes -join ', '))")
            Write-DeploymentDetail "$($request.Role): $($request.Size) restricted ($($reasonCodes -join ', '))." Yellow
            continue
        }

        $cores = [int](Get-VmSkuCapabilityValue -Sku $sku -Name 'vCPUs')
        $memoryGb = [decimal](Get-VmSkuCapabilityValue -Sku $sku -Name 'MemoryGB')
        $vCpusPerCoreValue = Get-VmSkuCapabilityValue -Sku $sku -Name 'vCPUsPerCore'
        $vCpusPerCore = if ($null -eq $vCpusPerCoreValue) { 1 } else { [int]$vCpusPerCoreValue }
        $physicalCores = [int]($cores / $vCpusPerCore)
        $cpuArchitecture = Get-VmSkuCapabilityValue -Sku $sku -Name 'CpuArchitectureType'
        $hyperVGenerations = Get-VmSkuCapabilityValue -Sku $sku -Name 'HyperVGenerations'
        $nestedVirtualization = Get-VmSkuCapabilityValue -Sku $sku -Name 'NestedVirtualization'
        if ($cores -lt [int]$request.MinimumCores -or $memoryGb -lt [decimal]$request.MinimumMemoryGb) {
            $issues.Add("$($request.Role): $($request.Size) provides $cores vCPUs/$memoryGb GB; requires at least $($request.MinimumCores) vCPUs/$($request.MinimumMemoryGb) GB")
            continue
        }
        $minimumPhysicalCoresProperty = $request.PSObject.Properties['MinimumPhysicalCores']
        if ($null -ne $minimumPhysicalCoresProperty -and
            $physicalCores -lt [int]$minimumPhysicalCoresProperty.Value) {
            $issues.Add("$($request.Role): $($request.Size) provides $physicalCores physical cores ($cores vCPUs); requires at least $($minimumPhysicalCoresProperty.Value) physical cores")
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($cpuArchitecture) -and $cpuArchitecture -notmatch 'x64') {
            $issues.Add("$($request.Role): $($request.Size) uses unsupported CPU architecture '$cpuArchitecture'")
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($hyperVGenerations) -and $hyperVGenerations -notmatch 'V2') {
            $issues.Add("$($request.Role): $($request.Size) does not advertise Hyper-V generation V2 support")
            continue
        }
        $nestedVirtualizationProperty = $request.PSObject.Properties['RequiresNestedVirtualization']
        if (
            $null -ne $nestedVirtualizationProperty -and
            [bool]$nestedVirtualizationProperty.Value -and
            -not (Test-VmSkuSupportsNestedVirtualization `
                -SkuName ([string]$sku.name) `
                -CapabilityValue $nestedVirtualization)
        ) {
            $issues.Add("$($request.Role): $($request.Size) is not in a documented nested-virtualization series")
            continue
        }

        $resolvedVirtualMachines.Add([pscustomobject]@{
            Role = $request.Role
            Size = $sku.name
            Cores = $cores
            PhysicalCores = $physicalCores
            VCpusPerCore = $vCpusPerCore
            MemoryGb = $memoryGb
            Family = $sku.family
            NestedVirtualization = $nestedVirtualization
        })
        Write-DeploymentDetail "$($request.Role): $($sku.name), $physicalCores physical cores/$cores vCPUs, $memoryGb GB RAM, family $($sku.family), unrestricted." Green
    }

    if ($issues.Count -gt 0) {
        return [pscustomobject]@{
            Eligible = $false
            Location = $Location
            Issues = @($issues)
            VirtualMachines = @($resolvedVirtualMachines)
            RequiredRegionalCores = 0
            AvailableRegionalCores = 0
            FamilyQuota = @()
        }
    }

    $usage = @(Get-AzureCliJson @(
        'vm', 'list-usage',
        '--subscription', $SubscriptionId,
        '--location', $Location,
        '--output', 'json',
        '--only-show-errors'
    ) "Could not read compute quota in '$Location'.")
    $requiredRegionalCores = [int](($resolvedVirtualMachines | Measure-Object -Property Cores -Sum).Sum)
    $regionalQuota = $usage |
        Where-Object { $_.name.value -eq 'cores' } |
        Select-Object -First 1
    if ($null -eq $regionalQuota) {
        $issues.Add("Total regional vCPU quota was not returned for '$Location'")
        $availableRegionalCores = 0
    }
    else {
        $availableRegionalCores = [int]$regionalQuota.limit - [int]$regionalQuota.currentValue
        Write-DeploymentDetail "Regional vCPU quota in ${Location}: $($regionalQuota.currentValue)/$($regionalQuota.limit) used; $requiredRegionalCores required."
        if ($availableRegionalCores -lt $requiredRegionalCores) {
            $issues.Add("Total regional vCPU quota requires $requiredRegionalCores; $availableRegionalCores is available")
        }
    }

    $familyQuotaSummary = [Collections.Generic.List[object]]::new()
    foreach ($familyGroup in $resolvedVirtualMachines | Group-Object -Property Family) {
        $familyName = $familyGroup.Name
        $requiredFamilyCores = [int](($familyGroup.Group | Measure-Object -Property Cores -Sum).Sum)
        $familyQuota = $usage |
            Where-Object { $_.name.value -ieq $familyName } |
            Select-Object -First 1
        if ($null -eq $familyQuota) {
            $issues.Add("Quota record '$familyName' was not returned in '$Location'")
            $availableFamilyCores = 0
        }
        else {
            $availableFamilyCores = [int]$familyQuota.limit - [int]$familyQuota.currentValue
            Write-DeploymentDetail "$($familyQuota.name.localizedValue): $($familyQuota.currentValue)/$($familyQuota.limit) used; $requiredFamilyCores required."
            if ($availableFamilyCores -lt $requiredFamilyCores) {
                $issues.Add("$($familyQuota.name.localizedValue) requires $requiredFamilyCores vCPUs; $availableFamilyCores is available")
            }
        }
        $familyQuotaSummary.Add([pscustomobject]@{
            Family = $familyName
            RequiredCores = $requiredFamilyCores
            AvailableCores = $availableFamilyCores
        })
    }

    return [pscustomobject]@{
        Eligible = $issues.Count -eq 0
        Location = $Location
        Issues = @($issues)
        VirtualMachines = @($resolvedVirtualMachines)
        RequiredRegionalCores = $requiredRegionalCores
        AvailableRegionalCores = $availableRegionalCores
        FamilyQuota = @($familyQuotaSummary)
    }
}

function New-RequestedVirtualMachineSet {
    param(
        [Parameter(Mandatory)][string]$DiscoverySize,
        [Parameter(Mandatory)][string]$ReplicationSize,
        [Parameter(Mandatory)][string]$HyperVHostSize
    )

    return @(
        [pscustomobject]@{ Role = 'discovery appliance'; Size = $DiscoverySize; MinimumCores = 8; MinimumMemoryGb = 32 }
        [pscustomobject]@{ Role = 'replication appliance'; Size = $ReplicationSize; MinimumCores = 8; MinimumPhysicalCores = 8; MinimumMemoryGb = 16 }
        [pscustomobject]@{ Role = 'nested Hyper-V host'; Size = $HyperVHostSize; MinimumCores = 16; MinimumMemoryGb = 64; RequiresNestedVirtualization = $true }
    )
}

function New-TargetVirtualMachineSet {
    param(
        [Parameter(Mandatory)][string]$WindowsSourceSize,
        [Parameter(Mandatory)][string]$LinuxSourceSize
    )

    return @(
        [pscustomobject]@{ Role = 'migrated Windows target'; Size = $WindowsSourceSize; MinimumCores = 2; MinimumMemoryGb = 8 }
        [pscustomobject]@{ Role = 'migrated Linux target'; Size = $LinuxSourceSize; MinimumCores = 2; MinimumMemoryGb = 4 }
    )
}

function Resolve-RegionalDefaultComputeProfile {
    param(
        [Parameter(Mandatory)][string]$SourceSubscriptionId,
        [Parameter(Mandatory)][string]$TargetSubscriptionId,
        [Parameter(Mandatory)][string]$SourceLocation,
        [Parameter(Mandatory)][string]$TargetLocation,
        [Parameter(Mandatory)][object[]]$Profiles,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    Write-DeploymentPhase 'Selecting region-compatible default VM sizes'
    $seenProfiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($profile in $Profiles) {
        $profileSignature = @(
            $profile.DiscoveryApplianceVmSize
            $profile.ReplicationApplianceVmSize
            $profile.HyperVHostVmSize
            $profile.WindowsSourceVmSize
            $profile.LinuxSourceVmSize
        ) -join '|'
        if (-not $seenProfiles.Add($profileSignature)) {
            continue
        }
        $sourceRequests = New-RequestedVirtualMachineSet `
            -DiscoverySize $profile.DiscoveryApplianceVmSize `
            -ReplicationSize $profile.ReplicationApplianceVmSize `
            -HyperVHostSize $profile.HyperVHostVmSize
        $targetRequests = New-TargetVirtualMachineSet `
            -WindowsSourceSize $profile.WindowsSourceVmSize `
            -LinuxSourceSize $profile.LinuxSourceVmSize
        $sourceAssessment = Get-ComputeOptionAssessment `
            -SubscriptionId $SourceSubscriptionId `
            -Location $SourceLocation `
            -RequestedVirtualMachines $sourceRequests
        $targetAssessment = Get-ComputeOptionAssessment `
            -SubscriptionId $TargetSubscriptionId `
            -Location $TargetLocation `
            -RequestedVirtualMachines $targetRequests

        if ($sourceAssessment.Eligible -and $targetAssessment.Eligible) {
            $script:DiscoveryApplianceVmSize = $profile.DiscoveryApplianceVmSize
            $script:ReplicationApplianceVmSize = $profile.ReplicationApplianceVmSize
            $script:HyperVHostVmSize = $profile.HyperVHostVmSize
            $script:WindowsSourceVmSize = $profile.WindowsSourceVmSize
            $script:LinuxSourceVmSize = $profile.LinuxSourceVmSize
            $env:AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE = $script:DiscoveryApplianceVmSize
            $env:AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE = $script:ReplicationApplianceVmSize
            $env:AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE = $script:HyperVHostVmSize
            Save-LocalConfiguration -Path $ConfigurationPath -Configuration (Get-CurrentConfiguration)
            Write-DeploymentDetail "Selected $($profile.Name): discovery $($profile.DiscoveryApplianceVmSize), replication $($profile.ReplicationApplianceVmSize), Hyper-V $($profile.HyperVHostVmSize), target assumptions $($profile.WindowsSourceVmSize)/$($profile.LinuxSourceVmSize)." Green
            return
        }

        $sourceIssues = if ($sourceAssessment.Eligible) { 'eligible' } else { $sourceAssessment.Issues -join '; ' }
        $targetIssues = if ($targetAssessment.Eligible) { 'eligible' } else { $targetAssessment.Issues -join '; ' }
        Write-DeploymentDetail "Skipped $($profile.Name). Source: $sourceIssues. Target: $targetIssues." Yellow
    }

    throw "No default VM profile passed SKU restriction and quota checks in source region '$SourceLocation' and target region '$TargetLocation'. Supply explicit VM sizes or select other regions."
}

function Find-RecommendedComputeOptions {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$CurrentLocation,
        [Parameter(Mandatory)][object[]]$RequestedVirtualMachines,
        [Parameter(Mandatory)][object[]]$FallbackProfiles,
        [int]$MaximumResults = 3
    )

    Write-Host 'Searching for alternate compute regions in the same Azure geography...' -ForegroundColor Cyan
    $locations = @(Get-AzureCliJson @(
        'account', 'list-locations',
        '--subscription', $SubscriptionId,
        '--query', '[].{name:name,geographyGroup:metadata.geographyGroup}',
        '--output', 'json',
        '--only-show-errors'
    ) 'Could not list Azure regions for recommendation.')
    $currentRegion = $locations |
        Where-Object { $_.name -ieq $CurrentLocation } |
        Select-Object -First 1
    if ($null -eq $currentRegion -or [string]::IsNullOrWhiteSpace($currentRegion.geographyGroup)) {
        Write-Warning "Could not determine the Azure geography for '$CurrentLocation'; recommendations will use global region fallback."
    }

    $preferredRegions = @(
        'westus2', 'centralus', 'eastus2', 'eastus',
        'southcentralus', 'northcentralus', 'westcentralus', 'westus',
        'northeurope', 'westeurope', 'uksouth', 'ukwest',
        'canadacentral', 'canadaeast',
        'australiaeast', 'australiasoutheast',
        'southeastasia', 'eastasia'
    )
    $sameGeographyRegions = @(
        $locations |
            Where-Object {
                $null -ne $currentRegion -and
                -not [string]::IsNullOrWhiteSpace($currentRegion.geographyGroup) -and
                $_.geographyGroup -eq $currentRegion.geographyGroup -and
                $_.name -ine $CurrentLocation
            } |
            Select-Object -ExpandProperty name -Unique
    )
    $sameGeographyCandidateRegions = @(
        $preferredRegions | Where-Object { $sameGeographyRegions -contains $_ }
        $sameGeographyRegions |
            Where-Object { $preferredRegions -notcontains $_ } |
            Sort-Object
    )
    $globalRegions = @(
        $locations |
            Where-Object {
                $_.name -ine $CurrentLocation -and
                $sameGeographyRegions -notcontains $_.name
            } |
            Select-Object -ExpandProperty name -Unique
    )
    $globalCandidateRegions = @(
        $preferredRegions | Where-Object { $globalRegions -contains $_ }
        $globalRegions |
            Where-Object { $preferredRegions -notcontains $_ } |
            Sort-Object
    )
    $searchScopes = @(
        [pscustomobject]@{
            Name = 'Same geography'
            Regions = $sameGeographyCandidateRegions
            IncludeCurrentRegionForFallbackProfiles = $true
        }
        [pscustomobject]@{
            Name = 'Global fallback'
            Regions = $globalCandidateRegions
            IncludeCurrentRegionForFallbackProfiles = $false
        }
    )

    foreach ($searchScope in $searchScopes) {
        if (@($searchScope.Regions).Count -eq 0) {
            continue
        }
        $recommendations = [Collections.Generic.List[object]]::new()
        foreach ($candidateRegion in $searchScope.Regions) {
            try {
                $assessment = Get-ComputeOptionAssessment `
                    -SubscriptionId $SubscriptionId `
                    -Location $candidateRegion `
                    -RequestedVirtualMachines $RequestedVirtualMachines
                if (-not $assessment.Eligible) {
                    continue
                }

                $familyHeadroom = @(
                    $assessment.FamilyQuota |
                        ForEach-Object { [int]$_.AvailableCores - [int]$_.RequiredCores }
                )
                $quotaHeadroom = @(
                    [int]$assessment.AvailableRegionalCores - [int]$assessment.RequiredRegionalCores
                    $familyHeadroom
                ) | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
                $recommendations.Add([pscustomobject]@{
                    Region = $candidateRegion
                    Scope = $searchScope.Name
                    Profile = 'Current sizes'
                    RequestedVirtualMachines = $RequestedVirtualMachines
                    RequiredCores = $assessment.RequiredRegionalCores
                    AvailableCores = $assessment.AvailableRegionalCores
                    QuotaHeadroom = [int]$quotaHeadroom
                })
            }
            catch {
                Write-Verbose "Skipping '$candidateRegion': $($_.Exception.Message)"
            }
        }

        if ($recommendations.Count -eq 0) {
            $profileRegions = if ($searchScope.IncludeCurrentRegionForFallbackProfiles) {
                @($CurrentLocation) + @($searchScope.Regions)
            }
            else {
                @($searchScope.Regions)
            }
            foreach ($profile in $FallbackProfiles) {
                $profileVirtualMachines = New-RequestedVirtualMachineSet `
                    -DiscoverySize $profile.DiscoveryApplianceVmSize `
                    -ReplicationSize $profile.ReplicationApplianceVmSize `
                    -HyperVHostSize $profile.HyperVHostVmSize
                foreach ($candidateRegion in $profileRegions) {
                    try {
                        $assessment = Get-ComputeOptionAssessment `
                            -SubscriptionId $SubscriptionId `
                            -Location $candidateRegion `
                            -RequestedVirtualMachines $profileVirtualMachines
                        if (-not $assessment.Eligible) {
                            continue
                        }
                        $familyHeadroom = @(
                            $assessment.FamilyQuota |
                                ForEach-Object { [int]$_.AvailableCores - [int]$_.RequiredCores }
                        )
                        $quotaHeadroom = @(
                            [int]$assessment.AvailableRegionalCores - [int]$assessment.RequiredRegionalCores
                            $familyHeadroom
                        ) | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
                        $recommendations.Add([pscustomobject]@{
                            Region = $candidateRegion
                            Scope = $searchScope.Name
                            Profile = $profile.Name
                            RequestedVirtualMachines = $profileVirtualMachines
                            RequiredCores = $assessment.RequiredRegionalCores
                            AvailableCores = $assessment.AvailableRegionalCores
                            QuotaHeadroom = [int]$quotaHeadroom
                        })
                    }
                    catch {
                        Write-Verbose "Skipping '$($profile.Name)' in '$candidateRegion': $($_.Exception.Message)"
                    }
                }
            }
        }

        if ($recommendations.Count -gt 0) {
            return @(
                $recommendations |
                    Sort-Object `
                        @{ Expression = { $_.Profile -ne 'Current sizes' }; Ascending = $true }, `
                        @{ Expression = 'QuotaHeadroom'; Descending = $true }, `
                        @{ Expression = 'Region'; Ascending = $true } |
                    Select-Object -First $MaximumResults
            )
        }
    }

    return @()
}

function Format-ComputeOptionRecommendations {
    param([Parameter(Mandatory)][object[]]$Recommendations)

    if ($Recommendations.Count -eq 0) {
        return 'No same-geography or global region with an allowlisted equivalent SKU profile passed subscription restrictions and quota checks.'
    }
    $formattedOptions = $Recommendations | ForEach-Object {
        $sizes = @($_.RequestedVirtualMachines | ForEach-Object { $_.Size }) -join '/'
        "$($_.Region) [$($_.Scope); $($_.Profile): $sizes; quota headroom $($_.QuotaHeadroom) vCPUs]"
    }
    return "Recommended compute options: $($formattedOptions -join '; ')."
}

function Get-ArmValidatedComputeOptions {
    param(
        [Parameter(Mandatory)][object[]]$Recommendations,
        [Parameter(Mandatory)][string]$TargetSubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentLocation,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][string]$ParameterFile,
        [int]$MaximumResults = 3
    )

    $validatedOptions = [Collections.Generic.List[object]]::new()
    $originalEnvironment = @{
        SourceLocation = $env:AZURE_MIGRATE_LAB_SOURCE_LOCATION
        Discovery = $env:AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE
        Replication = $env:AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE
        HyperVHost = $env:AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE
    }
    try {
        foreach ($recommendation in $Recommendations) {
            if ($validatedOptions.Count -ge $MaximumResults) {
                break
            }
            $sizes = @($recommendation.RequestedVirtualMachines)
            $env:AZURE_MIGRATE_LAB_SOURCE_LOCATION = $recommendation.Region
            $env:AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE = $sizes[0].Size
            $env:AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE = $sizes[1].Size
            $env:AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE = $sizes[2].Size

            & az deployment sub validate `
                --subscription $TargetSubscriptionId `
                --name 'azure-migrate-lab-option-validation' `
                --location $DeploymentLocation `
                --template-file $TemplateFile `
                --parameters $ParameterFile `
                --output none `
                --only-show-errors 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "ARM validation rejected $($recommendation.Profile) in $($recommendation.Region)."
                continue
            }

            & az deployment sub what-if `
                --subscription $TargetSubscriptionId `
                --name 'azure-migrate-lab-option-preview' `
                --location $DeploymentLocation `
                --template-file $TemplateFile `
                --parameters $ParameterFile `
                --result-format ResourceIdOnly `
                --output none `
                --only-show-errors 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "ARM what-if rejected $($recommendation.Profile) in $($recommendation.Region)."
                continue
            }

            $validatedOptions.Add($recommendation)
        }
    }
    finally {
        $env:AZURE_MIGRATE_LAB_SOURCE_LOCATION = $originalEnvironment.SourceLocation
        $env:AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE = $originalEnvironment.Discovery
        $env:AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE = $originalEnvironment.Replication
        $env:AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE = $originalEnvironment.HyperVHost
    }

    return @($validatedOptions)
}

function Select-ComputeOption {
    param([Parameter(Mandatory)][object[]]$Options)

    if ($Options.Count -eq 0) {
        throw 'No compute option passed SKU restriction, quota, ARM validation, and what-if checks. Retry later, request quota/SKU access, choose other sizes, or use an on-demand capacity reservation.'
    }

    Write-Host ''
    Write-Host 'Validated compute alternatives:' -ForegroundColor Cyan
    for ($index = 0; $index -lt $Options.Count; $index++) {
        $option = $Options[$index]
        $sizes = @($option.RequestedVirtualMachines | ForEach-Object { $_.Size }) -join ', '
        Write-Host "[$($index + 1)] $($option.Region) / $($option.Scope) / $($option.Profile) / $sizes / quota headroom $($option.QuotaHeadroom) vCPUs"
    }
    Write-Host '[Q] Quit without changing cached settings'

    while ($true) {
        $selection = (Read-Host 'Select a compute option').Trim()
        if ($selection -match '^(?i:q|quit)$') {
            throw 'Deployment cancelled. No compute alternative was selected.'
        }
        $selectedIndex = 0
        if (
            [int]::TryParse($selection, [ref]$selectedIndex) -and
            $selectedIndex -ge 1 -and
            $selectedIndex -le $Options.Count
        ) {
            return $Options[$selectedIndex - 1]
        }
        Write-Warning "Enter a number from 1 to $($Options.Count), or Q."
    }
}

function Set-ComputeOption {
    param(
        [Parameter(Mandatory)][object]$Option,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    $sizes = @($Option.RequestedVirtualMachines)
    $script:SourceLocation = $Option.Region
    $script:DiscoveryApplianceVmSize = $sizes[0].Size
    $script:ReplicationApplianceVmSize = $sizes[1].Size
    $script:HyperVHostVmSize = $sizes[2].Size
    $env:AZURE_MIGRATE_LAB_SOURCE_LOCATION = $script:SourceLocation
    $env:AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE = $script:DiscoveryApplianceVmSize
    $env:AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE = $script:ReplicationApplianceVmSize
    $env:AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE = $script:HyperVHostVmSize
    Save-LocalConfiguration -Path $ConfigurationPath -Configuration (Get-CurrentConfiguration)
    Show-CurrentConfiguration
}

function Resolve-ComputeFailure {
    param(
        [Parameter(Mandatory)][string]$SourceSubscriptionId,
        [Parameter(Mandatory)][string]$TargetSubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentLocation,
        [Parameter(Mandatory)][string]$CurrentLocation,
        [Parameter(Mandatory)][object[]]$RequestedVirtualMachines,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][string]$ParameterFile,
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [switch]$CurrentLocationOnly
    )

    $recommendations = @(Find-RecommendedComputeOptions `
        -SubscriptionId $SourceSubscriptionId `
        -CurrentLocation $CurrentLocation `
        -RequestedVirtualMachines $RequestedVirtualMachines `
        -FallbackProfiles $fallbackComputeProfiles `
        -MaximumResults 12)
    if ($CurrentLocationOnly) {
        $currentLocationRecommendations = @(
            $recommendations | Where-Object { $_.Region -ieq $CurrentLocation }
        )
        if ($currentLocationRecommendations.Count -eq 0) {
            $alternativeText = Format-ComputeOptionRecommendations -Recommendations $recommendations
            throw "Existing deterministic resource groups cannot move from '$CurrentLocation'. No equivalent SKU profile passed checks in the current region. $alternativeText To use another region, rerun with a new -NamePrefix or explicitly remove the partial lab resource groups first."
        }
        $recommendations = $currentLocationRecommendations
    }
    Write-Host 'Running ARM validation and what-if against candidate options...' -ForegroundColor Cyan
    $validatedOptions = @(Get-ArmValidatedComputeOptions `
        -Recommendations $recommendations `
        -TargetSubscriptionId $TargetSubscriptionId `
        -DeploymentLocation $DeploymentLocation `
        -TemplateFile $TemplateFile `
        -ParameterFile $ParameterFile)
    $selectedOption = Select-ComputeOption -Options $validatedOptions
    Set-ComputeOption -Option $selectedOption -ConfigurationPath $ConfigurationPath
}

function Get-AzureDeploymentFailure {
    param([Parameter(Mandatory)][object[]]$Output)

    $outputText = ($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $details = [Collections.Generic.List[string]]::new()
    $jsonStart = $outputText.IndexOf('{')
    if ($jsonStart -ge 0) {
        try {
            $payload = $outputText.Substring($jsonStart) | ConvertFrom-Json
            function Add-ErrorNode {
                param([object]$Node)
                if ($null -eq $Node) { return }
                $codeProperty = $Node.PSObject.Properties['code']
                $messageProperty = $Node.PSObject.Properties['message']
                if ($null -ne $codeProperty -or $null -ne $messageProperty) {
                    $code = if ($null -ne $codeProperty) { $codeProperty.Value } else { 'Error' }
                    $message = if ($null -ne $messageProperty) { $messageProperty.Value } else { '' }
                    $details.Add("$code`: $message")
                }
                $errorProperty = $Node.PSObject.Properties['error']
                if ($null -ne $errorProperty) { Add-ErrorNode -Node $errorProperty.Value }
                $propertiesProperty = $Node.PSObject.Properties['properties']
                if ($null -ne $propertiesProperty) { Add-ErrorNode -Node $propertiesProperty.Value }
                $detailsProperty = $Node.PSObject.Properties['details']
                if ($null -ne $detailsProperty) {
                    foreach ($child in @($detailsProperty.Value)) { Add-ErrorNode -Node $child }
                }
            }
            Add-ErrorNode -Node $payload
        }
        catch {
            Write-Verbose "Could not parse deployment failure JSON: $($_.Exception.Message)"
        }
    }
    if ($details.Count -eq 0) {
        $details.Add($outputText)
    }

    $category = if ($outputText -match 'osProfile\.adminPassword|Admin password specified is not allowed') {
        'Password'
    }
    elseif ($outputText -match 'SkuNotAvailable|AllocationFailed|ZonalAllocationFailed|Capacity Restrictions|NotAvailableForSubscription') {
        'Capacity'
    }
    elseif ($outputText -match 'QuotaExceeded|OperationNotAllowed.*quota|exceed.*quota') {
        'Quota'
    }
    elseif ($outputText -match 'RequestDisallowedByPolicy|PolicyViolation') {
        'Policy'
    }
    elseif ($outputText -match 'MissingSubscriptionRegistration|NoRegisteredProviderFound') {
        'Provider'
    }
    else {
        'Other'
    }

    return [pscustomobject]@{
        Category = $category
        Details = @($details | Sort-Object -Unique)
        RawText = $outputText
    }
}

function Show-ExistingDeploymentState {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentName
    )

    $state = & az deployment sub show `
        --subscription $SubscriptionId `
        --name $DeploymentName `
        --query properties.provisioningState `
        --output tsv `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($state)) {
        return $null
    }
    if ($state -eq 'Failed') {
        Write-Warning "A failed '$DeploymentName' deployment exists. The script will resume incrementally with the same deterministic resource names; it will not delete resource groups."
        $failedTargets = @(& az deployment operation sub list `
            --subscription $SubscriptionId `
            --name $DeploymentName `
            --query "[?properties.provisioningState=='Failed'].properties.targetResource.resourceName" `
            --output tsv `
            --only-show-errors 2>$null)
        if ($LASTEXITCODE -eq 0 -and $failedTargets.Count -gt 0) {
            Write-Host "Failed deployment targets: $($failedTargets -join ', ')"
        }
    }
    elseif ($state -eq 'Succeeded') {
        Write-Host "Existing deployment '$DeploymentName' succeeded previously; this run will apply an incremental update."
    }
    return $state
}

function Get-DeploymentMetadataLocation {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)][string]$DefaultLocation
    )

    $existingLocation = & az deployment sub show `
        --subscription $SubscriptionId `
        --name $DeploymentName `
        --query location `
        --output tsv `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$existingLocation)) {
        Write-DeploymentDetail "Deployment history location: $existingLocation (reused from '$DeploymentName')."
        return [string]$existingLocation
    }

    Write-DeploymentDetail "Deployment history location: $DefaultLocation (new deployment default)."
    return $DefaultLocation
}

function Show-AzureDeploymentOperations {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentName
    )

    Write-DeploymentPhase "ARM operation summary for $DeploymentName"
    try {
        $operations = @(Get-AzureCliJson @(
            'deployment', 'operation', 'sub', 'list',
            '--subscription', $SubscriptionId,
            '--name', $DeploymentName,
            '--output', 'json',
            '--only-show-errors'
        ) "Could not list operations for deployment '$DeploymentName'.")
    }
    catch {
        Write-DeploymentDetail $_.Exception.Message Yellow
        return
    }

    foreach ($operation in $operations | Sort-Object { $_.properties.timestamp }) {
        $properties = $operation.properties
        $target = $properties.targetResource
        $resourceLabel = if ($null -eq $target) {
            $operation.id
        }
        else {
            "$($target.resourceType)/$($target.resourceName)"
        }
        $state = [string]$properties.provisioningState
        $color = if ($state -eq 'Succeeded') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-DeploymentDetail "$state - $resourceLabel" $color
    }
}

function Wait-AzureSubscriptionDeployment {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentName,
        [ValidateRange(5, 300)][int]$PollIntervalSeconds = 30
    )

    $reportedOperationStates = @{}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $deployment = Get-AzureCliJson @(
            'deployment', 'sub', 'show',
            '--subscription', $SubscriptionId,
            '--name', $DeploymentName,
            '--output', 'json',
            '--only-show-errors'
        ) "Could not read deployment '$DeploymentName' while waiting for ARM."
        $state = [string]$deployment.properties.provisioningState
        $operations = @(Get-AzureCliJson @(
            'deployment', 'operation', 'sub', 'list',
            '--subscription', $SubscriptionId,
            '--name', $DeploymentName,
            '--output', 'json',
            '--only-show-errors'
        ) "Could not list operations for deployment '$DeploymentName' while waiting for ARM.")

        foreach ($operation in $operations | Sort-Object { $_.properties.timestamp }) {
            $properties = $operation.properties
            $target = $properties.targetResource
            $resourceLabel = if ($null -eq $target) {
                $operation.id
            }
            else {
                "$($target.resourceType)/$($target.resourceName)"
            }
            $operationState = [string]$properties.provisioningState
            $operationKey = [string]$operation.id
            if ($reportedOperationStates[$operationKey] -ne $operationState) {
                $color = if ($operationState -eq 'Succeeded') {
                    [ConsoleColor]::Green
                }
                elseif ($operationState -eq 'Failed') {
                    [ConsoleColor]::Red
                }
                else {
                    [ConsoleColor]::Yellow
                }
                Write-DeploymentDetail "$operationState - $resourceLabel" $color
                $reportedOperationStates[$operationKey] = $operationState
            }
        }

        $elapsed = $watch.Elapsed.ToString('hh\:mm\:ss')
        Write-DeploymentDetail "ARM deployment state: $state (elapsed $elapsed)."
        if ($state -in @('Succeeded', 'Failed', 'Canceled')) {
            return $deployment
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Get-ExistingLabWindowsVirtualMachines {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Prefix
    )

    $resourceGroups = @(& az group list `
        --subscription $SubscriptionId `
        --query "[?starts_with(name, 'rg-$Prefix-source-')].name" `
        --output tsv `
        --only-show-errors)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect existing source resource groups before incremental deployment.'
    }

    $existingVirtualMachines = [Collections.Generic.List[object]]::new()
    foreach ($resourceGroupName in $resourceGroups) {
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            continue
        }
        $virtualMachines = @(Get-AzureCliJson @(
            'vm', 'list',
            '--subscription', $SubscriptionId,
            '--resource-group', $resourceGroupName,
            '--query', "[?storageProfile.osDisk.osType=='Windows'].{name:name,resourceGroup:resourceGroup}",
            '--output', 'json',
            '--only-show-errors'
        ) "Could not inspect Windows VMs in '$resourceGroupName'.")
        foreach ($virtualMachine in $virtualMachines) {
            $existingVirtualMachines.Add($virtualMachine)
        }
    }
    return @($existingVirtualMachines)
}

function Get-ExistingLabSourceResourceGroups {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Prefix
    )

    return @(Get-AzureCliJson @(
        'group', 'list',
        '--subscription', $SubscriptionId,
        '--query', "[?starts_with(name, 'rg-$Prefix-source-')].{name:name,location:location}",
        '--output', 'json',
        '--only-show-errors'
    ) 'Could not inspect existing source resource groups before incremental deployment.')
}

function Get-ExistingLabTargetResourceGroups {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Prefix
    )

    return @(Get-AzureCliJson @(
        'group', 'list',
        '--subscription', $SubscriptionId,
        '--query', "[?starts_with(name, 'rg-$Prefix-target-')].{name:name,location:location}",
        '--output', 'json',
        '--only-show-errors'
    ) 'Could not inspect existing target resource groups before incremental deployment.')
}

function Remove-LabJitNetworkAccessPolicy {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Prefix
    )

    $policyUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Security/locations/$Location/jitNetworkAccessPolicies/default?api-version=2020-01-01"
    $output = @(& az rest --method get --url $policyUrl --only-show-errors --output json 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        if ($details -match '(?i)ResourceNotFound|NotFound|404') {
            return
        }
        throw "Could not inspect Defender JIT policy in '$ResourceGroupName'.$([Environment]::NewLine)$details"
    }

    $policy = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    $configuredVirtualMachines = @($policy.properties.virtualMachines)
    $labVmNamePattern = '^vm-{0}-(disc|repl|hyperv)-' -f [regex]::Escape($Prefix)
    $nonLabVirtualMachines = @(
        $configuredVirtualMachines | Where-Object {
            $vmName = ([string]$_.id).TrimEnd('/').Split('/')[-1]
            $vmName -notmatch $labVmNamePattern
        }
    )
    if ($nonLabVirtualMachines.Count -gt 0) {
        $nonLabIds = $nonLabVirtualMachines | ForEach-Object { [string]$_.id }
        throw "Defender JIT policy in '$ResourceGroupName' includes non-lab VMs; refusing to delete it: $($nonLabIds -join ', ')."
    }
    if ($configuredVirtualMachines.Count -eq 0) {
        return
    }

    Write-DeploymentDetail "Removing Defender JIT policy for $($configuredVirtualMachines.Count) lab VM(s) in '$ResourceGroupName'; Bicep will restore CIDR-restricted management rules." Yellow
    Invoke-AzureCli @(
        'rest', '--method', 'delete',
        '--url', $policyUrl,
        '--only-show-errors',
        '--output', 'none'
    ) "Could not remove Defender JIT policy in '$ResourceGroupName'."
}

function Confirm-ExistingWindowsPasswordRotation {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VirtualMachines)

    if ($VirtualMachines.Count -eq 0) {
        return $false
    }

    Write-Warning 'Windows VMs from a previous partial deployment already exist:'
    foreach ($virtualMachine in $VirtualMachines) {
        Write-Host "- $($virtualMachine.resourceGroup)/$($virtualMachine.name)"
    }
    Write-Host 'After a successful incremental deployment, their administrator passwords must be aligned with the newly generated password.'
    $confirmation = (Read-Host 'Type ROTATE to approve password rotation after deployment, or Q to quit').Trim()
    if ($confirmation -cne 'ROTATE') {
        throw 'Deployment cancelled before Azure changes. Existing Windows VM password rotation was not approved.'
    }
    return $true
}

function Set-ExistingWindowsAdminPasswords {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][object[]]$VirtualMachines,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password
    )

    foreach ($virtualMachine in $VirtualMachines) {
        Invoke-AzureCli @(
            'vm', 'user', 'update',
            '--subscription', $SubscriptionId,
            '--resource-group', $virtualMachine.resourceGroup,
            '--name', $virtualMachine.name,
            '--username', $Username,
            '--password', $Password,
            '--only-show-errors'
        ) "Deployment succeeded, but password rotation failed for '$($virtualMachine.name)'. Use Azure VMAccess to set the administrator password before RDP access."
    }
}

function Invoke-AzureDeploymentWhatIf {
    param(
        [Parameter(Mandatory)][string]$SourceSubscriptionId,
        [Parameter(Mandatory)][string]$TargetSubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)][string]$DeploymentLocation,
        [Parameter(Mandatory)][string]$SourceLocation,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][string]$ParameterFile,
        [Parameter(Mandatory)][object[]]$RequestedVirtualMachines
    )

    $output = @(& az deployment sub what-if `
        --subscription $TargetSubscriptionId `
        --name $DeploymentName `
        --location $DeploymentLocation `
        --template-file $TemplateFile `
        --parameters $ParameterFile 2>&1)
    $exitCode = $LASTEXITCODE
    $output | Out-Host

    if ($exitCode -eq 0) {
        return
    }

    $outputText = $output -join [Environment]::NewLine
    if ($outputText -match 'SkuNotAvailable|AllocationFailed|ZonalAllocationFailed|Capacity Restrictions|NotAvailableForSubscription') {
        throw "SOURCE_COMPUTE_CAPACITY: Azure currently lacks capacity for one or more requested source VM sizes in '$SourceLocation'."
    }

    throw 'Azure deployment what-if failed.'
}

function Test-SourceComputeCapacity {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][object[]]$RequestedVirtualMachines
    )

    $assessment = Get-ComputeOptionAssessment `
        -SubscriptionId $SubscriptionId `
        -Location $Location `
        -RequestedVirtualMachines $RequestedVirtualMachines
    if (-not $assessment.Eligible) {
        throw "SOURCE_COMPUTE_PREFLIGHT: Source compute preflight failed in '$Location': $($assessment.Issues -join '; ')."
    }

    Write-Host "VM SKU restrictions and total vCPU quota: PASS ($($assessment.RequiredRegionalCores) required, $($assessment.AvailableRegionalCores) available in $Location)" -ForegroundColor Green
    foreach ($familyQuota in $assessment.FamilyQuota) {
        Write-Host "VM family quota: PASS ($($familyQuota.Family): $($familyQuota.RequiredCores) required, $($familyQuota.AvailableCores) available)" -ForegroundColor Green
    }
    Write-Host "Recommended compute region: $Location (selected sizes satisfy subscription SKU and quota checks)." -ForegroundColor Green
    Write-Host 'Transient physical host capacity is allocated only during deployment and cannot be guaranteed without a capacity reservation.'
}

function Test-TargetComputeCapacity {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][object[]]$RequestedVirtualMachines
    )

    $assessment = Get-ComputeOptionAssessment `
        -SubscriptionId $SubscriptionId `
        -Location $Location `
        -RequestedVirtualMachines $RequestedVirtualMachines
    if (-not $assessment.Eligible) {
        throw "TARGET_COMPUTE_PREFLIGHT: Target compute preflight failed in '$Location': $($assessment.Issues -join '; '). Select another -TargetLocation or target VM sizes."
    }

    Write-Host "Target VM SKU restrictions and total vCPU quota: PASS ($($assessment.RequiredRegionalCores) required, $($assessment.AvailableRegionalCores) available in $Location)" -ForegroundColor Green
    foreach ($familyQuota in $assessment.FamilyQuota) {
        Write-Host "Target VM family quota: PASS ($($familyQuota.Family): $($familyQuota.RequiredCores) required, $($familyQuota.AvailableCores) available)" -ForegroundColor Green
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it before running this script.'
}
if (-not (Test-Path $templateFile) -or -not (Test-Path $parameterFile)) {
    throw 'The Bicep template or parameter file is missing from the infra directory.'
}

$loadedSavedSettings = $false
if (-not $Reconfigure -and (Test-Path $configFilePath)) {
    $cachedConfiguration = Import-LocalConfiguration -Path $configFilePath
    foreach ($parameterName in $cacheableParameterNames) {
        if ($explicitParameterNames -contains $parameterName) {
            continue
        }
        $property = $cachedConfiguration.PSObject.Properties[$parameterName]
        if ($null -ne $property) {
            Set-Variable -Name $parameterName -Value $property.Value -Scope Script
        }
    }
    Write-Host "Loaded saved settings from $configFilePath" -ForegroundColor Green
    $loadedSavedSettings = $true
}

if ($loadedSavedSettings) {
    Show-CurrentConfiguration
    $savedConfigurationAction = Read-SavedConfigurationAction
    if ($savedConfigurationAction -eq 'Quit') {
        Write-Host 'Deployment cancelled. No Azure changes were made.' -ForegroundColor Yellow
        Write-DeploymentResult -Status 'Cancelled'
        return
    }
    if ($savedConfigurationAction -eq 'Change') {
        Edit-CurrentConfiguration
        Show-CurrentConfiguration
    }
}

if ([string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
    $SourceSubscriptionId = Read-RequiredValue 'Source subscription ID'
}
if ([string]::IsNullOrWhiteSpace($TargetSubscriptionId)) {
    $TargetSubscriptionId = Read-RequiredValue 'Target subscription ID'
}
if ([string]::IsNullOrWhiteSpace($AdminSourceCidr)) {
    $AdminSourceCidr = Read-RequiredValue 'Your public IPv4 CIDR, for example 203.0.113.10/32'
}
if ([string]::IsNullOrWhiteSpace($SourceLocation)) {
    $SourceLocation = Read-ValueWithDefault 'Simulated source Azure region' 'eastus2'
}
if ([string]::IsNullOrWhiteSpace($TargetLocation)) {
    $TargetLocation = Read-ValueWithDefault 'Migration target and Azure Migrate region' 'westus2'
}
if ([string]::IsNullOrWhiteSpace($NamePrefix)) {
    $NamePrefix = Read-ValueWithDefault 'Resource name prefix' 'amiglab'
}
if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
    $AdminUsername = Read-ValueWithDefault 'VM administrator username' 'labadmin'
}
if ([string]::IsNullOrWhiteSpace($DiscoveryApplianceVmSize)) {
    $DiscoveryApplianceVmSize = Read-ValueWithDefault 'Discovery appliance VM size' 'Standard_D8as_v7'
}
if ([string]::IsNullOrWhiteSpace($ReplicationApplianceVmSize)) {
    $ReplicationApplianceVmSize = Read-ValueWithDefault 'Replication appliance VM size' 'Standard_D16as_v7'
}
if ([string]::IsNullOrWhiteSpace($HyperVHostVmSize)) {
    $HyperVHostVmSize = Read-ValueWithDefault 'Nested Hyper-V host VM size' 'Standard_D16as_v7'
}
if ([string]::IsNullOrWhiteSpace($WindowsSourceVmSize)) {
    $WindowsSourceVmSize = Read-ValueWithDefault 'Expected migrated Windows target VM size' 'Standard_D2as_v7'
}
if ([string]::IsNullOrWhiteSpace($LinuxSourceVmSize)) {
    $LinuxSourceVmSize = Read-ValueWithDefault 'Expected migrated Linux target VM size' 'Standard_D2as_v7'
}
if ($null -eq $AutoShutdownEnabled) {
    $AutoShutdownEnabled = Read-BoolWithDefault 'Enable automatic VM shutdown' $true
}
if ([string]::IsNullOrWhiteSpace($AutoShutdownTime)) {
    $AutoShutdownTime = Read-ValueWithDefault 'Automatic shutdown time in HHmm format' '1900'
}
if ([string]::IsNullOrWhiteSpace($AutoShutdownTimeZone)) {
    $AutoShutdownTimeZone = Read-ValueWithDefault 'Automatic shutdown time zone' 'UTC'
}
if ($null -eq $DeployTargetNatGateway) {
    $DeployTargetNatGateway = Read-BoolWithDefault 'Deploy target NAT Gateway' $false
}
if ($null -eq $DeployAzureMigrateProject) {
    $DeployAzureMigrateProject = Read-BoolWithDefault 'Deploy Azure Migrate project' $true
}

Assert-SubscriptionId $SourceSubscriptionId 'SourceSubscriptionId'
Assert-SubscriptionId $TargetSubscriptionId 'TargetSubscriptionId'
Assert-Ipv4Cidr $AdminSourceCidr

if ($SourceSubscriptionId -eq $TargetSubscriptionId) {
    throw 'Source and target subscription IDs must be different.'
}
if ($NamePrefix -notmatch '^[a-z0-9-]{3,12}$') {
    throw 'Resource name prefix must be 3-12 lowercase letters, numbers, or hyphens.'
}
if ($AdminUsername.Length -gt 15) {
    throw 'VM administrator username must be 15 characters or fewer.'
}
if ($AutoShutdownTime -notmatch '^(?:[01][0-9]|2[0-3])[0-5][0-9]$') {
    throw 'Automatic shutdown time must use 24-hour HHmm format, for example 1900.'
}
$configurationToSave = Get-CurrentConfiguration
Save-LocalConfiguration -Path $configFilePath -Configuration $configurationToSave

$temporaryPassword = New-AzureWindowsAdminPassword
Confirm-TemporaryPasswordStored -Password $temporaryPassword
$labEnvironmentVariables = @(
    'AZURE_MIGRATE_LAB_SOURCE_SUBSCRIPTION_ID'
    'AZURE_MIGRATE_LAB_TARGET_SUBSCRIPTION_ID'
    'AZURE_MIGRATE_LAB_ADMIN_SOURCE_CIDR'
    'AZURE_MIGRATE_LAB_ADMIN_PASSWORD'
    'AZURE_MIGRATE_LAB_SOURCE_LOCATION'
    'AZURE_MIGRATE_LAB_TARGET_LOCATION'
    'AZURE_MIGRATE_LAB_NAME_PREFIX'
    'AZURE_MIGRATE_LAB_ADMIN_USERNAME'
    'AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE'
    'AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE'
    'AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE'
    'AZURE_MIGRATE_LAB_CONFIGURE_HYPERV_SECURITY_TYPE'
    'AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_ENABLED'
    'AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_TIME'
    'AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_TIME_ZONE'
    'AZURE_MIGRATE_LAB_DEPLOY_TARGET_NAT'
    'AZURE_MIGRATE_LAB_DEPLOY_MIGRATE_PROJECT'
)
$previousAzureExtensionDirectory = $env:AZURE_EXTENSION_DIR
$isolatedAzureExtensionDirectory = Join-Path $env:TEMP 'azure-migrate-lab-az-extensions'
New-Item -Path $isolatedAzureExtensionDirectory -ItemType Directory -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $isolatedAzureExtensionDirectory

try {
    Write-DeploymentPhase 'Authenticating and validating subscription access'
    $env:AZURE_MIGRATE_LAB_SOURCE_SUBSCRIPTION_ID = $SourceSubscriptionId
    $env:AZURE_MIGRATE_LAB_TARGET_SUBSCRIPTION_ID = $TargetSubscriptionId
    $env:AZURE_MIGRATE_LAB_ADMIN_SOURCE_CIDR = $AdminSourceCidr
    $env:AZURE_MIGRATE_LAB_ADMIN_PASSWORD = $temporaryPassword
    $env:AZURE_MIGRATE_LAB_SOURCE_LOCATION = $SourceLocation
    $env:AZURE_MIGRATE_LAB_TARGET_LOCATION = $TargetLocation
    $env:AZURE_MIGRATE_LAB_NAME_PREFIX = $NamePrefix
    $env:AZURE_MIGRATE_LAB_ADMIN_USERNAME = $AdminUsername
    $env:AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE = $DiscoveryApplianceVmSize
    $env:AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE = $ReplicationApplianceVmSize
    $env:AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE = $HyperVHostVmSize
    $env:AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_ENABLED = $AutoShutdownEnabled.ToString().ToLowerInvariant()
    $env:AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_TIME = $AutoShutdownTime
    $env:AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_TIME_ZONE = $AutoShutdownTimeZone
    $env:AZURE_MIGRATE_LAB_DEPLOY_TARGET_NAT = $DeployTargetNatGateway.ToString().ToLowerInvariant()
    $env:AZURE_MIGRATE_LAB_DEPLOY_MIGRATE_PROJECT = $DeployAzureMigrateProject.ToString().ToLowerInvariant()
    & az account show --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-AzureCli @('login') 'Azure sign-in failed.'
    }

    & az account show --subscription $SourceSubscriptionId --only-show-errors 1>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'The source subscription is unavailable to the signed-in account.'
    }
    & az account show --subscription $TargetSubscriptionId --only-show-errors 1>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'The target subscription is unavailable to the signed-in account.'
    }
    Write-DeploymentDetail "Source subscription access: PASS ($SourceSubscriptionId)." Green
    Write-DeploymentDetail "Target subscription access: PASS ($TargetSubscriptionId)." Green

    $existingSourceResourceGroups = @(Get-ExistingLabSourceResourceGroups `
        -SubscriptionId $SourceSubscriptionId `
        -Prefix $NamePrefix)
    $hasExistingLabResources = $existingSourceResourceGroups.Count -gt 0
    $mismatchedSourceResourceGroups = @(
        $existingSourceResourceGroups | Where-Object { $_.location -ine $SourceLocation }
    )
    if ($mismatchedSourceResourceGroups.Count -gt 0) {
        $mismatchDetails = $mismatchedSourceResourceGroups |
            ForEach-Object { "$($_.name) is in $($_.location)" }
        throw "Existing deterministic source resource groups do not match requested region '$SourceLocation': $($mismatchDetails -join '; '). Use the existing region, choose a new -NamePrefix, or explicitly remove the partial lab resource groups."
    }
    $existingTargetResourceGroups = @(Get-ExistingLabTargetResourceGroups `
        -SubscriptionId $TargetSubscriptionId `
        -Prefix $NamePrefix)
    $mismatchedTargetResourceGroups = @(
        $existingTargetResourceGroups | Where-Object { $_.location -ine $TargetLocation }
    )
    if ($mismatchedTargetResourceGroups.Count -gt 0) {
        $mismatchDetails = $mismatchedTargetResourceGroups |
            ForEach-Object { "$($_.name) is in $($_.location)" }
        throw "Existing deterministic target resource groups do not match requested region '$TargetLocation': $($mismatchDetails -join '; '). Use the existing region, choose a new -NamePrefix, or explicitly remove the partial lab resource groups."
    }
    $existingWindowsVirtualMachines = @(Get-ExistingLabWindowsVirtualMachines `
        -SubscriptionId $SourceSubscriptionId `
        -Prefix $NamePrefix)
    $existingHyperVHost = @(
        $existingWindowsVirtualMachines | Where-Object {
            $_.name -like "vm-$NamePrefix-hyperv-*"
        }
    ).Count -gt 0
    $env:AZURE_MIGRATE_LAB_CONFIGURE_HYPERV_SECURITY_TYPE = (-not $existingHyperVHost).ToString().ToLowerInvariant()
    if ($existingHyperVHost) {
        Write-DeploymentDetail 'Existing Hyper-V host detected; omitting immutable securityType from incremental deployment.'
    }
    $rotateExistingWindowsPasswords = Confirm-ExistingWindowsPasswordRotation `
        -VirtualMachines $existingWindowsVirtualMachines

    if (-not $SkipProviderRegistration) {
        Write-DeploymentPhase 'Checking required resource providers'
        Ensure-AzureFeatureRegistered `
            -SubscriptionId $SourceSubscriptionId `
            -Namespace 'Microsoft.Compute' `
            -FeatureName 'UseStandardSecurityType' `
            -EnvironmentLabel 'source'
        foreach ($provider in 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.DevTestLab') {
            Ensure-AzureProviderRegistered `
                -SubscriptionId $SourceSubscriptionId `
                -Namespace $provider `
                -EnvironmentLabel 'source'
        }
        foreach ($provider in @(
            'Microsoft.Compute'
            'Microsoft.Network'
            'Microsoft.Storage'
            'Microsoft.RecoveryServices'
            'Microsoft.KeyVault'
            'Microsoft.Migrate'
        )) {
            Ensure-AzureProviderRegistered `
                -SubscriptionId $TargetSubscriptionId `
                -Namespace $provider `
                -EnvironmentLabel 'target'
        }
    }

    $explicitVmSizeParameters = @(
        @(
            'DiscoveryApplianceVmSize'
            'ReplicationApplianceVmSize'
            'HyperVHostVmSize'
            'WindowsSourceVmSize'
            'LinuxSourceVmSize'
        ) | Where-Object { $explicitParameterNames -contains $_ }
    )
    if (
        $AutoSelectVmSizes -and
        $explicitVmSizeParameters.Count -eq 0 -and
        -not $script:vmSizesSelectedInteractively
    ) {
        $configuredProfile = [pscustomobject]@{
            Name = 'Configured sizes'
            DiscoveryApplianceVmSize = $DiscoveryApplianceVmSize
            ReplicationApplianceVmSize = $ReplicationApplianceVmSize
            HyperVHostVmSize = $HyperVHostVmSize
            WindowsSourceVmSize = $WindowsSourceVmSize
            LinuxSourceVmSize = $LinuxSourceVmSize
        }
        Resolve-RegionalDefaultComputeProfile `
            -SourceSubscriptionId $SourceSubscriptionId `
            -TargetSubscriptionId $TargetSubscriptionId `
            -SourceLocation $SourceLocation `
            -TargetLocation $TargetLocation `
            -Profiles (@($configuredProfile) + $fallbackComputeProfiles) `
            -ConfigurationPath $configFilePath
    }
    else {
        $reason = if (-not $AutoSelectVmSizes) {
            '-AutoSelectVmSizes:$false'
        }
        elseif ($explicitVmSizeParameters.Count -gt 0) {
            "explicit parameters: $($explicitVmSizeParameters -join ', ')"
        }
        else {
            'interactive size selection'
        }
        Write-DeploymentDetail "Automatic VM-size selection skipped because of $reason."
    }

    Write-DeploymentPhase 'Checking existing deployment state'
    Invoke-AzureCli @('account', 'set', '--subscription', $TargetSubscriptionId) 'Could not select the target subscription.'

    $deploymentLocation = Get-DeploymentMetadataLocation `
        -SubscriptionId $TargetSubscriptionId `
        -DeploymentName 'azure-migrate-lab' `
        -DefaultLocation $SourceLocation

    $existingDeploymentState = Show-ExistingDeploymentState `
        -SubscriptionId $TargetSubscriptionId `
        -DeploymentName 'azure-migrate-lab'
    $passwordRetryCount = 0

    while ($true) {
        $requestedVirtualMachines = New-RequestedVirtualMachineSet `
            -DiscoverySize $DiscoveryApplianceVmSize `
            -ReplicationSize $ReplicationApplianceVmSize `
            -HyperVHostSize $HyperVHostVmSize
        $targetVirtualMachines = New-TargetVirtualMachineSet `
            -WindowsSourceSize $WindowsSourceVmSize `
            -LinuxSourceSize $LinuxSourceVmSize

        try {
            Write-DeploymentPhase 'Running Azure Migrate target-region precheck'
            if ($DeployAzureMigrateProject) {
                Test-AzureMigrateProjectLocation -SubscriptionId $TargetSubscriptionId -Location $TargetLocation
            }
            Write-DeploymentPhase "Running source compute precheck in $SourceLocation"
            Test-SourceComputeCapacity `
                -SubscriptionId $SourceSubscriptionId `
                -Location $SourceLocation `
                -RequestedVirtualMachines $requestedVirtualMachines
            Write-DeploymentPhase "Running target compute precheck in $TargetLocation"
            Test-TargetComputeCapacity `
                -SubscriptionId $TargetSubscriptionId `
                -Location $TargetLocation `
                -RequestedVirtualMachines $targetVirtualMachines

            Write-DeploymentPhase 'Compiling Bicep'
            Write-DeploymentDetail "Template: $templateFile"
            Write-DeploymentDetail "Parameters: $parameterFile"
            Invoke-AzureCli @('bicep', 'build', '--file', $templateFile) 'Bicep compilation failed.'
            Write-DeploymentDetail 'Bicep compilation: PASS.' Green

            Write-DeploymentPhase 'Validating deployment with Azure Resource Manager'
            Write-DeploymentDetail "Deployment scope: target subscription $TargetSubscriptionId; deployment history location $deploymentLocation."
            Write-DeploymentDetail "Resource placement: source $SourceLocation; target and Azure Migrate $TargetLocation."
            Invoke-AzureCli @(
                'deployment', 'sub', 'validate',
                '--name', 'azure-migrate-lab-validation',
                '--location', $deploymentLocation,
                '--template-file', $templateFile,
                '--parameters', $parameterFile,
                '--output', 'none',
                '--only-show-errors'
            ) 'Azure Resource Manager validation failed. Review policy, quota, provider, and template errors above.'
            Write-DeploymentDetail 'ARM validation: PASS.' Green

            Write-DeploymentPhase 'Running Azure Resource Manager what-if preview'
            Invoke-AzureDeploymentWhatIf `
                -SourceSubscriptionId $SourceSubscriptionId `
                -TargetSubscriptionId $TargetSubscriptionId `
                -DeploymentName 'azure-migrate-lab-preview' `
                -DeploymentLocation $deploymentLocation `
                -SourceLocation $SourceLocation `
                -TemplateFile $templateFile `
                -ParameterFile $parameterFile `
                -RequestedVirtualMachines $requestedVirtualMachines
            Write-DeploymentDetail 'ARM what-if: PASS.' Green
        }
        catch {
            if ($_.Exception.Message -match '^SOURCE_COMPUTE_(PREFLIGHT|CAPACITY):') {
                Write-Warning $_.Exception.Message
                Resolve-ComputeFailure `
                    -SourceSubscriptionId $SourceSubscriptionId `
                    -TargetSubscriptionId $TargetSubscriptionId `
                    -DeploymentLocation $deploymentLocation `
                    -CurrentLocation $SourceLocation `
                    -RequestedVirtualMachines $requestedVirtualMachines `
                    -TemplateFile $templateFile `
                    -ParameterFile $parameterFile `
                    -ConfigurationPath $configFilePath `
                    -CurrentLocationOnly:$hasExistingLabResources
                continue
            }
            throw
        }

        if ($WhatIfOnly) {
            Write-Host 'Preview completed. No resources were deployed.' -ForegroundColor Green
            Write-DeploymentResult -Status 'Previewed'
            return
        }

        $confirmation = if ($ApproveDeployment) {
            Write-Host ''
            Write-Host 'Deployment pre-approved by -ApproveDeployment.' -ForegroundColor Yellow
            'Deploy'
        }
        else {
            Read-DeploymentConfirmation
        }
        if ($confirmation -eq 'Cancel') {
            Write-Host 'Deployment cancelled. No resources were deployed.' -ForegroundColor Yellow
            Write-DeploymentResult -Status 'Cancelled'
            return
        }

        foreach ($sourceResourceGroup in $existingSourceResourceGroups) {
            Remove-LabJitNetworkAccessPolicy `
                -SubscriptionId $SourceSubscriptionId `
                -ResourceGroupName $sourceResourceGroup.name `
                -Location $SourceLocation `
                -Prefix $NamePrefix
        }

        Write-DeploymentPhase 'Deploying the lab with Bicep'
        Write-DeploymentDetail 'Submitting the deployment; live ARM operation updates follow.'
        $deploymentOutput = @(& az deployment sub create `
            --subscription $TargetSubscriptionId `
            --name 'azure-migrate-lab' `
            --location $deploymentLocation `
            --template-file $templateFile `
            --parameters $parameterFile `
            --no-wait `
            --output none `
            --only-show-errors 2>&1)
        $deploymentExitCode = $LASTEXITCODE
        if ($deploymentExitCode -eq 0) {
            $deployment = Wait-AzureSubscriptionDeployment `
                -SubscriptionId $TargetSubscriptionId `
                -DeploymentName 'azure-migrate-lab'
            $deploymentOutput = @($deployment | ConvertTo-Json -Depth 100 -Compress)
            $deploymentExitCode = if ($deployment.properties.provisioningState -eq 'Succeeded') { 0 } else { 1 }
        }
        else {
            $deploymentOutput | Out-Host
        }
        Show-AzureDeploymentOperations `
            -SubscriptionId $TargetSubscriptionId `
            -DeploymentName 'azure-migrate-lab'
        if ($deploymentExitCode -eq 0) {
            if ($rotateExistingWindowsPasswords) {
                Write-Host 'Aligning existing Windows VM administrator passwords...' -ForegroundColor Cyan
                Set-ExistingWindowsAdminPasswords `
                    -SubscriptionId $SourceSubscriptionId `
                    -VirtualMachines $existingWindowsVirtualMachines `
                    -Username $AdminUsername `
                    -Password $temporaryPassword
            }
            Write-Host 'Deployment completed.' -ForegroundColor Green
            Write-DeploymentResult -Status 'Deployed'
            break
        }

        $deploymentFailure = Get-AzureDeploymentFailure -Output $deploymentOutput
        Write-Host "Deployment failure category: $($deploymentFailure.Category)" -ForegroundColor Red
        foreach ($detail in $deploymentFailure.Details) {
            Write-Host "- $detail" -ForegroundColor Red
        }

        if ($deploymentFailure.Category -eq 'Password' -and $passwordRetryCount -lt 1) {
            $passwordRetryCount++
            Write-Warning 'Azure rejected the generated password. A new password will be generated before retrying incrementally.'
            $temporaryPassword = New-AzureWindowsAdminPassword
            Confirm-TemporaryPasswordStored -Password $temporaryPassword
            $env:AZURE_MIGRATE_LAB_ADMIN_PASSWORD = $temporaryPassword
            $existingWindowsVirtualMachines = @(Get-ExistingLabWindowsVirtualMachines `
                -SubscriptionId $SourceSubscriptionId `
                -Prefix $NamePrefix)
            if (-not $rotateExistingWindowsPasswords -and $existingWindowsVirtualMachines.Count -gt 0) {
                $rotateExistingWindowsPasswords = Confirm-ExistingWindowsPasswordRotation `
                    -VirtualMachines $existingWindowsVirtualMachines
            }
            continue
        }
        if ($deploymentFailure.Category -in @('Capacity', 'Quota')) {
            Resolve-ComputeFailure `
                -SourceSubscriptionId $SourceSubscriptionId `
                -TargetSubscriptionId $TargetSubscriptionId `
                -DeploymentLocation $deploymentLocation `
                -CurrentLocation $SourceLocation `
                -RequestedVirtualMachines $requestedVirtualMachines `
                -TemplateFile $templateFile `
                -ParameterFile $parameterFile `
                -ConfigurationPath $configFilePath `
                -CurrentLocationOnly
            continue
        }

        $remediation = switch ($deploymentFailure.Category) {
            'Password' { 'Azure rejected two generated passwords. Stop and review current Azure password policy before retrying.' }
            'Policy' { 'Review the named Azure Policy assignment and update the configuration or request an exemption.' }
            'Provider' { 'Register the missing resource provider in the subscription and retry.' }
            default { 'Review the nested ARM errors above before retrying. Existing resources are retained for incremental recovery.' }
        }
        throw "Azure deployment failed. $remediation"
    }
}
finally {
    foreach ($variableName in $labEnvironmentVariables) {
        Remove-Item "Env:$variableName" -ErrorAction SilentlyContinue
    }
    Remove-Variable temporaryPassword -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($previousAzureExtensionDirectory)) {
        Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory
    }
}