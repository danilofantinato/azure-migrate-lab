[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$WindowsServerIsoUri,
    [Parameter(Mandatory)][Alias('UbuntuVhdArchiveUri', 'UbuntuIsoUri')][uri]$UbuntuCloudImageUri,
    [Parameter(Mandatory)][uri]$QemuImgArchiveUri,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$WindowsServerIsoSha256,
    [Alias('UbuntuVhdArchiveSha256', 'UbuntuIsoSha256')][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$UbuntuCloudImageSha256,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$QemuImgArchiveSha256,
    [Parameter(Mandatory)][string]$CredentialPayloadPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$root = 'C:\AzureMigrateNested'
$statusPath = Join-Path $root 'status.json'
$script:downloadPath = $null
$script:virtualMachinePath = $null
$script:windowsIsoPath = $null
$script:ubuntuCloudImagePath = $null
$script:qemuImgPath = $null
$routedSwitchName = 'NestedRouted'
$natSwitchName = 'NestedNat'
$routedGateway = '10.10.3.1'
$natGateway = '192.168.250.1'
$natName = 'AzureMigrateNestedNat'
$windowsImagePreparationVersion = 'iso-dynamic-v2'
$linuxImagePreparationVersion = 'generic-cloudimg-v1'
$script:currentPhase = 'Starting'

function Write-SanitizedStatus {
    param(
        [Parameter(Mandatory)][ValidateSet('Provisioning', 'Ready', 'Failed')][string]$State,
        [string]$Phase,
        [string]$Message
    )

    $script:currentPhase = $Phase
    $status = [ordered]@{
        schemaVersion = 1
        state = $State
        phase = $Phase
        message = $Message
        updatedUtc = [DateTime]::UtcNow.ToString('o')
        windows = [ordered]@{ name = 'source-win01'; routedIp = '10.10.3.10'; natIp = '192.168.250.10' }
        linux = [ordered]@{ name = 'source-linux01'; routedIp = '10.10.3.20'; natIp = '192.168.250.20' }
    }
    $temporaryStatusPath = "$statusPath.tmp"
    $status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryStatusPath -Encoding utf8
    Move-Item -LiteralPath $temporaryStatusPath -Destination $statusPath -Force
}

function Get-GuestPassword {
    if (-not (Test-Path -LiteralPath $CredentialPayloadPath -PathType Leaf)) {
        throw 'The protected guest credential payload is missing.'
    }
    $clearBytes = $null
    $characters = $null
    try {
        $protectedBytes = [Convert]::FromBase64String((Get-Content -LiteralPath $CredentialPayloadPath -Raw).Trim())
        $clearBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        $characters = [Text.Encoding]::UTF8.GetChars($clearBytes)
        $secureString = [Security.SecureString]::new()
        foreach ($character in $characters) {
            $secureString.AppendChar($character)
        }
        $secureString.MakeReadOnly()
        return $secureString
    }
    finally {
        if ($null -ne $clearBytes) { [Array]::Clear($clearBytes, 0, $clearBytes.Length) }
        if ($null -ne $characters) { [Array]::Clear($characters, 0, $characters.Length) }
        Remove-Item -LiteralPath $CredentialPayloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-OrDownloadFile {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ExpectedSha256
    )

    if ($Uri.Scheme -ne 'https') {
        throw "Only HTTPS downloads are allowed: $Uri"
    }
    $downloadRequired = -not (Test-Path -LiteralPath $Destination -PathType Leaf)
    if (-not $downloadRequired -and $ExpectedSha256) {
        $downloadRequired = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $ExpectedSha256
    }
    if ($downloadRequired) {
        $partialPath = "$Destination.partial"
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($null -ne $curl) {
            & $curl.Source `
                --location `
                --fail `
                --silent `
                --show-error `
                --retry 8 `
                --retry-delay 5 `
                --retry-all-errors `
                --connect-timeout 30 `
                --speed-limit 1024 `
                --speed-time 120 `
                --continue-at - `
                --output $partialPath `
                $Uri.AbsoluteUri
            if ($LASTEXITCODE -ne 0) {
                throw "Resumable download failed for $Uri with curl exit code $LASTEXITCODE. The partial file was retained for retry."
            }
        }
        else {
            Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
            $previousProgressPreference = $ProgressPreference
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $Uri -OutFile $partialPath -UseBasicParsing
            }
            finally {
                $ProgressPreference = $previousProgressPreference
            }
        }
        if ($ExpectedSha256 -and (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash -ne $ExpectedSha256) {
            Remove-Item -LiteralPath $partialPath -Force
            throw "SHA-256 verification failed for $Uri"
        }
        Move-Item -LiteralPath $partialPath -Destination $Destination -Force
    }
}

function Test-IsoMedia {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Windows', 'Ubuntu')][string]$Kind
    )

    $image = Mount-DiskImage -ImagePath $Path -PassThru
    try {
        $driveLetter = ($image | Get-Volume).DriveLetter
        if ([string]::IsNullOrWhiteSpace($driveLetter)) { throw "$Kind ISO did not expose a volume." }
        $drive = "${driveLetter}:"
        if ($Kind -eq 'Windows' -and -not (Test-Path -LiteralPath "$drive\sources\install.wim" -PathType Leaf)) {
            throw 'Windows ISO does not contain sources\install.wim.'
        }
        if ($Kind -eq 'Ubuntu' -and -not (Test-Path -LiteralPath "$drive\casper\vmlinuz" -PathType Leaf)) {
            throw 'Ubuntu ISO does not contain casper\vmlinuz.'
        }
    }
    finally {
        Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
    }
}

function Initialize-NestedDataDisk {
    $volume = Get-Volume -FileSystemLabel 'NestedGuests' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $volume) { return "$($volume.DriveLetter):" }

    $disk = Get-Disk | Where-Object {
        -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -ge 500GB
    } | Sort-Object Number | Select-Object -First 1
    if ($null -eq $disk) { throw 'The 512 GB nested guest data disk was not found.' }
    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
    if ($disk.PartitionStyle -eq 'RAW') { $disk = $disk | Initialize-Disk -PartitionStyle GPT -PassThru }
    $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
        Where-Object Type -notin @('Reserved', 'System', 'Recovery') | Select-Object -First 1
    if ($null -eq $partition) { $partition = $disk | New-Partition -UseMaximumSize -AssignDriveLetter }
    $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
    if ($null -eq $volume -or [string]::IsNullOrWhiteSpace($volume.FileSystem)) {
        $volume = $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'NestedGuests' -Confirm:$false
    }
    elseif ($volume.FileSystemLabel -ne 'NestedGuests') {
        $volume | Set-Volume -NewFileSystemLabel 'NestedGuests'
        $volume = Get-Volume -DriveLetter $partition.DriveLetter
    }
    return "$($volume.DriveLetter):"
}

function Initialize-InternalSwitch {
    param([string]$Name, [string]$Gateway)

    $switch = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $switch) { $switch = New-VMSwitch -Name $Name -SwitchType Internal }
    if ($switch.SwitchType -ne 'Internal') { throw "The $Name switch must be internal." }
    $adapter = Get-NetAdapter -Name "vEthernet ($Name)" -ErrorAction Stop
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -ne $Gateway | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    if (-not (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -IPAddress $Gateway -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Gateway -PrefixLength 24 | Out-Null
    }
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Forwarding Enabled
}

function Initialize-NestedNetworking {
    Initialize-InternalSwitch -Name $routedSwitchName -Gateway $routedGateway
    Initialize-InternalSwitch -Name $natSwitchName -Gateway $natGateway
    $nat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
    if ($null -eq $nat) { New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix '192.168.250.0/24' | Out-Null }
    elseif ($nat.InternalIPInterfaceAddressPrefix -ne '192.168.250.0/24') {
        throw "WinNAT '$natName' uses an unexpected prefix."
    }
    Set-NetIPInterface -InterfaceAlias "vEthernet ($routedSwitchName)" -Forwarding Enabled
    Set-NetIPInterface -InterfaceAlias "vEthernet ($natSwitchName)" -Forwarding Enabled
    Get-NetIPInterface -AddressFamily IPv4 | Where-Object ConnectionState -eq Connected |
        Set-NetIPInterface -Forwarding Enabled
    Set-Service -Name RemoteAccess -StartupType Automatic
    Start-Service -Name RemoteAccess
    New-NetFirewallRule -DisplayName 'Azure Migrate nested guests block IMDS' -Direction Outbound `
        -RemoteAddress '169.254.169.254' -Action Block -Profile Any -ErrorAction SilentlyContinue | Out-Null
}

function Initialize-DynamicVhd {
    param([string]$Path, [uint64]$SizeBytes)
    if (-not (Test-Path -LiteralPath $Path)) { New-VHD -Path $Path -SizeBytes $SizeBytes -Dynamic | Out-Null }
}

function Set-VmNic {
    param([string]$VmName, [string]$SwitchName, [string]$AdapterName, [string]$MacAddress)
    $adapter = Get-VMNetworkAdapter -VMName $VmName -Name $AdapterName -ErrorAction SilentlyContinue
    if ($null -eq $adapter) { Add-VMNetworkAdapter -VMName $VmName -SwitchName $SwitchName -Name $AdapterName }
    else { Connect-VMNetworkAdapter -VMName $VmName -Name $AdapterName -SwitchName $SwitchName }
    Set-VMNetworkAdapter -VMName $VmName -Name $AdapterName -StaticMacAddress $MacAddress
}

function New-WindowsUnattendContent {
    param([securestring]$GuestSecret)
    $plainText = [Net.NetworkCredential]::new('', $GuestSecret).Password
    $escapedPassword = [Security.SecurityElement]::Escape($plainText)
    $plainText = $null
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><ComputerName>source-win01</ComputerName></component></settings>
  <settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><OOBE><HideEULAPage>true</HideEULAPage><ProtectYourPC>3</ProtectYourPC><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE></OOBE><UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>labadmin</Name><Group>Administrators</Group><Password><Value>$escapedPassword</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts><AutoLogon><Username>labadmin</Username><Enabled>true</Enabled><LogonCount>1</LogonCount><Password><Value>$escapedPassword</Value><PlainText>true</PlainText></Password></AutoLogon><FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\FirstLogon.ps1</CommandLine></SynchronousCommand></FirstLogonCommands></component></settings>
</unattend>
"@
}

function Initialize-WindowsVhd {
    param([string]$OsVhdPath, [string]$DataVhdPath, [securestring]$GuestSecret)
    $completionPath = "$OsVhdPath.prepared"
    $preparedVersion = if (Test-Path -LiteralPath $completionPath) {
        (Get-Content -LiteralPath $completionPath -Raw).Trim()
    }
    if ((Test-Path -LiteralPath $OsVhdPath) -and $preparedVersion -eq $windowsImagePreparationVersion) { return }
    if (Get-VM -Name 'source-win01' -ErrorAction SilentlyContinue) {
        throw 'The Windows guest exists but its offline preparation marker is missing or outdated. Rerun with -Force.'
    }
    Remove-Item -LiteralPath $OsVhdPath, $DataVhdPath, $completionPath -Force -ErrorAction SilentlyContinue
    Write-SanitizedStatus -State Provisioning -Phase CreateWindowsDisks -Message 'Creating dynamic Windows OS and data disks.'
    Initialize-DynamicVhd -Path $OsVhdPath -SizeBytes 80GB
    Initialize-DynamicVhd -Path $DataVhdPath -SizeBytes 64GB
    $iso = Mount-DiskImage -ImagePath $windowsIsoPath -PassThru
    $vhd = Mount-VHD -Path $OsVhdPath -PassThru
    try {
        $isoDrive = (($iso | Get-Volume).DriveLetter) + ':'
        $disk = $vhd | Get-Disk
        $disk | Initialize-Disk -PartitionStyle GPT | Out-Null
        $efi = $disk | New-Partition -Size 260MB -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' -AssignDriveLetter
        $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        $msr = $disk | New-Partition -Size 16MB -GptType '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}'
        $null = $msr
        $windows = $disk | New-Partition -UseMaximumSize -AssignDriveLetter
        $windows | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
        $windowsDrive = "$($windows.DriveLetter):"
        $efiDrive = "$($efi.DriveLetter):"
        $image = Get-WindowsImage -ImagePath "$isoDrive\sources\install.wim" |
            Where-Object ImageName -match 'Desktop Experience' | Select-Object -First 1
        if ($null -eq $image) { throw 'Windows Server Desktop Experience image was not found.' }
        Write-SanitizedStatus -State Provisioning -Phase ApplyWindowsImage -Message 'Applying Windows Server Desktop Experience to the dynamic OS disk.'
        Expand-WindowsImage -ImagePath "$isoDrive\sources\install.wim" -Index $image.ImageIndex -ApplyPath "$windowsDrive\" | Out-Null
        Write-SanitizedStatus -State Provisioning -Phase ConfigureWindowsImage -Message 'Configuring Windows boot files, unattended setup, and first-logon tasks.'
        $bcdbootPath = "$windowsDrive\Windows\System32\bcdboot.exe"
        if (-not (Test-Path -LiteralPath $bcdbootPath -PathType Leaf)) {
            throw "BCDBoot was not found in the applied Windows image at '$bcdbootPath'."
        }
        $bcdbootOutput = @(& $bcdbootPath "$windowsDrive\Windows" /s $efiDrive /f UEFI /v 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "BCDBoot failed with exit code $LASTEXITCODE`: $($bcdbootOutput -join ' ')"
        }
        $windowsEfiPath = "$windowsDrive\Windows\Boot\EFI"
        $efiMicrosoftBootPath = "$efiDrive\EFI\Microsoft\Boot"
        $efiFallbackPath = "$efiDrive\EFI\Boot"
        New-Item -Path $efiMicrosoftBootPath, $efiFallbackPath -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$windowsEfiPath\*" -Destination $efiMicrosoftBootPath -Recurse -Force
        $windowsBootResourcesPath = "$windowsDrive\Windows\Boot\Resources"
        if (Test-Path -LiteralPath $windowsBootResourcesPath -PathType Container) {
            Copy-Item -LiteralPath $windowsBootResourcesPath -Destination $efiMicrosoftBootPath -Recurse -Force
        }
        $efiBootManagerPath = Join-Path $efiMicrosoftBootPath 'bootmgfw.efi'
        $efiFallbackBootManagerPath = Join-Path $efiFallbackPath 'bootx64.efi'
        if (-not (Test-Path -LiteralPath $efiBootManagerPath -PathType Leaf)) {
            throw "The Windows EFI boot manager was not created at '$efiBootManagerPath'."
        }
        Copy-Item -LiteralPath $efiBootManagerPath -Destination $efiFallbackBootManagerPath -Force
        foreach ($requiredBootPath in @(
            (Join-Path $efiMicrosoftBootPath 'BCD'),
            $efiBootManagerPath,
            $efiFallbackBootManagerPath
        )) {
            if (-not (Test-Path -LiteralPath $requiredBootPath -PathType Leaf) -or
                (Get-Item -LiteralPath $requiredBootPath).Length -eq 0) {
                throw "The required EFI boot file '$requiredBootPath' is missing or empty."
            }
        }
        $panther = "$windowsDrive\Windows\Panther"
        $setupScripts = "$windowsDrive\Windows\Setup\Scripts"
        New-Item -Path $panther, $setupScripts -ItemType Directory -Force | Out-Null
        New-WindowsUnattendContent -GuestSecret $GuestSecret | Set-Content -LiteralPath "$panther\unattend.xml" -Encoding utf8
        Use-WindowsUnattend -Path "$windowsDrive\" -UnattendPath "$panther\unattend.xml" | Out-Null
        @'
$ErrorActionPreference = 'Stop'
function Get-AdapterByMac([string]$MacAddress) {
    $normalized = $MacAddress -replace '[:-]', ''
    return Get-NetAdapter | Where-Object { ($_.MacAddress -replace '[:-]', '') -eq $normalized } | Select-Object -First 1
}
$routed = Get-AdapterByMac '00155D030010'
$nat = Get-AdapterByMac '00155DFA0010'
if ($null -eq $routed -or $null -eq $nat) { throw 'Expected nested network adapters were not found.' }
Get-NetIPAddress -InterfaceIndex $routed.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
Get-NetIPAddress -InterfaceIndex $nat.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
New-NetIPAddress -InterfaceIndex $routed.ifIndex -IPAddress 10.10.3.10 -PrefixLength 24
New-NetIPAddress -InterfaceIndex $nat.ifIndex -IPAddress 192.168.250.10 -PrefixLength 24 -DefaultGateway 192.168.250.1
Set-DnsClientServerAddress -InterfaceIndex $nat.ifIndex -ServerAddresses 168.63.129.16
$routeOutput = @(& route.exe -p add 10.10.0.0 mask 255.255.0.0 10.10.3.1 metric 1 if $routed.ifIndex 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Adding the routed guest return route failed: $($routeOutput -join ' ')" }
New-NetFirewallRule -DisplayName 'Block Azure IMDS' -Direction Outbound -RemoteAddress 169.254.169.254 -Action Block -Profile Any | Out-Null
Install-WindowsFeature Web-Server
$account = "$env:COMPUTERNAME\labadmin"
Enable-LocalUser -Name 'labadmin'
Add-LocalGroupMember -Group 'Administrators' -Member $account -ErrorAction SilentlyContinue
@(
    'Remote Management Users'
    'Performance Monitor Users'
    'Performance Log Users'
) | ForEach-Object {
    Add-LocalGroupMember -Group $_ -Member $account -ErrorAction SilentlyContinue
}
Set-Service WinRM -StartupType Automatic; Start-Service WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value true
Set-Item WSMan:\localhost\Service\Auth\Basic -Value true
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' LocalAccountTokenFilterPolicy 1 -Type DWord
$managementRules = @(
    Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -Direction Inbound
    Get-NetFirewallRule -DisplayGroup 'Windows Management Instrumentation (WMI)' -Direction Inbound
    Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -Direction Inbound
)
$managementRules | Set-NetFirewallRule -Enabled True
$managementRules | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress 10.10.1.10,10.10.1.20
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0 -Type DWord
Set-Service TermService -StartupType Automatic
Start-Service TermService
$remoteDesktopRules = Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -Direction Inbound
$remoteDesktopRules | Set-NetFirewallRule -Enabled True
$remoteDesktopRules | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress 10.10.1.10
$disk = Get-Disk | Where-Object {-not $_.IsBoot -and -not $_.IsSystem} | Select-Object -First 1
if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
if ($disk.PartitionStyle -eq 'RAW') { $disk = $disk | Initialize-Disk -PartitionStyle GPT -PassThru }
$partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object Type -notin @('Reserved','System','Recovery') | Select-Object -First 1
if ($null -eq $partition) { $partition = $disk | New-Partition -UseMaximumSize -DriveLetter D }
$volume = $partition | Get-Volume
if ([string]::IsNullOrWhiteSpace($volume.FileSystem)) { $volume = $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel LabData -Confirm:$false }
elseif ($volume.FileSystemLabel -ne 'LabData') { $volume | Set-Volume -NewFileSystemLabel LabData }
New-Item D:\lab-data -ItemType Directory -Force | Out-Null
'nested-windows-source' | Set-Content D:\lab-data\migration-marker.txt
'<html><body><h1>Azure Migrate Lab - source-win01</h1><p>Nested Windows source workload</p></body></html>' | Set-Content C:\inetpub\wwwroot\index.html
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon,DefaultUserName,DefaultPassword,AutoLogonCount -ErrorAction SilentlyContinue
Remove-Item C:\Windows\Panther\unattend.xml,C:\Windows\Setup\Scripts\FirstLogon.ps1 -Force -ErrorAction SilentlyContinue
'ready'|Set-Content C:\AzureMigrateNested.ready
'@ | Set-Content -LiteralPath "$setupScripts\FirstLogon.ps1" -Encoding utf8
    Set-Content -LiteralPath $completionPath -Value $windowsImagePreparationVersion -Encoding ascii
    }
    finally {
        Dismount-VHD -Path $OsVhdPath -ErrorAction SilentlyContinue
        Dismount-DiskImage -ImagePath $windowsIsoPath -ErrorAction SilentlyContinue
    }
}

function New-LinuxUserData {
    param([securestring]$GuestSecret)
    $plainText = [Net.NetworkCredential]::new('', $GuestSecret).Password
    $yamlLines = @(
        '#cloud-config'
        'autoinstall:'
        '  version: 1'
        '  locale: en_US.UTF-8'
        '  keyboard:'
        '    layout: us'
        '  identity:'
        '    hostname: source-linux01'
        '    username: labadmin'
        "    password: '!'"
        '  ssh:'
        '    install-server: true'
        '    allow-pw: true'
        '  packages:'
        '    - nginx'
        '  storage:'
        '    layout:'
        '      name: direct'
        '  network:'
        '    version: 2'
        '    ethernets:'
        '      routed0:'
        '        match:'
        "          macaddress: '00:15:5d:03:00:20'"
        '        set-name: routed0'
        '        addresses:'
        '          - 10.10.3.20/24'
        '        routes:'
        '          - to: 10.10.0.0/16'
        '            via: 10.10.3.1'
        '          - to: 169.254.169.254/32'
        '            type: blackhole'
        '      nat0:'
        '        match:'
        "          macaddress: '00:15:5d:fa:00:20'"
        '        set-name: nat0'
        '        addresses:'
        '          - 192.168.250.20/24'
        '        routes:'
        '          - to: default'
        '            via: 192.168.250.1'
        '        nameservers:'
        '          addresses:'
        '            - 168.63.129.16'
        '  user-data:'
        '    disable_root: false'
        '    write_files:'
        '      - path: /etc/ssh/sshd_config.d/00-azure-migrate-lab.conf'
        "        permissions: '0600'"
        '        content: |'
        '          PermitRootLogin yes'
        '          PasswordAuthentication yes'
        '      - path: /etc/cloud/cloud.cfg.d/99-azure-migrate-datasource.cfg'
        "        permissions: '0644'"
        '        content: |'
        '          datasource_list: [NoCloud, None]'
        '      - path: /usr/local/sbin/prepare-lab-data.sh'
        "        permissions: '0700'"
        '        content: |'
        '          #!/bin/sh'
        '          set -eu'
        '          root_source=$(findmnt -n -o SOURCE /)'
        '          root_parent=$(lsblk -no PKNAME "$root_source" | head -n 1)'
        '          data_device=$(lsblk -bdpno NAME,SIZE,TYPE | awk -v root="/dev/$root_parent" ''$3 == "disk" && $1 != root && $2 >= 30000000000 && $2 <= 40000000000 { print $1; exit }'')'
        '          test -n "$data_device"'
        '          blkid "$data_device" >/dev/null 2>&1 || mkfs.ext4 -L LabData "$data_device"'
        '          data_uuid=$(blkid -s UUID -o value "$data_device")'
        '          mkdir -p /data'
        '          grep -q "UUID=$data_uuid /data " /etc/fstab || echo "UUID=$data_uuid /data ext4 defaults,nofail 0 2" >> /etc/fstab'
        '          mount /data || mount -a'
        '          mkdir -p /data/lab-data'
        '          echo nested-linux-source > /data/lab-data/migration-marker.txt'
        '          rm -f /etc/systemd/system/prepare-lab-data.service /usr/local/sbin/prepare-lab-data.sh'
        '      - path: /etc/systemd/system/prepare-lab-data.service'
        "        permissions: '0644'"
        '        content: |'
        '          [Unit]'
        '          Description=Prepare Azure Migrate nested guest data disk'
        '          After=local-fs.target'
        '          [Service]'
        '          Type=oneshot'
        '          ExecStart=/usr/local/sbin/prepare-lab-data.sh'
        '          RemainAfterExit=yes'
        '          [Install]'
        '          WantedBy=multi-user.target'
        '    runcmd:'
        '      - [sh, -c, "echo ''labadmin:__GUEST_PASSWORD__'' | chpasswd"]'
        '      - [sh, -c, "echo ''root:__GUEST_PASSWORD__'' | chpasswd"]'
        '      - [netplan, apply]'
        '      - [systemctl, daemon-reload]'
        '      - [systemctl, enable, --now, prepare-lab-data.service]'
        '      - [systemctl, enable, --now, ssh]'
        '      - [sh, -c, "echo ''<html><body><h1>Azure Migrate Lab - source-linux01</h1><p>Nested Linux source workload</p></body></html>'' > /var/www/html/index.nginx-debian.html"]'
        '      - [systemctl, enable, --now, nginx]'
        '      - [sh, -c, "systemctl disable --now walinuxagent 2>/dev/null || true; dpkg-query -W walinuxagent >/dev/null 2>&1 && apt-get purge -y walinuxagent || true"]'
        '      - [sh, -c, "ip route replace blackhole 169.254.169.254/32; iptables -C OUTPUT -d 169.254.169.254 -j REJECT 2>/dev/null || iptables -A OUTPUT -d 169.254.169.254 -j REJECT"]'
        '      - [sh, -c, "rm -rf /var/lib/waagent /var/lib/cloud/instances/* /var/lib/cloud/instance; touch /etc/cloud/cloud-init.disabled"]'
    )
    $content = ($yamlLines -join "`n").Replace('__GUEST_PASSWORD__', $plainText)
    $plainText = $null
    return $content
}

function New-LinuxCloudUserData {
        param([securestring]$GuestSecret)
        $plainText = [Net.NetworkCredential]::new('', $GuestSecret).Password
        $yamlLines = @(
                '#cloud-config'
                'hostname: source-linux01'
                'manage_etc_hosts: true'
                'ssh_pwauth: true'
                'disable_root: false'
                'users:'
                '  - default'
                '  - name: labadmin'
                '    groups: [adm, sudo]'
                '    shell: /bin/bash'
                '    lock_passwd: false'
                '    sudo: ALL=(ALL) NOPASSWD:ALL'
                'packages:'
                '  - nginx'
                'write_files:'
                '  - path: /etc/ssh/sshd_config.d/00-azure-migrate-lab.conf'
                "    permissions: '0600'"
                '    content: |'
                '      PermitRootLogin yes'
                '      PasswordAuthentication yes'
                '  - path: /etc/cloud/cloud.cfg.d/99-azure-migrate-datasource.cfg'
                "    permissions: '0644'"
                '    content: |'
                '      datasource_list: [NoCloud, None]'
                '  - path: /usr/local/sbin/prepare-lab-data.sh'
                "    permissions: '0700'"
                '    content: |'
                '      #!/bin/sh'
                '      set -eu'
                '      root_source=$(findmnt -n -o SOURCE /)'
                '      root_parent=$(lsblk -no PKNAME "$root_source" | head -n 1)'
                '      data_device=$(lsblk -bdpno NAME,SIZE,TYPE | awk -v root="/dev/$root_parent" ''$3 == "disk" && $1 != root && $2 >= 30000000000 && $2 <= 40000000000 { print $1; exit }'')'
                '      test -n "$data_device"'
                '      blkid "$data_device" >/dev/null 2>&1 || mkfs.ext4 -L LabData "$data_device"'
                '      data_uuid=$(blkid -s UUID -o value "$data_device")'
                '      mkdir -p /data'
                '      grep -q "UUID=$data_uuid /data " /etc/fstab || echo "UUID=$data_uuid /data ext4 defaults,nofail 0 2" >> /etc/fstab'
                '      mount /data || mount -a'
                '      mkdir -p /data/lab-data'
                '      echo nested-linux-source > /data/lab-data/migration-marker.txt'
                '      rm -f /etc/systemd/system/prepare-lab-data.service /usr/local/sbin/prepare-lab-data.sh'
                '  - path: /etc/systemd/system/prepare-lab-data.service'
                "    permissions: '0644'"
                '    content: |'
                '      [Unit]'
                '      Description=Prepare Azure Migrate nested guest data disk'
                '      After=local-fs.target'
                '      [Service]'
                '      Type=oneshot'
                '      ExecStart=/usr/local/sbin/prepare-lab-data.sh'
                '      RemainAfterExit=yes'
                '      [Install]'
                '      WantedBy=multi-user.target'
                'runcmd:'
                '  - [sh, -c, "echo ''labadmin:__GUEST_PASSWORD__'' | chpasswd"]'
                '  - [sh, -c, "echo ''root:__GUEST_PASSWORD__'' | chpasswd"]'
                '  - [netplan, apply]'
                '  - [systemctl, daemon-reload]'
                '  - [systemctl, enable, --now, prepare-lab-data.service]'
                '  - [systemctl, enable, --now, ssh]'
                '  - [sh, -c, "echo ''<html><body><h1>Azure Migrate Lab - source-linux01</h1><p>Nested Linux source workload</p></body></html>'' > /var/www/html/index.nginx-debian.html"]'
                '  - [systemctl, enable, --now, nginx]'
                '  - [sh, -c, "systemctl disable --now walinuxagent 2>/dev/null || true; dpkg-query -W walinuxagent >/dev/null 2>&1 && apt-get purge -y walinuxagent || true"]'
                '  - [sh, -c, "ip route replace blackhole 169.254.169.254/32; iptables -C OUTPUT -d 169.254.169.254 -j REJECT 2>/dev/null || iptables -A OUTPUT -d 169.254.169.254 -j REJECT"]'
                '  - [sh, -c, "rm -rf /var/lib/waagent /var/lib/cloud/instances/* /var/lib/cloud/instance; touch /etc/cloud/cloud-init.disabled"]'
        )
        $content = ($yamlLines -join "`n").Replace('__GUEST_PASSWORD__', $plainText)
        $plainText = $null
        return $content
}

function New-LinuxNetworkConfig {
    return @(
        'version: 2'
        'ethernets:'
        '  routed0:'
        '    match:'
        "      macaddress: '00:15:5d:03:00:20'"
        '    set-name: routed0'
        '    addresses: [10.10.3.20/24]'
        '    routes:'
        '      - to: 10.10.0.0/16'
        '        via: 10.10.3.1'
        '      - to: 169.254.169.254/32'
        '        type: blackhole'
        '  nat0:'
        '    match:'
        "      macaddress: '00:15:5d:fa:00:20'"
        '    set-name: nat0'
        '    addresses: [192.168.250.20/24]'
        '    routes:'
        '      - to: default'
        '        via: 192.168.250.1'
        '    nameservers:'
        '      addresses: [168.63.129.16]'
    ) -join "`n"
}

function New-CidataVhd {
    param([string]$Path, [securestring]$GuestSecret)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    New-VHD -Path $Path -SizeBytes 128MB -Dynamic | Out-Null
    $mounted = Mount-VHD -Path $Path -PassThru
    try {
        $disk = $mounted | Get-Disk | Initialize-Disk -PartitionStyle MBR -PassThru
        $partition = $disk | New-Partition -UseMaximumSize -AssignDriveLetter
        $partition | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'CIDATA' -Confirm:$false | Out-Null
        $drive = "$($partition.DriveLetter):"
        $utf8NoBom = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText("$drive\user-data", (New-LinuxCloudUserData -GuestSecret $GuestSecret), $utf8NoBom)
        "instance-id: source-linux01`nlocal-hostname: source-linux01" | Set-Content -LiteralPath "$drive\meta-data" -Encoding ascii
        [IO.File]::WriteAllText("$drive\network-config", (New-LinuxNetworkConfig), $utf8NoBom)
    }
    finally { Dismount-VHD -Path $Path -ErrorAction SilentlyContinue }
}

function Initialize-QemuImg {
    param([string]$ArchivePath, [string]$DestinationPath)

    $qemuImgPath = Join-Path $DestinationPath 'qemu-img.exe'
    if (Test-Path -LiteralPath $qemuImgPath -PathType Leaf) { return $qemuImgPath }
    Remove-Item -LiteralPath $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force
    $qemuImg = Get-ChildItem -LiteralPath $DestinationPath -Filter 'qemu-img.exe' -File -Recurse | Select-Object -First 1
    if ($null -eq $qemuImg) { throw 'The qemu-img archive did not contain qemu-img.exe.' }
    if ($qemuImg.FullName -ne $qemuImgPath) { Copy-Item -LiteralPath $qemuImg.FullName -Destination $qemuImgPath }
    return $qemuImgPath
}

function Initialize-LinuxOsVhd {
    param([string]$CloudImagePath, [string]$OsVhdPath, [string]$QemuImgPath)

    $markerPath = "$OsVhdPath.prepared"
    $preparedVersion = if (Test-Path -LiteralPath $markerPath) {
        (Get-Content -LiteralPath $markerPath -Raw).Trim()
    }
    if ((Test-Path -LiteralPath $OsVhdPath) -and $preparedVersion -eq $linuxImagePreparationVersion) { return }
    Remove-Item -LiteralPath $OsVhdPath, $markerPath -Force -ErrorAction SilentlyContinue
    & $QemuImgPath convert -p -f qcow2 -O vhdx -o subformat=dynamic $CloudImagePath $OsVhdPath
    if ($LASTEXITCODE -ne 0) { throw "Ubuntu cloud image conversion failed with exit code $LASTEXITCODE." }
    Resize-VHD -Path $OsVhdPath -SizeBytes 64GB
    Set-Content -LiteralPath $markerPath -Value $linuxImagePreparationVersion -Encoding ascii
}

function Get-LinuxVmGeneration {
    param([string]$OsVhdPath)

    $mounted = Mount-VHD -Path $OsVhdPath -ReadOnly -PassThru
    try {
        $partitionStyle = [string](($mounted | Get-Disk).PartitionStyle)
        if ($partitionStyle -eq 'GPT') { return 2 }
        if ($partitionStyle -eq 'MBR') { return 1 }
        throw "The Ubuntu cloud VHD has unsupported partition style '$partitionStyle'."
    }
    finally { Dismount-VHD -Path $OsVhdPath -ErrorAction SilentlyContinue }
}

function Set-LinuxNoCloudDiscovery {
    param([string]$VmName)

    $vm = Get-WmiObject -Namespace 'root\virtualization\v2' -Class Msvm_ComputerSystem |
        Where-Object ElementName -eq $VmName |
        Select-Object -First 1
    if ($null -eq $vm) { throw "The Hyper-V WMI object for $VmName was not found." }
    $settings = $vm.GetRelated('Msvm_VirtualSystemSettingData') |
        Where-Object VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' |
        Select-Object -First 1
    if ($null -eq $settings) { throw "The active Hyper-V settings for $VmName were not found." }
    $settings.BIOSSerialNumber = 'ds=nocloud'
    $managementService = Get-WmiObject -Namespace 'root\virtualization\v2' -Class Msvm_VirtualSystemManagementService |
        Select-Object -First 1
    $result = $managementService.ModifySystemSettings($settings.GetText(1))
    if ($result.ReturnValue -eq 4096) {
        $job = [wmi]$result.Job
        while ($job.JobState -in 2, 3, 4 -and $job.PercentComplete -lt 100) {
            Start-Sleep -Milliseconds 250
            $job.Get()
        }
        if ($job.JobState -ne 7) { throw "Setting NoCloud discovery on $VmName failed: $($job.ErrorDescription)" }
    }
    elseif ($result.ReturnValue -ne 0) {
        throw "Setting NoCloud discovery on $VmName failed with Hyper-V result $($result.ReturnValue)."
    }
}

function Initialize-WindowsVm {
    param([securestring]$GuestSecret)
    $vmPath = Join-Path $virtualMachinePath 'source-win01'
    $osVhd = Join-Path $vmPath 'source-win01-os.vhdx'
    $dataVhd = Join-Path $vmPath 'source-win01-data.vhdx'
    New-Item -Path $vmPath -ItemType Directory -Force | Out-Null
    Initialize-WindowsVhd -OsVhdPath $osVhd -DataVhdPath $dataVhd -GuestSecret $GuestSecret
    Write-SanitizedStatus -State Provisioning -Phase CreateWindowsVm -Message 'Creating and configuring the source-win01 Hyper-V VM.'
    if (-not (Get-VM -Name 'source-win01' -ErrorAction SilentlyContinue)) {
        New-VM -Name 'source-win01' -Generation 2 -MemoryStartupBytes 12GB -VHDPath $osVhd -Path $vmPath | Out-Null
        Add-VMHardDiskDrive -VMName 'source-win01' -Path $dataVhd
    }
    $windowsVm = Get-VM -Name 'source-win01'
    if ($windowsVm.State -ne 'Off') { return }
    Get-VMNetworkAdapter -VMName 'source-win01' | Where-Object Name -notin @('Routed', 'Nat') | Remove-VMNetworkAdapter
    Set-VMProcessor -VMName 'source-win01' -Count 4
    Set-VMMemory -VMName 'source-win01' -DynamicMemoryEnabled $false -StartupBytes 12GB
    Set-VmNic -VmName 'source-win01' -SwitchName $routedSwitchName -AdapterName 'Routed' -MacAddress '00155D030010'
    Set-VmNic -VmName 'source-win01' -SwitchName $natSwitchName -AdapterName 'Nat' -MacAddress '00155DFA0010'
    $osDisk = Get-VMHardDiskDrive -VMName 'source-win01' | Where-Object Path -eq $osVhd | Select-Object -First 1
    if ($null -eq $osDisk) { throw 'The source-win01 OS disk is not attached.' }
    Set-VMFirmware -VMName 'source-win01' -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $osDisk
}

function Initialize-LinuxVm {
    param([securestring]$GuestSecret)
    $vmPath = Join-Path $virtualMachinePath 'source-linux01'
    $osVhd = Join-Path $vmPath 'source-linux01-os.vhdx'
    $dataVhd = Join-Path $vmPath 'source-linux01-data.vhdx'
    $cidataVhd = Join-Path $vmPath 'source-linux01-cidata.vhdx'
    New-Item -Path $vmPath -ItemType Directory -Force | Out-Null
    $existingVm = Get-VM -Name 'source-linux01' -ErrorAction SilentlyContinue
    $preparedVersion = if (Test-Path -LiteralPath "$osVhd.prepared") {
        (Get-Content -LiteralPath "$osVhd.prepared" -Raw).Trim()
    }
    if ($null -ne $existingVm -and $preparedVersion -eq $linuxImagePreparationVersion -and $existingVm.State -ne 'Off') {
        return
    }
    if ($null -ne $existingVm -and $preparedVersion -ne $linuxImagePreparationVersion) {
        if ($existingVm.State -ne 'Off') { Stop-VM -VM $existingVm -TurnOff -Force }
        Remove-VM -VM $existingVm -Force
    }
    Initialize-LinuxOsVhd -CloudImagePath $ubuntuCloudImagePath -OsVhdPath $osVhd -QemuImgPath $qemuImgPath
    $linuxGeneration = Get-LinuxVmGeneration -OsVhdPath $osVhd
    Initialize-DynamicVhd -Path $dataVhd -SizeBytes 32GB
    if (-not (Get-VM -Name 'source-linux01' -ErrorAction SilentlyContinue)) {
        New-VM -Name 'source-linux01' -Generation $linuxGeneration -MemoryStartupBytes 4GB -VHDPath $osVhd -Path $vmPath | Out-Null
        Add-VMHardDiskDrive -VMName 'source-linux01' -Path $dataVhd
        New-CidataVhd -Path $cidataVhd -GuestSecret $GuestSecret
        Add-VMHardDiskDrive -VMName 'source-linux01' -Path $cidataVhd
    }
    Get-VMNetworkAdapter -VMName 'source-linux01' | Where-Object Name -notin @('Routed', 'Nat') | Remove-VMNetworkAdapter
    Set-VMProcessor -VMName 'source-linux01' -Count 2
    Set-VMMemory -VMName 'source-linux01' -DynamicMemoryEnabled $false -StartupBytes 4GB
    Set-VmNic -VmName 'source-linux01' -SwitchName $routedSwitchName -AdapterName 'Routed' -MacAddress '00155D030020'
    Set-VmNic -VmName 'source-linux01' -SwitchName $natSwitchName -AdapterName 'Nat' -MacAddress '00155DFA0020'
    Set-LinuxNoCloudDiscovery -VmName 'source-linux01'
    $osDisk = Get-VMHardDiskDrive -VMName 'source-linux01' | Where-Object Path -eq $osVhd | Select-Object -First 1
    if ($null -eq $osDisk) { throw 'The source-linux01 OS disk is not attached.' }
    if ($linuxGeneration -eq 2) {
        Set-VMFirmware -VMName 'source-linux01' -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $osDisk
    }
    else { Set-VMBios -VMName 'source-linux01' -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy') }
}

function Wait-TcpProbe {
    param([string]$Address, [int]$Port, [int]$MaximumAttempts = 180)
    foreach ($attempt in 1..$MaximumAttempts) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync($Address, $Port)
            if ($task.Wait(2000) -and $client.Connected) { return $true }
        }
        catch { }
        finally { $client.Dispose() }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds 10 }
    }
    return $false
}

New-Item -Path $root -ItemType Directory -Force | Out-Null
$guestPassword = $null
try {
    Write-SanitizedStatus -State Provisioning -Phase Credential -Message 'Decrypting the temporary nested guest credential.'
    $guestPassword = Get-GuestPassword
    Write-SanitizedStatus -State Provisioning -Phase DataDisk -Message 'Preparing the 512-GB nested guest data disk.'
    $nestedDataRoot = Initialize-NestedDataDisk
    $assetRoot = Join-Path $nestedDataRoot 'AzureMigrateNested'
    $script:downloadPath = Join-Path $assetRoot 'downloads'
    $script:virtualMachinePath = Join-Path $assetRoot 'virtual-machines'
    $script:windowsIsoPath = Join-Path $script:downloadPath 'windows-server.iso'
    $script:ubuntuCloudImagePath = Join-Path $script:downloadPath 'ubuntu-server-cloudimg-amd64.img'
    $qemuImgArchivePath = Join-Path $script:downloadPath 'qemu-img-win-x64-2_3_0.zip'
    New-Item -Path $script:downloadPath, $script:virtualMachinePath -ItemType Directory -Force | Out-Null
    if ($Force) {
        Write-SanitizedStatus -State Provisioning -Phase ForceCleanup -Message 'Removing existing nested guests and VHDX artifacts.'
        foreach ($vmName in 'source-win01', 'source-linux01') {
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($null -ne $vm) {
                if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
                Remove-VM -VM $vm -Force
            }
            Remove-Item -LiteralPath (Join-Path $script:virtualMachinePath $vmName) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-SanitizedStatus -State Provisioning -Phase Network -Message 'Configuring internal switches, routing, WinNAT, and IMDS blocking.'
    Initialize-NestedNetworking
    Write-SanitizedStatus -State Provisioning -Phase DownloadWindows -Message 'Downloading or validating the cached Windows Server evaluation ISO.'
    Get-OrDownloadFile -Uri $WindowsServerIsoUri -Destination $windowsIsoPath -ExpectedSha256 $WindowsServerIsoSha256
    Write-SanitizedStatus -State Provisioning -Phase DownloadUbuntu -Message 'Downloading or validating the generic Ubuntu cloud image.'
    Get-OrDownloadFile -Uri $UbuntuCloudImageUri -Destination $ubuntuCloudImagePath -ExpectedSha256 $UbuntuCloudImageSha256
    Write-SanitizedStatus -State Provisioning -Phase DownloadQemuImg -Message 'Downloading or validating the qemu-img converter.'
    Get-OrDownloadFile -Uri $QemuImgArchiveUri -Destination $qemuImgArchivePath -ExpectedSha256 $QemuImgArchiveSha256
    $script:qemuImgPath = Initialize-QemuImg -ArchivePath $qemuImgArchivePath -DestinationPath (Join-Path $assetRoot 'tools\qemu-img')
    Write-SanitizedStatus -State Provisioning -Phase ValidateWindowsMedia -Message 'Mounting and validating Windows Server installation media.'
    Test-IsoMedia -Path $windowsIsoPath -Kind Windows
    Write-SanitizedStatus -State Provisioning -Phase BuildWindows -Message 'Applying Windows Server and creating source-win01.'
    Initialize-WindowsVm -GuestSecret $guestPassword
    Write-SanitizedStatus -State Provisioning -Phase BuildLinux -Message 'Creating source-linux01 and its unattended installation media.'
    Initialize-LinuxVm -GuestSecret $guestPassword
    Write-SanitizedStatus -State Provisioning -Phase StartGuests -Message 'Starting both nested source guests.'
    Get-VM -Name 'source-win01', 'source-linux01' | Where-Object State -ne Running | Start-VM | Out-Null
    Write-SanitizedStatus -State Provisioning -Phase ProbeWindows -Message 'Waiting for Windows WinRM on 10.10.3.10:5985.'
    $windowsReady = Wait-TcpProbe -Address '10.10.3.10' -Port 5985
    Write-SanitizedStatus -State Provisioning -Phase ProbeLinux -Message 'Waiting for Linux SSH on 10.10.3.20:22.'
    $linuxReady = Wait-TcpProbe -Address '10.10.3.20' -Port 22
    if (-not $windowsReady -or -not $linuxReady) { throw 'Nested guest readiness probes did not complete within the bounded wait.' }
    Write-SanitizedStatus -State Provisioning -Phase CleanupMedia -Message 'Detaching unattended installation media and removing temporary seed artifacts.'
    Get-VMDvdDrive -VMName 'source-linux01' -ErrorAction SilentlyContinue | Set-VMDvdDrive -Path $null
    Get-VMHardDiskDrive -VMName 'source-linux01' | Where-Object Path -like '*-cidata.vhdx' | Remove-VMHardDiskDrive
    Remove-Item -LiteralPath (Join-Path $virtualMachinePath 'source-linux01\source-linux01-cidata.vhdx') -Force -ErrorAction SilentlyContinue
    Write-SanitizedStatus -State Ready -Phase Complete -Message 'Nested guests are ready.'
}
catch {
    Write-SanitizedStatus -State Failed -Phase $script:currentPhase -Message 'Provisioning failed. Review the scheduled task event and PowerShell logs on the Hyper-V host.'
    throw
}
finally {
    $guestPassword = $null
    Remove-Item -LiteralPath $CredentialPayloadPath -Force -ErrorAction SilentlyContinue
}