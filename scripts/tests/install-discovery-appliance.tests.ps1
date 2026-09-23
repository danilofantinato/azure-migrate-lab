[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\install-discovery-appliance.ps1')).Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "install-discovery-appliance.ps1 has parse errors: $($parseErrors -join '; ')"
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

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
if (($scriptText | Select-String -Pattern "'--scripts'" -AllMatches).Matches.Count -ne 1) {
    throw 'Expected exactly one --scripts argument.'
}
if (-not $scriptText.Contains('''--scripts'', "@$remoteScriptFile"')) {
    throw 'Azure Run Command must use the documented @script.ps1 file transport.'
}
if (-not $scriptText.Contains('Remove-Item -LiteralPath $remoteScriptFile -Force')) {
    throw 'The temporary remote script file is not removed in cleanup.'
}
if (-not $scriptText.Contains('''--parameters''')) {
    throw 'Named Azure Run Command parameters must be preserved.'
}
if ($remoteScriptText.Contains("-Include '*.ps1', '*.psm1'")) {
    throw 'PowerShell signature validation must not use the ambiguous Get-ChildItem -Include form.'
}
if (-not $remoteScriptText.Contains("Where-Object { `$_.Extension -in @('.ps1', '.psm1') }")) {
    throw 'PowerShell signature validation must explicitly filter .ps1 and .psm1 extensions.'
}
if (-not $remoteScriptText.Contains('. $InstallerPath -Scenario Physical -Cloud Public -PrivateEndpoint:$false')) {
    throw 'The wrapper must dot-source the installer and bind PrivateEndpoint false in the compatibility scope.'
}
if ($remoteScriptText.Contains('& $InstallerPath -Scenario Physical')) {
    throw 'The installer must not run in a child scope that bypasses the compatibility function.'
}
if (-not $remoteScriptText.Contains('Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0')) {
    throw 'The wrapper must verify the installed PowerShell ISE Windows capability.'
}
if (-not $remoteScriptText.Contains('ServerManager\Install-WindowsFeature -Name $requestedFeatures')) {
    throw 'The compatibility wrapper must delegate remaining roles to the native Server Manager cmdlet.'
}
if ($remoteScriptText.Contains("'-NonInteractive'")) {
    throw 'The Microsoft installer requires Read-Host support and must not run in NonInteractive mode.'
}
if (-not $remoteScriptText.Contains("@('Y', 'N', 'N')")) {
    throw 'The bounded installer response sequence must confirm setup and decline browser changes.'
}
if (-not $remoteScriptText.Contains('-RedirectStandardInput $installerInputPath')) {
    throw 'The installer process must receive the bounded response file through standard input.'
}
if (-not $remoteScriptText.Contains('Remove-Item -LiteralPath $installerWrapperPath, $installerInputPath')) {
    throw 'Temporary installer wrapper and response files must be removed.'
}
if (-not $scriptText.Contains('Checking discovery appliance state through Azure VM Run Command.')) {
    throw 'The outer script must describe the initial operation as a state check.'
}
if (-not $remoteScriptText.Contains("Write-InstallResult -Status 'AlreadyInstalled'")) {
    throw 'A healthy no-Force run must report AlreadyInstalled.'
}
if (-not $remoteScriptText.Contains("'Repaired'")) {
    throw 'A forced partial installation must report Repaired.'
}
if (-not $scriptText.Contains('Check complete: discovery appliance is already installed and healthy.')) {
    throw 'The local output must clearly report a healthy existing installation.'
}
foreach ($registrationInstruction in @(
    'Overview > Inventory, select Start discovery > Using appliance > Physical or other'
    'Windows | source-win01   | 10.10.3.10 | labwindows'
    'Linux   | source-linux01 | 10.10.3.20 | lablinux'
    'Validate both sources, select Start discovery'
    'A 401 from graph.windows.net proves endpoint reachability'
)) {
    if (-not $scriptText.Contains($registrationInstruction)) {
        throw "Discovery registration guidance is missing: $registrationInstruction"
    }
}
if (-not $scriptText.Contains('AZURE_MIGRATE_DISCOVERY_RESULT=')) {
    throw 'The outer script must emit a machine-readable discovery result.'
}
if (-not $scriptText.Contains('Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE')) {
    throw 'Discovery results must support the setup result-file channel.'
}
foreach ($componentUpdateText in @(
    'DADC4E031E671CDD288D1B060E5DF687A295E60BF44054FE339FB318BB12C7D5'
    'C3220E19E18731A08F4EA78C6B91E64D5A89450A2696E9E20A36AD1ECCEAA58A'
    'MicrosoftAzureApplianceConfigurationManager.msi'
    'MicrosoftAzureAutoUpdate.msi'
    'function Install-VerifiedMicrosoftMsi'
    'function Get-MsiProperty'
    '$database = $windowsInstaller.OpenDatabase($msiPath, 0)'
    '$view = $database.OpenView('
    '[void]$view.Execute()'
    '$record = $view.Fetch()'
    '$record.StringData(1)'
    '[Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)'
    '$null -ne $_.PSObject.Properties[''DisplayName'']'
    '[string]$_.DisplayName -eq $productName'
    "Get-MsiProperty -PropertyName 'ProductName'"
    "Get-MsiProperty -PropertyName 'ProductVersion'"
    '[version]$installedProduct[0].DisplayVersion -ge [version]$productVersion'
    'foreach ($attempt in 1..30)'
    '$process.ExitCode -ne 1618'
    "`$signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation'"
    "@('/i', ('`"{0}`"' -f `$msiPath), '/qn', '/norestart', '/L*v'"
    '$process.ExitCode -notin @(0, 3010)'
    "Join-Path `$setupRoot 'component-updates.json'"
    'ConfigurationManagerSha256'
    'AutoUpdateSha256'
    'ComponentUpdatesApplied'
    'ComponentUpdateRebootRequired'
)) {
    if (-not $scriptText.Contains($componentUpdateText) -and -not $remoteScriptText.Contains($componentUpdateText)) {
        throw "Discovery component update behavior is missing: $componentUpdateText"
    }
}
$updatePosition = $remoteScriptText.IndexOf('Update-ApplianceComponents')
$alreadyInstalledPosition = $remoteScriptText.IndexOf("Write-InstallResult -Status 'AlreadyInstalled'")
if ($updatePosition -lt 0 -or $alreadyInstalledPosition -lt 0 -or $updatePosition -gt $alreadyInstalledPosition) {
    throw 'Healthy existing appliances must update components before reporting AlreadyInstalled.'
}

$observedRunCommandMessage = "  AZURE_MIGRATE_DISCOVERY_INSTALL_RESULT={`"Status`":`"Installed`",`"RegistryPresent`":true,`"ConfigurationPortListening`":true,`"IisRunning`":true}`r`n"
$resultPattern = '(?m)^\s*AZURE_MIGRATE_DISCOVERY_INSTALL_RESULT=(?<result>\{[^\r\n]+\})\s*$'
$observedResultMatch = [regex]::Match($observedRunCommandMessage, $resultPattern)
if (-not $observedResultMatch.Success) {
    throw 'The result parser did not accept the observed indented CRLF payload.'
}
$observedResult = $observedResultMatch.Groups['result'].Value | ConvertFrom-Json
if ($observedResult.Status -ne 'Installed' -or -not $observedResult.ConfigurationPortListening) {
    throw 'The observed success payload was not parsed correctly.'
}

$wrapperArrayMatch = [regex]::Match(
    $remoteScriptText,
    '(?s)(?<array>@\(\s*''param\(\[Parameter\(Mandatory\)\]\[string\]\$InstallerPath\)''.*?\))\s*\|\s*Set-Content -LiteralPath \$installerWrapperPath'
)
if (-not $wrapperArrayMatch.Success) {
    throw 'The generated installer wrapper line array was not found.'
}
$wrapperLines = & ([scriptblock]::Create($wrapperArrayMatch.Groups['array'].Value))
$wrapperText = $wrapperLines -join [Environment]::NewLine
$wrapperTokens = $null
$wrapperParseErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $wrapperText,
    [ref]$wrapperTokens,
    [ref]$wrapperParseErrors
) | Out-Null
if ($wrapperParseErrors.Count -gt 0) {
    throw "The generated installer wrapper has parse errors: $($wrapperParseErrors -join '; ')"
}
if (-not $wrapperText.Contains("`$requestedFeatures = @(`$requestedFeatures | Where-Object { `$_ -ne 'PowerShell-ISE' })")) {
    throw 'The generated compatibility wrapper must remove only the obsolete PowerShell-ISE feature name.'
}

$temporaryScript = Join-Path $env:TEMP "azure-migrate-discovery-test-$([Guid]::NewGuid().ToString('N')).ps1"
try {
    Set-Content -LiteralPath $temporaryScript -Value $remoteScriptText -Encoding utf8NoBOM
    $scriptArgument = "@$temporaryScript"
    if (-not $scriptArgument.StartsWith('@')) {
        throw 'The Run Command file argument does not start with @.'
    }
    if (-not (Test-Path -LiteralPath $scriptArgument.Substring(1) -PathType Leaf)) {
        throw 'The Run Command file argument does not resolve to the temporary script.'
    }
}
finally {
    Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $temporaryScript) {
    throw 'Temporary script cleanup failed.'
}

Write-Host 'install-discovery-appliance local tests: PASS' -ForegroundColor Green