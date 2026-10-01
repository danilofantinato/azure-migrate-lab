[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [switch]$SkipGuestChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$configFilePath = if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    Join-Path $PSScriptRoot 'deploy-lab.local.json'
}
elseif ([IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
}
else {
    Join-Path $repositoryRoot $ConfigFile
}
$powerShellPath = (Get-Command pwsh -ErrorAction Stop).Source

function Invoke-AzureCliText {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $output = @(& az @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "$FailureMessage$([Environment]::NewLine)$details"
    }
    return ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
}

function Get-DeploymentOutputValue {
    param(
        [Parameter(Mandatory)][object]$Deployment,
        [Parameter(Mandatory)][string]$Name
    )

    $outputs = $Deployment.properties.PSObject.Properties['outputs']
    $output = if ($null -eq $outputs) { $null } else { $outputs.Value.PSObject.Properties[$Name] }
    if ($null -eq $output -or $null -eq $output.Value.PSObject.Properties['value']) {
        throw "Deployment output '$Name' is missing. Redeploy the current Bicep template."
    }
    return $output.Value.value
}

function Invoke-ValidationCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    try {
        $detailOutput = @(& $Action)
        $detail = ($detailOutput | ForEach-Object { $_.ToString() }) -join '; '
        $checks.Add([pscustomobject]@{ Name = $Name; Status = 'Passed'; Detail = $detail })
        Write-Host "PASS: $Name$(if ($detail) { " - $detail" })" -ForegroundColor Green
    }
    catch {
        $message = $_.Exception.Message
        $checks.Add([pscustomobject]@{ Name = $Name; Status = 'Failed'; Detail = $message })
        $issues.Add("${Name}: $message")
        Write-Host "FAIL: $Name - $message" -ForegroundColor Red
    }
}

function Test-ResourceExists {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$Label
    )

    Invoke-AzureCliText @(
        'resource', 'show',
        '--subscription', $SubscriptionId,
        '--ids', $ResourceId,
        '--output', 'none',
        '--only-show-errors'
    ) "Could not read $Label at '$ResourceId'." | Out-Null
    return $Label
}

function Test-SubnetExists {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$Label
    )

    $segments = $ResourceId.Trim('/').Split('/')
    $resourceGroupIndex = [Array]::IndexOf($segments, 'resourceGroups')
    $virtualNetworkIndex = [Array]::IndexOf($segments, 'virtualNetworks')
    $subnetIndex = [Array]::IndexOf($segments, 'subnets')
    if (
        $resourceGroupIndex -lt 0 -or $resourceGroupIndex + 1 -ge $segments.Count -or
        $virtualNetworkIndex -lt 0 -or $virtualNetworkIndex + 1 -ge $segments.Count -or
        $subnetIndex -lt 0 -or $subnetIndex + 1 -ge $segments.Count
    ) {
        throw "Subnet resource ID is invalid: '$ResourceId'."
    }

    Invoke-AzureCliText @(
        'network', 'vnet', 'subnet', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $segments[$resourceGroupIndex + 1],
        '--vnet-name', $segments[$virtualNetworkIndex + 1],
        '--name', $segments[$subnetIndex + 1],
        '--output', 'none',
        '--only-show-errors'
    ) "Could not read $Label at '$ResourceId'." | Out-Null
    return $Label
}

function Test-VirtualMachine {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VirtualMachineName,
        [ValidateRange(0, 16)][int]$MinimumDataDisks
    )

    $instanceViewJson = Invoke-AzureCliText @(
        'vm', 'get-instance-view',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $VirtualMachineName,
        '--output', 'json',
        '--only-show-errors'
    ) "Could not read instance view for VM '$VirtualMachineName'."
    $instanceView = $instanceViewJson | ConvertFrom-Json
    $statusCodes = @($instanceView.instanceView.statuses | ForEach-Object { [string]$_.code })
    if ('ProvisioningState/succeeded' -notin $statusCodes) {
        throw "VM provisioning has not succeeded: $($statusCodes -join ', ')."
    }
    if ('PowerState/running' -notin $statusCodes) {
        throw "VM is not running: $($statusCodes -join ', ')."
    }

    $vmJson = Invoke-AzureCliText @(
        'vm', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $VirtualMachineName,
        '--output', 'json',
        '--only-show-errors'
    ) "Could not read VM '$VirtualMachineName'."
    $vm = $vmJson | ConvertFrom-Json
    $dataDiskCount = @($vm.storageProfile.dataDisks).Count
    if ($dataDiskCount -lt $MinimumDataDisks) {
        throw "VM has $dataDiskCount data disks; expected at least $MinimumDataDisks."
    }
    return "$VirtualMachineName running with $dataDiskCount data disks"
}

