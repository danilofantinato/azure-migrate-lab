[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\deploy-lab.ps1')).Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "deploy-lab.ps1 has parse errors: $($parseErrors -join '; ')"
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($deploymentStatus in 'Cancelled', 'Previewed', 'Deployed') {
    if (-not $scriptText.Contains("Write-DeploymentResult -Status '$deploymentStatus'")) {
        throw "Deployment script must emit the '$deploymentStatus' result."
    }
}
if (-not $scriptText.Contains('AZURE_MIGRATE_DEPLOYMENT_RESULT=')) {
    throw 'Deployment script must expose a machine-readable result marker.'
}
foreach ($linuxPreparationContract in @(
    "Join-Path `$PSScriptRoot 'prepare-linux-mobility.ps1'"
    "-DeploymentName 'azure-migrate-lab'"
    'Preparing and validating Linux Mobility Service prerequisites...'
    'Infrastructure deployment succeeded, but Linux Mobility Service prerequisite preparation failed.'
)) {
    if (-not $scriptText.Contains($linuxPreparationContract)) {
        throw "Deployment is missing Linux Mobility preparation behavior: $linuxPreparationContract"
    }
}
if (-not $scriptText.Contains('Generated temporary Windows administrator and Linux root password:') -or
    -not $scriptText.Contains('This lab-only shared password is displayed once and is not saved by the script.')) {
    throw 'The one-time deployment password prompt must identify both lab accounts and its non-persistence.'
}
if (-not $scriptText.Contains('$env:AZURE_MIGRATE_LAB_RESULT_FILE') -or
    -not $scriptText.Contains('Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE')) {
    throw 'Deployment results must support the setup result-file channel.'
}
if (-not $scriptText.Contains("`$explicitVmSizeParameters = @(`r`n        @(")) {
    throw 'Explicit VM-size filtering must preserve an empty array under strict mode.'
}
foreach ($regionContract in @(
    '[string]$SourceLocation'
    '[string]$TargetLocation'
    'AZURE_MIGRATE_LAB_SOURCE_LOCATION'
    'AZURE_MIGRATE_LAB_TARGET_LOCATION'
    'function Test-TargetComputeCapacity'
    'function Get-ExistingLabTargetResourceGroups'
    "Test-AzureMigrateProjectLocation -SubscriptionId `$TargetSubscriptionId -Location `$TargetLocation"
)) {
    if (-not $scriptText.Contains($regionContract)) {
        throw "Dual-region deployment behavior is missing: $regionContract"
    }
}
foreach ($progressContract in @(
    'function Write-DeploymentPhase'
    'function Write-DeploymentDetail'
    'Selecting region-compatible default VM sizes'
    'Running source compute precheck'
    'Running target compute precheck'
    'Compiling Bicep'
    'Validating deployment with Azure Resource Manager'
    'Running Azure Resource Manager what-if preview'
    'function Show-AzureDeploymentOperations'
    'ARM operation summary'
)) {
    if (-not $scriptText.Contains($progressContract)) {
        throw "Verbose deployment behavior is missing: $progressContract"
    }
}
foreach ($targetProvider in @(
    'Microsoft.Compute'
    'Microsoft.Network'
    'Microsoft.Storage'
    'Microsoft.RecoveryServices'
    'Microsoft.KeyVault'
    'Microsoft.Migrate'
)) {
    if (-not $scriptText.Contains("'$targetProvider'")) {
        throw "Target provider registration is missing '$targetProvider'."
    }
}
foreach ($removedRegionContract in @(
    '[string]$MigrateProjectLocation'
    'AZURE_MIGRATE_LAB_MIGRATE_PROJECT_LOCATION'
    'AZURE_MIGRATE_LAB_LOCATION'
)) {
    if ($scriptText.Contains($removedRegionContract)) {
        throw "Removed shared-region behavior remains: $removedRegionContract"
    }
}

$sourceComputePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\infra\modules\source-compute.bicep')).Path
$sourceComputeText = Get-Content -LiteralPath $sourceComputePath -Raw
$sourceNetworkPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\infra\modules\source-network.bicep')).Path
$sourceNetworkText = Get-Content -LiteralPath $sourceNetworkPath -Raw
if (-not $sourceNetworkText.Contains("name: 'AllowMobilityPushFromReplication'") -or
    -not $sourceNetworkText.Contains("'49152-65535'")) {
    throw 'Replication appliance networking must allow the Windows WMI/DCOM dynamic RPC range.'
}
if (-not $sourceComputeText.Contains("Set-NetFirewallAddressFilter -RemoteAddress @('10.10.1.10/32', '10.10.1.20/32')")) {
    throw 'Windows source bootstrap must scope the Public WinRM address filter to both appliance IPs.'
}
foreach ($mobilityFirewallGroup in 'File and Printer Sharing', 'Windows Management Instrumentation (WMI)') {
    if (-not $sourceComputeText.Contains("Get-NetFirewallRule -DisplayGroup '$mobilityFirewallGroup' -Direction Inbound")) {
        throw "Windows source bootstrap must enable and scope '$mobilityFirewallGroup' inbound rules."
    }
}
foreach ($linuxReplicationAccessContract in @(
    "name: 'ConfigureLinuxRootPassword'"
    "publisher: 'Microsoft.OSTCExtensions'"
    "type: 'VMAccessForLinux'"
    'protectedSettings:'
    "username: 'root'"
    'password: adminPassword'
    "name: 'ConfigureLinuxRootSsh'"
    'PermitRootLogin yes'
    'PasswordAuthentication yes'
    'ssh_pwauth: true'
    'disable_root: false'
    'disablePasswordAuthentication: false'
    "sshd -T | grep -qx 'permitrootlogin yes'"
    "sshd -T | grep -qx 'passwordauthentication yes'"
    "sshd -T | grep -qx 'pubkeyauthentication yes'"
    '/dev/disk/azure/data/by-lun/0'
    'ROOT_PARENT=$(lsblk -no PKNAME "$ROOT_SOURCE" | head -n 1)'
    'The Linux source data disk was not found.'
    'UUID=$DEVICE_UUID /data ext4 defaults,nofail 0 2'
    'linuxRootPasswordExtension'
    'keyData: sshPublicKey'
)) {
    if (-not $sourceComputeText.Contains($linuxReplicationAccessContract)) {
        throw "Linux replication access behavior is missing: $linuxReplicationAccessContract"
    }
}
$linuxSourceVmStart = $sourceComputeText.IndexOf("resource linuxSourceVm 'Microsoft.Compute/virtualMachines@2024-11-01'")
$linuxSourceVmEnd = $sourceComputeText.IndexOf("resource replicationDiskExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01'")
if ($linuxSourceVmStart -lt 0 -or $linuxSourceVmEnd -le $linuxSourceVmStart) {
    throw 'Linux source VM resource boundaries were not found.'
}
$linuxSourceVmText = $sourceComputeText.Substring($linuxSourceVmStart, $linuxSourceVmEnd - $linuxSourceVmStart)
if (-not $linuxSourceVmText.Contains('adminPassword: adminPassword') -or
    -not $linuxSourceVmText.Contains('disablePasswordAuthentication: false') -or
    -not $linuxSourceVmText.Contains('keyData: sshPublicKey')) {
    throw 'Linux source VM must enable the secure password and retain SSH public-key authentication.'
}
if (-not $scriptText.Contains('[switch]$ApproveDeployment') -or
    -not $scriptText.Contains("if (`$ApproveDeployment)")) {
    throw 'Deployment script must support explicit command-line pre-approval.'
}
if (-not $scriptText.Contains("Deployment pre-approved by -ApproveDeployment.")) {
    throw 'Pre-approved deployment must remain visible in output.'
}
if (-not $scriptText.Contains("`$_.resourceType -ieq 'migrateProjects'")) {
    throw 'Azure Migrate metadata-region preflight must match migrateProjects case-insensitively.'
}
if (-not $scriptText.Contains('resourceTypes[].{resourceType:resourceType,locations:locations}')) {
    throw 'Azure Migrate metadata-region preflight must retrieve resource types before matching in PowerShell.'
}
foreach ($requiredExtensionIsolationText in @(
    '$previousAzureExtensionDirectory = $env:AZURE_EXTENSION_DIR'
    "Join-Path `$env:TEMP 'azure-migrate-lab-az-extensions'"
    '$env:AZURE_EXTENSION_DIR = $isolatedAzureExtensionDirectory'
    'Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue'
    '$env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory'
)) {
    if (-not $scriptText.Contains($requiredExtensionIsolationText)) {
        throw "Azure CLI extension isolation behavior is missing: $requiredExtensionIsolationText"
    }
}

function Import-FunctionFromAst {
    param([Parameter(Mandatory)][string]$Name)

    $definition = $ast.Find(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        },
        $true
    ) | Select-Object -First 1
    if ($null -eq $definition) {
        throw "Function '$Name' was not found in deploy-lab.ps1."
    }
    $bodyText = $definition.Body.Extent.Text
    $functionBody = $bodyText.Substring(1, $bodyText.Length - 2)
    Set-Item -Path "Function:\script:$Name" -Value ([scriptblock]::Create($functionBody))
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "$Label failed. Expected '$Expected'; received '$Actual'."
    }
}

