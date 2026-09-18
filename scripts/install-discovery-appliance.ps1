[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [uri]$InstallerUri = 'https://go.microsoft.com/fwlink/?linkid=2140334',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedSha256 = '277C53620DB299F57E3AC5A65569E9720F06190A245476810B36BF651C8B795B',
    [uri]$ConfigurationManagerUpdateUri = 'https://download.microsoft.com/download/06f46dfb-39ff-439e-bab5-4795e2f4fad4/MicrosoftAzureApplianceConfigurationManager.msi',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ConfigurationManagerUpdateSha256 = 'DADC4E031E671CDD288D1B060E5DF687A295E60BF44054FE339FB318BB12C7D5',
    [uri]$AutoUpdateUri = 'https://download.microsoft.com/download/c8ee5975-595e-48ba-b8b8-1104f08063d5/MicrosoftAzureAutoUpdate.msi',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AutoUpdateSha256 = 'C3220E19E18731A08F4EA78C6B91E64D5A89450A2696E9E20A36AD1ECCEAA58A',
    [switch]$SkipComponentUpdates,
    [switch]$Force,
    [switch]$SkipExternalReachabilityCheck
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

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it before running this script.'
}
if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) {
    throw "Deployment configuration was not found: $configFilePath"
}
if ($InstallerUri.Scheme -ne 'https') {
    throw 'InstallerUri must use HTTPS.'
}
if ($InstallerUri.Host -notin @('go.microsoft.com', 'aka.ms', 'download.microsoft.com')) {
    throw "InstallerUri must use an approved Microsoft download host. Received: $($InstallerUri.Host)"
}
foreach ($updateUri in $ConfigurationManagerUpdateUri, $AutoUpdateUri) {
    if ($updateUri.Scheme -ne 'https' -or $updateUri.Host -ne 'download.microsoft.com') {
        throw "Component update URI must use HTTPS on download.microsoft.com. Received: $updateUri"
    }
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
    $discoveryVmName = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--query', 'properties.outputs.discoveryApplianceName.value',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read discoveryApplianceName from subscription deployment '$DeploymentName'."
    $sourceResourceGroupName = ($sourceResourceGroupId -split '/')[-1]

    $vmPowerState = Get-RequiredAzureCliValue @(
        'vm', 'show',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $discoveryVmName,
        '--show-details',
        '--query', 'powerState',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read the power state for discovery VM '$discoveryVmName'."
    if ($vmPowerState -ne 'VM running') {
        throw "Discovery VM '$discoveryVmName' must be running. Current state: $vmPowerState"
    }

    $vmAgentState = Get-RequiredAzureCliValue @(
        'vm', 'get-instance-view',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $discoveryVmName,
        '--query', 'instanceView.vmAgent.statuses[0].displayStatus',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not read the VM Agent state for discovery VM '$discoveryVmName'."
    if ($vmAgentState -ne 'Ready') {
        throw "The Azure VM Agent must be ready before remote installation. Current state: $vmAgentState"
    }

    $publicIpAddress = Get-RequiredAzureCliValue @(
        'vm', 'show',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $discoveryVmName,
        '--show-details',
        '--query', 'publicIps',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not resolve the public IP address for discovery VM '$discoveryVmName'."

    Write-Host "Discovery VM: $discoveryVmName" -ForegroundColor Cyan
    Write-Host "Source resource group: $sourceResourceGroupName"
    Write-Host "Public IP address: $publicIpAddress"
    Write-Host 'Checking discovery appliance state through Azure VM Run Command. No WinRM ports or administrator password are used.'

    $remoteInstallerScript = @'
param(
    [Parameter(Mandatory)][string]$installerUri,
    [Parameter(Mandatory)][string]$expectedSha256,
    [Parameter(Mandatory)][string]$force,
    [Parameter(Mandatory)][string]$configurationManagerUpdateUri,
    [Parameter(Mandatory)][string]$configurationManagerUpdateSha256,
    [Parameter(Mandatory)][string]$autoUpdateUri,
    [Parameter(Mandatory)][string]$autoUpdateSha256,
    [Parameter(Mandatory)][string]$skipComponentUpdates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$forceInstall = [Convert]::ToBoolean($force)
$skipUpdates = [Convert]::ToBoolean($skipComponentUpdates)
$setupRoot = 'C:\AzureMigrateSetup'
$packagePath = Join-Path $setupRoot 'AzureMigrateInstaller.zip'
$extractPath = Join-Path $setupRoot 'package'
$stdoutPath = Join-Path $setupRoot 'installer-stdout.log'
$stderrPath = Join-Path $setupRoot 'installer-stderr.log'
$installerWrapperPath = Join-Path $setupRoot 'invoke-installer.ps1'
$installerInputPath = Join-Path $setupRoot 'installer-input.txt'
$applianceRegistryPath = 'HKLM:\SOFTWARE\Microsoft\AzureAppliance'
$componentUpdateMarkerPath = Join-Path $setupRoot 'component-updates.json'
$componentUpdateRebootRequired = $false
$componentUpdatesApplied = $false

function Get-ApplianceStatus {
    $listener = Get-NetTCPConnection -State Listen -LocalPort 44368 -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $iisService = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        RegistryPresent = Test-Path -LiteralPath $applianceRegistryPath
        ConfigurationPortListening = $null -ne $listener
        IisRunning = $null -ne $iisService -and $iisService.Status -eq 'Running'
    }
}

function Install-VerifiedMicrosoftMsi {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    $msiPath = Join-Path $setupRoot "$Name.msi"
    $logPath = Join-Path $setupRoot "$Name-install.log"
    Invoke-WebRequest -Uri $Uri -OutFile $msiPath -UseBasicParsing
    $actualSha256 = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
    if ($actualSha256 -ine $ExpectedSha256) {
        throw "$Name SHA256 mismatch. Expected $ExpectedSha256; received $actualSha256."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $msiPath
    if (
        $signature.Status -ne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation'
    ) {
        throw "$Name does not have a valid Microsoft Authenticode signature ($($signature.Status))."
    }

    $arguments = @('/i', ('"{0}"' -f $msiPath), '/qn', '/norestart', '/L*v', ('"{0}"' -f $logPath))
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "$Name installation failed with exit code $($process.ExitCode). Review $logPath."
    }
    if ($process.ExitCode -eq 3010) {
        $script:componentUpdateRebootRequired = $true
    }
}

function Update-ApplianceComponents {
    if ($skipUpdates) {
        return
    }

    New-Item -Path $setupRoot -ItemType Directory -Force | Out-Null
    $expectedMarker = [ordered]@{
        ConfigurationManagerSha256 = $configurationManagerUpdateSha256.ToUpperInvariant()
        AutoUpdateSha256 = $autoUpdateSha256.ToUpperInvariant()
    }
    if (Test-Path -LiteralPath $componentUpdateMarkerPath -PathType Leaf) {
        try {
            $currentMarker = Get-Content -LiteralPath $componentUpdateMarkerPath -Raw | ConvertFrom-Json
            if (
                [string]$currentMarker.ConfigurationManagerSha256 -ieq $expectedMarker.ConfigurationManagerSha256 -and
                [string]$currentMarker.AutoUpdateSha256 -ieq $expectedMarker.AutoUpdateSha256
            ) {
                return
            }
        }
        catch {
            Write-Warning "Ignoring invalid component update marker: $($_.Exception.Message)"
        }
    }

    Install-VerifiedMicrosoftMsi -Name 'MicrosoftAzureAutoUpdate' -Uri $autoUpdateUri -ExpectedSha256 $autoUpdateSha256
    Install-VerifiedMicrosoftMsi `
        -Name 'MicrosoftAzureApplianceConfigurationManager' `
        -Uri $configurationManagerUpdateUri `
        -ExpectedSha256 $configurationManagerUpdateSha256
    $expectedMarker | ConvertTo-Json | Set-Content -LiteralPath $componentUpdateMarkerPath -Encoding utf8
    $script:componentUpdatesApplied = $true
    Restart-Service -Name W3SVC -Force -ErrorAction SilentlyContinue
}

function Write-InstallResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][object]$ApplianceStatus
    )

    $result = [ordered]@{
        Status = $Status
        RegistryPresent = [bool]$ApplianceStatus.RegistryPresent
        ConfigurationPortListening = [bool]$ApplianceStatus.ConfigurationPortListening
        IisRunning = [bool]$ApplianceStatus.IisRunning
        ComponentUpdatesApplied = $componentUpdatesApplied
        ComponentUpdateRebootRequired = $componentUpdateRebootRequired
        SetupRoot = $setupRoot
        InstallerStdout = $stdoutPath
        InstallerStderr = $stderrPath
    } | ConvertTo-Json -Compress
    Write-Output "AZURE_MIGRATE_DISCOVERY_INSTALL_RESULT=$result"
}

$initialStatus = Get-ApplianceStatus
$installationEvidencePresent = `
    $initialStatus.RegistryPresent -or `
    $initialStatus.ConfigurationPortListening -or `
    $initialStatus.IisRunning
if (
    $initialStatus.RegistryPresent -and
    $initialStatus.ConfigurationPortListening -and
    $initialStatus.IisRunning -and
    -not $forceInstall
) {
    Update-ApplianceComponents
    $updatedStatus = Get-ApplianceStatus
    if (-not $updatedStatus.ConfigurationPortListening -or -not $updatedStatus.IisRunning) {
        throw 'Discovery appliance component updates completed, but Configuration Manager is not healthy on TCP 44368.'
    }
    Write-InstallResult -Status 'AlreadyInstalled' -ApplianceStatus $updatedStatus
    exit 0
}
if ($installationEvidencePresent -and -not $forceInstall) {
    throw 'A partial Azure Migrate appliance installation was detected. Review the remote logs, then rerun with -Force to repair it.'
}
$completionStatus = if ($installationEvidencePresent -and $forceInstall) {
    'Repaired'
}
else {
    'Installed'
}

New-Item -Path $setupRoot -ItemType Directory -Force | Out-Null
if (Test-Path -LiteralPath $extractPath) {
    Remove-Item -LiteralPath $extractPath -Recurse -Force
}
New-Item -Path $extractPath -ItemType Directory -Force | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $installerUri -OutFile $packagePath -UseBasicParsing
$actualSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
if ($actualSha256 -ine $expectedSha256) {
    throw "Azure Migrate installer SHA256 mismatch. Expected $expectedSha256; received $actualSha256."
}

Expand-Archive -LiteralPath $packagePath -DestinationPath $extractPath -Force
$installer = Get-ChildItem -LiteralPath $extractPath -Filter 'AzureMigrateInstaller.ps1' -File -Recurse |
    Select-Object -First 1
if ($null -eq $installer) {
    throw 'AzureMigrateInstaller.ps1 was not found in the downloaded package.'
}

$powerShellFiles = @(
    Get-ChildItem -LiteralPath $extractPath -File -Recurse |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') }
)
if ($powerShellFiles.Count -eq 0) {
    throw 'The installer package did not contain PowerShell files to validate.'
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

@(
    'param([Parameter(Mandatory)][string]$InstallerPath)'
    'function Install-WindowsFeature {'
    '    [CmdletBinding()]'
    '    param([Parameter(Mandatory, Position = 0)][string[]]$Name)'
    '    $requestedFeatures = @($Name)'
    '    if ($requestedFeatures -contains ''PowerShell-ISE'') {'
    '        $iseCapability = Get-WindowsCapability -Online -Name ''Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0'' -ErrorAction SilentlyContinue'
    '        $iseExecutable = ''C:\Windows\System32\WindowsPowerShell\v1.0\PowerShell_ISE.exe'''
    '        if ($null -eq $iseCapability -or $iseCapability.State -ne ''Installed'' -or -not (Test-Path -LiteralPath $iseExecutable)) {'
    '            throw ''PowerShell ISE is unavailable as both a Server Manager feature and an installed Windows capability.'''
    '        }'
    '        $requestedFeatures = @($requestedFeatures | Where-Object { $_ -ne ''PowerShell-ISE'' })'
    '    }'
    '    if ($requestedFeatures.Count -gt 0) {'
    '        ServerManager\Install-WindowsFeature -Name $requestedFeatures'
    '    }'
    '}'
    '. $InstallerPath -Scenario Physical -Cloud Public -PrivateEndpoint:$false'
    'if (-not $?) { exit 1 }'
    'exit 0'
) | Set-Content -LiteralPath $installerWrapperPath -Encoding utf8

# Confirm the selected configuration, then decline optional browser installation
# and Internet Explorer removal so unattended setup cannot trigger a reboot.
@('Y', 'N', 'N') | Set-Content -LiteralPath $installerInputPath -Encoding ascii

try {
    $installerArguments = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"{0}"' -f $installerWrapperPath)
        '-InstallerPath'
        ('"{0}"' -f $installer.FullName)
    )
    $installerProcess = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $installerArguments `
        -WorkingDirectory $installer.DirectoryName `
        -RedirectStandardInput $installerInputPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -Wait `
        -PassThru
}
finally {
    Remove-Item -LiteralPath $installerWrapperPath, $installerInputPath -Force -ErrorAction SilentlyContinue
}

if ($installerProcess.ExitCode -ne 0) {
    $errorTail = if (Test-Path -LiteralPath $stderrPath) {
        (Get-Content -LiteralPath $stderrPath -Tail 30) -join [Environment]::NewLine
    }
    else {
        'No installer error log was produced.'
    }
    throw "Azure Migrate discovery installer failed with exit code $($installerProcess.ExitCode).$([Environment]::NewLine)$errorTail"
}

Update-ApplianceComponents

$finalStatus = $null
foreach ($attempt in 1..60) {
    $finalStatus = Get-ApplianceStatus
    if (
        $finalStatus.RegistryPresent -and
        $finalStatus.ConfigurationPortListening -and
        $finalStatus.IisRunning
    ) {
        break
    }
    Start-Sleep -Seconds 5
}
if (
    $null -eq $finalStatus -or
    -not $finalStatus.RegistryPresent -or
    -not $finalStatus.ConfigurationPortListening -or
    -not $finalStatus.IisRunning
) {
    throw "The installer exited successfully, but Configuration Manager did not become ready on TCP 44368. Review logs under $setupRoot."
}

Write-InstallResult -Status $completionStatus -ApplianceStatus $finalStatus
'@

    $forceValue = $Force.IsPresent.ToString().ToLowerInvariant()
    $skipComponentUpdatesValue = $SkipComponentUpdates.IsPresent.ToString().ToLowerInvariant()
    $remoteScriptFile = Join-Path $env:TEMP "azure-migrate-discovery-$([Guid]::NewGuid().ToString('N')).ps1"
    Set-Content -LiteralPath $remoteScriptFile -Value $remoteInstallerScript -Encoding utf8NoBOM
    $runCommandOutput = Invoke-AzureCliText @(
        'vm', 'run-command', 'invoke',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', $sourceResourceGroupName,
        '--name', $discoveryVmName,
        '--command-id', 'RunPowerShellScript',
        '--scripts', "@$remoteScriptFile",
        '--parameters',
        "installerUri=$($InstallerUri.AbsoluteUri)",
        "expectedSha256=$($ExpectedSha256.ToUpperInvariant())",
        "force=$forceValue",
        "configurationManagerUpdateUri=$($ConfigurationManagerUpdateUri.AbsoluteUri)",
        "configurationManagerUpdateSha256=$($ConfigurationManagerUpdateSha256.ToUpperInvariant())",
        "autoUpdateUri=$($AutoUpdateUri.AbsoluteUri)",
        "autoUpdateSha256=$($AutoUpdateSha256.ToUpperInvariant())",
        "skipComponentUpdates=$skipComponentUpdatesValue",
        '--output', 'json',
        '--only-show-errors'
    ) 'Remote Azure Migrate discovery appliance installation failed.'

    $runCommandResult = $runCommandOutput | ConvertFrom-Json
    $runCommandMessage = @($runCommandResult.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
    $resultMatch = [regex]::Match(
        $runCommandMessage,
        '(?m)^\s*AZURE_MIGRATE_DISCOVERY_INSTALL_RESULT=(?<result>\{[^\r\n]+\})\s*$'
    )
    if (-not $resultMatch.Success) {
        throw "Remote installation did not return a completion result.$([Environment]::NewLine)$runCommandMessage"
    }
    $installResult = $resultMatch.Groups['result'].Value | ConvertFrom-Json
    $installResultJson = $installResult | ConvertTo-Json -Depth 5 -Compress
    $resultLine = "AZURE_MIGRATE_DISCOVERY_RESULT=$installResultJson"
    Write-Output $resultLine
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_MIGRATE_LAB_RESULT_FILE)) {
        Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE -Value $resultLine -Encoding utf8NoBOM
    }

    switch ($installResult.Status) {
        'AlreadyInstalled' { Write-Host 'Check complete: discovery appliance is already installed and healthy.' -ForegroundColor Green }
        'Installed' { Write-Host 'Installation complete: discovery appliance is installed and healthy.' -ForegroundColor Green }
        'Repaired' { Write-Host 'Repair complete: discovery appliance is installed and healthy.' -ForegroundColor Green }
        default { Write-Host "Discovery appliance status: $($installResult.Status)" -ForegroundColor Green }
    }
    Write-Host "Configuration Manager port listening: $($installResult.ConfigurationPortListening)"
    Write-Host "Latest component updates applied: $($installResult.ComponentUpdatesApplied)"
    if ($installResult.ComponentUpdateRebootRequired) {
        Write-Warning 'A component update requested a reboot. Restart the discovery VM before registration if prerequisites remain unhealthy.'
    }
    Write-Host "Remote setup directory: $($installResult.SetupRoot)"

    if (-not $SkipExternalReachabilityCheck) {
        $configurationManagerReachable = Test-NetConnection `
            -ComputerName $publicIpAddress `
            -Port 44368 `
            -InformationLevel Quiet
        if (-not $configurationManagerReachable) {
            Write-Warning "Configuration Manager is listening on the VM but https://$publicIpAddress`:44368 is not reachable from this computer. Confirm your current public IP matches AdminSourceCidr in $configFilePath."
        }
        else {
            Write-Host "Configuration Manager: https://$publicIpAddress`:44368" -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host 'Manual registration remains:' -ForegroundColor Cyan
    Write-Host '1. In Azure Migrate Overview > Inventory, select Start discovery > Using appliance > Physical or other.'
    Write-Host '2. Generate the project key with an alphanumeric appliance name of 14 characters or fewer.'
    Write-Host "3. Open https://$publicIpAddress`:44368, paste the key, install updates, and complete device-code sign-in."
    Write-Host '4. Add credentials: labwindows = Windows/labadmin/password; lablinux = Linux/labadmin/SSH key.'
    Write-Host '5. Add sources:'
    Write-Host '   Windows | source-win01   | 10.10.2.10 | labwindows'
    Write-Host '   Linux   | source-linux01 | 10.10.2.20 | lablinux'
    Write-Host '6. Validate both sources, select Start discovery, and wait for successful initiation.'
    Write-Host 'A 401 from graph.windows.net proves endpoint reachability; it is not a NAT or firewall failure.'
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