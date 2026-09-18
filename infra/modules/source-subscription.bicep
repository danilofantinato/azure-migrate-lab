targetScope = 'subscription'

@description('Azure region for the simulated source environment.')
param location string

@description('Short resource name prefix.')
param namePrefix string

@description('Deterministic resource name suffix.')
param suffix string

@description('Public administrator IPv4 CIDR allowed to reach appliances.')
param adminSourceCidr string

@description('Virtual machine administrator username.')
param adminUsername string

@description('Windows administrator and Linux root replication password.')
@secure()
param adminPassword string

@description('Linux administrator SSH public key.')
param sshPublicKey string

@description('Discovery appliance VM size.')
param discoveryApplianceVmSize string

@description('Replication appliance VM size.')
param replicationApplianceVmSize string

@description('Windows source VM size.')
param windowsSourceVmSize string

@description('Linux source VM size.')
param linuxSourceVmSize string

@description('Enable automatic shutdown schedules.')
param autoShutdownEnabled bool

@description('Automatic shutdown time in HHmm format.')
param autoShutdownTime string

@description('Automatic shutdown time zone ID.')
param autoShutdownTimeZone string

@description('Tags applied to source resources.')
param tags object

resource sourceResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: 'rg-${namePrefix}-source-${suffix}'
  location: location
  tags: tags
}

module sourceNetwork './source-network.bicep' = {
  name: 'network-${suffix}'
  scope: sourceResourceGroup
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    adminSourceCidr: adminSourceCidr
    tags: tags
  }
}

module sourceCompute './source-compute.bicep' = {
  name: 'compute-${suffix}'
  scope: sourceResourceGroup
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    discoveryApplianceVmSize: discoveryApplianceVmSize
    replicationApplianceVmSize: replicationApplianceVmSize
    windowsSourceVmSize: windowsSourceVmSize
    linuxSourceVmSize: linuxSourceVmSize
    applianceSubnetId: sourceNetwork.outputs.applianceSubnetId
    workloadSubnetId: sourceNetwork.outputs.workloadSubnetId
    discoveryNsgId: sourceNetwork.outputs.discoveryNsgId
    replicationNsgId: sourceNetwork.outputs.replicationNsgId
    discoveryPublicIpId: sourceNetwork.outputs.discoveryPublicIpId
    replicationPublicIpId: sourceNetwork.outputs.replicationPublicIpId
    autoShutdownEnabled: autoShutdownEnabled
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    tags: tags
  }
}

output resourceGroupId string = sourceResourceGroup.id
output applianceSubnetId string = sourceNetwork.outputs.applianceSubnetId
output workloadSubnetId string = sourceNetwork.outputs.workloadSubnetId
output discoveryApplianceName string = sourceCompute.outputs.discoveryApplianceName
output replicationApplianceName string = sourceCompute.outputs.replicationApplianceName
output windowsSourceName string = sourceCompute.outputs.windowsSourceName
output linuxSourceName string = sourceCompute.outputs.linuxSourceName
