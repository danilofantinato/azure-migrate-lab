targetScope = 'resourceGroup'

@description('Azure region for source network resources.')
param location string

@description('Short resource name prefix.')
param namePrefix string

@description('Deterministic resource name suffix.')
param suffix string

@description('Public administrator IPv4 CIDR allowed to reach appliance management ports.')
param adminSourceCidr string

@description('Tags applied to source network resources.')
param tags object

var applianceSubnetName = 'snet-appliances'
var workloadSubnetName = 'snet-workloads'
var applianceSubnetPrefix = '10.10.1.0/24'
var workloadSubnetPrefix = '10.10.2.0/24'
var discoveryPrivateIp = '10.10.1.10'
var replicationPrivateIp = '10.10.1.20'

resource discoveryNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-discovery-${suffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAdminRdp'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'AllowAdminApplianceUi'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '44368'
        }
      }
      {
        name: 'DenyOtherVnetInbound'
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

resource replicationNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-replication-${suffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAdminRdp'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'AllowMobilityControl'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: workloadSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: replicationPrivateIp
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowMobilityData'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: workloadSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: replicationPrivateIp
          destinationPortRange: '9443'
        }
      }
      {
        name: 'DenyOtherVnetInbound'
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

resource workloadNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-workloads-${suffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowDiscoveryAndAdminFromAppliance'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '${discoveryPrivateIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: workloadSubnetPrefix
          destinationPortRanges: [
            '22'
            '3389'
            '5985'
            '5986'
          ]
        }
      }
      {
        name: 'AllowMobilityPushFromReplication'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '${replicationPrivateIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: workloadSubnetPrefix
          destinationPortRanges: [
            '22'
            '135'
            '445'
            '5985'
            '5986'
            '49152-65535'
          ]
        }
      }
      {
        name: 'DenyOtherVnetInbound'
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

resource discoveryPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: 'pip-${namePrefix}-discovery-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource replicationPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: 'pip-${namePrefix}-replication-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource sourceEgressPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: 'pip-${namePrefix}-source-egress-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource sourceNatGateway 'Microsoft.Network/natGateways@2024-07-01' = {
  name: 'ng-${namePrefix}-source-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: sourceEgressPublicIp.id
      }
    ]
  }
}

resource sourceVnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-${namePrefix}-source-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: applianceSubnetName
        properties: {
          addressPrefix: applianceSubnetPrefix
        }
      }
      {
        name: workloadSubnetName
        properties: {
          addressPrefix: workloadSubnetPrefix
          networkSecurityGroup: {
            id: workloadNsg.id
          }
          natGateway: {
            id: sourceNatGateway.id
          }
        }
      }
    ]
  }
}

output applianceSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', sourceVnet.name, applianceSubnetName)
output workloadSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', sourceVnet.name, workloadSubnetName)
output discoveryNsgId string = discoveryNsg.id
output replicationNsgId string = replicationNsg.id
output discoveryPublicIpId string = discoveryPublicIp.id
output replicationPublicIpId string = replicationPublicIp.id
output discoveryPrivateIp string = discoveryPrivateIp
output replicationPrivateIp string = replicationPrivateIp
