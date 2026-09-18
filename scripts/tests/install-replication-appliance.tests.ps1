[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\install-replication-appliance.ps1')).Path
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "install-replication-appliance.ps1 has parse errors: $($parseErrors -join '; ')"
}

$remoteScriptAssignment = $ast.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$remoteInstallerScript'
    },
    $true
) | Select-Object -First 1
if ($null -eq $remoteScriptAssignment) {
    throw 'The remote installer payload assignment was not found.'
}
$remoteScriptString = $remoteScriptAssignment.Right.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString
    },
    $true
) | Select-Object -First 1
if ($null -eq $remoteScriptString) {
    throw 'The embedded remote installer here-string was not found.'
}
$remoteScriptText = $remoteScriptString.Value
$remoteTokens = $null
$remoteParseErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $remoteScriptText,
    [ref]$remoteTokens,
    [ref]$remoteParseErrors
) | Out-Null
if ($remoteParseErrors.Count -gt 0) {
    throw "The embedded remote installer has parse errors: $($remoteParseErrors -join '; ')"
}

$requiredOuterText = @(
    'replicationApplianceName.value'
    'discoveryApplianceName.value'
    'Discovery and replication appliance components must not target the same VM.'
    'privateIps'
    'publicIps'
    '''--scripts'', "@$remoteScriptFile"'
    '''--parameters'''
    'Type RESTART to restart the replication VM now, or Q to stop'
    'RDP to ''$publicIpAddress'' for replication VM'
    'function Wait-ReplicationVmAgentReady'
    'Wait-ReplicationVmAgentReady `'
    'AZURE_MIGRATE_REPLICATION_RESULT='
    'Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE'
    "throw 'Review the remote logs, then rerun with -Force.'"
    "throw 'Resolve the reported replication appliance prerequisites, then rerun.'"
    '[switch]$RequireRegistered'
    'function Get-ReplicationRegistrationStatus'
    'function Wait-ReplicationRegistration'
    'targetResourceGroupId.value'
    '/replicationFabrics?api-version=2025-08-01'
    '/replicationRecoveryServicesProviders?api-version=2025-08-01'
    "properties.customDetails.instanceType -eq 'InMageRcm'"
    "properties.connectionStatus -eq 'Connected'"
    'RegistrationProviderName'
    'RegistrationLastHeartbeat'
)
foreach ($requiredText in $requiredOuterText) {
    if (-not $scriptText.Contains($requiredText)) {
        throw "Required outer-script behavior is missing: $requiredText"
    }
}

$requiredRemoteText = @(
    'B603C434A54E4C41DF715947676C187B75D839B3ECB1B48608F6652750610DC7'
    'curl.exe is required to download the 4 GB replication appliance package.'
    "Where-Object { `$_.Extension -in @('.ps1', '.psm1') }"
    'DRInstaller.ps1'
    "Write-ReplicationInstallResult -Status 'AlreadyInstalled'"
    "'PrerequisiteFailed'"
    "'RequiresReboot'"
    "'Partial'"
    "'Repaired'"
    'AD-Domain-Services'
    'Web-Server'
    'Hyper-V'
    'FIPS mode must be disabled.'
    'At least 8 physical CPU cores are required'
    'Win32_Processor'
    'Microsoft Edge must be installed before DRInstaller runs.'
    'The ReplicationCache volume was not found on E: after waiting for storage discovery.'
    "`$cacheVolume.PSObject.Properties['Size']"
    "`$cacheVolume.PSObject.Properties['FileSystem']"
    "`$cacheVolume.PSObject.Properties['HealthStatus']"
    'Update-HostStorageCache'
    'Get-Volume -DriveLetter C'
    'ConfigurationManagerPresent'
    'ConfigurationManagerSiteStarted'
    'ConfigurationManagerPoolStarted'
    'download did not create a non-empty file'
    "`$_.PSObject.Properties['DisplayName']"
    'function Get-OptionalRegistryValue'
    "Join-Path `$env:USERPROFILE 'Desktop'"
    "'InstalledWithWarnings'"
    'Get-Website'
    'IIS:\AppPools\Microsoft Azure DR Appliance Configuration Manager'
    'Import-Module WebAdministration -PassThru -ErrorAction SilentlyContinue'
    'if ($null -ne $webAdministrationModule)'
)
foreach ($requiredText in $requiredRemoteText) {
    if (-not $scriptText.Contains($requiredText) -and -not $remoteScriptText.Contains($requiredText)) {
        throw "Required remote behavior is missing: $requiredText"
    }
}

$healthPosition = $remoteScriptText.IndexOf("Write-ReplicationInstallResult -Status 'AlreadyInstalled'")
$downloadPosition = $remoteScriptText.IndexOf('& $curl.Source')
if ($healthPosition -lt 0 -or $downloadPosition -lt 0 -or $healthPosition -gt $downloadPosition) {
    throw 'Healthy-state detection must occur before package download.'
}

foreach ($forbiddenText in 'applianceKey', 'registrationKey', 'sourcePassword', 'guestPassword') {
    if ($scriptText -match $forbiddenText) {
        throw "The installer must not accept or store registration/source secrets: $forbiddenText"
    }
}

$uninstallEntries = @(
    [pscustomobject]@{ PSPath = 'Registry::without-display-name' }
    [pscustomobject]@{ DisplayName = 'Microsoft Azure Site Recovery Process Server' }
)
$matchingEntries = @(
    $uninstallEntries | Where-Object {
        $displayNameProperty = $_.PSObject.Properties['DisplayName']
        $null -ne $displayNameProperty -and
        [string]$displayNameProperty.Value -match 'Site Recovery|Replication appliance|Azure RCM|Process Server'
    }
)
if ($matchingEntries.Count -ne 1) {
    throw 'Null-safe replication product detection failed under strict mode.'
}

$webHealthBlock = [regex]::Match(
    $remoteScriptText,
    '(?s)\$configurationManagerSite = \$null.*?\$products = @\('
).Value
if ([string]::IsNullOrWhiteSpace($webHealthBlock)) {
    throw 'The guarded WebAdministration health block was not found.'
}
if ($webHealthBlock.IndexOf('if ($null -ne $webAdministrationModule)') -gt $webHealthBlock.IndexOf('Get-Website')) {
    throw 'Get-Website must be called only after WebAdministration imports successfully.'
}

$registryHelperMatch = [regex]::Match(
    $remoteScriptText,
    '(?s)function Get-OptionalRegistryValue\s*\{.*?\n\}'
)
if (-not $registryHelperMatch.Success) {
    throw 'Optional registry-value helper was not found.'
}
Set-Item -Path Function:\Get-OptionalRegistryValue -Value (
    [scriptblock]::Create(
        ([regex]::Match($registryHelperMatch.Value, '(?s)\{(?<body>.*)\}').Groups['body'].Value)
    )
)
$script:MockRegistryMode = 'MissingKey'
function global:Get-ItemProperty {
    if ($script:MockRegistryMode -eq 'MissingKey') { return $null }
    if ($script:MockRegistryMode -eq 'MissingValue') { return [pscustomobject]@{ PSPath = 'test' } }
    return [pscustomobject]@{ Enabled = 1 }
}
if ($null -ne (Get-OptionalRegistryValue -Path 'HKLM:\test' -Name Enabled)) {
    throw 'Missing registry key must return null.'
}
$script:MockRegistryMode = 'MissingValue'
if ($null -ne (Get-OptionalRegistryValue -Path 'HKLM:\test' -Name Enabled)) {
    throw 'Missing registry value must return null.'
}
$script:MockRegistryMode = 'PresentValue'
if ((Get-OptionalRegistryValue -Path 'HKLM:\test' -Name Enabled) -ne 1) {
    throw 'Present registry value was not returned.'
}
Remove-Item Function:\Get-ItemProperty -ErrorAction SilentlyContinue
Remove-Item Function:\Get-OptionalRegistryValue -ErrorAction SilentlyContinue
Remove-Variable MockRegistryMode -Scope Script -ErrorAction SilentlyContinue

$observedMessage = "  AZURE_MIGRATE_REPLICATION_INSTALL_RESULT={`"Status`":`"AlreadyInstalled`",`"RegistryPresent`":true,`"ConfigurationPortListening`":true,`"IisRunning`":true,`"ProductCount`":8,`"Registered`":false,`"RequiresReboot`":false,`"Issues`":[]}`r`n"
$resultPattern = '(?m)^\s*AZURE_MIGRATE_REPLICATION_INSTALL_RESULT=(?<result>\{[^\r\n]+\})\s*$'
$resultMatch = [regex]::Match($observedMessage, $resultPattern)
if (-not $resultMatch.Success) {
    throw 'The result parser did not accept an indented CRLF payload.'
}
$parsedResult = $resultMatch.Groups['result'].Value | ConvertFrom-Json
if ($parsedResult.Status -ne 'AlreadyInstalled' -or $parsedResult.ProductCount -ne 8) {
    throw 'The replication result payload was not parsed correctly.'
}

Write-Host 'install-replication-appliance local tests: PASS' -ForegroundColor Green