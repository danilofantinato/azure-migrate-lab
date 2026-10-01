[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$StateFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [string]$SourceLocation,
    [string]$TargetLocation,
    [ValidateSet(
        'DeployInfrastructure',
        'PrepareNestedGuests',
        'VerifyProject',
        'InstallDiscovery',
        'RegisterDiscovery',
        'CreateMigrationResources',
        'InstallReplication',
        'RegisterReplication',
        'ValidateLab'
    )]
    [string]$FromStep,
    [switch]$Status,
    [switch]$ResetState,
    [switch]$ApproveDeployment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'lab-console.ps1')
$configFilePath = if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    Join-Path $PSScriptRoot 'deploy-lab.local.json'
}
elseif ([IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
}
else {
    Join-Path $repositoryRoot $ConfigFile
}
$stateFilePath = if ([string]::IsNullOrWhiteSpace($StateFile)) {
    Join-Path $PSScriptRoot 'setup-lab.state.local.json'
}
elseif ([IO.Path]::IsPathRooted($StateFile)) {
    $StateFile
}
else {
    Join-Path $repositoryRoot $StateFile
}
$powerShellPath = (Get-Command pwsh -ErrorAction Stop).Source
$stepDefinitions = @(
    [pscustomobject]@{ Name = 'DeployInfrastructure'; Label = 'Deploy infrastructure' }
    [pscustomobject]@{ Name = 'PrepareNestedGuests'; Label = 'Prepare nested Hyper-V guests' }
    [pscustomobject]@{ Name = 'VerifyProject'; Label = 'Verify Azure Migrate project' }
    [pscustomobject]@{ Name = 'InstallDiscovery'; Label = 'Install discovery appliance' }
    [pscustomobject]@{ Name = 'RegisterDiscovery'; Label = 'Register discovery appliance' }
    [pscustomobject]@{ Name = 'CreateMigrationResources'; Label = 'Generate replication key' }
    [pscustomobject]@{ Name = 'InstallReplication'; Label = 'Install replication appliance' }
    [pscustomobject]@{ Name = 'RegisterReplication'; Label = 'Register replication appliance' }
    [pscustomobject]@{ Name = 'ValidateLab'; Label = 'Validate complete lab' }
)

function New-SetupState {
    $steps = [ordered]@{}
    foreach ($step in $stepDefinitions) {
        $steps[$step.Name] = [ordered]@{
            Status = 'Pending'
            UpdatedUtc = $null
            Detail = $null
        }
    }
    return [pscustomobject][ordered]@{
        Version = 1
        DeploymentName = $DeploymentName
        ConfigurationPath = $configFilePath
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Steps = [pscustomobject]$steps
    }
}

function Save-SetupState {
    param([Parameter(Mandatory)][object]$SetupState)

    $SetupState.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $stateDirectory = Split-Path -Parent $stateFilePath
    if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
        New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
    }
    $temporaryStatePath = "$stateFilePath.tmp"
    $SetupState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryStatePath -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporaryStatePath -Destination $stateFilePath -Force
}

function Set-StepState {
    param(
        [Parameter(Mandatory)][object]$SetupState,
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][ValidateSet('Pending', 'Running', 'AwaitingManual', 'Completed', 'Failed')]
        [string]$StepStatus,
        [string]$Detail
    )

    $stepProperty = $SetupState.Steps.PSObject.Properties[$StepName]
    if ($null -eq $stepProperty) {
        throw "Unknown setup step '$StepName'."
    }
    $stepProperty.Value.Status = $StepStatus
    $stepProperty.Value.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $stepProperty.Value.Detail = $Detail
    Save-SetupState -SetupState $SetupState
}

function Show-SetupStatus {
    param([Parameter(Mandatory)][object]$SetupState)

    Write-Host "Setup state: $stateFilePath" -ForegroundColor Cyan
    foreach ($step in $stepDefinitions) {
        $stepState = $SetupState.Steps.PSObject.Properties[$step.Name].Value
        $detail = if ([string]::IsNullOrWhiteSpace([string]$stepState.Detail)) { '' } else { " - $($stepState.Detail)" }
        Write-Host ("{0,-28} {1}{2}" -f $step.Name, $stepState.Status, $detail)
    }
}