$disallowedAzureWindowsPasswords = @(
    'abc@123', 'P@$$w0rd', 'P@ssw0rd', 'P@ssword123', 'Pa$$word',
    'pass@word1', 'Password!', 'Password1', 'Password22', 'iloveyou!'
)
foreach ($functionName in @(
    'Write-DeploymentPhase',
    'Write-DeploymentDetail',
    'Assert-AzureWindowsAdminPassword',
    'New-AzureWindowsAdminPassword',
    'Read-DeploymentConfirmation',
    'Get-AzureCliJson',
    'Get-VmSkuCapabilityValue',
    'Get-ComputeOptionAssessment',
    'New-RequestedVirtualMachineSet',
    'New-TargetVirtualMachineSet',
    'Test-TargetComputeCapacity',
    'Resolve-RegionalDefaultComputeProfile',
    'Find-RecommendedComputeOptions',
    'Get-DeploymentMetadataLocation',
    'Get-AzureDeploymentFailure',
    'Confirm-ExistingWindowsPasswordRotation'
)) {
    Import-FunctionFromAst -Name $functionName
}

$generatedPasswords = @{}
foreach ($attempt in 1..100) {
    $password = New-AzureWindowsAdminPassword
    Assert-AzureWindowsAdminPassword -Password $password
    Assert-Equal -Actual $password.Length -Expected 24 -Label 'Generated password length'
    foreach ($pattern in '[a-z]', '[A-Z]', '[0-9]', '[^a-zA-Z0-9]') {
        if ($password -cnotmatch $pattern) {
            throw "Generated password is missing required character class '$pattern'."
        }
    }
    $generatedPasswords[$password] = $true
}
Assert-Equal -Actual $generatedPasswords.Count -Expected 100 -Label 'Generated password uniqueness'