function Invoke-GuestProbe {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VirtualMachineName,
        [Parameter(Mandatory)][ValidateSet('RunPowerShellScript', 'RunShellScript')][string]$CommandId,
        [Parameter(Mandatory)][string]$ScriptText,
        [Parameter(Mandatory)][string]$ResultMarker
    )

    $extension = if ($CommandId -eq 'RunPowerShellScript') { 'ps1' } else { 'sh' }
    $temporaryScript = Join-Path $env:TEMP "azure-migrate-probe-$([Guid]::NewGuid().ToString('N')).$extension"
    try {
        Set-Content -LiteralPath $temporaryScript -Value $ScriptText -Encoding utf8NoBOM
        $runCommandJson = Invoke-AzureCliText @(
            'vm', 'run-command', 'invoke',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--name', $VirtualMachineName,
            '--command-id', $CommandId,
            '--scripts', "@$temporaryScript",
            '--output', 'json',
            '--only-show-errors'
        ) "Guest probe failed for VM '$VirtualMachineName'."
        $runCommand = $runCommandJson | ConvertFrom-Json
        $message = @($runCommand.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
        $resultMatch = [regex]::Match(
            $message,
            "(?m)^\s*$([regex]::Escape($ResultMarker))(?<result>\{[^\r\n]+\})\s*$"
        )
        if (-not $resultMatch.Success) {
            throw "Guest probe did not return '$ResultMarker'. $message"
        }
        return $resultMatch.Groups['result'].Value | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it before running this script.'
}
if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) {
    throw "Deployment configuration was not found: $configFilePath"
}

$configuration = Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json
foreach ($propertyName in 'SourceSubscriptionId', 'TargetSubscriptionId') {
    $property = $configuration.PSObject.Properties[$propertyName]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Deployment configuration is missing $propertyName."
    }
}
$sourceSubscriptionId = [string]$configuration.SourceSubscriptionId
$targetSubscriptionId = [string]$configuration.TargetSubscriptionId
$previousAzureExtensionDirectory = $env:AZURE_EXTENSION_DIR
$isolatedAzureExtensionDirectory = Join-Path $env:TEMP 'azure-migrate-lab-az-extensions'
New-Item -Path $isolatedAzureExtensionDirectory -ItemType Directory -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $isolatedAzureExtensionDirectory
$checks = [Collections.Generic.List[object]]::new()
$issues = [Collections.Generic.List[string]]::new()

