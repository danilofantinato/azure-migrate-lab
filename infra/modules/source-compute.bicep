targetScope = 'resourceGroup'

@description('Azure region for source virtual machines.')
param location string

@description('Short resource name prefix.')
param namePrefix string

@description('Deterministic resource name suffix.')
param suffix string

@description('Virtual machine administrator username.')
param adminUsername string

@description('Windows administrator and Linux root replication password.')
@secure()
param adminPassword string

@description('Linux administrator SSH public key.')
param sshPublicKey string

@description('Discovery appliance VM size with at least 8 vCPUs and 32 GB RAM.')
param discoveryApplianceVmSize string

@description('Replication appliance VM size with at least 8 physical cores and 16 GB RAM.')
param replicationApplianceVmSize string

@description('Windows source VM size.')
param windowsSourceVmSize string

@description('Linux source VM size.')
param linuxSourceVmSize string

@description('Resource ID of the source appliance subnet.')
param applianceSubnetId string

@description('Resource ID of the source workload subnet.')
param workloadSubnetId string

@description('Resource ID of the discovery appliance NSG.')
param discoveryNsgId string

@description('Resource ID of the replication appliance NSG.')
param replicationNsgId string

@description('Resource ID of the discovery appliance public IP.')
param discoveryPublicIpId string

@description('Resource ID of the replication appliance public IP.')
param replicationPublicIpId string

@description('Enable daily automatic shutdown schedules.')
param autoShutdownEnabled bool

@description('Daily shutdown time in HHmm format.')
param autoShutdownTime string

@description('Time zone ID used by VM shutdown schedules.')
param autoShutdownTimeZone string

@description('Tags applied to source compute resources.')
param tags object

var discoveryVmName = 'vm-${namePrefix}-disc-${suffix}'
var replicationVmName = 'vm-${namePrefix}-repl-${suffix}'
var windowsSourceVmName = 'source-win01'
var linuxSourceVmName = 'source-linux01'

var windowsSourceBootstrap = '''
$ErrorActionPreference = 'Stop'

Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Set-Service -Name WinRM -StartupType Automatic
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
$winRmPublicRules = @(Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -Direction Inbound |
  Where-Object { $_.Profile -match 'Public' })
$winRmPublicRules | Set-NetFirewallRule -Enabled True
$winRmPublicRules | Get-NetFirewallAddressFilter |
  Set-NetFirewallAddressFilter -RemoteAddress @('10.10.1.10/32', '10.10.1.20/32')
$mobilityPushRules = @(
  Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -Direction Inbound
  Get-NetFirewallRule -DisplayGroup 'Windows Management Instrumentation (WMI)' -Direction Inbound
)
$mobilityPushRules | Set-NetFirewallRule -Enabled True
$mobilityPushRules | Get-NetFirewallAddressFilter |
  Set-NetFirewallAddressFilter -RemoteAddress @('10.10.1.10/32', '10.10.1.20/32')
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null

$dataVolume = Get-Volume -FileSystemLabel 'LabData' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $dataVolume) {
  $dataDisk = $null
  foreach ($attempt in 1..30) {
    Update-HostStorageCache
    $dataDisk = Get-Disk |
      Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.PartitionStyle -in @('RAW', 'GPT') } |
      Select-Object -First 1
    if ($null -ne $dataDisk) {
      break
    }
    Start-Sleep -Seconds 2
  }
  if ($null -eq $dataDisk) {
    throw 'The Windows source data disk was not found.'
  }
  if ($dataDisk.IsOffline) {
    Set-Disk -Number $dataDisk.Number -IsOffline $false
  }
  if ($dataDisk.IsReadOnly) {
    Set-Disk -Number $dataDisk.Number -IsReadOnly $false
  }
  if ($dataDisk.PartitionStyle -eq 'RAW') {
    $dataDisk = $dataDisk | Initialize-Disk -PartitionStyle GPT -PassThru
  }

  $dataPartition = Get-Partition -DiskNumber $dataDisk.Number -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -notin @('Reserved', 'System', 'Recovery') } |
    Select-Object -First 1
  if ($null -eq $dataPartition) {
    $dataPartition = $dataDisk | New-Partition -UseMaximumSize -AssignDriveLetter
  }
  elseif ($null -eq $dataPartition.DriveLetter) {
    $dataPartition | Add-PartitionAccessPath -AssignDriveLetter
    $dataPartition = Get-Partition -DiskNumber $dataDisk.Number -PartitionNumber $dataPartition.PartitionNumber
  }

  $dataVolume = $dataPartition | Get-Volume -ErrorAction SilentlyContinue
  if ($null -eq $dataVolume -or [string]::IsNullOrWhiteSpace($dataVolume.FileSystem)) {
    $dataVolume = $dataPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'LabData' -Confirm:$false
  }
  elseif ($dataVolume.FileSystemLabel -ne 'LabData') {
    $dataVolume | Set-Volume -NewFileSystemLabel 'LabData'
  }
}

$dataRoot = "$($dataVolume.DriveLetter):\lab-data"
New-Item -Path $dataRoot -ItemType Directory -Force | Out-Null
Set-Content -Path (Join-Path $dataRoot 'migration-marker.txt') -Value "Created on $env:COMPUTERNAME at $(Get-Date -Format o)"
Set-Content -Path 'C:\inetpub\wwwroot\index.html' -Value "<html><body><h1>Azure Migrate Lab - $env:COMPUTERNAME</h1><p>Windows source workload</p></body></html>"
'''

