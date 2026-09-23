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
var hyperVHostSubnetName = 'snet-hyperv-host'
var applianceSubnetPrefix = '10.10.1.0/24'
var hyperVHostSubnetPrefix = '10.10.2.0/24'
var nestedGuestPrefix = '10.10.3.0/24'
var discoveryPrivateIp = '10.10.1.10'
var replicationPrivateIp = '10.10.1.20'
var hyperVHostPrivateIp = '10.10.2.10'

resource applianceSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-appliances-subnet-${suffix}'
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
            '44368'
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
    ]
  }
}

resource discoveryNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-discovery-${suffix}'
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
          priority: 105
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
        name: 'AllowMobilityControl'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: nestedGuestPrefix
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
          sourceAddressPrefix: nestedGuestPrefix
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

resource hyperVHostNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${namePrefix}-hyperv-${suffix}'
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
        name: 'AllowHostManagementFromAppliances'
        properties: {
          priority: 200
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: applianceSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '${hyperVHostPrivateIp}/32'
          destinationPortRanges: [
            '3389'
            '5985'
            '5986'
          ]
        }
      }
      {
        name: 'AllowDiscoveryToNestedGuests'
        properties: {
          priority: 210
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '${discoveryPrivateIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: nestedGuestPrefix
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
          priority: 220
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '${replicationPrivateIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: nestedGuestPrefix
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

resource applianceRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
  name: 'rt-${namePrefix}-nested-guests-${suffix}'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'ToNestedGuests'
        properties: {
          addressPrefix: nestedGuestPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.10.2.10'
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

resource hyperVHostPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: 'pip-${namePrefix}-hyperv-${suffix}'
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
          networkSecurityGroup: {
            id: applianceSubnetNsg.id
          }
          routeTable: {
            id: applianceRouteTable.id
          }
        }
      }
      {
        name: hyperVHostSubnetName
        properties: {
          addressPrefix: hyperVHostSubnetPrefix
          networkSecurityGroup: {
            id: hyperVHostNsg.id
          }
          natGateway: {
            id: sourceNatGateway.id
          }
        }
      }
    ]
  }
}

output applianceSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  sourceVnet.name,
  applianceSubnetName
)
output hyperVHostSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  sourceVnet.name,
  hyperVHostSubnetName
)
output discoveryNsgId string = discoveryNsg.id
output replicationNsgId string = replicationNsg.id
output hyperVHostNsgId string = hyperVHostNsg.id
output discoveryPublicIpId string = discoveryPublicIp.id
output replicationPublicIpId string = replicationPublicIp.id
output hyperVHostPublicIpId string = hyperVHostPublicIp.id
output discoveryPrivateIp string = discoveryPrivateIp
output replicationPrivateIp string = replicationPrivateIp
output hyperVHostPrivateIp string = hyperVHostPrivateIp
output nestedGuestPrefix string = nestedGuestPrefix
