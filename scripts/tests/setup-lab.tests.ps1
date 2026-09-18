[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\setup-lab.ps1')).Path
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "setup-lab.ps1 has parse errors: $($parseErrors -join '; ')"
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
if (-not $scriptText.Contains(". (Join-Path `$PSScriptRoot 'lab-console.ps1')")) {
    throw 'Setup must load the shared console-formatting helpers.'
}
foreach ($checkpointLayoutText in @(
    'Confirm-LabCheckpoint'
    "Title = 'Credentials'"
    "Title = 'Discovery sources'"
    "FriendlyName = 'labwindows'"
    "FriendlyName = 'lablinux'"
    "VM = 'source-win01'"
    "VM = 'source-linux01'"
    'Discovery has been successfully initiated'
)) {
    if (-not $scriptText.Contains($checkpointLayoutText)) {
        throw "Structured discovery checkpoint behavior is missing: $checkpointLayoutText"
    }
}
$consoleHelperPath = (Resolve-Path (Join-Path $PSScriptRoot '..\lab-console.ps1')).Path
$consoleTokens = $null
$consoleParseErrors = $null
$consoleText = Get-Content -LiteralPath $consoleHelperPath -Raw
[Management.Automation.Language.Parser]::ParseFile(
    $consoleHelperPath,
    [ref]$consoleTokens,
    [ref]$consoleParseErrors
) | Out-Null
if ($consoleParseErrors.Count -gt 0) {
    throw "lab-console.ps1 has parse errors: $($consoleParseErrors -join '; ')"
}
foreach ($helperFunction in 'Write-LabRule', 'Write-LabCheckpoint', 'Confirm-LabCheckpoint') {
    if (-not $consoleText.Contains("function $helperFunction")) {
        throw "Shared console helper is missing '$helperFunction'."
    }
}
if ($scriptText.Contains('Tee-Object -Variable childOutput')) {
    throw 'Interactive child scripts must not be piped through Tee-Object because prompts can be reordered.'
}
foreach ($resultChannelText in @(
    '$env:AZURE_MIGRATE_LAB_RESULT_FILE = $resultFile'
    '$processStartInfo = [Diagnostics.ProcessStartInfo]::new()'
    '$processStartInfo.UseShellExecute = $false'
    '$processStartInfo.ArgumentList.Add($argument)'
    '$childProcess.WaitForExit()'
    '$childExitCode = $childProcess.ExitCode'
    'Get-Content -LiteralPath $resultFile -Raw'
    'Remove-Item -LiteralPath $resultFile -Force'
    'Remove-Item Env:AZURE_MIGRATE_LAB_RESULT_FILE'
    '$env:AZURE_MIGRATE_LAB_RESULT_FILE = $previousResultFile'
)) {
    if (-not $scriptText.Contains($resultChannelText)) {
        throw "Setup result-file behavior is missing: $resultChannelText"
    }
}
foreach ($stepName in @(
    'DeployInfrastructure'
    'VerifyProject'
    'InstallDiscovery'
    'RegisterDiscovery'
    'CreateMigrationResources'
    'InstallReplication'
    'RegisterReplication'
    'ValidateLab'
)) {
    if (-not $scriptText.Contains("Name = '$stepName'")) {
        throw "Setup workflow is missing step '$stepName'."
    }
}
foreach ($switchName in '[string]$FromStep', '[switch]$Status', '[switch]$ResetState') {
    if (-not $scriptText.Contains($switchName)) {
        throw "Setup workflow is missing control '$switchName'."
    }
}
if (-not $scriptText.Contains('[switch]$ApproveDeployment') -or
    -not $scriptText.Contains("`$deploymentArguments += '-ApproveDeployment'")) {
    throw 'Setup must forward explicit deployment pre-approval to deploy-lab.ps1.'
}
foreach ($regionParameter in '[string]$SourceLocation', '[string]$TargetLocation') {
    if (-not $scriptText.Contains($regionParameter)) {
        throw "Setup workflow is missing region parameter '$regionParameter'."
    }
}
if (-not $scriptText.Contains("`$deploymentArguments += @('-SourceLocation', `$SourceLocation)") -or
    -not $scriptText.Contains("`$deploymentArguments += @('-TargetLocation', `$TargetLocation)")) {
    throw 'Setup must forward separate source and target regions to deploy-lab.ps1.'
}
foreach ($confirmationText in 'DISCOVERY REGISTERED', 'MIGRATION KEY GENERATED', 'REPLICATION REGISTERED') {
    if (-not $scriptText.Contains($confirmationText)) {
        throw "Setup workflow is missing manual checkpoint '$confirmationText'."
    }
}
foreach ($replicationInstruction in @(
    'https://localhost:44368'
    'https://10.10.1.20:44368'
    'select FQDN'
    'detected name amig-repl and port 9443'
    'Do not select NAT IP'
    'cannot be changed after it is saved'
    'Why servers are added again'
    'credentials are never copied between appliances'
    'lablinuxroot'
    'Linux password'
    'I will add Physical server details later'
    'labadmin SSH key installed'
    'Migration and modernization > Infrastructure servers > Configuration servers'
    'The appliance is not shown in the discovery-appliance inventory.'
    'RegistrationProviderName'
    'RegistrationConnectionStatus'
    'RegistrationFabricHealth'
    'RegistrationLastHeartbeat'
    'Recovery Services vault created in step 5'
    'source-win01'
    'source-linux01'
    'Do not confirm this checkpoint while a sizing or prerequisite validation error remains.'
)) {
    if (-not $scriptText.Contains($replicationInstruction)) {
        throw "Replication checkpoint is missing configuration guidance: $replicationInstruction"
    }
}
foreach ($migrationInstruction in @(
    'Execute > Migrations'
    'select Enable MSI'
    'From all inventory'
    'No replication appliance is registered'
    'select Click here to set up'
    'Select Generate key'
    'Stop if it shows another region'
)) {
    if (-not $scriptText.Contains($migrationInstruction)) {
        throw "Migration-resource checkpoint is missing current portal guidance: $migrationInstruction"
    }
}
if (-not $scriptText.Contains("-AllowedStatuses @('Deployed', 'Cancelled')")) {
    throw 'Setup must accept deployment cancellation as a resumable result.'
}
if (-not $scriptText.Contains("if (`$result.Status -eq 'Cancelled')")) {
    throw 'Setup must pause cleanly when infrastructure deployment is cancelled.'
}
foreach ($verificationSwitch in '-RequireDiscoveryResources', '-RequireMigrationResources', '-RequireRegistered') {
    if (-not $scriptText.Contains($verificationSwitch)) {
        throw "Setup workflow is missing verification gate '$verificationSwitch'."
    }
}
if (-not $scriptText.Contains('Move-Item -LiteralPath $temporaryStatePath')) {
    throw 'Setup state must be replaced atomically.'
}
if (-not $scriptText.Contains("Type RESET to delete local setup state")) {
    throw 'Setup state reset must require explicit confirmation.'
}
foreach ($forbiddenName in 'AdminPassword', 'ProjectKey', 'RegistrationKey', 'SourcePassword') {
    if ($scriptText -match "(?i)$forbiddenName\\s*=") {
        throw "Setup state must not store secret field '$forbiddenName'."
    }
}

Write-Host 'setup-lab tests passed.' -ForegroundColor Green
