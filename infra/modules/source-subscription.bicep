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

@description('Windows administrator password for the Azure appliances and Hyper-V host.')
@secure()
param adminPassword string

@description('Discovery appliance VM size.')
param discoveryApplianceVmSize string

@description('Replication appliance VM size.')
param replicationApplianceVmSize string

@description('Nested-virtualization Hyper-V host VM size.')
param hyperVHostVmSize string

@description('Set explicit Standard security while creating the Hyper-V host.')
param configureHyperVHostSecurityType bool

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
    adminSourceCidr: adminSourceCidr
    adminUsername: adminUsername
    adminPassword: adminPassword
    discoveryApplianceVmSize: discoveryApplianceVmSize
    replicationApplianceVmSize: replicationApplianceVmSize
    hyperVHostVmSize: hyperVHostVmSize
    configureHyperVHostSecurityType: configureHyperVHostSecurityType
    applianceSubnetId: sourceNetwork.outputs.applianceSubnetId
    hyperVHostSubnetId: sourceNetwork.outputs.hyperVHostSubnetId
    discoveryNsgId: sourceNetwork.outputs.discoveryNsgId
    replicationNsgId: sourceNetwork.outputs.replicationNsgId
    discoveryPublicIpId: sourceNetwork.outputs.discoveryPublicIpId
    replicationPublicIpId: sourceNetwork.outputs.replicationPublicIpId
    hyperVHostPublicIpId: sourceNetwork.outputs.hyperVHostPublicIpId
    autoShutdownEnabled: autoShutdownEnabled
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    tags: tags
  }
}

output resourceGroupId string = sourceResourceGroup.id
output applianceSubnetId string = sourceNetwork.outputs.applianceSubnetId
output hyperVHostSubnetId string = sourceNetwork.outputs.hyperVHostSubnetId
output discoveryApplianceName string = sourceCompute.outputs.discoveryApplianceName
output replicationApplianceName string = sourceCompute.outputs.replicationApplianceName
output hyperVHostName string = sourceCompute.outputs.hyperVHostName
output windowsSourceName string = sourceCompute.outputs.windowsSourceName
output linuxSourceName string = sourceCompute.outputs.linuxSourceName
output windowsSourcePrivateIp string = sourceCompute.outputs.windowsSourcePrivateIp
output linuxSourcePrivateIp string = sourceCompute.outputs.linuxSourcePrivateIp
