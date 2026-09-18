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
    'AZURE_MIGRATE_WINDOWS_WORKLOAD='
    'AZURE_MIGRATE_LINUX_WORKLOAD='
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
if (-not $scriptText.Contains("Get-Volume -FileSystemLabel 'LabData'") -or
    $scriptText.Contains("Test-Path -LiteralPath 'D:\lab-data\migration-marker.txt'")) {
    throw 'Windows workload validation must resolve its marker from the LabData volume label.'
}
if ($scriptText.Contains("foreach (`$propertyName in 'IsApplianceRegistered', 'IsRegistered')")) {
    throw 'Replication registration must be verified from Azure, not guessed guest registry flags.'
}
foreach ($linuxMobilityGate in @(
    "expected_kernel='6.8.0-1041-azure'"
    'PasswordAuthentication'
    'PermitRootLogin'
    'RootPasswordSet'
    'SftpEnabled'
    'HostMappingPresent'
    'Mobility prerequisites ready on kernel'
)) {
    if (-not $scriptText.Contains($linuxMobilityGate)) {
        throw "Lab validation is missing Linux Mobility gate: $linuxMobilityGate"
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
