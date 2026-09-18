[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [uri]$InstallerUri = 'https://aka.ms/V2ARcmApplianceCreationPowershellZip',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedSha256 = 'B603C434A54E4C41DF715947676C187B75D839B3ECB1B48608F6652750610DC7',
    [switch]$Force,
    [switch]$RequireRegistered
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
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $output = @(& az @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "$FailureMessage$([Environment]::NewLine)$details"
    }
    return ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
}

function Get-RequiredAzureCliValue {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $value = (Invoke-AzureCliText -Arguments $Arguments -FailureMessage $FailureMessage).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw $FailureMessage
    }
    return $value
}

function Get-ReplicationRegistrationStatus {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $vaultsJson = Invoke-AzureCliText @(
        'resource', 'list',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.RecoveryServices/vaults',
        '--output', 'json',
        '--only-show-errors'
    ) "Could not list Recovery Services vaults in '$ResourceGroupName'."
    $vaults = @($vaultsJson | ConvertFrom-Json)
    foreach ($vault in $vaults) {
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
            ) "Could not list registered providers for Site Recovery fabric '$($fabric.name)'."
            $provider = @(($providersJson | ConvertFrom-Json).value) |
                Where-Object { $_.properties.connectionStatus -eq 'Connected' } |
                Sort-Object { [datetime]$_.properties.lastHeartbeat } -Descending |
                Select-Object -First 1
            if ($null -ne $provider) {
                return [pscustomobject]@{
                    Registered = $true
                    VaultName = [string]$vault.name
                    FabricName = [string]$fabric.name
                    FabricHealth = [string]$fabric.properties.health
                    ProviderName = [string]$provider.name
                    ConnectionStatus = [string]$provider.properties.connectionStatus
                    LastHeartbeat = [string]$provider.properties.lastHeartbeat
                    MachineName = [string]$provider.properties.machineName
                }
            }
        }
    }

    return [pscustomobject]@{ Registered = $false }
}

function Wait-ReplicationRegistration {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [ValidateRange(1, 30)][int]$MaximumAttempts = 6
    )

    foreach ($attempt in 1..$MaximumAttempts) {
        $status = Get-ReplicationRegistrationStatus `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName
        if ($status.Registered) {
            return $status
        }
        if ($attempt -lt $MaximumAttempts) {
            Write-Host "Azure has not exposed a connected replication provider yet. Retrying ($attempt/$MaximumAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
        }
    }
    throw "No connected InMageRcm replication provider appeared in Recovery Services vaults under '$ResourceGroupName'. Refresh Azure Migrate, wait for propagation, and rerun this check."
}

function Wait-ReplicationVmAgentReady {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VirtualMachineName,
        [ValidateRange(1, 60)][int]$MaximumAttempts = 30
    )

    foreach ($attempt in 1..$MaximumAttempts) {
        $state = & az vm get-instance-view `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroupName `
            --name $VirtualMachineName `
            --query 'instanceView.vmAgent.statuses[0].displayStatus' `
            --output tsv `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0 -and $state -eq 'Ready') {
            return
        }
        if ($attempt -lt $MaximumAttempts) {
            Start-Sleep -Seconds 10
        }
    }
    throw "The Azure VM Agent for '$VirtualMachineName' did not become ready."
}