var replicationDiskBootstrap = '''
$ErrorActionPreference = 'Stop'
$cacheVolume = Get-Volume -FileSystemLabel 'ReplicationCache' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $cacheVolume) {
  $dataDisk = $null
  foreach ($attempt in 1..60) {
    Update-HostStorageCache
    $dataDisk = Get-Disk |
      Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -ge 620GB } |
      Select-Object -First 1
    if ($null -ne $dataDisk) {
      break
    }
    Start-Sleep -Seconds 2
  }
  if ($null -eq $dataDisk) {
    throw 'The replication cache disk was not found.'
  }
  if ($dataDisk.IsOffline) {
    Set-Disk -Number $dataDisk.Number -IsOffline $false
  }
  if ($dataDisk.IsReadOnly) {
    Set-Disk -Number $dataDisk.Number -IsReadOnly $false
  }
  if ($dataDisk.PartitionStyle -eq 'RAW') {
    $dataDisk = $dataDisk | Initialize-Disk -PartitionStyle GPT -PassThru
  }

  $dataPartition = Get-Partition -DiskNumber $dataDisk.Number -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -notin @('Reserved', 'System', 'Recovery') } |
    Select-Object -First 1
  if ($null -eq $dataPartition) {
    $dataPartition = $dataDisk | New-Partition -UseMaximumSize -DriveLetter E
  }
  elseif ($dataPartition.DriveLetter -ne 'E') {
    $dataPartition | Set-Partition -NewDriveLetter E
    $dataPartition = Get-Partition -DiskNumber $dataDisk.Number -PartitionNumber $dataPartition.PartitionNumber
  }

  $cacheVolume = $dataPartition | Get-Volume -ErrorAction SilentlyContinue
  if ($null -eq $cacheVolume -or [string]::IsNullOrWhiteSpace($cacheVolume.FileSystem)) {
    $cacheVolume = $dataPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'ReplicationCache' -Confirm:$false
  }
  elseif ($cacheVolume.FileSystemLabel -ne 'ReplicationCache') {
    $cacheVolume | Set-Volume -NewFileSystemLabel 'ReplicationCache'
  }
}
'''

var windowsSourceBootstrapCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$script=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(windowsSourceBootstrap)}\')); Invoke-Expression $script"'
var replicationDiskBootstrapCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$script=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(replicationDiskBootstrap)}\')); Invoke-Expression $script"'

var linuxCloudInit = '''
#cloud-config
ssh_pwauth: true
disable_root: false
package_update: true
packages:
  - nginx
runcmd:
  - |
    set -eux
    DEVICE=''
    for attempt in $(seq 1 60); do
      for candidate in /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0; do
        if [ -b "$candidate" ]; then
          DEVICE=$(readlink -f "$candidate")
          break
        fi
      done
      if [ -z "$DEVICE" ]; then
        ROOT_SOURCE=$(findmnt -n -o SOURCE /)
        ROOT_PARENT=$(lsblk -no PKNAME "$ROOT_SOURCE" | head -n 1)
        DEVICE=$(lsblk -dpno NAME,TYPE | awk '$2 == "disk" { print $1 }' | grep -vx "/dev/$ROOT_PARENT" | head -n 1 || true)
      fi
      if [ -n "$DEVICE" ] && [ -b "$DEVICE" ]; then break; fi
      DEVICE=''
      sleep 2
    done
    if [ -z "$DEVICE" ]; then
      echo 'The Linux source data disk was not found.' >&2
      exit 1
    fi
    if ! blkid "$DEVICE"; then mkfs.ext4 "$DEVICE"; fi
    DEVICE_UUID=$(blkid -s UUID -o value "$DEVICE")
    mkdir -p /data
    grep -qF "UUID=$DEVICE_UUID /data ext4 defaults,nofail 0 2" /etc/fstab || echo "UUID=$DEVICE_UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
    mount -a
    mkdir -p /data/lab-data
    printf 'Created on %s at %s\n' "$(hostname)" "$(date --iso-8601=seconds)" > /data/lab-data/migration-marker.txt
    printf '<html><body><h1>Azure Migrate Lab - %s</h1><p>Linux source workload</p></body></html>\n' "$(hostname)" > /var/www/html/index.nginx-debian.html
    systemctl enable --now nginx
'''

