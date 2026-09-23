using './main.bicep'

param sourceSubscriptionId = readEnvironmentVariable('AZURE_MIGRATE_LAB_SOURCE_SUBSCRIPTION_ID', '')
param targetSubscriptionId = readEnvironmentVariable('AZURE_MIGRATE_LAB_TARGET_SUBSCRIPTION_ID', '')
param adminSourceCidr = readEnvironmentVariable('AZURE_MIGRATE_LAB_ADMIN_SOURCE_CIDR', '')
param adminPassword = readEnvironmentVariable('AZURE_MIGRATE_LAB_ADMIN_PASSWORD', '')

param sourceLocation = readEnvironmentVariable('AZURE_MIGRATE_LAB_SOURCE_LOCATION', 'eastus2')
param targetLocation = readEnvironmentVariable('AZURE_MIGRATE_LAB_TARGET_LOCATION', 'westus2')
param namePrefix = readEnvironmentVariable('AZURE_MIGRATE_LAB_NAME_PREFIX', 'amiglab')
param adminUsername = readEnvironmentVariable('AZURE_MIGRATE_LAB_ADMIN_USERNAME', 'labadmin')

param discoveryApplianceVmSize = readEnvironmentVariable('AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE', 'Standard_D8as_v7')
param replicationApplianceVmSize = readEnvironmentVariable('AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE', 'Standard_D16as_v7')
param hyperVHostVmSize = readEnvironmentVariable('AZURE_MIGRATE_LAB_HYPERV_HOST_VM_SIZE', 'Standard_D16as_v7')
param configureHyperVHostSecurityType = bool(readEnvironmentVariable('AZURE_MIGRATE_LAB_CONFIGURE_HYPERV_SECURITY_TYPE', 'true'))

param autoShutdownEnabled = bool(readEnvironmentVariable('AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_ENABLED', 'true'))
param autoShutdownTime = readEnvironmentVariable('AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_TIME', '1900')
param autoShutdownTimeZone = readEnvironmentVariable('AZURE_MIGRATE_LAB_AUTO_SHUTDOWN_TIME_ZONE', 'UTC')

param deployTargetNatGateway = bool(readEnvironmentVariable('AZURE_MIGRATE_LAB_DEPLOY_TARGET_NAT', 'false'))
param deployAzureMigrateProject = bool(readEnvironmentVariable('AZURE_MIGRATE_LAB_DEPLOY_MIGRATE_PROJECT', 'true'))

param tags = {
  workload: 'azure-migrate-lab'
  environment: 'lab'
  purpose: 'physical-server-simulation'
}
