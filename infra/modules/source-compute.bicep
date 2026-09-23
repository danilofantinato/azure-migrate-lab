targetScope = 'resourceGroup'

@description('Azure region for source appliances and the nested Hyper-V host.')
param location string

@description('Short resource name prefix.')
param namePrefix string

@description('Deterministic resource name suffix.')
param suffix string

@description('Public administrator IPv4 CIDR allowed through the Windows guest firewall.')
param adminSourceCidr string

@description('Virtual machine administrator username.')
param adminUsername string

@description('Windows administrator password for the Azure appliances and Hyper-V host.')
@secure()
param adminPassword string

@description('Discovery appliance VM size with at least 8 vCPUs and 32 GB RAM.')
param discoveryApplianceVmSize string

@description('Replication appliance VM size with at least 8 physical cores and 16 GB RAM.')
param replicationApplianceVmSize string

@description('Hyper-V host VM size with nested virtualization, at least 16 vCPUs, and 64 GB RAM.')
param hyperVHostVmSize string

@description('Set explicit Standard security while creating the Hyper-V host.')
param configureHyperVHostSecurityType bool

@description('Resource ID of the source appliance subnet.')
param applianceSubnetId string

@description('Resource ID of the Hyper-V host subnet.')
param hyperVHostSubnetId string

@description('Resource ID of the discovery appliance NSG.')
param discoveryNsgId string

@description('Resource ID of the replication appliance NSG.')
param replicationNsgId string

@description('Resource ID of the discovery appliance public IP.')
param discoveryPublicIpId string

@description('Resource ID of the replication appliance public IP.')
param replicationPublicIpId string

@description('Resource ID of the Hyper-V host public IP.')
param hyperVHostPublicIpId string

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
var hyperVHostVmName = 'vm-${namePrefix}-hyperv-${suffix}'
var windowsSourceVmName = 'source-win01'
var linuxSourceVmName = 'source-linux01'

var adminFirewallBootstrap = '''
$ErrorActionPreference = 'Stop'
$remoteDesktopRules = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -Direction Inbound -ErrorAction SilentlyContinue)
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0 -Type DWord
Set-Service TermService -StartupType Automatic
Start-Service TermService
$remoteDesktopRules | Set-NetFirewallRule -Enabled True -Action Allow -Profile Any
$remoteDesktopRules | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress '__ADMIN_SOURCE_CIDR__'
$ruleName = 'AzureMigrateLab-AllowAdminIcmpV4'
$rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if ($null -eq $rule) {
  New-NetFirewallRule -Name $ruleName -DisplayName 'Azure Migrate lab admin ICMPv4' -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -RemoteAddress '__ADMIN_SOURCE_CIDR__' -Profile Any | Out-Null
}
else {
  $rule | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile Any
  $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress '__ADMIN_SOURCE_CIDR__'
}
'''

var adminFirewallBootstrapCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$script=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(replace(adminFirewallBootstrap, '__ADMIN_SOURCE_CIDR__', adminSourceCidr))}\')); Invoke-Expression $script"'

var replicationDiskBootstrap = '''
$ErrorActionPreference = 'Stop'
$ruleName = 'AzureMigrateLab-AllowAdminIcmpV4'
$rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if ($null -eq $rule) {
  New-NetFirewallRule -Name $ruleName -DisplayName 'Azure Migrate lab admin ICMPv4' -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -RemoteAddress '__ADMIN_SOURCE_CIDR__' -Profile Any | Out-Null
}
else {
  $rule | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile Any
  $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress '__ADMIN_SOURCE_CIDR__'
}
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

var replicationDiskBootstrapCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$script=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(replace(replicationDiskBootstrap, '__ADMIN_SOURCE_CIDR__', adminSourceCidr))}\')); Invoke-Expression $script"'

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

resource hyperVHostNic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: 'nic-${namePrefix}-hyperv-${suffix}'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.10.2.10'
          subnet: {
            id: hyperVHostSubnetId
          }
          publicIPAddress: {
            id: hyperVHostPublicIpId
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

resource hyperVHostVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: hyperVHostVmName
  location: location
  tags: union(tags, {
    sourceType: 'nested-hyperv-host'
  })
  properties: union({
    hardwareProfile: {
      vmSize: hyperVHostVmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${namePrefix}-hyperv-${suffix}'
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: 'disk-${namePrefix}-hyperv-guests-${suffix}'
          createOption: 'Empty'
          diskSizeGB: 512
          caching: 'None'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: 'amig-hyperv'
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
          id: hyperVHostNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }, configureHyperVHostSecurityType ? {
    securityProfile: {
      securityType: 'Standard'
    }
  } : {})
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

resource discoveryAdminFirewallExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: discoveryVm
  name: 'EnableAdminFirewall'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: adminFirewallBootstrapCommand
    }
  }
}

resource hyperVHostAdminFirewallExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: hyperVHostVm
  name: 'EnableAdminFirewall'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: adminFirewallBootstrapCommand
    }
  }
}

var shutdownVmNames = [
  discoveryVmName
  replicationVmName
  hyperVHostVmName
]

resource shutdownSchedules 'Microsoft.DevTestLab/schedules@2018-09-15' = [
  for vmName in shutdownVmNames: {
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
      hyperVHostVm
    ]
  }
]

output discoveryApplianceName string = discoveryVm.name
output replicationApplianceName string = replicationVm.name
output hyperVHostName string = hyperVHostVm.name
output windowsSourceName string = windowsSourceVmName
output linuxSourceName string = linuxSourceVmName
output windowsSourcePrivateIp string = '10.10.3.10'
output linuxSourcePrivateIp string = '10.10.3.20'
