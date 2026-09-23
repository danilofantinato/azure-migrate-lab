targetScope = 'subscription'

@description('Azure region for migration target resources.')
param location string

@description('Short resource name prefix.')
param namePrefix string

@description('Deterministic resource name suffix.')
param suffix string

@description('Public administrator IPv4 CIDR allowed to reach VM management ports.')
param adminSourceCidr string

@description('Deploy target NAT Gateway resources.')
param deployTargetNatGateway bool

@description('Deploy the Azure Migrate project and server solutions.')
param deployAzureMigrateProject bool

@description('Tags applied to target resources.')
param tags object

resource targetResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: 'rg-${namePrefix}-target-${suffix}'
  location: location
  tags: tags
}

module targetNetwork './target-network.bicep' = {
  name: 'network-${suffix}'
  scope: targetResourceGroup
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    adminSourceCidr: adminSourceCidr
    deployTargetNatGateway: deployTargetNatGateway
    deployAzureMigrateProject: deployAzureMigrateProject
    tags: tags
  }
}

output resourceGroupId string = targetResourceGroup.id
output testSubnetId string = targetNetwork.outputs.testSubnetId
output finalSubnetId string = targetNetwork.outputs.finalSubnetId
output azureMigrateProjectId string = targetNetwork.outputs.azureMigrateProjectId
output azureMigrateProjectName string = targetNetwork.outputs.azureMigrateProjectName
output azureMigrateSolutionIds array = targetNetwork.outputs.azureMigrateSolutionIds