function Invoke-LabScript {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$ScriptArguments = @(),
        [Parameter(Mandatory)][string]$ResultMarker,
        [Parameter(Mandatory)][string[]]$AllowedStatuses
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required script was not found: $scriptPath"
    }

    $resultFile = Join-Path $env:TEMP "azure-migrate-result-$([Guid]::NewGuid().ToString('N')).txt"
    $previousResultFile = $env:AZURE_MIGRATE_LAB_RESULT_FILE
    try {
        $env:AZURE_MIGRATE_LAB_RESULT_FILE = $resultFile
        $processStartInfo = [Diagnostics.ProcessStartInfo]::new()
        $processStartInfo.FileName = $powerShellPath
        $processStartInfo.UseShellExecute = $false
        foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $ScriptArguments) {
            $processStartInfo.ArgumentList.Add($argument)
        }
        $childProcess = [Diagnostics.Process]::new()
        $childProcess.StartInfo = $processStartInfo
        if (-not $childProcess.Start()) {
            throw "Could not start $ScriptName."
        }
        $childProcess.WaitForExit()
        $childExitCode = $childProcess.ExitCode
        $childProcess.Dispose()
        if ($childExitCode -ne 0) {
            throw "$ScriptName failed with exit code $childExitCode."
        }
        if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
            throw "$ScriptName did not write required result marker '$ResultMarker'."
        }

        $resultLine = Get-Content -LiteralPath $resultFile -Raw
        if (-not $resultLine.TrimStart().StartsWith($ResultMarker, [StringComparison]::Ordinal)) {
            throw "$ScriptName returned an unexpected result marker. Expected '$ResultMarker'."
        }
        $resultJson = $resultLine.Trim().Substring($ResultMarker.Length)
        $result = $resultJson | ConvertFrom-Json
        if ([string]$result.Status -notin $AllowedStatuses) {
            throw "$ScriptName returned status '$($result.Status)', expected: $($AllowedStatuses -join ', ')."
        }
        return $result
    }
    finally {
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($previousResultFile)) {
            Remove-Item Env:AZURE_MIGRATE_LAB_RESULT_FILE -ErrorAction SilentlyContinue
        }
        else {
            $env:AZURE_MIGRATE_LAB_RESULT_FILE = $previousResultFile
        }
    }
}

