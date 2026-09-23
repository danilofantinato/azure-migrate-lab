[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [uri]$WindowsServerIsoUri = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US',
    [Alias('UbuntuVhdArchiveUri', 'UbuntuIsoUri')][uri]$UbuntuCloudImageUri = 'https://cloud-images.ubuntu.com/releases/jammy/release-20251031/ubuntu-22.04-server-cloudimg-amd64.img',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$WindowsServerIsoSha256,
    [Alias('UbuntuVhdArchiveSha256', 'UbuntuIsoSha256')][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$UbuntuCloudImageSha256 = 'f73a2d754110b0fc0ddaa3e7c4c1005d9e3067409f20e0c1ddd61c57d36f257a',
    [uri]$QemuImgArchiveUri = 'https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$QemuImgArchiveSha256 = '8DC1C69D9880919CDAD8C09126A016262D4A9EDF48B87A1EF587914FE4177909',
    [ValidateRange(2, 8)][int]$ProvisioningTimeoutHours = 8,
    [switch]$RebuildLinux,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$guestAssetPath = Join-Path $PSScriptRoot 'guest-assets\Provision-NestedGuests.ps1'
$configFilePath = if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    Join-Path $PSScriptRoot 'deploy-lab.local.json'
}
elseif ([IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
}
else {
    Join-Path $repositoryRoot $ConfigFile
}

function Write-HyperVProgress {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message" -ForegroundColor Cyan
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
    if ([string]::IsNullOrWhiteSpace($value)) { throw $FailureMessage }
    return $value
}

function Wait-HyperVVmAgentReady {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VirtualMachineName,
        [ValidateRange(1, 90)][int]$MaximumAttempts = 60
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
            Write-HyperVProgress "Azure VM Agent is ready on $VirtualMachineName."
            return
        }
        if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
            $displayState = if ([string]::IsNullOrWhiteSpace([string]$state)) { 'unavailable' } else { [string]$state }
            Write-HyperVProgress "Waiting for Azure VM Agent on $VirtualMachineName ($attempt/$MaximumAttempts; state: $displayState)."
        }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds 10 }
    }
    throw "The Azure VM Agent for '$VirtualMachineName' did not become ready."
}

