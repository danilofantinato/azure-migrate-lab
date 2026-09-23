[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\test-lab.ps1')).Path
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "test-lab.ps1 has parse errors: $($parseErrors -join '; ')"
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($requiredOutput in @(
    'sourceResourceGroupId'
    'targetResourceGroupId'
    'discoveryApplianceName'
    'replicationApplianceName'
    'hyperVHostName'
    'windowsSourceName'
    'linuxSourceName'
    'targetTestSubnetId'
    'targetFinalSubnetId'
)) {
    if (-not $scriptText.Contains($requiredOutput)) {
        throw "Lab validation must consume deployment output '$requiredOutput'."
    }
}
foreach ($requiredProbe in @(
    'AZURE_MIGRATE_DISCOVERY_HEALTH='
    'AZURE_MIGRATE_REPLICATION_HEALTH='
    'AZURE_MIGRATE_NESTED_GUESTS='
)) {
    if (-not $scriptText.Contains($requiredProbe)) {
        throw "Lab validation is missing guest probe '$requiredProbe'."
    }
}
foreach ($requiredGate in '-RequireDiscoveryResources', '-RequireDiscoveredServers', '-RequireMigrationResources', '-RequireReplicationProvider') {
    if (-not $scriptText.Contains($requiredGate)) {
        throw "Lab validation is missing project gate '$requiredGate'."
    }
}
foreach ($subnetValidationContract in @(
    'function Test-SubnetExists'
    "'network', 'vnet', 'subnet', 'show'"
    'Test-SubnetExists -SubscriptionId $targetSubscriptionId -ResourceId $testSubnetId'
    'Test-SubnetExists -SubscriptionId $targetSubscriptionId -ResourceId $finalSubnetId'
)) {
    if (-not $scriptText.Contains($subnetValidationContract)) {
        throw "Lab validation is missing subnet-specific validation: $subnetValidationContract"
    }
}
foreach ($obsoleteSubnetValidation in @(
    'Test-ResourceExists -SubscriptionId $targetSubscriptionId -ResourceId $testSubnetId'
    'Test-ResourceExists -SubscriptionId $targetSubscriptionId -ResourceId $finalSubnetId'
)) {
    if ($scriptText.Contains($obsoleteSubnetValidation)) {
        throw "Lab validation still uses generic resource lookup for a subnet: $obsoleteSubnetValidation"
    }
}
if ($scriptText.Contains("foreach (`$propertyName in 'IsApplianceRegistered', 'IsRegistered')")) {
    throw 'Replication registration must be verified from Azure, not guessed guest registry flags.'
}
foreach ($nestedGuestGate in @(
    "Get-VM -Name 'source-win01','source-linux01'"
    'Get-VMSwitch -ErrorAction SilentlyContinue'
    "Where-Object Name -in 'NestedRouted','NestedNat'"
    "Test-TcpEndpoint '10.10.3.10' 5985"
    "Test-TcpEndpoint '10.10.3.20' 22"
    "Get-WebContent '10.10.3.10'"
    "Get-WebContent '10.10.3.20'"
    '-VirtualMachineName $hyperVHostName'
    "[string]`$_.SwitchType -eq 'Internal' -or [int]`$_.SwitchType -eq 1"
)) {
    if (-not $scriptText.Contains($nestedGuestGate)) {
        throw "Lab validation is missing nested guest gate: $nestedGuestGate"
    }
}
$discoveryProbePosition = $scriptText.IndexOf('$discoveryProbe = @''')
$nestedProbePosition = $scriptText.IndexOf('$nestedGuestProbe = @''')
foreach ($discoveryOriginatedProbe in @(
    "Test-TcpEndpoint '10.10.3.10' 5985"
    "Test-TcpEndpoint '10.10.3.20' 22"
)) {
    $probePosition = $scriptText.IndexOf($discoveryOriginatedProbe)
    if (
        $probePosition -lt $discoveryProbePosition -or
        $probePosition -gt $nestedProbePosition -or
        $scriptText.IndexOf($discoveryOriginatedProbe, $probePosition + 1) -ge 0
    ) {
        throw "Nested management probe must run exactly once from the discovery appliance: $discoveryOriginatedProbe"
    }
}
foreach ($forbiddenDirectProbe in '-VirtualMachineName $windowsSourceName', '-VirtualMachineName $linuxSourceName') {
    if ($scriptText.Contains($forbiddenDirectProbe)) {
        throw "Nested guests must not be probed through Azure Run Command: $forbiddenDirectProbe"
    }
}
if (-not $scriptText.Contains('AZURE_MIGRATE_LAB_TEST_RESULT=')) {
    throw 'Lab validation must emit a machine-readable result marker.'
}
if (-not $scriptText.Contains('Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE')) {
    throw 'Lab validation results must support the setup result-file channel.'
}
if (-not $scriptText.Contains('''--scripts'', "@$temporaryScript"')) {
    throw 'Guest probes must use the documented Run Command file transport.'
}
if (-not $scriptText.Contains('Remove-Item -LiteralPath $temporaryScript -Force')) {
    throw 'Guest probe temporary scripts must be removed.'
}

Write-Host 'test-lab tests passed.' -ForegroundColor Green
