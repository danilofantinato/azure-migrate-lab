targetScope = 'subscription'

@description('Subscription ID that hosts the simulated on-premises environment.')
param sourceSubscriptionId string

@description('Subscription ID that hosts Azure Migrate and the migration target network.')
param targetSubscriptionId string

@description('Azure region for the simulated source network, appliances, and nested Hyper-V host.')
param sourceLocation string = 'eastus2'

@description('Azure region for the migration target network, Azure Migrate project, and migration resources.')
param targetLocation string = 'westus2'

@description('Short lowercase identifier used in resource names.')
@minLength(3)
@maxLength(12)
param namePrefix string = 'amiglab'

@description('Public administrator IPv4 CIDR allowed to reach appliance management ports, for example 203.0.113.10/32.')
param adminSourceCidr string

@description('Administrator username for Windows and Linux virtual machines.')
@minLength(1)
@maxLength(15)
param adminUsername string = 'labadmin'

@description('Administrator password for Windows virtual machines and the Linux root replication credential. Supply securely at deployment time.')
@secure()
param adminPassword string

@description('VM size for the physical discovery appliance. Must provide at least 8 vCPUs and 32 GB RAM.')
param discoveryApplianceVmSize string = 'Standard_D8as_v7'

@description('VM size for the simplified replication appliance. Must provide at least 8 physical cores and 16 GB RAM.')
param replicationApplianceVmSize string = 'Standard_D16as_v7'

@description('VM size for the nested-virtualization Hyper-V host. Must provide at least 16 vCPUs and 64 GB RAM.')
param hyperVHostVmSize string = 'Standard_D16as_v7'

@description('Set explicit Standard security while creating the Hyper-V host; disable for incremental updates to an existing host.')
param configureHyperVHostSecurityType bool = true

@description('Enable daily automatic shutdown schedules for all source-side virtual machines.')
param autoShutdownEnabled bool = true

@description('Daily shutdown time in 24-hour HHmm format.')
param autoShutdownTime string = '1900'

@description('Time zone ID used by VM shutdown schedules.')
param autoShutdownTimeZone string = 'UTC'

@description('Deploy a NAT Gateway for target test and final subnets. Disabled by default to reduce idle cost.')
param deployTargetNatGateway bool = false

@description('Create the Azure Migrate hub project with server assessment, discovery, and migration solutions.')
param deployAzureMigrateProject bool = true

@description('Tags applied to resources that support tags.')
param tags object = {
  workload: 'azure-migrate-lab'
  environment: 'lab'
  purpose: 'physical-server-simulation'
}

var suffix = toLower(uniqueString(tenant().tenantId, sourceSubscriptionId, targetSubscriptionId, namePrefix))

module sourceSubscription './modules/source-subscription.bicep' = {
  name: 'source-${suffix}'
  scope: subscription(sourceSubscriptionId)
  params: {
    location: sourceLocation
    namePrefix: namePrefix
    suffix: suffix
    adminSourceCidr: adminSourceCidr
    adminUsername: adminUsername
    adminPassword: adminPassword
    discoveryApplianceVmSize: discoveryApplianceVmSize
    replicationApplianceVmSize: replicationApplianceVmSize
    hyperVHostVmSize: hyperVHostVmSize
    configureHyperVHostSecurityType: configureHyperVHostSecurityType
    autoShutdownEnabled: autoShutdownEnabled
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    tags: tags
  }
}

module targetSubscription './modules/target-subscription.bicep' = {
  name: 'target-${suffix}'
  scope: subscription(targetSubscriptionId)
  params: {
    location: targetLocation
    namePrefix: namePrefix
    suffix: suffix
    adminSourceCidr: adminSourceCidr
    deployTargetNatGateway: deployTargetNatGateway
    deployAzureMigrateProject: deployAzureMigrateProject
    tags: tags
  }
}

output sourceResourceGroupId string = sourceSubscription.outputs.resourceGroupId
output targetResourceGroupId string = targetSubscription.outputs.resourceGroupId
output discoveryApplianceName string = sourceSubscription.outputs.discoveryApplianceName
output replicationApplianceName string = sourceSubscription.outputs.replicationApplianceName
output hyperVHostName string = sourceSubscription.outputs.hyperVHostName
output windowsSourceName string = sourceSubscription.outputs.windowsSourceName
output linuxSourceName string = sourceSubscription.outputs.linuxSourceName
output windowsSourcePrivateIp string = sourceSubscription.outputs.windowsSourcePrivateIp
output linuxSourcePrivateIp string = sourceSubscription.outputs.linuxSourcePrivateIp
output targetTestSubnetId string = targetSubscription.outputs.testSubnetId
output targetFinalSubnetId string = targetSubscription.outputs.finalSubnetId
output azureMigrateProjectId string = targetSubscription.outputs.azureMigrateProjectId
output azureMigrateProjectName string = targetSubscription.outputs.azureMigrateProjectName
output azureMigrateSolutionIds array = targetSubscription.outputs.azureMigrateSolutionIds

output sourceLocation string = sourceLocation
output targetLocation string = targetLocation