var linuxRootSshBootstrap = '''
set -eu
cat > /etc/ssh/sshd_config.d/00-azure-migrate-lab-root.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
chmod 600 /etc/ssh/sshd_config.d/00-azure-migrate-lab-root.conf
sshd -t
systemctl restart ssh
sshd -T | grep -qx 'permitrootlogin yes'
sshd -T | grep -qx 'passwordauthentication yes'
sshd -T | grep -qx 'pubkeyauthentication yes'
'''
var linuxRootSshBootstrapCommand = 'bash -c "echo ${base64(linuxRootSshBootstrap)} | base64 -d | bash"'

resource discoveryNic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: 'nic-${namePrefix}-disc-${suffix}'
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: discoveryNsgId
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.10.1.10'
          subnet: {
            id: applianceSubnetId
          }
          publicIPAddress: {
            id: discoveryPublicIpId
          }
        }
      }
    ]
  }
}

resource replicationNic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: 'nic-${namePrefix}-repl-${suffix}'
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: replicationNsgId
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.10.1.20'
          subnet: {
            id: applianceSubnetId
          }
          publicIPAddress: {
            id: replicationPublicIpId
          }
        }
      }
    ]
  }
}

resource windowsSourceNic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: 'nic-${windowsSourceVmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.10.2.10'
          subnet: {
            id: workloadSubnetId
          }
        }
      }
    ]
  }
}

resource linuxSourceNic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: 'nic-${linuxSourceVmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.10.2.20'
          subnet: {
            id: workloadSubnetId
          }
        }
      }
    ]
  }
}

resource discoveryVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: discoveryVmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: discoveryApplianceVmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${namePrefix}-disc-${suffix}'
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'amig-disc'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: discoveryNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource replicationVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: replicationVmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: replicationApplianceVmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${namePrefix}-repl-${suffix}'
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: 'disk-${namePrefix}-repl-cache-${suffix}'
          createOption: 'Empty'
          diskSizeGB: 640
          caching: 'None'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: 'amig-repl'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: replicationNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource windowsSourceVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: windowsSourceVmName
  location: location
  tags: union(tags, {
    sourceType: 'simulated-physical'
  })
  properties: {
    hardwareProfile: {
      vmSize: windowsSourceVmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${windowsSourceVmName}'
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: 'disk-${windowsSourceVmName}-data01'
          createOption: 'Empty'
          diskSizeGB: 64
          caching: 'None'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: windowsSourceVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: windowsSourceNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource linuxSourceVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: linuxSourceVmName
  location: location
  tags: union(tags, {
    sourceType: 'simulated-physical'
  })
  properties: {
    hardwareProfile: {
      vmSize: linuxSourceVmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${linuxSourceVmName}'
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: 'disk-${linuxSourceVmName}-data01'
          createOption: 'Empty'
          diskSizeGB: 32
          caching: 'None'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: linuxSourceVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(linuxCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: linuxSourceNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource replicationDiskExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: replicationVm
  name: 'InitializeReplicationCache'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: replicationDiskBootstrapCommand
    }
  }
}

resource windowsSourceExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: windowsSourceVm
  name: 'ConfigureSourceWorkload'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: windowsSourceBootstrapCommand
    }
  }
}

resource linuxRootPasswordExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: linuxSourceVm
  name: 'ConfigureLinuxRootPassword'
  location: location
  properties: {
    publisher: 'Microsoft.OSTCExtensions'
    type: 'VMAccessForLinux'
    typeHandlerVersion: '1.5'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      username: 'root'
      password: adminPassword
    }
  }
}

resource linuxRootSshExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: linuxSourceVm
  name: 'ConfigureLinuxRootSsh'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: linuxRootSshBootstrapCommand
    }
  }
  dependsOn: [
    linuxRootPasswordExtension
  ]
}

var shutdownVmNames = [
  discoveryVmName
  replicationVmName
  windowsSourceVmName
  linuxSourceVmName
]

resource shutdownSchedules 'Microsoft.DevTestLab/schedules@2018-09-15' = [for vmName in shutdownVmNames: {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: autoShutdownEnabled ? 'Enabled' : 'Disabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
    targetResourceId: resourceId('Microsoft.Compute/virtualMachines', vmName)
  }
  dependsOn: [
    discoveryVm
    replicationVm
    windowsSourceVm
    linuxSourceVm
  ]
}]

output discoveryApplianceName string = discoveryVm.name
output replicationApplianceName string = replicationVm.name
output windowsSourceName string = windowsSourceVm.name
output linuxSourceName string = linuxSourceVm.name
output windowsSourcePrivateIp string = '10.10.2.10'
output linuxSourcePrivateIp string = '10.10.2.20'