function Get-ReplicationInstallResult {
    param([Parameter(Mandatory)][string]$RunCommandOutput)

    $runCommandResult = $RunCommandOutput | ConvertFrom-Json
    $runCommandMessage = @($runCommandResult.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
    $resultMatch = [regex]::Match(
        $runCommandMessage,
        '(?m)^\s*AZURE_MIGRATE_REPLICATION_INSTALL_RESULT=(?<result>\{[^\r\n]+\})\s*$'
    )
    if (-not $resultMatch.Success) {
        throw "Remote installation did not return a completion result.$([Environment]::NewLine)$runCommandMessage"
    }
    return $resultMatch.Groups['result'].Value | ConvertFrom-Json
}

function Write-LocalReplicationResult {
    param([Parameter(Mandatory)][object]$Result)

    $resultJson = $Result | ConvertTo-Json -Depth 5 -Compress
    $resultLine = "AZURE_MIGRATE_REPLICATION_RESULT=$resultJson"
    Write-Output $resultLine
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_MIGRATE_LAB_RESULT_FILE)) {
        Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE -Value $resultLine -Encoding utf8NoBOM
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it before running this script.'
}
if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) {
    throw "Deployment configuration was not found: $configFilePath"
}
if ($InstallerUri.Scheme -ne 'https') {
    throw 'InstallerUri must use HTTPS.'
}
if ($InstallerUri.Host -notin @('aka.ms', 'download.microsoft.com')) {
    throw "InstallerUri must use an approved Microsoft download host. Received: $($InstallerUri.Host)"
}

$configuration = Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json
foreach ($propertyName in 'SourceSubscriptionId', 'TargetSubscriptionId') {
    $property = $configuration.PSObject.Properties[$propertyName]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "The configuration file is missing $propertyName."
    }
}

$sourceSubscriptionId = [string]$configuration.SourceSubscriptionId
$targetSubscriptionId = [string]$configuration.TargetSubscriptionId
$previousAzureExtensionDirectory = $env:AZURE_EXTENSION_DIR
$isolatedAzureExtensionDirectory = Join-Path $env:TEMP 'azure-migrate-lab-az-extensions'
New-Item -Path $isolatedAzureExtensionDirectory -ItemType Directory -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $isolatedAzureExtensionDirectory
$remoteScriptFile = $null