try {
    & az account show --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        & az login
        if ($LASTEXITCODE -ne 0) {
            throw 'Azure sign-in failed.'
        }
    }

    $deploymentJson = Invoke-AzureCliText @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--output', 'json',
        '--only-show-errors'
    ) "Could not read subscription deployment '$DeploymentName'."
    $deployment = $deploymentJson | ConvertFrom-Json
    $sourceResourceGroupId = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'sourceResourceGroupId')
    $targetResourceGroupId = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'targetResourceGroupId')
    $sourceResourceGroupName = ($sourceResourceGroupId -split '/')[-1]
    $targetResourceGroupName = ($targetResourceGroupId -split '/')[-1]
    $discoveryVmName = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'discoveryApplianceName')
    $replicationVmName = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'replicationApplianceName')
    $hyperVHostName = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'hyperVHostName')
    $windowsSourceName = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'windowsSourceName')
    $linuxSourceName = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'linuxSourceName')
    $testSubnetId = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'targetTestSubnetId')
    $finalSubnetId = [string](Get-DeploymentOutputValue -Deployment $deployment -Name 'targetFinalSubnetId')

    Invoke-ValidationCheck -Name 'Subscription deployment' -Action {
        if ([string]$deployment.properties.provisioningState -ne 'Succeeded') {
            throw "Provisioning state is '$($deployment.properties.provisioningState)'."
        }
        return $DeploymentName
    }
    Invoke-ValidationCheck -Name 'Source resource group' -Action {
        Test-ResourceExists -SubscriptionId $sourceSubscriptionId -ResourceId $sourceResourceGroupId -Label $sourceResourceGroupName
    }
    Invoke-ValidationCheck -Name 'Target resource group' -Action {
        Test-ResourceExists -SubscriptionId $targetSubscriptionId -ResourceId $targetResourceGroupId -Label $targetResourceGroupName
    }
    Invoke-ValidationCheck -Name 'Target test subnet' -Action {
        Test-SubnetExists -SubscriptionId $targetSubscriptionId -ResourceId $testSubnetId -Label 'target test subnet'
    }
    Invoke-ValidationCheck -Name 'Target final subnet' -Action {
        Test-SubnetExists -SubscriptionId $targetSubscriptionId -ResourceId $finalSubnetId -Label 'target final subnet'
    }

    foreach ($vmExpectation in @(
        [pscustomobject]@{ Name = $discoveryVmName; MinimumDataDisks = 0 }
        [pscustomobject]@{ Name = $replicationVmName; MinimumDataDisks = 1 }
        [pscustomobject]@{ Name = $hyperVHostName; MinimumDataDisks = 1 }
    )) {
        Invoke-ValidationCheck -Name "VM $($vmExpectation.Name)" -Action {
            Test-VirtualMachine `
                -SubscriptionId $sourceSubscriptionId `
                -ResourceGroupName $sourceResourceGroupName `
                -VirtualMachineName $vmExpectation.Name `
                -MinimumDataDisks $vmExpectation.MinimumDataDisks
        }
    }

    Invoke-ValidationCheck -Name 'Azure Migrate project and registrations' -Action {
        $projectOutput = @(& $powerShellPath `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File (Join-Path $PSScriptRoot 'verify-migrate-project.ps1') `
            -ConfigFile $configFilePath `
            -DeploymentName $DeploymentName `
            -RequireDiscoveryResources `
            -RequireDiscoveredServers `
            -RequireMigrationResources `
            -RequireReplicationProvider 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ($projectOutput | ForEach-Object { $_.ToString() } | Select-Object -Last 1)
        }
        $resultLine = $projectOutput |
            ForEach-Object { $_.ToString() } |
            Where-Object { $_.TrimStart().StartsWith('AZURE_MIGRATE_PROJECT_RESULT=', [StringComparison]::Ordinal) } |
            Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$resultLine)) {
            throw 'Project verifier did not emit its result marker.'
        }
        $projectResult = $resultLine.Trim().Substring('AZURE_MIGRATE_PROJECT_RESULT='.Length) | ConvertFrom-Json
        return "$($projectResult.ProjectName), $(@($projectResult.LinkedResourceIds).Count) linked resources"
    }

    if (-not $SkipGuestChecks) {
        $discoveryProbe = @'
$registryPresent = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\AzureAppliance'
$iisRunning = (Get-Service -Name W3SVC -ErrorAction SilentlyContinue).Status -eq 'Running'
$portListening = $null -ne (Get-NetTCPConnection -State Listen -LocalPort 44368 -ErrorAction SilentlyContinue | Select-Object -First 1)
function Test-TcpEndpoint([string]$Address, [int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try { $task = $client.ConnectAsync($Address, $Port); return $task.Wait(5000) -and $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}
$result = [ordered]@{
    RegistryPresent = $registryPresent
    IisRunning = $iisRunning
    ConfigurationPortListening = $portListening
    WindowsWinRm = Test-TcpEndpoint '10.10.3.10' 5985
    LinuxSsh = Test-TcpEndpoint '10.10.3.20' 22
}
Write-Output "AZURE_MIGRATE_DISCOVERY_HEALTH=$($result | ConvertTo-Json -Compress)"
'@
        Invoke-ValidationCheck -Name 'Discovery appliance health' -Action {
            $result = Invoke-GuestProbe `
                -SubscriptionId $sourceSubscriptionId `
                -ResourceGroupName $sourceResourceGroupName `
                -VirtualMachineName $discoveryVmName `
                -CommandId 'RunPowerShellScript' `
                -ScriptText $discoveryProbe `
                -ResultMarker 'AZURE_MIGRATE_DISCOVERY_HEALTH='
            if (
                -not $result.RegistryPresent -or
                -not $result.IisRunning -or
                -not $result.ConfigurationPortListening -or
                -not $result.WindowsWinRm -or
                -not $result.LinuxSsh
            ) {
                throw "Discovery health failed: $($result | ConvertTo-Json -Compress)."
            }
            return 'registry, IIS, TCP 44368, Windows WinRM, and Linux SSH ready'
        }

        $replicationProbe = @'
$registryPaths = @('HKLM:\SOFTWARE\Microsoft\AzureAppliance', 'HKLM:\SOFTWARE\Microsoft Azure\Appliance')
$registryPath = $registryPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$iisRunning = (Get-Service -Name W3SVC -ErrorAction SilentlyContinue).Status -eq 'Running'
$portListening = $null -ne (Get-NetTCPConnection -State Listen -LocalPort 44368 -ErrorAction SilentlyContinue | Select-Object -First 1)
$result = [ordered]@{ RegistryPresent = $null -ne $registryPath; IisRunning = $iisRunning; ConfigurationPortListening = $portListening }
Write-Output "AZURE_MIGRATE_REPLICATION_HEALTH=$($result | ConvertTo-Json -Compress)"
'@
        Invoke-ValidationCheck -Name 'Replication appliance health' -Action {
            $result = Invoke-GuestProbe `
                -SubscriptionId $sourceSubscriptionId `
                -ResourceGroupName $sourceResourceGroupName `
                -VirtualMachineName $replicationVmName `
                -CommandId 'RunPowerShellScript' `
                -ScriptText $replicationProbe `
                -ResultMarker 'AZURE_MIGRATE_REPLICATION_HEALTH='
            if (-not $result.RegistryPresent -or -not $result.IisRunning -or -not $result.ConfigurationPortListening) {
                throw "Replication health failed: $($result | ConvertTo-Json -Compress)."
            }
            return 'local registry, IIS, and TCP 44368 ready; Azure provider connected'
        }

        $nestedGuestProbe = @'
$statusPath = 'C:\AzureMigrateNested\status.json'
$status = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } else { $null }
$vms = @(Get-VM -Name 'source-win01','source-linux01' -ErrorAction SilentlyContinue)
$switches = @(
    Get-VMSwitch -ErrorAction SilentlyContinue |
        Where-Object Name -in 'NestedRouted','NestedNat'
)
$adapters = @($vms | Get-VMNetworkAdapter | Select-Object VMName,Name,SwitchName,MacAddress)
$routedInterface = Get-NetIPInterface -InterfaceAlias 'vEthernet (NestedRouted)' -AddressFamily IPv4 -ErrorAction SilentlyContinue
function Test-TcpEndpoint([string]$Address, [int]$Port) {
  $client = [Net.Sockets.TcpClient]::new()
  try { $task = $client.ConnectAsync($Address, $Port); return $task.Wait(3000) -and $client.Connected }
  catch { return $false }
  finally { $client.Dispose() }
}
function Get-WebContent([string]$Address) {
  try { return (Invoke-WebRequest -Uri "http://$Address" -UseBasicParsing -TimeoutSec 10).Content }
  catch { return '' }
}
$result = [ordered]@{
  StatusReady = $null -ne $status -and $status.state -eq 'Ready'
  WindowsRunning = $null -ne ($vms | Where-Object { $_.Name -eq 'source-win01' -and $_.State -eq 'Running' })
  LinuxRunning = $null -ne ($vms | Where-Object { $_.Name -eq 'source-linux01' -and $_.State -eq 'Running' })
    InternalSwitchesReady = @($switches | Where-Object {
        [string]$_.SwitchType -eq 'Internal' -or [int]$_.SwitchType -eq 1
    }).Count -eq 2
  RoutedForwardingEnabled = $null -ne $routedInterface -and [string]$routedInterface.Forwarding -eq 'Enabled'
  EachGuestHasTwoNics = @($adapters | Group-Object VMName | Where-Object Count -eq 2).Count -eq 2
  WindowsWeb = (Get-WebContent '10.10.3.10') -match 'Nested Windows source workload'
  LinuxWeb = (Get-WebContent '10.10.3.20') -match 'Nested Linux source workload'
}
Write-Output "AZURE_MIGRATE_NESTED_GUESTS=$($result | ConvertTo-Json -Compress)"
'@
        Invoke-ValidationCheck -Name 'Nested physical source workloads' -Action {
            $result = Invoke-GuestProbe `
                -SubscriptionId $sourceSubscriptionId `
                -ResourceGroupName $sourceResourceGroupName `
                -VirtualMachineName $hyperVHostName `
                -CommandId 'RunPowerShellScript' `
                -ScriptText $nestedGuestProbe `
                -ResultMarker 'AZURE_MIGRATE_NESTED_GUESTS='
            $failedProperties = @($result.PSObject.Properties | Where-Object { -not [bool]$_.Value } | ForEach-Object Name)
            if ($failedProperties.Count -gt 0) {
                throw "Nested guest validation failed: $($failedProperties -join ', ')."
            }
            return "$windowsSourceName and $linuxSourceName running with routed management and web workloads"
        }
    }

    $failedChecks = @($checks | Where-Object { $_.Status -eq 'Failed' })
    $result = [ordered]@{
        Status = if ($failedChecks.Count -eq 0) { 'Passed' } else { 'Failed' }
        PassedChecks = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
        FailedChecks = $failedChecks.Count
        GuestChecksSkipped = $SkipGuestChecks.IsPresent
        Checks = @($checks)
        Issues = @($issues)
    }
    $resultJson = $result | ConvertTo-Json -Depth 6 -Compress
    $resultLine = "AZURE_MIGRATE_LAB_TEST_RESULT=$resultJson"
    Write-Output $resultLine
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_MIGRATE_LAB_RESULT_FILE)) {
        Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE -Value $resultLine -Encoding utf8NoBOM
    }
    if ($failedChecks.Count -gt 0) {
        throw "$($failedChecks.Count) lab validation checks failed."
    }
}
finally {
    if ([string]::IsNullOrWhiteSpace($previousAzureExtensionDirectory)) {
        Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory
    }
}