function Invoke-HyperVRunCommand {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VirtualMachineName,
        [Parameter(Mandatory)][string]$ScriptText,
        [Parameter(Mandatory)][string]$FailureMessage,
        [ValidateRange(1, 60)][int]$MaximumAttempts = 18,
        [ValidateRange(0, 60)][int]$RetryDelaySeconds = 10
    )

    $temporaryScript = Join-Path $env:TEMP "azure-migrate-hyperv-$([Guid]::NewGuid().ToString('N')).ps1"
    try {
        Set-Content -LiteralPath $temporaryScript -Value $ScriptText -Encoding utf8
        foreach ($attempt in 1..$MaximumAttempts) {
            $output = @(& az vm run-command invoke `
                --subscription $SubscriptionId `
                --resource-group $ResourceGroupName `
                --name $VirtualMachineName `
                --command-id RunPowerShellScript `
                --scripts "@$temporaryScript" `
                --output json `
                --only-show-errors 2>&1)
            $exitCode = $LASTEXITCODE
            $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            if ($exitCode -eq 0) {
                $response = $details | ConvertFrom-Json
                return @($response.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
            }

            $runCommandBusy = $details -match '(?i)Run command extension execution is in progress'
            if (-not $runCommandBusy -or $attempt -eq $MaximumAttempts) {
                throw "$FailureMessage$([Environment]::NewLine)$details"
            }
            if ($attempt -eq 1 -or $attempt % 3 -eq 0) {
                Write-HyperVProgress "Another Run Command is still finishing on $VirtualMachineName; retrying status access ($attempt/$MaximumAttempts)."
            }
            if ($RetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction SilentlyContinue
    }
}

function Get-RemoteResult {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Marker
    )

    $match = [regex]::Match($Message, "(?m)^\s*$([regex]::Escape($Marker))(?<result>\{[^\r\n]+\})\s*$")
    if (-not $match.Success) { throw "Remote command did not return $Marker$([Environment]::NewLine)$Message" }
    return $match.Groups['result'].Value | ConvertFrom-Json
}

function New-GuestPassword {
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
    while ($characters.Count -lt 24) {
        $characters.Add($allCharacters[[Security.Cryptography.RandomNumberGenerator]::GetInt32($allCharacters.Length)])
    }
    for ($index = $characters.Count - 1; $index -gt 0; $index--) {
        $swapIndex = [Security.Cryptography.RandomNumberGenerator]::GetInt32($index + 1)
        $temporaryCharacter = $characters[$index]
        $characters[$index] = $characters[$swapIndex]
        $characters[$swapIndex] = $temporaryCharacter
    }
    $secureString = [Security.SecureString]::new()
    foreach ($character in $characters) {
        $secureString.AppendChar($character)
    }
    $secureString.MakeReadOnly()
    return $secureString
}

function Confirm-GuestPasswordStored {
    param([Parameter(Mandatory)][securestring]$GuestSecret)

    $plainText = [Net.NetworkCredential]::new('', $GuestSecret).Password
    Write-Host ''
    $passwordLabel = if ($RebuildLinux) {
        'Generated replacement Linux guest labadmin/root password (Windows password is unchanged):'
    }
    else {
        'Generated temporary nested guest labadmin/root password:'
    }
    Write-Host $passwordLabel -ForegroundColor Yellow
    Write-Host $plainText -ForegroundColor Yellow
    Write-Host 'This password is displayed once and is not written to configuration, status, or result output.'
    $confirmation = (Read-Host 'Store it securely, then type READY to continue').Trim()
    $plainText = $null
    if ($confirmation -cne 'READY') { throw 'Password confirmation was not received. No provisioning task was launched.' }
}

function Write-HyperVResult {
    param([Parameter(Mandatory)][ValidateSet('AlreadyReady', 'Provisioning', 'Ready')][string]$Status)

    $result = [ordered]@{
        Status = $Status
        HyperVHostName = $script:hyperVHostName
        SourceResourceGroupName = $script:sourceResourceGroupName
        WindowsGuestName = 'source-win01'
        WindowsGuestIp = '10.10.3.10'
        LinuxGuestName = 'source-linux01'
        LinuxGuestIp = '10.10.3.20'
    }
    $resultLine = "AZURE_MIGRATE_HYPERV_RESULT=$($result | ConvertTo-Json -Compress)"
    Write-Output $resultLine
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_MIGRATE_LAB_RESULT_FILE)) {
        Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE -Value $resultLine -Encoding utf8NoBOM
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI was not found. Install it before running this script.' }
if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) { throw "Deployment configuration was not found: $configFilePath" }
if (-not (Test-Path -LiteralPath $guestAssetPath -PathType Leaf)) { throw "Nested guest asset was not found: $guestAssetPath" }
if ($WindowsServerIsoUri.Scheme -ne 'https' -or $UbuntuCloudImageUri.Scheme -ne 'https' -or $QemuImgArchiveUri.Scheme -ne 'https') {
    throw 'Media and tool URIs must use HTTPS.'
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
$isolatedAzureExtensionDirectory = Join-Path $env:TEMP "azure-migrate-lab-az-extensions-$([Guid]::NewGuid().ToString('N'))"
New-Item -Path $isolatedAzureExtensionDirectory -ItemType Directory -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $isolatedAzureExtensionDirectory
$guestPassword = $null

try {
    Write-HyperVProgress 'Resolving the deployed Hyper-V host and source resource group.'
    & az account show --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run az login before preparing the Hyper-V host.' }

    $sourceResourceGroupId = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show', '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName, '--query', 'properties.outputs.sourceResourceGroupId.value',
        '--output', 'tsv', '--only-show-errors'
    ) "Could not read sourceResourceGroupId from exact subscription deployment '$DeploymentName'."
    $script:hyperVHostName = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show', '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName, '--query', 'properties.outputs.hyperVHostName.value',
        '--output', 'tsv', '--only-show-errors'
    ) "Could not read hyperVHostName from exact subscription deployment '$DeploymentName'."
    $script:sourceResourceGroupName = ($sourceResourceGroupId -split '/')[-1]
    if ($sourceResourceGroupId -notmatch "(?i)^/subscriptions/$([regex]::Escape($sourceSubscriptionId))/resourceGroups/") {
        throw 'The deployment source resource group does not belong to SourceSubscriptionId.'
    }

    $powerState = Get-RequiredAzureCliValue @(
        'vm', 'show', '--subscription', $sourceSubscriptionId,
        '--resource-group', $script:sourceResourceGroupName, '--name', $script:hyperVHostName,
        '--show-details', '--query', 'powerState', '--output', 'tsv', '--only-show-errors'
    ) "Could not read the Hyper-V host power state."
    if ($powerState -ne 'VM running') { throw "Hyper-V host '$script:hyperVHostName' must be running. Current state: $powerState" }
    Write-HyperVProgress "Hyper-V host $script:hyperVHostName is running; checking its Azure VM Agent."
    Wait-HyperVVmAgentReady -SubscriptionId $sourceSubscriptionId -ResourceGroupName $script:sourceResourceGroupName -VirtualMachineName $script:hyperVHostName

    Write-HyperVProgress 'Inspecting Hyper-V roles and any previous nested provisioning state.'
    $inspectionScript = @'
$ErrorActionPreference = 'Stop'
$statusPath = 'C:\AzureMigrateNested\status.json'
$state = $null
if (Test-Path -LiteralPath $statusPath) {
    try { $state = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).state } catch { $state = 'Invalid' }
}
$featureStates = @('Hyper-V','RemoteAccess','Routing') | ForEach-Object {
    $feature = Get-WindowsFeature -Name $_
    [ordered]@{ name = $_; installed = [bool]$feature.Installed }
}
$result = [ordered]@{ state = $state; features = $featureStates }
Write-Output "AZURE_MIGRATE_HYPERV_INSPECTION=$($result | ConvertTo-Json -Compress)"
'@
    $inspectionMessage = Invoke-HyperVRunCommand -SubscriptionId $sourceSubscriptionId `
        -ResourceGroupName $script:sourceResourceGroupName -VirtualMachineName $script:hyperVHostName `
        -ScriptText $inspectionScript -FailureMessage 'Could not inspect the Hyper-V host.'
    $inspection = Get-RemoteResult -Message $inspectionMessage -Marker 'AZURE_MIGRATE_HYPERV_INSPECTION='
    if ($inspection.state -eq 'Ready' -and -not $Force -and -not $RebuildLinux) {
        Write-HyperVResult -Status AlreadyReady
        return
    }

    if ($RebuildLinux) {
        Write-HyperVProgress 'Linux-only rebuild requested; preserving existing Hyper-V and routing roles.'
    }
    elseif (@($inspection.features | Where-Object { -not $_.installed }).Count -gt 0) {
        Write-HyperVProgress 'Installing Hyper-V, Remote Access, and Routing roles. This can take several minutes.'
        $featureScript = @'
$ErrorActionPreference = 'Stop'
$result = Install-WindowsFeature -Name Hyper-V,RemoteAccess,Routing -IncludeManagementTools
$payload = [ordered]@{ success = [bool]$result.Success; restartNeeded = [string]$result.RestartNeeded }
Write-Output "AZURE_MIGRATE_HYPERV_FEATURES=$($payload | ConvertTo-Json -Compress)"
if (-not $result.Success) { exit 1 }
'@
        $featureMessage = Invoke-HyperVRunCommand -SubscriptionId $sourceSubscriptionId `
            -ResourceGroupName $script:sourceResourceGroupName -VirtualMachineName $script:hyperVHostName `
            -ScriptText $featureScript -FailureMessage 'Could not install Hyper-V and routing roles.'
        $featureResult = Get-RemoteResult -Message $featureMessage -Marker 'AZURE_MIGRATE_HYPERV_FEATURES='
        if ($featureResult.restartNeeded -ne 'No') {
            Write-HyperVProgress 'Restarting the Hyper-V host to complete role installation.'
            Invoke-AzureCliText @(
                'vm', 'restart', '--subscription', $sourceSubscriptionId,
                '--resource-group', $script:sourceResourceGroupName, '--name', $script:hyperVHostName,
                '--only-show-errors'
            ) "Could not restart Hyper-V host '$script:hyperVHostName'." | Out-Null
            Wait-HyperVVmAgentReady -SubscriptionId $sourceSubscriptionId `
                -ResourceGroupName $script:sourceResourceGroupName -VirtualMachineName $script:hyperVHostName
        }
    }
    else {
        Write-HyperVProgress 'Hyper-V, Remote Access, and Routing roles are already installed.'
    }

    Write-HyperVProgress 'Establishing an encrypted credential channel with the Hyper-V host.'
    $keyExchangeScript = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$root = 'C:\AzureMigrateNested'
New-Item -Path $root -ItemType Directory -Force | Out-Null
$rsa = [Security.Cryptography.RSACryptoServiceProvider]::new(2048)
$privateBytes = $null
try {
    $privateBytes = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
    $protectedPrivateBytes = [Security.Cryptography.ProtectedData]::Protect($privateBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllText((Join-Path $root 'credential-key.bin'), [Convert]::ToBase64String($protectedPrivateBytes))
    $publicKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($false)))
    Write-Output "AZURE_MIGRATE_HYPERV_KEY=$([ordered]@{ publicKey = $publicKey } | ConvertTo-Json -Compress)"
}
finally {
    if ($null -ne $privateBytes) { [Array]::Clear($privateBytes, 0, $privateBytes.Length) }
    $rsa.Dispose()
}
'@
    $keyExchangeMessage = Invoke-HyperVRunCommand -SubscriptionId $sourceSubscriptionId `
        -ResourceGroupName $script:sourceResourceGroupName -VirtualMachineName $script:hyperVHostName `
        -ScriptText $keyExchangeScript -FailureMessage 'Could not establish protected credential transport with the Hyper-V host.'
    $keyExchange = Get-RemoteResult -Message $keyExchangeMessage -Marker 'AZURE_MIGRATE_HYPERV_KEY='

    Write-HyperVProgress 'Generating the one-time nested guest credential.'
    $guestPassword = New-GuestPassword
    Confirm-GuestPasswordStored -GuestSecret $guestPassword
    $workerBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($guestAssetPath))
    $plainText = [Net.NetworkCredential]::new('', $guestPassword).Password
    $passwordBytes = [Text.Encoding]::UTF8.GetBytes($plainText)
    $publicKeyXml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$keyExchange.publicKey))
    $rsa = [Security.Cryptography.RSACryptoServiceProvider]::new()
    $rsa.FromXmlString($publicKeyXml)
    $encryptedPasswordBase64 = [Convert]::ToBase64String($rsa.Encrypt($passwordBytes, $true))
    $rsa.Dispose()
    [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
    $plainText = $null
    $publicKeyXml = $null
    $windowsHashArgument = if ($WindowsServerIsoSha256) { " -WindowsServerIsoSha256 ```"$WindowsServerIsoSha256```"" } else { '' }
    $ubuntuHashArgument = if ($UbuntuCloudImageSha256) { " -UbuntuCloudImageSha256 ```"$UbuntuCloudImageSha256```"" } else { '' }
    $qemuHashArgument = if ($QemuImgArchiveSha256) { " -QemuImgArchiveSha256 ```"$QemuImgArchiveSha256```"" } else { '' }
    $forceArgument = if ($Force) { ' -Force' } else { '' }
    $launchScript = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
`$root = 'C:\AzureMigrateNested'
New-Item -Path `$root -ItemType Directory -Force | Out-Null
`$workerPath = Join-Path `$root 'Provision-NestedGuests.ps1'
[IO.File]::WriteAllBytes(`$workerPath, [Convert]::FromBase64String('$workerBase64'))
`$keyPath = Join-Path `$root 'credential-key.bin'
`$protectedPrivateBytes = [Convert]::FromBase64String((Get-Content -LiteralPath `$keyPath -Raw).Trim())
`$privateBytes = [Security.Cryptography.ProtectedData]::Unprotect(`$protectedPrivateBytes, `$null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
`$rsa = [Security.Cryptography.RSACryptoServiceProvider]::new()
`$clearBytes = `$null
try {
    `$rsa.FromXmlString([Text.Encoding]::UTF8.GetString(`$privateBytes))
    `$clearBytes = `$rsa.Decrypt([Convert]::FromBase64String('$encryptedPasswordBase64'), `$true)
    `$protectedBytes = [Security.Cryptography.ProtectedData]::Protect(`$clearBytes, `$null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    `$credentialPath = Join-Path `$root 'credential.bin'
    [IO.File]::WriteAllText(`$credentialPath, [Convert]::ToBase64String(`$protectedBytes))
}
finally {
    if (`$null -ne `$clearBytes) { [Array]::Clear(`$clearBytes, 0, `$clearBytes.Length) }
    [Array]::Clear(`$privateBytes, 0, `$privateBytes.Length)
    `$rsa.Dispose()
    Remove-Item -LiteralPath `$keyPath -Force -ErrorAction SilentlyContinue
}
`$arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ```"`$workerPath```" -WindowsServerIsoUri ```"$($WindowsServerIsoUri.AbsoluteUri)```" -UbuntuCloudImageUri ```"$($UbuntuCloudImageUri.AbsoluteUri)```" -QemuImgArchiveUri ```"$($QemuImgArchiveUri.AbsoluteUri)```" -CredentialPayloadPath ```"`$credentialPath```"$windowsHashArgument$ubuntuHashArgument$qemuHashArgument$forceArgument"
`$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arguments
`$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
`$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -StartWhenAvailable
Register-ScheduledTask -TaskName 'AzureMigrateNestedGuests' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
Start-ScheduledTask -TaskName 'AzureMigrateNestedGuests'
Write-Output 'AZURE_MIGRATE_HYPERV_LAUNCH={"Status":"Provisioning"}'
"@
    Write-HyperVProgress 'Uploading the provisioning worker and starting its SYSTEM scheduled task.'
    $launchMessage = Invoke-HyperVRunCommand -SubscriptionId $sourceSubscriptionId `
        -ResourceGroupName $script:sourceResourceGroupName -VirtualMachineName $script:hyperVHostName `
        -ScriptText $launchScript -FailureMessage 'Could not launch nested guest provisioning.'
    $null = Get-RemoteResult -Message $launchMessage -Marker 'AZURE_MIGRATE_HYPERV_LAUNCH='
    $guestPassword = $null
    Write-HyperVResult -Status Provisioning
    Write-HyperVProgress 'Nested guest provisioning is running. Status refreshes every 30 seconds.'

    $pollScript = @'
