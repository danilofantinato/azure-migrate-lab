targetScope = 'resourceGroup'

@description('Azure region for target network resources.')
param location string

@description('Short resource name prefix.')
param namePrefix string

@description('Deterministic resource name suffix.')
param suffix string

@description('Public administrator IPv4 CIDR allowed to reach VM management ports.')
param adminSourceCidr string

@description('Deploy a NAT Gateway for target test and final subnets.')
param deployTargetNatGateway bool

@description('Deploy the Azure Migrate project and server solutions.')
param deployAzureMigrateProject bool

@description('Tags applied to target network resources.')
param tags object

var testSubnetName = 'snet-test'
var finalSubnetName = 'snet-final'
var azureMigrateProjectName = 'amig-${take(namePrefix, 5)}-${suffix}'
var serverAssessmentSolutionName = 'Servers-Assessment-ServerAssessment'
var serverDiscoverySolutionName = 'Servers-Discovery-ServerDiscovery'
var serverMigrationSolutionName = 'Servers-Migration-ServerMigration'

resource testNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-target-test-${suffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAdminManagementTcp'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAdminIcmp'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Icmp'
          sourceAddressPrefix: adminSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyVnetInbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource finalNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-target-final-${suffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAdminManagementTcp'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAdminIcmp'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Icmp'
          sourceAddressPrefix: adminSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyVnetInbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource targetEgressPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (deployTargetNatGateway) {
  name: 'pip-${namePrefix}-target-egress-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource targetNatGateway 'Microsoft.Network/natGateways@2024-07-01' = if (deployTargetNatGateway) {
  name: 'ng-${namePrefix}-target-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: targetEgressPublicIp.id
      }
    ]
  }
}

resource targetVnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-${namePrefix}-target-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: testSubnetName
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: {
            id: testNsg.id
          }
          natGateway: deployTargetNatGateway ? {
            id: targetNatGateway!.id
          } : null
        }
      }
      {
        name: finalSubnetName
        properties: {
          addressPrefix: '10.20.2.0/24'
          networkSecurityGroup: {
            id: finalNsg.id
          }
          natGateway: deployTargetNatGateway ? {
            id: targetNatGateway!.id
          } : null
        }
      }
    ]
  }
}

resource azureMigrateProject 'Microsoft.Migrate/migrateProjects@2020-05-01' = if (deployAzureMigrateProject) {
  name: azureMigrateProjectName
  location: location
  #disable-next-line BCP187
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

#disable-next-line BCP081
resource serverAssessmentSolution 'Microsoft.Migrate/migrateProjects/solutions@2020-05-01' = if (deployAzureMigrateProject) {
  parent: azureMigrateProject
  name: serverAssessmentSolutionName
  properties: {
    tool: 'ServerAssessment'
    purpose: 'Assessment'
    goal: 'Servers'
    status: 'Active'
  }
}

#disable-next-line BCP081
resource serverDiscoverySolution 'Microsoft.Migrate/migrateProjects/solutions@2020-05-01' = if (deployAzureMigrateProject) {
  parent: azureMigrateProject
  name: serverDiscoverySolutionName
  properties: {
    tool: 'ServerDiscovery'
    purpose: 'Discovery'
    goal: 'Servers'
    status: 'Inactive'
  }
}

#disable-next-line BCP081
resource serverMigrationSolution 'Microsoft.Migrate/migrateProjects/solutions@2020-05-01' = if (deployAzureMigrateProject) {
  parent: azureMigrateProject
  name: serverMigrationSolutionName
  properties: {
    tool: 'ServerMigration'
    purpose: 'Migration'
    goal: 'Servers'
    status: 'Active'
  }
}

output targetVnetId string = targetVnet.id
output testSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', targetVnet.name, testSubnetName)
output finalSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', targetVnet.name, finalSubnetName)
output azureMigrateProjectId string = deployAzureMigrateProject ? azureMigrateProject!.id : ''
output azureMigrateProjectName string = deployAzureMigrateProject ? azureMigrateProject!.name : ''
output azureMigrateSolutionIds array = deployAzureMigrateProject ? [
  serverAssessmentSolution!.id
  serverDiscoverySolution!.id
  serverMigrationSolution!.id
] : []
