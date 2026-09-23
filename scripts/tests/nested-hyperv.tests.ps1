$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mainPath = Join-Path $repositoryRoot 'infra\main.bicep'
$networkPath = Join-Path $repositoryRoot 'infra\modules\source-network.bicep'
$computePath = Join-Path $repositoryRoot 'infra\modules\source-compute.bicep'
$preparePath = Join-Path $repositoryRoot 'scripts\prepare-hyperv-host.ps1'
$guestAssetPath = Join-Path $repositoryRoot 'scripts\guest-assets\Provision-NestedGuests.ps1'

$mainText = Get-Content -LiteralPath $mainPath -Raw
$networkText = Get-Content -LiteralPath $networkPath -Raw
$computeText = Get-Content -LiteralPath $computePath -Raw

foreach ($requiredText in @(
    'param hyperVHostVmSize string'
    'hyperVHostVmSize: hyperVHostVmSize'
)) {
    if (-not $mainText.Contains($requiredText)) {
        throw "Root template is missing the nested Hyper-V contract: $requiredText"
    }
}

foreach ($requiredText in @(
    "var nestedGuestPrefix = '10.10.3.0/24'"
    "nextHopType: 'VirtualAppliance'"
    "nextHopIpAddress: '10.10.2.10'"
)) {
    if (-not $networkText.Contains($requiredText)) {
        throw "Source network is missing the routed nested-guest contract: $requiredText"
    }
}

$discoveryRule = [regex]::Match(
    $networkText,
    "(?s)name:\s*'AllowDiscoveryToNestedGuests'.*?destinationPortRanges:\s*\[(.*?)\]"
)
if (-not $discoveryRule.Success -or $discoveryRule.Groups[1].Value -notmatch "'3389'") {
    throw 'Source network must allow discovery to reach nested Windows RDP on port 3389.'
}

foreach ($requiredText in @(
    "var hyperVHostVmName = 'vm-`$`{namePrefix`}-hyperv-`$`{suffix`}'"
    'enableIPForwarding: true'
    "securityType: 'Standard'"
    "output windowsSourcePrivateIp string = '10.10.3.10'"
    "output linuxSourcePrivateIp string = '10.10.3.20'"
)) {
    if (-not $computeText.Contains($requiredText)) {
        throw "Source compute is missing the nested Hyper-V contract: $requiredText"
    }
}

foreach ($removedResource in 'resource windowsSourceVm ', 'resource linuxSourceVm ') {
    if ($computeText.Contains($removedResource)) {
        throw "Direct Azure source VM resource remains: $removedResource"
    }
}

if (-not (Test-Path -LiteralPath $preparePath -PathType Leaf)) {
    throw 'The nested Hyper-V host preparation script is missing.'
}

if (-not (Test-Path -LiteralPath $guestAssetPath -PathType Leaf)) {
    throw 'The nested guest provisioning asset is missing.'
}

function Get-ParsedScript {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell parser errors in $Path`n$($errors | Out-String)"
    }
    return $ast
}

$prepareAst = Get-ParsedScript -Path $preparePath
$guestAssetAst = Get-ParsedScript -Path $guestAssetPath
$prepareText = Get-Content -LiteralPath $preparePath -Raw
$guestAssetText = Get-Content -LiteralPath $guestAssetPath -Raw

foreach ($requiredText in @(
    "[string]`$DeploymentName = 'azure-migrate-lab'"
    "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
    'https://cloud-images.ubuntu.com/releases/jammy/release-20251031/ubuntu-22.04-server-cloudimg-amd64.img'
    'f73a2d754110b0fc0ddaa3e7c4c1005d9e3067409f20e0c1ddd61c57d36f257a'
    'https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip'
    '8DC1C69D9880919CDAD8C09126A016262D4A9EDF48B87A1EF587914FE4177909'
    "'properties.outputs.sourceResourceGroupId.value'"
    "'properties.outputs.hyperVHostName.value'"
    "'Hyper-V','RemoteAccess','Routing'"
    'AZURE_MIGRATE_HYPERV_RESULT='
    "[ValidateSet('AlreadyReady', 'Provisioning', 'Ready')]"
    '[switch]$RebuildLinux'
    '-not $Force -and -not $RebuildLinux'
    'Windows password is unchanged'
    'Linux-only rebuild requested; preserving existing Hyper-V and routing roles.'
    "-UserId 'SYSTEM'"
    "Read-Host 'Store it securely, then type READY to continue'"
    'Join-Path $env:TEMP "azure-migrate-lab-az-extensions-'
    'AZURE_MIGRATE_HYPERV_KEY='
    'Add-Type -AssemblyName System.Security'
    'RSACryptoServiceProvider'
    '$rsa.Encrypt($passwordBytes, $true)'
    '`$clearBytes = `$rsa.Decrypt'
    '[Security.Cryptography.ProtectedData]::Protect'
    ' -UbuntuCloudImageSha256 ```"$UbuntuCloudImageSha256```"'
    ' -QemuImgArchiveSha256 ```"$QemuImgArchiveSha256```"'
    'Run command extension execution is in progress'
    'Another Run Command is still finishing'
)) {
    if (-not $prepareText.Contains($requiredText)) {
        throw "Hyper-V host preparation is missing the contract: $requiredText"
    }
}
if ($prepareText.Contains('$passwordBase64')) {
    throw 'Hyper-V host preparation must not send a reversible base64 plaintext credential through Run Command.'
}
foreach ($forbiddenHashArgument in "-UbuntuCloudImageSha256 '`$UbuntuCloudImageSha256'", "-QemuImgArchiveSha256 '`$QemuImgArchiveSha256'") {
    if ($prepareText.Contains($forbiddenHashArgument)) {
        throw "Hyper-V host preparation contains native-unsafe single-quoted hash argument: $forbiddenHashArgument"
    }
}