$ErrorActionPreference = 'Stop'
$statusPath = 'C:\AzureMigrateNested\status.json'
    $task = Get-ScheduledTask -TaskName 'AzureMigrateNestedGuests' -ErrorAction SilentlyContinue
    $taskInfo = Get-ScheduledTaskInfo -TaskName 'AzureMigrateNestedGuests' -ErrorAction SilentlyContinue
    $assetRoot = Get-Volume -FileSystemLabel 'NestedGuests' -ErrorAction SilentlyContinue |
        Select-Object -First 1 |
        ForEach-Object { "$($_.DriveLetter):\AzureMigrateNested" }
    function Get-SizeMb([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
        return [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
    }
    $windowsIso = if ($assetRoot) { Join-Path $assetRoot 'downloads\windows-server.iso' } else { $null }
    $windowsPartial = if ($assetRoot) { "$windowsIso.partial" } else { $null }
    $ubuntuImage = if ($assetRoot) { Join-Path $assetRoot 'downloads\ubuntu-server-cloudimg-amd64.img' } else { $null }
    $ubuntuPartial = if ($assetRoot) { "$ubuntuImage.partial" } else { $null }
    $vmStates = @('source-win01','source-linux01' | ForEach-Object {
        $vm = Get-VM -Name $_ -ErrorAction SilentlyContinue
        [ordered]@{ name = $_; state = if ($vm) { [string]$vm.State } else { 'NotCreated' } }
    })
$payload = if (Test-Path -LiteralPath $statusPath) {
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        [ordered]@{
            state = [string]$status.state
            phase = [string]$status.phase
            message = [string]$status.message
            taskState = if ($task) { [string]$task.State } else { 'NotFound' }
            taskResult = if ($taskInfo) { [int]$taskInfo.LastTaskResult } else { $null }
            windowsMediaMb = [math]::Max((Get-SizeMb $windowsIso), (Get-SizeMb $windowsPartial))
            ubuntuMediaMb = [math]::Max((Get-SizeMb $ubuntuImage), (Get-SizeMb $ubuntuPartial))
            virtualMachines = $vmStates
        }
    } else {
        [ordered]@{
            state = 'Provisioning'
            phase = 'Starting'
            message = 'The task is starting.'
            taskState = if ($task) { [string]$task.State } else { 'NotFound' }
            taskResult = if ($taskInfo) { [int]$taskInfo.LastTaskResult } else { $null }
            windowsMediaMb = [math]::Max((Get-SizeMb $windowsIso), (Get-SizeMb $windowsPartial))
            ubuntuMediaMb = [math]::Max((Get-SizeMb $ubuntuArchive), (Get-SizeMb $ubuntuPartial))
            virtualMachines = $vmStates
        }
    }
Write-Output "AZURE_MIGRATE_HYPERV_STATUS=$($payload | ConvertTo-Json -Compress)"
'@
    $maximumPollAttempts = $ProvisioningTimeoutHours * 120
    foreach ($attempt in 1..$maximumPollAttempts) {
        Start-Sleep -Seconds 30
        $pollMessage = Invoke-HyperVRunCommand -SubscriptionId $sourceSubscriptionId `
            -ResourceGroupName $script:sourceResourceGroupName -VirtualMachineName $script:hyperVHostName `
            -ScriptText $pollScript -FailureMessage 'Could not read nested guest provisioning status.'
        $status = Get-RemoteResult -Message $pollMessage -Marker 'AZURE_MIGRATE_HYPERV_STATUS='
        Write-HyperVProgress "Nested guests: $($status.state) / $($status.phase) - $($status.message)"
        $vmSummary = @($status.virtualMachines | ForEach-Object { "$($_.name)=$($_.state)" }) -join ', '
        Write-Host "    Task: $($status.taskState), last result: $($status.taskResult); media: Windows $($status.windowsMediaMb) MB, Ubuntu $($status.ubuntuMediaMb) MB; VMs: $vmSummary"
        if ($status.state -eq 'Ready') { Write-HyperVResult -Status Ready; return }
        if ($status.state -eq 'Failed') { throw "Nested guest provisioning failed during '$($status.phase)': $($status.message)" }
    }
    throw "Nested guest provisioning did not finish within the $ProvisioningTimeoutHours-hour bounded wait. The remote scheduled task can continue until its own execution limit."
}
finally {
    $guestPassword = $null
    if ([string]::IsNullOrWhiteSpace($previousAzureExtensionDirectory)) {
        Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
    }
    else { $env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory }
    Remove-Item -LiteralPath $isolatedAzureExtensionDirectory -Recurse -Force -ErrorAction SilentlyContinue
}