try {
    & az account show --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        & az login
        if ($LASTEXITCODE -ne 0) {
            throw 'Azure sign-in failed.'
        }
    }

    $sourceResourceGroupId = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--query', 'properties.outputs.sourceResourceGroupId.value',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read sourceResourceGroupId from subscription deployment '$DeploymentName'. Deploy the lab first."
    $targetResourceGroupId = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--query', 'properties.outputs.targetResourceGroupId.value',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read targetResourceGroupId from subscription deployment '$DeploymentName'. Deploy the current template first."
    $replicationVmName = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--query', 'properties.outputs.replicationApplianceName.value',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read replicationApplianceName from subscription deployment '$DeploymentName'."
    $discoveryVmName = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--query', 'properties.outputs.discoveryApplianceName.value',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read discoveryApplianceName from subscription deployment '$DeploymentName'."
    if ($replicationVmName -eq $discoveryVmName) {
        throw 'Discovery and replication appliance components must not target the same VM.'
    }
    $sourceResourceGroupName = ($sourceResourceGroupId -split '/')[-1]
    $targetResourceGroupName = ($targetResourceGroupId -split '/')[-1]

    $vmPowerState = Get-RequiredAzureCliValue @(
        'vm', 'show',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $replicationVmName,
        '--show-details',
        '--query', 'powerState',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read the power state for replication VM '$replicationVmName'."
    if ($vmPowerState -ne 'VM running') {
        throw "Replication VM '$replicationVmName' must be running. Current state: $vmPowerState"
    }

    $vmAgentState = Get-RequiredAzureCliValue @(
        'vm', 'get-instance-view',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $replicationVmName,
        '--query', 'instanceView.vmAgent.statuses[0].displayStatus',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read the VM Agent state for replication VM '$replicationVmName'."
    if ($vmAgentState -ne 'Ready') {
        throw "The Azure VM Agent must be ready before remote installation. Current state: $vmAgentState"
    }

    $privateIpAddress = Get-RequiredAzureCliValue @(
        'vm', 'show',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $replicationVmName,
        '--show-details',
        '--query', 'privateIps',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not resolve the private IP address for replication VM '$replicationVmName'."
    if ($privateIpAddress -ne '10.10.1.20') {
        throw "Replication VM '$replicationVmName' must use the expected static private IP 10.10.1.20. Current value: $privateIpAddress"
    }
    $publicIpAddress = Get-RequiredAzureCliValue @(
        'vm', 'show',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $replicationVmName,
        '--show-details',
        '--query', 'publicIps',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not resolve the public IP address for replication VM '$replicationVmName'."

    Write-Host "Replication VM: $replicationVmName" -ForegroundColor Cyan
    Write-Host "Source resource group: $sourceResourceGroupName"
    Write-Host "Private IP address: $privateIpAddress"
    Write-Host "Public IP address: $publicIpAddress"
    Write-Host 'Checking simplified replication appliance state through Azure VM Run Command.'
    Write-Host 'No WinRM ports, administrator password, appliance key, or source credentials are used.'

    $remoteInstallerScript = @'
param(
    [Parameter(Mandatory)][string]$installerUri,
    [Parameter(Mandatory)][string]$expectedSha256,
    [Parameter(Mandatory)][string]$force,
    [Parameter(Mandatory)][string]$checkOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$forceInstall = [Convert]::ToBoolean($force)
$checkOnlyMode = [Convert]::ToBoolean($checkOnly)
$setupRoot = 'C:\AzureMigrateReplicationSetup'
$packagePath = Join-Path $setupRoot 'DRAppliance.zip'
$extractPath = Join-Path $setupRoot 'package'
$stdoutPath = Join-Path $setupRoot 'installer-stdout.log'
$stderrPath = Join-Path $setupRoot 'installer-stderr.log'
$configurationManagerPath = 'C:\Program Files\Microsoft Azure Appliance Configuration Manager'
$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\AzureAppliance'
    'HKLM:\SOFTWARE\Microsoft Azure\Appliance'
)

function Get-ReplicationApplianceStatus {
    $registryPath = $registryPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $iisService = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    $configurationManagerSite = $null
    $configurationManagerPool = $null
    $httpsBinding = $null
    $webAdministrationModule = Import-Module WebAdministration -PassThru -ErrorAction SilentlyContinue
    if ($null -ne $webAdministrationModule) {
        $configurationManagerSite = Get-Website `
            -Name 'Microsoft Azure DR Appliance Configuration Manager' `
            -ErrorAction SilentlyContinue
        $configurationManagerPool = Get-Item `
            'IIS:\AppPools\Microsoft Azure DR Appliance Configuration Manager' `
            -ErrorAction SilentlyContinue
    }
    $httpsBinding = if ($null -ne $configurationManagerSite) {
        @($configurationManagerSite.Bindings.Collection) |
            Where-Object {
                $_.protocol -ieq 'https' -and
                $_.bindingInformation -match ':44368:'
            } |
            Select-Object -First 1
    }
    $products = @(
        Get-ItemProperty `
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', `
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $displayNameProperty = $_.PSObject.Properties['DisplayName']
                $null -ne $displayNameProperty -and
                [string]$displayNameProperty.Value -match 'Site Recovery|Replication appliance|Azure RCM|Process Server'
            }
    )
    $registered = $false
    if ($null -ne $registryPath) {
        $registry = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        foreach ($propertyName in 'IsApplianceRegistered', 'IsRegistered') {
            $property = $registry.PSObject.Properties[$propertyName]
            if ($null -ne $property -and [string]$property.Value -match '^(?i:true|1)$') {
                $registered = $true
            }
        }
    }
    return [pscustomobject]@{
        RegistryPresent = $null -ne $registryPath
        ConfigurationPortListening = $null -ne $httpsBinding
        IisRunning = $null -ne $iisService -and $iisService.Status -eq 'Running'
        ConfigurationManagerPresent = Test-Path -LiteralPath $configurationManagerPath -PathType Container
        ConfigurationManagerSiteStarted = `
            $null -ne $configurationManagerSite -and `
            $configurationManagerSite.State -eq 'Started'
        ConfigurationManagerPoolStarted = `
            $null -ne $configurationManagerPool -and `
            $configurationManagerPool.State -eq 'Started'
        ProductCount = $products.Count
        Registered = $registered
    }
}

function Write-ReplicationInstallResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][object]$ApplianceStatus,
        [bool]$RequiresReboot = $false,
        [string[]]$Issues = @()
    )

    $result = [ordered]@{
        Status = $Status
        RegistryPresent = [bool]$ApplianceStatus.RegistryPresent
        ConfigurationPortListening = [bool]$ApplianceStatus.ConfigurationPortListening
        IisRunning = [bool]$ApplianceStatus.IisRunning
        ConfigurationManagerPresent = [bool]$ApplianceStatus.ConfigurationManagerPresent
        ConfigurationManagerSiteStarted = [bool]$ApplianceStatus.ConfigurationManagerSiteStarted
        ConfigurationManagerPoolStarted = [bool]$ApplianceStatus.ConfigurationManagerPoolStarted
        ProductCount = [int]$ApplianceStatus.ProductCount
        Registered = [bool]$ApplianceStatus.Registered
        RequiresReboot = $RequiresReboot
        Issues = @($Issues)
        SetupRoot = $setupRoot
        InstallerStdout = $stdoutPath
        InstallerStderr = $stderrPath
    } | ConvertTo-Json -Compress
    Write-Output "AZURE_MIGRATE_REPLICATION_INSTALL_RESULT=$result"
}