function Import-PrepareFunction {
    param([Parameter(Mandatory)][string]$Name)

    $definition = $prepareAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Function '$Name' was not found in prepare-hyperv-host.ps1." }
    $bodyText = $definition.Body.Extent.Text
    Set-Item -Path "Function:\script:$Name" -Value ([scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2)))
}

Import-PrepareFunction -Name 'Write-HyperVProgress'
Import-PrepareFunction -Name 'Invoke-HyperVRunCommand'
$script:mockRunCommandCount = 0
function global:az {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

    $script:mockRunCommandCount++
    if ($script:mockRunCommandCount -eq 1) {
        $global:LASTEXITCODE = 1
        return 'ERROR: (Conflict) Run command extension execution is in progress. Please wait for completion before invoking a run command.'
    }
    $global:LASTEXITCODE = 0
    return '{"value":[{"message":"AZURE_MIGRATE_RETRY_TEST={\"Status\":\"Ready\"}"}]}'
}
$retryMessage = Invoke-HyperVRunCommand `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -ResourceGroupName 'rg-test' `
    -VirtualMachineName 'vm-test' `
    -ScriptText 'Write-Output test' `
    -FailureMessage 'Mock Run Command failed.' `
    -MaximumAttempts 2 `
    -RetryDelaySeconds 0
if ($script:mockRunCommandCount -ne 2 -or $retryMessage -notmatch 'AZURE_MIGRATE_RETRY_TEST=') {
    throw 'Run Command conflict retry did not recover on the next successful attempt.'
}
Remove-Item Function:\az -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-HyperVRunCommand -ErrorAction SilentlyContinue
Remove-Item Function:\Write-HyperVProgress -ErrorAction SilentlyContinue
Remove-Variable mockRunCommandCount -Scope Script -ErrorAction SilentlyContinue