function Confirm-ManualCheckpoint {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Instructions,
        [hashtable[]]$Tables = @(),
        [string[]]$Notes = @(),
        [Parameter(Mandatory)][string]$ConfirmationText
    )

    return Confirm-LabCheckpoint `
        -Title $Title `
        -Steps $Instructions `
        -Tables $Tables `
        -Notes $Notes `
        -ConfirmationText $ConfirmationText
}

function Invoke-SetupStep {
    param([Parameter(Mandatory)][string]$StepName)

    switch ($StepName) {
        'DeployInfrastructure' {
            $deploymentArguments = @('-ConfigFile', $configFilePath)
            if (-not [string]::IsNullOrWhiteSpace($SourceLocation)) {
                $deploymentArguments += @('-SourceLocation', $SourceLocation)
            }
            if (-not [string]::IsNullOrWhiteSpace($TargetLocation)) {
                $deploymentArguments += @('-TargetLocation', $TargetLocation)
            }
            if ($ApproveDeployment) {
                $deploymentArguments += '-ApproveDeployment'
            }
            $result = Invoke-LabScript `
                -ScriptName 'deploy-lab.ps1' `
                -ScriptArguments $deploymentArguments `
                -ResultMarker 'AZURE_MIGRATE_DEPLOYMENT_RESULT=' `
                -AllowedStatuses @('Deployed', 'Cancelled')
            if ($result.Status -eq 'Cancelled') {
                Write-Host 'Infrastructure deployment was cancelled before resource creation.' -ForegroundColor Yellow
                return $null
            }
            return "Deployment $($result.DeploymentName) completed."
        }
        'PrepareNestedGuests' {
            $result = Invoke-LabScript `
                -ScriptName 'prepare-hyperv-host.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName) `
                -ResultMarker 'AZURE_MIGRATE_HYPERV_RESULT=' `
                -AllowedStatuses @('AlreadyReady', 'Ready')
            return "Nested guests $($result.WindowsGuestName) ($($result.WindowsGuestIp)) and $($result.LinuxGuestName) ($($result.LinuxGuestIp)) are ready."
        }
        'VerifyProject' {
            $result = Invoke-LabScript `
                -ScriptName 'verify-migrate-project.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName) `
                -ResultMarker 'AZURE_MIGRATE_PROJECT_RESULT=' `
                -AllowedStatuses @('Ready')
            return "Project $($result.ProjectName) is ready."
        }
        'InstallDiscovery' {
            $result = Invoke-LabScript `
                -ScriptName 'install-discovery-appliance.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName) `
                -ResultMarker 'AZURE_MIGRATE_DISCOVERY_RESULT=' `
                -AllowedStatuses @('AlreadyInstalled', 'Installed', 'Repaired')
            return "Discovery appliance status: $($result.Status)."
        }
        'RegisterDiscovery' {
            $confirmed = Confirm-ManualCheckpoint `
                -Title 'Register discovery appliance' `
                -Instructions @(
                    'Azure Migrate: Overview > Inventory > Start discovery > Using appliance > Physical or other.'
                    'Generate a project key using an alphanumeric appliance name of 14 characters or fewer.'
                    'Open Configuration Manager, paste the key, install updates, and complete device-code sign-in.'
                    'Add the two credentials shown below.'
                    'Add the two discovery sources shown below and wait for both validations to pass.'
                    'Select Start discovery and wait for: Discovery has been successfully initiated.'
                ) `
                -Tables @(
                    @{
                        Title = 'Credentials'
                        Rows = @(
                            [pscustomobject]@{ FriendlyName = 'labwindows'; Type = 'Windows Server'; Username = 'labadmin'; Secret = 'Nested guest password from step 2' }
                            [pscustomobject]@{ FriendlyName = 'lablinux'; Type = 'Linux password'; Username = 'labadmin'; Secret = 'Nested guest password from step 2' }
                        )
                    }
                    @{
                        Title = 'Discovery sources'
                        Rows = @(
                            [pscustomobject]@{ OS = 'Windows'; VM = 'source-win01'; PrivateIP = '10.10.3.10'; Credential = 'labwindows' }
                            [pscustomobject]@{ OS = 'Linux'; VM = 'source-linux01'; PrivateIP = '10.10.3.20'; Credential = 'lablinux' }
                        )
                    }
                ) `
                -Notes @(
                    'Friendly names cannot contain hyphens.'
                    'Both nested guests use the one-time password displayed during step 2.'
                    'HTTP 401 from graph.windows.net confirms endpoint reachability; it is not a NAT or firewall failure.'
                ) `
                -ConfirmationText 'DISCOVERY REGISTERED'
            if (-not $confirmed) { return $null }
            $result = Invoke-LabScript `
                -ScriptName 'verify-migrate-project.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName, '-RequireDiscoveryResources') `
                -ResultMarker 'AZURE_MIGRATE_PROJECT_RESULT=' `
                -AllowedStatuses @('Ready')
            return "Discovery resources verified for $($result.ProjectName)."
        }
        'CreateMigrationResources' {
            $configuration = Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json
            $migrationTargetLocation = [string]$configuration.TargetLocation
            $confirmed = Confirm-ManualCheckpoint `
                -Title 'Manual checkpoint: generate replication appliance key' `
                -Instructions @(
                    'In the Azure Migrate project, open Execute > Migrations.'
                    'If prompted, select Enable MSI, wait for completion, and select Reload. Do not switch to the classic experience.'
                    'Select Start execution > Servers or virtual machines (VMs) > Azure VM > From all inventory.'
                    'Select the registered Physical discovery appliance.'
                    'In the red No replication appliance is registered message, select Click here to set up.'
                    "On the replication appliance setup page, verify Target region is $migrationTargetLocation. Stop if it shows another region."
                    'Select Generate key and keep the page open until the key is displayed.'
                    'Copy the key to secure temporary storage; it is pasted into the replication appliance during step 7.'
                ) `
                -ConfirmationText 'MIGRATION KEY GENERATED'
            if (-not $confirmed) { return $null }
            $result = Invoke-LabScript `
                -ScriptName 'verify-migrate-project.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName, '-RequireMigrationResources') `
                -ResultMarker 'AZURE_MIGRATE_PROJECT_RESULT=' `
                -AllowedStatuses @('Ready')
            return "$(@($result.LinkedResourceIds).Count) linked migration resources verified."
        }
        'InstallReplication' {
            $result = Invoke-LabScript `
                -ScriptName 'install-replication-appliance.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName) `
                -ResultMarker 'AZURE_MIGRATE_REPLICATION_RESULT=' `
                -AllowedStatuses @('AlreadyInstalled', 'Installed', 'Repaired', 'InstalledWithWarnings')
            return "Replication appliance status: $($result.Status)."
        }
        'RegisterReplication' {
            $configuration = Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json
            $confirmed = Confirm-ManualCheckpoint `
                -Title 'Manual checkpoint: register replication appliance' `
                -Instructions @(
                    'RDP to the replication VM using the public IP shown in step 6.'
                    'In that RDP session, open https://localhost:44368 in Microsoft Edge.'
                    'Complete the prerequisite and component checks, then select Continue.'
                    'Under Select Replication appliance connectivity, select FQDN. Keep the detected name amig-repl and port 9443, then select Save and Continue.'
                    'Enter a friendly appliance name, paste the replication key generated in step 5, and complete device-code sign-in.'
                    "Verify target subscription $($configuration.TargetSubscriptionId), target region $($configuration.TargetLocation), and the Recovery Services vault created in step 5, then select Continue."
                    'Under Provide Physical server details, add the two replication credentials shown below. These are separate from discovery-appliance credentials.'
                    'Add the two physical servers shown below and wait for both validations to pass. Do not select I will add Physical server details later when completing the full lab.'
                    'Wait until Configuration Manager reports the replication appliance as connected or registered.'
                ) `
                -Tables @(
                    @{
                        Title = 'Appliance connection'
                        Rows = @(
                            [pscustomobject]@{ VM = 'Replication appliance'; LocalURL = 'https://localhost:44368'; PrivateIP = '10.10.1.20'; PrivateURL = 'https://10.10.1.20:44368' }
                        )
                    }
                    @{
                        Title = 'Replication traffic'
                        Rows = @(
                            [pscustomobject]@{ Mode = 'FQDN'; Address = 'amig-repl'; Port = '9443'; SourceSubnet = '10.10.3.0/24 via Hyper-V host' }
                        )
                    }
                    @{
                        Title = 'Why servers are added again'
                        Rows = @(
                            [pscustomobject]@{ Appliance = 'Discovery'; InventoryUse = 'Assessment and sizing'; CredentialUse = 'Guest inventory collection' }
                            [pscustomobject]@{ Appliance = 'Replication'; InventoryUse = 'Migration and replication'; CredentialUse = 'Mobility Service installation' }
                        )
                    }
                    @{
                        Title = 'Replication credentials'
                        Rows = @(
                            [pscustomobject]@{ FriendlyName = 'labwindows'; Type = 'Windows Server'; Username = 'labadmin'; Password = 'Nested guest password from step 2' }
                            [pscustomobject]@{ FriendlyName = 'lablinuxroot'; Type = 'Linux password'; Username = 'root'; Password = 'Nested guest password from step 2' }
                        )
                    }
                    @{
                        Title = 'Physical servers'
                        Rows = @(
                            [pscustomobject]@{ OS = 'Windows'; VM = 'source-win01'; PrivateIP = '10.10.3.10'; Credential = 'labwindows' }
                            [pscustomobject]@{ OS = 'Linux'; VM = 'source-linux01'; PrivateIP = '10.10.3.20'; Credential = 'lablinuxroot' }
                        )
                    }
                ) `
                -Notes @(
                    'Use the localhost URL from inside the replication VM. The private URL is for source-VNet access only.'
                    'The FQDN or NAT IP selection cannot be changed after it is saved. Use FQDN for this lab because the source servers route directly to the appliance on the same VNet.'
                    'Do not select NAT IP. The appliance public IP is for CIDR-restricted RDP only; replication ports 443 and 9443 are not exposed publicly.'
                    'Discovery inventory is reused for assessment selection, but credentials are never copied between appliances. Replication still requires these server entries.'
                    'The Linux root and labadmin passwords match the one-time nested guest password displayed during step 2.'
                    'Friendly names cannot contain hyphens.'
                    'Using one password for Windows and Linux root is a lab-only convenience, not a production practice.'
                    'Do not confirm this checkpoint while a sizing or prerequisite validation error remains.'
                    'After registration, refresh Azure Migrate and open Migration and modernization > Infrastructure servers > Configuration servers. The appliance is not shown in the discovery-appliance inventory.'
                ) `
                -ConfirmationText 'REPLICATION REGISTERED'
            if (-not $confirmed) { return $null }
            $result = Invoke-LabScript `
                -ScriptName 'install-replication-appliance.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName, '-RequireRegistered') `
                -ResultMarker 'AZURE_MIGRATE_REPLICATION_RESULT=' `
                -AllowedStatuses @('AlreadyInstalled', 'Installed', 'Repaired', 'InstalledWithWarnings')
            return "Provider $($result.RegistrationProviderName) is $($result.RegistrationConnectionStatus); fabric health $($result.RegistrationFabricHealth); heartbeat $($result.RegistrationLastHeartbeat)."
        }
        'ValidateLab' {
            $result = Invoke-LabScript `
                -ScriptName 'test-lab.ps1' `
                -ScriptArguments @('-ConfigFile', $configFilePath, '-DeploymentName', $DeploymentName) `
                -ResultMarker 'AZURE_MIGRATE_LAB_TEST_RESULT=' `
                -AllowedStatuses @('Passed')
            return "$($result.PassedChecks) lab checks passed."
        }
        default {
            throw "Unknown setup step '$StepName'."
        }
    }
}

if ($ResetState -and (Test-Path -LiteralPath $stateFilePath -PathType Leaf)) {
    $resetConfirmation = (Read-Host "Type RESET to delete local setup state '$stateFilePath'").Trim()
    if ($resetConfirmation -cne 'RESET') {
        throw 'Setup state reset was not approved.'
    }
    Remove-Item -LiteralPath $stateFilePath -Force
}

$setupState = if (Test-Path -LiteralPath $stateFilePath -PathType Leaf) {
    Get-Content -LiteralPath $stateFilePath -Raw | ConvertFrom-Json
}
else {
    New-SetupState
}

if ($setupState.Version -ne 1) {
    throw "Unsupported setup state version '$($setupState.Version)'."
}
foreach ($step in $stepDefinitions) {
    if ($null -eq $setupState.Steps.PSObject.Properties[$step.Name]) {
        throw "Setup state is missing step '$($step.Name)'. Use -ResetState to recreate it."
    }
}

if ($Status) {
    Show-SetupStatus -SetupState $setupState
    return
}

$startIndex = 0
if (-not [string]::IsNullOrWhiteSpace($FromStep)) {
    $startIndex = [Array]::FindIndex(
        [object[]]$stepDefinitions,
        [Predicate[object]] { param($step) $step.Name -eq $FromStep }
    )
}

for ($index = $startIndex; $index -lt $stepDefinitions.Count; $index++) {
    $step = $stepDefinitions[$index]
    $stepState = $setupState.Steps.PSObject.Properties[$step.Name].Value
    $forceCurrentStep = -not [string]::IsNullOrWhiteSpace($FromStep) -and $index -eq $startIndex
    if ($stepState.Status -eq 'Completed' -and -not $forceCurrentStep) {
        Write-Host "Skipping completed step: $($step.Label)"
        continue
    }

    Write-Host ''
    Write-Host "Step $($index + 1)/$($stepDefinitions.Count): $($step.Label)" -ForegroundColor Cyan
    Set-StepState -SetupState $setupState -StepName $step.Name -StepStatus 'Running'
    try {
        $detail = Invoke-SetupStep -StepName $step.Name
        if ($null -eq $detail) {
            $pauseDetail = if ($step.Name -eq 'DeployInfrastructure') {
                'Deployment was cancelled before resource creation. Rerun setup to review and confirm the preview.'
            }
            else {
                'Resume this checkpoint when the portal or appliance action is complete.'
            }
            Set-StepState `
                -SetupState $setupState `
                -StepName $step.Name `
                -StepStatus 'AwaitingManual' `
                -Detail $pauseDetail
            Write-Host "Setup paused at $($step.Label). Rerun setup-lab.ps1 to resume." -ForegroundColor Yellow
            return
        }
        Set-StepState `
            -SetupState $setupState `
            -StepName $step.Name `
            -StepStatus 'Completed' `
            -Detail $detail
    }
    catch {
        Set-StepState `
            -SetupState $setupState `
            -StepName $step.Name `
            -StepStatus 'Failed' `
            -Detail $_.Exception.Message
        throw
    }
}

Show-SetupStatus -SetupState $setupState
Write-Host 'Azure Migrate lab setup completed.' -ForegroundColor Green