$global:MockAzureMode = 'Eligible'
function global:az {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

    $global:LASTEXITCODE = 0
    $commandText = $Arguments -join ' '
    if ($commandText -match 'vm list-skus') {
        $restrictions = if ($global:MockAzureMode -eq 'Restricted') {
            @([pscustomobject]@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' })
        }
        else {
            @()
        }
        $skus = foreach ($size in 'Standard_D8as_v7', 'Standard_D16as_v7', 'Standard_D2as_v7') {
            $cores = switch ($size) {
                'Standard_D16as_v7' { 16 }
                'Standard_D8as_v7' { 8 }
                default { 2 }
            }
            $memory = switch ($size) {
                'Standard_D16as_v7' { 64 }
                'Standard_D8as_v7' { 32 }
                default { 8 }
            }
            [pscustomobject]@{
                name = $size
                family = 'standardDASv7Family'
                restrictions = $restrictions
                capabilities = @(
                    [pscustomobject]@{ name = 'vCPUs'; value = [string]$cores }
                    [pscustomobject]@{ name = 'vCPUsPerCore'; value = '2' }
                    [pscustomobject]@{ name = 'MemoryGB'; value = [string]$memory }
                    [pscustomobject]@{ name = 'CpuArchitectureType'; value = 'x64' }
                    [pscustomobject]@{ name = 'HyperVGenerations'; value = 'V1,V2' }
                )
            }
        }
        return $skus | ConvertTo-Json -Depth 6
    }
    if ($commandText -match 'vm list-usage') {
        $familyLimit = switch ($global:MockAzureMode) {
            'Quota' { 10 }
            'TargetQuota' { 2 }
            default { 100 }
        }
        return @(
            [pscustomobject]@{
                name = [pscustomobject]@{ value = 'cores'; localizedValue = 'Total Regional vCPUs' }
                currentValue = 0
                limit = 100
            }
            [pscustomobject]@{
                name = [pscustomobject]@{ value = 'standardDASv7Family'; localizedValue = 'Standard DASv7 Family vCPUs' }
                currentValue = 0
                limit = $familyLimit
            }
        ) | ConvertTo-Json -Depth 5
    }
    if ($commandText -match 'deployment sub show' -and $commandText -match '--query location') {
        if ($global:MockAzureMode -eq 'NoDeploymentHistory') {
            $global:LASTEXITCODE = 3
            return
        }
        return 'eastus2'
    }
    throw "Unexpected mocked Azure CLI command: $commandText"
}

$requests = New-RequestedVirtualMachineSet `
    -DiscoverySize 'Standard_D8as_v7' `
    -ReplicationSize 'Standard_D16as_v7' `
    -WindowsSourceSize 'Standard_D2as_v7' `
    -LinuxSourceSize 'Standard_D2as_v7'

$targetRequests = New-TargetVirtualMachineSet `
    -WindowsSourceSize 'Standard_D2as_v7' `
    -LinuxSourceSize 'Standard_D2as_v7'
Assert-Equal -Actual $targetRequests.Count -Expected 2 -Label 'Target workload count'
$targetAssessment = Get-ComputeOptionAssessment `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Location 'westus2' `
    -RequestedVirtualMachines $targetRequests
Assert-Equal -Actual $targetAssessment.Eligible -Expected $true -Label 'Eligible target compute profile'
Assert-Equal -Actual $targetAssessment.RequiredRegionalCores -Expected 4 -Label 'Required target regional cores'

$global:MockAzureMode = 'TargetQuota'
$targetQuotaFailed = $false
try {
    Test-TargetComputeCapacity `
        -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -Location 'westus2' `
        -RequestedVirtualMachines $targetRequests
}
catch {
    $targetQuotaFailed = $_.Exception.Message -match '^TARGET_COMPUTE_PREFLIGHT:'
}
Assert-Equal -Actual $targetQuotaFailed -Expected $true -Label 'Target quota preflight failure'
$global:MockAzureMode = 'Eligible'

function script:Get-CurrentConfiguration { return [ordered]@{} }
function script:Save-LocalConfiguration {
    param([string]$Path, [Collections.IDictionary]$Configuration)
}
$regionalProfile = [pscustomobject]@{
    Name = 'Regional test profile'
    DiscoveryApplianceVmSize = 'Standard_D8as_v7'
    ReplicationApplianceVmSize = 'Standard_D16as_v7'
    WindowsSourceVmSize = 'Standard_D2as_v7'
    LinuxSourceVmSize = 'Standard_D2as_v7'
}
Resolve-RegionalDefaultComputeProfile `
    -SourceSubscriptionId '00000000-0000-0000-0000-000000000000' `
    -TargetSubscriptionId '11111111-1111-1111-1111-111111111111' `
    -SourceLocation 'eastus2' `
    -TargetLocation 'westus2' `
    -Profiles @($regionalProfile) `
    -ConfigurationPath 'test.local.json'
Assert-Equal -Actual $script:DiscoveryApplianceVmSize -Expected 'Standard_D8as_v7' -Label 'Regional discovery default'
Assert-Equal -Actual $script:ReplicationApplianceVmSize -Expected 'Standard_D16as_v7' -Label 'Regional replication default'
Assert-Equal -Actual $script:WindowsSourceVmSize -Expected 'Standard_D2as_v7' -Label 'Regional workload default'

$eligibleAssessment = Get-ComputeOptionAssessment `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Location 'eastus2' `
    -RequestedVirtualMachines $requests
Assert-Equal -Actual $eligibleAssessment.Eligible -Expected $true -Label 'Eligible compute profile'
Assert-Equal -Actual $eligibleAssessment.RequiredRegionalCores -Expected 28 -Label 'Required regional cores'

$undersizedReplicationRequests = New-RequestedVirtualMachineSet `
    -DiscoverySize 'Standard_D8as_v7' `
    -ReplicationSize 'Standard_D8as_v7' `
    -WindowsSourceSize 'Standard_D2as_v7' `
    -LinuxSourceSize 'Standard_D2as_v7'
$undersizedReplicationAssessment = Get-ComputeOptionAssessment `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Location 'eastus2' `
    -RequestedVirtualMachines $undersizedReplicationRequests
Assert-Equal -Actual $undersizedReplicationAssessment.Eligible -Expected $false -Label 'Replication physical core minimum'
if (($undersizedReplicationAssessment.Issues -join ' ') -notmatch 'provides 4 physical cores .* requires at least 8 physical cores') {
    throw 'Replication assessment did not report the physical core shortage.'
}

$global:MockAzureMode = 'Restricted'
$restrictedAssessment = Get-ComputeOptionAssessment `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Location 'eastus2' `
    -RequestedVirtualMachines $requests
Assert-Equal -Actual $restrictedAssessment.Eligible -Expected $false -Label 'Restricted compute profile'
if (($restrictedAssessment.Issues -join ' ') -notmatch 'NotAvailableForSubscription') {
    throw 'Restricted compute profile did not report NotAvailableForSubscription.'
}

$global:MockAzureMode = 'Quota'
$quotaAssessment = Get-ComputeOptionAssessment `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Location 'eastus2' `
    -RequestedVirtualMachines $requests
Assert-Equal -Actual $quotaAssessment.Eligible -Expected $false -Label 'Insufficient family quota'
if (($quotaAssessment.Issues -join ' ') -notmatch 'requires 28 vCPUs; 10 is available') {
    throw 'Quota assessment did not report the expected family quota shortage.'
}

$failureCases = @(
    @{ Expected = 'Password'; Json = '{"status":"Failed","error":{"code":"DeploymentFailed","details":[{"code":"InvalidParameter","target":"osProfile.adminPassword","message":"The Admin password specified is not allowed."}]}}' }
    @{ Expected = 'Capacity'; Json = '{"error":{"code":"SkuNotAvailable","message":"Capacity Restrictions"}}' }
    @{ Expected = 'Quota'; Json = '{"error":{"code":"QuotaExceeded","message":"Regional quota exceeded"}}' }
    @{ Expected = 'Policy'; Json = '{"error":{"code":"RequestDisallowedByPolicy","message":"Denied"}}' }
    @{ Expected = 'Provider'; Json = '{"error":{"code":"MissingSubscriptionRegistration","message":"Register provider"}}' }
)
foreach ($failureCase in $failureCases) {
    $failure = Get-AzureDeploymentFailure -Output @($failureCase.Json)
    Assert-Equal -Actual $failure.Category -Expected $failureCase.Expected -Label "$($failureCase.Expected) failure classification"
}

$freshDeploymentRotation = Confirm-ExistingWindowsPasswordRotation -VirtualMachines @()
Assert-Equal -Actual $freshDeploymentRotation -Expected $false -Label 'Fresh deployment password rotation'

$existingWindowsVm = @(
    [pscustomobject]@{ resourceGroup = 'rg-test-source'; name = 'vm-test-windows' }
)
$script:MockReadHostResponse = 'ROTATE'
function global:Read-Host { return $script:MockReadHostResponse }
$approvedRotation = Confirm-ExistingWindowsPasswordRotation -VirtualMachines $existingWindowsVm
Assert-Equal -Actual $approvedRotation -Expected $true -Label 'Approved existing password rotation'

$script:MockReadHostResponse = 'Q'
$declinedRotationFailed = $false
try {
    Confirm-ExistingWindowsPasswordRotation -VirtualMachines $existingWindowsVm | Out-Null
}
catch {
    $declinedRotationFailed = $_.Exception.Message -match 'rotation was not approved'
}
Assert-Equal -Actual $declinedRotationFailed -Expected $true -Label 'Declined existing password rotation'

$script:MockReadHostResponses = [Collections.Generic.Queue[string]]::new()
foreach ($response in '', 'deploy', 'DEPLOY') {
    $script:MockReadHostResponses.Enqueue($response)
}
function global:Read-Host { return $script:MockReadHostResponses.Dequeue() }
$deploymentConfirmation = Read-DeploymentConfirmation
Assert-Equal -Actual $deploymentConfirmation -Expected 'Deploy' -Label 'Explicit deployment confirmation'
Assert-Equal -Actual $script:MockReadHostResponses.Count -Expected 0 -Label 'Blank and invalid deployment confirmation retries'

$script:MockReadHostResponses.Enqueue('CANCEL')
$cancellationConfirmation = Read-DeploymentConfirmation
Assert-Equal -Actual $cancellationConfirmation -Expected 'Cancel' -Label 'Explicit deployment cancellation'

$script:MockRecommendationMode = 'SameGeography'
function script:Get-AzureCliJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $currentGeography = if ($script:MockRecommendationMode -eq 'MissingGeography') { $null } else { 'US' }
    return @(
        [pscustomobject]@{ name = 'eastus2'; geographyGroup = $currentGeography }
        [pscustomobject]@{ name = 'westus2'; geographyGroup = 'US' }
        [pscustomobject]@{ name = 'centralus'; geographyGroup = 'US' }
        [pscustomobject]@{ name = 'westeurope'; geographyGroup = 'Europe' }
    )
}
function script:Get-ComputeOptionAssessment {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][object[]]$RequestedVirtualMachines
    )

    $eligible = if ($script:MockRecommendationMode -eq 'SameGeography') {
        $Location -in @('westus2', 'centralus', 'westeurope')
    }
    else {
        $Location -eq 'westeurope'
    }
    $availableCores = switch ($Location) {
        'westus2' { 60 }
        'centralus' { 90 }
        'westeurope' { 100 }
        default { 0 }
    }
    return [pscustomobject]@{
        Eligible = $eligible
        Location = $Location
        Issues = if ($eligible) { @() } else { @('Unavailable for test') }
        RequiredRegionalCores = 28
        AvailableRegionalCores = $availableCores
        FamilyQuota = @(
            [pscustomobject]@{
                Family = 'standardDASv7Family'
                RequiredCores = 28
                AvailableCores = $availableCores
            }
        )
    }
}
$testFallbackProfiles = @(
    [pscustomobject]@{
        Name = 'Dasv7'
        DiscoveryApplianceVmSize = 'Standard_D8as_v7'
        ReplicationApplianceVmSize = 'Standard_D16as_v7'
        WindowsSourceVmSize = 'Standard_D2as_v7'
        LinuxSourceVmSize = 'Standard_D2as_v7'
    }
)
$sameGeographyRecommendations = @(Find-RecommendedComputeOptions `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -CurrentLocation 'eastus2' `
    -RequestedVirtualMachines $requests `
    -FallbackProfiles $testFallbackProfiles)
Assert-Equal -Actual $sameGeographyRecommendations[0].Region -Expected 'centralus' -Label 'Same-geography quota ranking'
if (@($sameGeographyRecommendations | Where-Object { $_.Scope -ne 'Same geography' }).Count -ne 0) {
    throw 'Global recommendations must not be returned when same-geography options are eligible.'
}

$script:MockRecommendationMode = 'GlobalFallback'
$globalRecommendations = @(Find-RecommendedComputeOptions `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -CurrentLocation 'eastus2' `
    -RequestedVirtualMachines $requests `
    -FallbackProfiles $testFallbackProfiles)