foreach ($requiredText in @(
    "`$routedSwitchName = 'NestedRouted'"
    "`$natSwitchName = 'NestedNat'"
    "`$routedGateway = '10.10.3.1'"
    "`$natGateway = '192.168.250.1'"
    "`$windowsImagePreparationVersion = 'iso-dynamic-v2'"
    "'192.168.250.0/24'"
    "-RemoteAddress '169.254.169.254' -Action Block"
    'Set-NetIPInterface -InterfaceAlias "vEthernet ($routedSwitchName)" -Forwarding Enabled'
    'Set-NetIPInterface -InterfaceAlias "vEthernet ($natSwitchName)" -Forwarding Enabled'
    "New-VM -Name 'source-win01' -Generation 2 -MemoryStartupBytes 12GB"
    'function Initialize-DynamicVhd'
    'New-VHD -Path $Path -SizeBytes $SizeBytes -Dynamic'
    'Initialize-DynamicVhd -Path $OsVhdPath -SizeBytes 80GB'
    'Initialize-DynamicVhd -Path $DataVhdPath -SizeBytes 64GB'
    "Set-VMProcessor -VMName 'source-win01' -Count 4"
    "if (`$windowsVm.State -ne 'Off') { return }"
    "New-VM -Name 'source-linux01' -Generation `$linuxGeneration -MemoryStartupBytes 4GB"
    "Set-VMProcessor -VMName 'source-linux01' -Count 2"
    "Set-VMFirmware -VMName 'source-linux01' -EnableSecureBoot Off -FirstBootDevice `$osDisk"
    "-MacAddress '00155D030010'"
    "-MacAddress '00155DFA0010'"
    "-MacAddress '00155D030020'"
    "-MacAddress '00155DFA0020'"
    '& route.exe -p add 10.10.0.0 mask 255.255.0.0 10.10.3.1 metric 1 if $routed.ifIndex'
    'Adding the routed guest return route failed'
    '$account = "$env:COMPUTERNAME\labadmin"'
    "Enable-LocalUser -Name 'labadmin'"
    "Add-LocalGroupMember -Group 'Administrators' -Member `$account -ErrorAction SilentlyContinue"
    "'Remote Management Users'"
    "'Performance Monitor Users'"
    "'Performance Log Users'"
    'Add-LocalGroupMember -Group $_ -Member $account -ErrorAction SilentlyContinue'
    "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' LocalAccountTokenFilterPolicy 1 -Type DWord"
    'Enable-PSRemoting -Force -SkipNetworkProfileCheck'
    'Set-Item WSMan:\localhost\Service\Auth\Basic -Value true'
    'Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value true'
    "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0 -Type DWord"
    'Set-Service TermService -StartupType Automatic'
    "Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -Direction Inbound"
    '$remoteDesktopRules | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress 10.10.1.10'
    "NewFileSystemLabel 'CIDATA'"
    'New-LinuxCloudUserData -GuestSecret $GuestSecret'
    'New-LinuxNetworkConfig'
    'network-config'
    "`$linuxImagePreparationVersion = 'generic-cloudimg-kernel-5.15.0-161-v2'"
    'apt-mark hold linux-image-virtual linux-virtual linux-headers-virtual'
    '[Text.UTF8Encoding]::new($false)'
    "`$settings.BIOSSerialNumber = 'ds=nocloud'"
    'ModifySystemSettings($settings.GetText(1))'
    '$preparedVersion -ne $linuxImagePreparationVersion'
    '$preparedVersion -eq $linuxImagePreparationVersion -and $existingVm.State -ne ''Off'''
    'datasource_list: [NoCloud, None]'
    'systemctl disable --now walinuxagent'
    'apt-get purge -y walinuxagent'
    "Wait-TcpProbe -Address '10.10.3.10' -Port 5985"
    "Wait-TcpProbe -Address '10.10.3.20' -Port 22"
    'Get-Command curl.exe'
    '--continue-at -'
    '--retry-all-errors'
    'The partial file was retained for retry.'
    'BCDBoot failed with exit code'
    'Join-Path $efiMicrosoftBootPath ''bootmgfw.efi'''
    'Join-Path $efiFallbackPath ''bootx64.efi'''
    'The required EFI boot file'
    '-SecureBootTemplate MicrosoftWindows -FirstBootDevice $osDisk'
    "Get-ChildItem -LiteralPath `$DestinationPath -Filter 'qemu-img.exe'"
    '& $QemuImgPath convert -p -f qcow2 -O vhdx -o subformat=dynamic $CloudImagePath $OsVhdPath'
    'Ubuntu cloud image conversion failed with exit code'
    'Resize-VHD -Path $OsVhdPath -SizeBytes 64GB'
    'Get-LinuxVmGeneration -OsVhdPath $osVhd'
    "if (`$partitionStyle -eq 'GPT') { return 2 }"
    "if (`$partitionStyle -eq 'MBR') { return 1 }"
    'Test-Path -LiteralPath "$osVhd.prepared"'
    'Stop-VM -VM $existingVm -TurnOff -Force'
    'Remove-VM -VM $existingVm -Force'
    "Phase DownloadWindows"
    "Phase DownloadUbuntu"
    "Phase BuildWindows"
    'Phase CreateWindowsDisks'
    'Phase ApplyWindowsImage'
    'Phase ConfigureWindowsImage'
    'Phase CreateWindowsVm'
    "Phase BuildLinux"
    "Phase ProbeWindows"
    "Phase ProbeLinux"
)) {
    if (-not $guestAssetText.Contains($requiredText)) {
        throw "Nested guest provisioning is missing the contract: $requiredText"
    }
}
if ($guestAssetText.Contains("Set-VMFirmware -VMName 'source-linux01' -EnableSecureBoot On")) {
    throw 'Nested Linux Secure Boot must remain disabled for physical-server Mobility Service replication.'
}

foreach ($forbiddenText in @(
    'MacAddressSpoofing'
    '-SwitchType External'
    'New-VMSwitch -SwitchType External'
    "Add-VMDvdDrive -VMName 'source-linux01'"
    'New-LinuxCloudUserData -GuestSecret $GuestSecret | Set-Content'
    'New-LinuxNetworkConfig | Set-Content'
    'New-NetRoute -InterfaceIndex $routed.ifIndex -DestinationPrefix 10.10.0.0/16 -NextHop 10.10.3.1 -PolicyStore PersistentStore'
    'New-VHD -Path $Path -SizeBytes $SizeBytes -Fixed'
    'fsutil.exe sparse setflag'
    'Convert-VHD -Path $sourceVhd.FullName'
    'tar.exe -xzf'
)) {
    if ($guestAssetText.Contains($forbiddenText)) {
        throw "Nested guest provisioning contains a forbidden networking contract: $forbiddenText"
    }
}

$statusFunction = $guestAssetAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Write-SanitizedStatus'
}, $true)
$resultFunction = $prepareAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Write-HyperVResult'
}, $true)
if ($null -eq $statusFunction -or $null -eq $resultFunction) {
    throw 'Credential-free status/result functions could not be located.'
}
foreach ($functionAst in @($statusFunction, $resultFunction)) {
    if ($functionAst.Extent.Text -match '(?i)password|credential|secret') {
        throw "Durable status/result function contains credential-related content: $($functionAst.Name)"
    }
}

Write-Host 'nested Hyper-V architecture tests passed.' -ForegroundColor Green