function Test-PendingReboot {
    return `
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or `
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Get-OptionalRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $registryKey = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $registryKey) {
        return $null
    }
    $property = $registryKey.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-PrerequisiteIssues {
    $issues = [Collections.Generic.List[string]]::new()
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    if ($operatingSystem.Caption -notmatch 'Windows Server 2022') {
        $issues.Add("Windows Server 2022 is required; found '$($operatingSystem.Caption)'.")
    }
    if ((Get-Culture).Name -notmatch '^en-') {
        $issues.Add("An English OS locale is required; found '$((Get-Culture).Name)'.")
    }
    $computer = Get-CimInstance Win32_ComputerSystem
    $physicalCoreCount = [int]((Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum)
    if ($physicalCoreCount -lt 8) {
        $issues.Add("At least 8 physical CPU cores are required; found $physicalCoreCount.")
    }
    if ([math]::Floor([decimal]$computer.TotalPhysicalMemory / 1GB) -lt 16) {
        $issues.Add('At least 16 GB RAM is required.')
    }
    $cacheVolume = $null
    foreach ($attempt in 1..60) {
        Update-HostStorageCache
        $cacheVolume = @(
            Get-Volume -DriveLetter E -ErrorAction SilentlyContinue |
                Where-Object { $_.FileSystemLabel -eq 'ReplicationCache' }
        ) | Select-Object -First 1
        if ($null -ne $cacheVolume) {
            break
        }
        Start-Sleep -Seconds 2
    }
    if ($null -eq $cacheVolume) {
        $issues.Add('The ReplicationCache volume was not found on E: after waiting for storage discovery.')
    }
    else {
        $sizeProperty = $cacheVolume.PSObject.Properties['Size']
        $fileSystemProperty = $cacheVolume.PSObject.Properties['FileSystem']
        $healthProperty = $cacheVolume.PSObject.Properties['HealthStatus']
        if ($null -eq $sizeProperty -or [decimal]$sizeProperty.Value -lt 620GB) {
            $issues.Add('The E: ReplicationCache volume must be at least 620 GB.')
        }
        if ($null -eq $fileSystemProperty -or [string]$fileSystemProperty.Value -ne 'NTFS') {
            $issues.Add('The E: ReplicationCache volume must use NTFS.')
        }
        if ($null -eq $healthProperty -or [string]$healthProperty.Value -ne 'Healthy') {
            $issues.Add('The E: ReplicationCache volume must be healthy.')
        }
    }
    foreach ($roleName in 'AD-Domain-Services', 'Web-Server', 'Hyper-V') {
        $role = Get-WindowsFeature -Name $roleName -ErrorAction SilentlyContinue
        if ($null -ne $role -and $role.InstallState -eq 'Installed') {
            $issues.Add("Prohibited Windows role is installed: $roleName")
        }
    }
    $fipsPolicy = Get-OptionalRegistryValue `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy' `
        -Name Enabled
    if ($fipsPolicy -eq 1) {
        $issues.Add('FIPS mode must be disabled.')
    }
    $disableRegistryTools = Get-OptionalRegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name DisableRegistryTools
    if ($null -ne $disableRegistryTools -and $disableRegistryTools -ne 0) {
        $issues.Add('Group policy prevents access to registry editing tools.')
    }
    $disableCommandPrompt = Get-OptionalRegistryValue `
        -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
        -Name DisableCMD
    if ($null -ne $disableCommandPrompt -and $disableCommandPrompt -ne 0) {
        $issues.Add('Group policy prevents access to the command prompt.')
    }
    $trustedHandlers = Get-OptionalRegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' `
        -Name UseTrustedHandlers
    if ($trustedHandlers -eq 3) {
        $issues.Add('Attachment Manager trusted-handler policy is incompatible with the appliance.')
    }
    $executionPolicies = Get-ExecutionPolicy -List
    foreach ($scope in 'MachinePolicy', 'UserPolicy') {
        $policy = $executionPolicies | Where-Object { $_.Scope -eq $scope } | Select-Object -First 1
        if ($null -ne $policy -and $policy.ExecutionPolicy -in @('AllSigned', 'Restricted')) {
            $issues.Add("PowerShell execution policy at $scope is incompatible: $($policy.ExecutionPolicy)")
        }
    }
    if (-not (Test-Path 'HKLM:\SOFTWARE\Clients\StartMenuInternet\Microsoft Edge')) {
        $issues.Add('Microsoft Edge must be installed before DRInstaller runs.')
    }
    $osVolume = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
    if ($null -eq $osVolume -or $osVolume.SizeRemaining -lt 30GB) {
        $issues.Add('At least 30 GB free space is required on C: to stage and extract the 4 GB package.')
    }
    return @($issues)
}

$initialStatus = Get-ReplicationApplianceStatus
$healthy = `
    $initialStatus.RegistryPresent -and `
    $initialStatus.ConfigurationPortListening -and `
    $initialStatus.IisRunning -and `
    $initialStatus.ConfigurationManagerPresent -and `
    $initialStatus.ConfigurationManagerSiteStarted -and `
    $initialStatus.ConfigurationManagerPoolStarted
$installationEvidencePresent = `
    $initialStatus.RegistryPresent -or `
    $initialStatus.ConfigurationPortListening -or `
    $initialStatus.IisRunning -or `
    $initialStatus.ConfigurationManagerPresent -or `
    $initialStatus.ProductCount -gt 0

if ($healthy -and -not $forceInstall) {
    Write-ReplicationInstallResult -Status 'AlreadyInstalled' -ApplianceStatus $initialStatus
    exit 0
}
if ($checkOnlyMode) {
    $status = if ($healthy) { 'AlreadyInstalled' } elseif ($installationEvidencePresent) { 'Partial' } else { 'Absent' }
    Write-ReplicationInstallResult -Status $status -ApplianceStatus $initialStatus -RequiresReboot:(Test-PendingReboot)
    exit 0
}
if ($installationEvidencePresent -and -not $forceInstall) {
    Write-ReplicationInstallResult `
        -Status 'Partial' `
        -ApplianceStatus $initialStatus `
        -RequiresReboot:(Test-PendingReboot) `
        -Issues @('A partial installation was detected. Review logs, then rerun with -Force to repair it.')
    exit 0
}

$prerequisiteIssues = @(Get-PrerequisiteIssues)
if ($prerequisiteIssues.Count -gt 0) {
    Write-ReplicationInstallResult -Status 'PrerequisiteFailed' -ApplianceStatus $initialStatus -Issues $prerequisiteIssues
    exit 0
}
if (Test-PendingReboot) {
    Write-ReplicationInstallResult -Status 'RequiresReboot' -ApplianceStatus $initialStatus -RequiresReboot $true
    exit 0
}

$completionStatus = if ($installationEvidencePresent -and $forceInstall) { 'Repaired' } else { 'Installed' }
New-Item -Path $setupRoot -ItemType Directory -Force | Out-Null

$packageIsValid = $false
if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
    $cachedHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
    $packageIsValid = $cachedHash -ieq $expectedSha256
}
if (-not $packageIsValid) {
    Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
        throw 'curl.exe is required to download the 4 GB replication appliance package.'
    }
    & $curl.Source -L --fail --silent --show-error --output $packagePath $installerUri
    if ($LASTEXITCODE -ne 0) {
        throw 'The replication appliance package download failed.'
    }
    if (
        -not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or
        (Get-Item -LiteralPath $packagePath).Length -eq 0
    ) {
        throw "The replication appliance package download did not create a non-empty file at '$packagePath'."
    }
}
$actualSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
if ($actualSha256 -ine $expectedSha256) {
    throw "Replication appliance package SHA256 mismatch. Expected $expectedSha256; received $actualSha256."
}

if (Test-Path -LiteralPath $extractPath) {
    Remove-Item -LiteralPath $extractPath -Recurse -Force
}
New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
Expand-Archive -LiteralPath $packagePath -DestinationPath $extractPath -Force
$installer = Get-ChildItem -LiteralPath $extractPath -Filter 'DRInstaller.ps1' -File -Recurse |
    Select-Object -First 1
if ($null -eq $installer) {
    throw 'DRInstaller.ps1 was not found in the downloaded package.'
}

$powerShellFiles = @(
    Get-ChildItem -LiteralPath $extractPath -File -Recurse |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') }
)
if ($powerShellFiles.Count -eq 0) {
    throw 'The package did not contain PowerShell files to validate.'
}
foreach ($powerShellFile in $powerShellFiles) {
    $signature = Get-AuthenticodeSignature -LiteralPath $powerShellFile.FullName
    if (
        $signature.Status -ne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation'
    ) {
        throw "Invalid Microsoft Authenticode signature: $($powerShellFile.FullName) ($($signature.Status))"
    }
}

# Azure VM Run Command executes as SYSTEM. Microsoft creates a shortcut in the
# current profile's Desktop as its final setup operation, so ensure it exists.
$systemDesktopPath = Join-Path $env:USERPROFILE 'Desktop'
New-Item -Path $systemDesktopPath -ItemType Directory -Force | Out-Null

$installerProcess = Start-Process `
    -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $installer.FullName)
    ) `
    -WorkingDirectory $installer.DirectoryName `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -Wait `
    -PassThru

$postInstallStatus = Get-ReplicationApplianceStatus
$pendingReboot = Test-PendingReboot
if ($pendingReboot) {
    Write-ReplicationInstallResult `
        -Status 'RequiresReboot' `
        -ApplianceStatus $postInstallStatus `
        -RequiresReboot $true
    exit 0
}
if ($installerProcess.ExitCode -ne 0) {
    $errorTail = if (Test-Path -LiteralPath $stderrPath) {
        @((Get-Content -LiteralPath $stderrPath -Tail 30))
    }
    else {
        @('No installer error log was produced.')
    }
    $healthyAfterFailure = `
        $postInstallStatus.RegistryPresent -and `
        $postInstallStatus.ConfigurationPortListening -and `
        $postInstallStatus.IisRunning -and `
        $postInstallStatus.ConfigurationManagerPresent -and `
        $postInstallStatus.ConfigurationManagerSiteStarted -and `
        $postInstallStatus.ConfigurationManagerPoolStarted
    if ($healthyAfterFailure) {
        Write-ReplicationInstallResult `
            -Status 'InstalledWithWarnings' `
            -ApplianceStatus $postInstallStatus `
            -Issues @("DRInstaller exited with code $($installerProcess.ExitCode).", ($errorTail -join [Environment]::NewLine))
        exit 0
    }
    throw "DRInstaller failed with exit code $($installerProcess.ExitCode).$([Environment]::NewLine)$($errorTail -join [Environment]::NewLine)"
}

$finalStatus = $null
foreach ($attempt in 1..60) {
    $finalStatus = Get-ReplicationApplianceStatus
    if (
        $finalStatus.RegistryPresent -and
        $finalStatus.ConfigurationPortListening -and
        $finalStatus.IisRunning -and
        $finalStatus.ConfigurationManagerPresent -and
        $finalStatus.ConfigurationManagerSiteStarted -and
        $finalStatus.ConfigurationManagerPoolStarted
    ) {
        break
    }
    Start-Sleep -Seconds 5
}
if (
    $null -eq $finalStatus -or
    -not $finalStatus.RegistryPresent -or
    -not $finalStatus.ConfigurationPortListening -or
    -not $finalStatus.IisRunning -or
    -not $finalStatus.ConfigurationManagerPresent -or
    -not $finalStatus.ConfigurationManagerSiteStarted -or
    -not $finalStatus.ConfigurationManagerPoolStarted
) {
    throw "DRInstaller exited successfully, but Configuration Manager did not become ready. Review logs under $setupRoot."
}

Write-ReplicationInstallResult -Status $completionStatus -ApplianceStatus $finalStatus
'@

    $remoteScriptFile = Join-Path $env:TEMP "azure-migrate-replication-$([Guid]::NewGuid().ToString('N')).ps1"
    Set-Content -LiteralPath $remoteScriptFile -Value $remoteInstallerScript -Encoding utf8NoBOM

    function Invoke-ReplicationRemoteScript {
        param([Parameter(Mandatory)][bool]$CheckOnly)

        $output = Invoke-AzureCliText @(
            'vm', 'run-command', 'invoke',
            '--subscription', $sourceSubscriptionId,
            '--resource-group', $sourceResourceGroupName,
            '--name', $replicationVmName,
            '--command-id', 'RunPowerShellScript',
            '--scripts', "@$remoteScriptFile",
            '--parameters',
            "installerUri=$($InstallerUri.AbsoluteUri)",
            "expectedSha256=$($ExpectedSha256.ToUpperInvariant())",
            "force=$($Force.IsPresent.ToString().ToLowerInvariant())",
            "checkOnly=$($CheckOnly.ToString().ToLowerInvariant())",
            '--output', 'json',
            '--only-show-errors'
        ) 'Remote simplified replication appliance operation failed.'
        return Get-ReplicationInstallResult -RunCommandOutput $output
    }

    $installResult = Invoke-ReplicationRemoteScript -CheckOnly $false
    if ($installResult.Status -eq 'RequiresReboot') {
        Write-Warning 'DRInstaller requires a reboot before health verification can continue.'
        $restartConfirmation = (Read-Host 'Type RESTART to restart the replication VM now, or Q to stop').Trim()
        if ($restartConfirmation -cne 'RESTART') {
            Write-LocalReplicationResult -Result $installResult
            throw 'Restart was not approved. Rerun this script after restarting the VM.'
        }
        Invoke-AzureCliText @(
            'vm', 'restart',
            '--subscription', $sourceSubscriptionId,
            '--resource-group', $sourceResourceGroupName,
            '--name', $replicationVmName,
            '--only-show-errors'
        ) "Could not restart replication VM '$replicationVmName'." | Out-Null
        Wait-ReplicationVmAgentReady `
            -SubscriptionId $sourceSubscriptionId `
            -ResourceGroupName $sourceResourceGroupName `
            -VirtualMachineName $replicationVmName
        $installResult = Invoke-ReplicationRemoteScript -CheckOnly $true
    }

    switch ($installResult.Status) {
        'AlreadyInstalled' { Write-Host 'Check complete: simplified replication appliance is already installed and healthy.' -ForegroundColor Green }
        'Installed' { Write-Host 'Installation complete: simplified replication appliance configurator is ready.' -ForegroundColor Green }
        'Repaired' { Write-Host 'Repair complete: simplified replication appliance configurator is ready.' -ForegroundColor Green }
        'InstalledWithWarnings' {
            Write-Warning 'Installation completed with a healthy configurator but DRInstaller reported a late warning.'
            foreach ($issue in @($installResult.Issues)) { Write-Host "- $issue" -ForegroundColor Yellow }
        }
        'Partial' {
            Write-Warning 'A partial simplified replication appliance installation was detected.'
            Write-LocalReplicationResult -Result $installResult
            throw 'Review the remote logs, then rerun with -Force.'
        }
        'PrerequisiteFailed' {
            Write-Host 'Replication appliance prerequisites failed:' -ForegroundColor Red
            foreach ($issue in @($installResult.Issues)) { Write-Host "- $issue" -ForegroundColor Red }
            Write-LocalReplicationResult -Result $installResult
            throw 'Resolve the reported replication appliance prerequisites, then rerun.'
        }
        default { Write-Host "Simplified replication appliance status: $($installResult.Status)" }
    }

    $registrationStatus = $null
    if ($RequireRegistered) {
        Write-Host 'Checking Azure for a connected Site Recovery replication provider...' -ForegroundColor Cyan
        $registrationStatus = Wait-ReplicationRegistration `
            -SubscriptionId $targetSubscriptionId `
            -ResourceGroupName $targetResourceGroupName
        $installResult.Registered = $true
        $installResult | Add-Member -NotePropertyName RegistrationVaultName -NotePropertyValue $registrationStatus.VaultName
        $installResult | Add-Member -NotePropertyName RegistrationFabricName -NotePropertyValue $registrationStatus.FabricName
        $installResult | Add-Member -NotePropertyName RegistrationFabricHealth -NotePropertyValue $registrationStatus.FabricHealth
        $installResult | Add-Member -NotePropertyName RegistrationProviderName -NotePropertyValue $registrationStatus.ProviderName
        $installResult | Add-Member -NotePropertyName RegistrationConnectionStatus -NotePropertyValue $registrationStatus.ConnectionStatus
        $installResult | Add-Member -NotePropertyName RegistrationLastHeartbeat -NotePropertyValue $registrationStatus.LastHeartbeat
        $installResult | Add-Member -NotePropertyName RegistrationMachineName -NotePropertyValue $registrationStatus.MachineName
    }
    Write-LocalReplicationResult -Result $installResult
    Write-Host "Configuration Manager port listening: $($installResult.ConfigurationPortListening)"
    if ($null -ne $registrationStatus) {
        Write-Host "Registered provider: $($registrationStatus.ProviderName)" -ForegroundColor Green
        Write-Host "Connection: $($registrationStatus.ConnectionStatus); fabric health: $($registrationStatus.FabricHealth)" -ForegroundColor Green
        Write-Host "Last heartbeat: $($registrationStatus.LastHeartbeat)"
    }
    else {
        Write-Host 'Azure registration verification: not requested.'
    }
    Write-Host "Remote setup directory: $($installResult.SetupRoot)"
    Write-Host ''
    Write-Host 'Manual registration remains:' -ForegroundColor Cyan
    Write-Host "1. RDP to '$publicIpAddress' for replication VM '$replicationVmName'."
    Write-Host '2. Open Microsoft Azure Appliance Configuration Manager locally.'
    Write-Host '3. Select private IP or FQDN connectivity for the static appliance address 10.10.1.20.'
    Write-Host '4. Enter the portal-generated simplified replication appliance key.'
    Write-Host '5. Complete device-code authentication and select the Recovery Services vault.'
    Write-Host '6. Add physical-server credentials and source IP addresses.'
    Write-Host '7. Continue in the UI to install and register the remaining replication components.'
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($remoteScriptFile)) {
        Remove-Item -LiteralPath $remoteScriptFile -Force -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($previousAzureExtensionDirectory)) {
        Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory
    }
}