Assert-Equal -Actual $globalRecommendations.Count -Expected 1 -Label 'Global fallback recommendation count'
Assert-Equal -Actual $globalRecommendations[0].Region -Expected 'westeurope' -Label 'Global fallback region'
Assert-Equal -Actual $globalRecommendations[0].Scope -Expected 'Global fallback' -Label 'Global fallback scope'

$script:MockRecommendationMode = 'MissingGeography'
$missingGeographyRecommendations = @(Find-RecommendedComputeOptions `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -CurrentLocation 'eastus2' `
    -RequestedVirtualMachines $requests `
    -FallbackProfiles $testFallbackProfiles)
Assert-Equal -Actual $missingGeographyRecommendations[0].Region -Expected 'westeurope' -Label 'Missing-geography global fallback region'
Assert-Equal -Actual $missingGeographyRecommendations[0].Scope -Expected 'Global fallback' -Label 'Missing-geography global fallback scope'

Remove-Item Function:\az -ErrorAction SilentlyContinue
Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
Remove-Item Function:\Get-AzureCliJson -ErrorAction SilentlyContinue
Remove-Item Function:\Get-ComputeOptionAssessment -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CurrentConfiguration -ErrorAction SilentlyContinue
Remove-Item Function:\Save-LocalConfiguration -ErrorAction SilentlyContinue
foreach ($variableName in @(
    'AZURE_MIGRATE_LAB_DISCOVERY_VM_SIZE'
    'AZURE_MIGRATE_LAB_REPLICATION_VM_SIZE'
    'AZURE_MIGRATE_LAB_WINDOWS_SOURCE_VM_SIZE'
    'AZURE_MIGRATE_LAB_LINUX_SOURCE_VM_SIZE'
)) {
    Remove-Item "Env:$variableName" -ErrorAction SilentlyContinue
}
Remove-Variable MockAzureMode -Scope Global -ErrorAction SilentlyContinue
Remove-Variable MockReadHostResponse -Scope Script -ErrorAction SilentlyContinue
Remove-Variable MockReadHostResponses -Scope Script -ErrorAction SilentlyContinue
Remove-Variable MockRecommendationMode -Scope Script -ErrorAction SilentlyContinue
Write-Host 'deploy-lab local tests: PASS' -ForegroundColor Green