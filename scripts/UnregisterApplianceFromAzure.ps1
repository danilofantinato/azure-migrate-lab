<#
.SYNOPSIS
    Unregisters THIS Azure Migrate appliance from its Recovery Services vault.

.DESCRIPTION
    Deletes, in order, only the SRS objects belonging to the fabric this
    appliance owns:

        1. Protection container mapping(s) on this appliance's container
        2. Protection container
        3. Recovery Services provider (the DRA hosted on this appliance)
        4. Replication fabric, only if no sibling DRAs remain

    Identifiers are read from the appliance itself (modern Appliance.json with
    legacy registry fallback), or from a minimal context file exported from the
    appliance with Azure VM Run Command. This prevents the script from touching
    another appliance registered to the same vault.

    Prerequisites:
        * Run on the appliance host (or a machine that has the appliance's
          registry hive and Appliance.json copied over).
        * Run `az login` and `az account set --subscription <sub>` beforehand.
        * The signed-in principal must have Contributor on the RS vault RG.
        * Complete or disable replication for every protected machine first.

.PARAMETER Force
    Skip the interactive confirmation prompt.

.PARAMETER KeepFabric
    Do not delete the fabric even when this appliance was the last DRA on it.

.PARAMETER ApplianceJsonPath
    Optional explicit path to Appliance.json. Falls back to the standard
    install location under %ProgramData%\Microsoft Azure\Config.

.PARAMETER ApplianceContextPath
    Optional path to a minimal JSON context exported from Appliance.json. Use
    this to run the control-plane cleanup from an authenticated workstation
    when Azure CLI is not installed on the appliance.

.EXAMPLE
    .\UnregisterApplianceFromAzure.ps1

.EXAMPLE
    .\UnregisterApplianceFromAzure.ps1 -Force -KeepFabric

.EXAMPLE
    .\UnregisterApplianceFromAzure.ps1 -ApplianceContextPath .\appliance-context.json

.NOTES
    Related ICM: 51000001385895 (TenantAlreadyRegisteredInAnotherVault).
    Deleting the container mapping is what fires SRS
    VMwareCbtCloudActionHandlers.BeforeCleanupCloud -> UnregisterRcm ->
    RcmServiceProxy.CbtUnregisterIdentity, which is the piece the vault-delete
    path can miss.
#>

[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $KeepFabric,
    [string] $ApplianceJsonPath,
    [string] $ApplianceContextPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------ Logging --
function Log-Info    ([string]$m) { Write-Host  "[INFO ] $m" -ForegroundColor Cyan }
function Log-Ok      ([string]$m) { Write-Host  "[ OK  ] $m" -ForegroundColor Green }
function Log-Warn    ([string]$m) { Write-Host  "[WARN ] $m" -ForegroundColor Yellow }
function Log-Error   ([string]$m) { Write-Host  "[FAIL ] $m" -ForegroundColor Red }

# ---------------------------------------------------------- Preconditions ----
function Assert-AzCli {
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) { throw "Azure CLI ('az') not found on PATH. Install it and run 'az login' first." }
    $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
    if (-not $acct) { throw "You are not signed in. Run 'az login' (and 'az account set --subscription <id>') first." }
    Log-Info "Signed in as $($acct.user.name) on subscription $($acct.name) [$($acct.id)]."
    return $acct
}

function ConvertFrom-VaultArmId {
    param([Parameter(Mandatory)][string] $VaultArmId)

    $normalizedId = $VaultArmId.Trim().TrimEnd('/')
    $match = [regex]::Match(
        $normalizedId,
        '(?i)^/subscriptions/(?<subscriptionId>[^/]+)/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.RecoveryServices/vaults/(?<vaultName>[^/]+)$'
    )
    $subscriptionId = [guid]::Empty
    if (
        -not $match.Success -or
        -not [guid]::TryParse($match.Groups['subscriptionId'].Value, [ref]$subscriptionId)
    ) {
        throw "VaultArmId '$VaultArmId' is not a Recovery Services vault ARM id."
    }

    return [pscustomobject]@{
        SubscriptionId = $subscriptionId.ToString()
        ResourceGroup  = $match.Groups['resourceGroup'].Value
        VaultName      = $match.Groups['vaultName'].Value
        VaultArmId     = $normalizedId
    }
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $Objects,
        [Parameter(Mandatory)][string[]] $Names
    )

    foreach ($object in $Objects) {
        if ($null -eq $object) {
            continue
        }
        foreach ($name in $Names) {
            $property = $object.PSObject.Properties[$name]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return [string]$property.Value
            }
        }
    }
    return $null
}

# ----------------------------------------------------- Appliance discovery ---
function Read-ApplianceSettings {
    param(
        [string] $JsonPath,
        [string] $ContextPath
    )

    $srsKey = 'HKLM:\SOFTWARE\Microsoft\Azure Site Recovery'
    $reg = if (Test-Path $srsKey) {
        Get-ItemProperty -Path $srsKey
    }
    else {
        $null
    }

    if ($ContextPath) {
        if (-not (Test-Path -LiteralPath $ContextPath -PathType Leaf)) {
            throw "Appliance context file was not found: $ContextPath"
        }
        try {
            $json = Get-Content -Raw -LiteralPath $ContextPath | ConvertFrom-Json
        }
        catch {
            throw "Could not parse appliance context '$ContextPath': $($_.Exception.Message)"
        }
        $JsonPath = $ContextPath
    }
    elseif (-not $JsonPath) {
        $candidates = @(
            (Join-Path $env:ProgramData 'Microsoft Azure\Config\Appliance.json'),
            (Join-Path $env:ProgramData 'Microsoft Azure\Appliance.json')
        )
        $JsonPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        $json = $null
        if ($JsonPath) {
            try {
                $json = Get-Content -Raw -LiteralPath $JsonPath | ConvertFrom-Json
            }
            catch {
                Log-Warn "Could not parse '$JsonPath': $($_.Exception.Message). Continuing with registry values only."
            }
        }
    }
    else {
        try {
            $json = Get-Content -Raw -LiteralPath $JsonPath | ConvertFrom-Json
        }
        catch {
            Log-Warn "Could not parse '$JsonPath': $($_.Exception.Message). Continuing with registry values only."
            $json = $null
        }
    }

    if ($null -eq $json -and $null -eq $reg) {
        throw "Neither Appliance.json nor the legacy registry key '$srsKey' is available."
    }

    $dra = if ($null -ne $json) {
        $property = $json.PSObject.Properties['Dra']
        if ($null -ne $property) { $property.Value } else { $null }
    }
    else {
        $null
    }
    $cloudDetails = if ($null -ne $json) {
        $property = $json.PSObject.Properties['CloudDetails']
        if ($null -ne $property) { $property.Value } else { $null }
    }
    else {
        $null
    }
    $site = if ($null -ne $json) {
        $property = $json.PSObject.Properties['Site']
        if ($null -ne $property) { $property.Value } else { $null }
    }
    else {
        $null
    }

    $vaultArmId = Get-FirstPropertyValue -Objects @($reg, $dra, $json) -Names @('VaultArmId')
    $draName = Get-FirstPropertyValue -Objects @($reg, $json, $dra) -Names @('DraName', 'DraId')
    $fabricId = Get-FirstPropertyValue -Objects @($reg, $dra, $json) -Names @('FabricId')
    $resourceLocation = Get-FirstPropertyValue -Objects @($reg, $dra, $json) -Names @('ResourceLocation', 'Location')
    foreach ($requiredValue in @{
        VaultArmId = $vaultArmId
        DraName = $draName
        FabricId = $fabricId
        ResourceLocation = $resourceLocation
    }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredValue.Value)) {
            throw "Required appliance context value '$($requiredValue.Key)' is missing."
        }
    }

    $vault = ConvertFrom-VaultArmId -VaultArmId $vaultArmId

    [pscustomobject]@{
        SubscriptionId  = $vault.SubscriptionId
        ResourceGroup   = $vault.ResourceGroup
        VaultName       = $vault.VaultName
        VaultArmId      = $vault.VaultArmId
        Location        = $resourceLocation
        DraName         = $draName
        FabricId        = $fabricId
        SrsFabricName   = Get-FirstPropertyValue -Objects @($json, $dra) -Names @('SrsFabricName', 'FabricName')
        SrsContainerName= Get-FirstPropertyValue -Objects @($json, $cloudDetails) -Names @('SrsContainerName', 'ContainerUniqueName')
        SiteName        = Get-FirstPropertyValue -Objects @($json, $site) -Names @('SiteName', 'PhysicalSite')
        AppliancesName  = Get-FirstPropertyValue -Objects @($json) -Names @('AppliancesName', 'MachineName', 'MachineIdentifier')
        JsonPath        = $JsonPath
    }
}

# ---------------------------------------------------------------- ARM I/O ----
$script:ApiVersion = '2024-04-01'   # SRS replication API

function Invoke-Arm {
    param(
        [Parameter(Mandatory)] [ValidateSet('GET','POST','DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [string] $ApiVersion = $script:ApiVersion
    )
    $sep = if ($Path.Contains('?')) { '&' } else { '?' }
    $url = "https://management.azure.com$Path${sep}api-version=$ApiVersion"
    Log-Info "$Method $url"
    $raw = az rest --method $Method --url $url --only-show-errors 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        # az rest surfaces the error JSON on stderr; keep it visible
        throw "ARM $Method failed ($code): $raw"
    }
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return $null }
    try   { return ($raw | Out-String | ConvertFrom-Json) }
    catch { return $raw }
}

function Get-List {
    param([string] $Path)
    $resp = Invoke-Arm -Method GET -Path $Path
    if ($null -eq $resp) { return @() }
    if ($resp.PSObject.Properties.Name -contains 'value') { return @($resp.value) }
    return @($resp)
}

# ----------------------------------------------- Resource resolution helpers -
function Resolve-Fabric {
    param($Ctx)

    $fabrics = @(Get-List "$($Ctx.VaultArmId)/replicationFabrics")
    if (-not $fabrics -or $fabrics.Count -eq 0) {
        throw "No replication fabrics exist under vault '$($Ctx.VaultName)'."
    }

    $match = $null
    # Preferred: internalIdentifier matches the appliance's FabricId GUID.
    foreach ($f in $fabrics) {
        $intId = $null
        if ($f.properties -and $f.properties.internalIdentifier) { $intId = $f.properties.internalIdentifier }
        if ($intId -and ($intId -ieq $Ctx.FabricId)) { $match = $f; break }
    }
    # Fallback: fabric name matches Appliance.json.
    if (-not $match -and $Ctx.SrsFabricName) {
        $match = $fabrics | Where-Object { $_.name -ieq $Ctx.SrsFabricName } | Select-Object -First 1
    }
    if (-not $match) {
        throw ("Could not identify this appliance's fabric under vault '{0}'. " +
               "Registry FabricId='{1}', Appliance.json srsFabricName='{2}'. " +
               "Aborting to avoid touching another appliance's data.") -f `
               $Ctx.VaultName, $Ctx.FabricId, $Ctx.SrsFabricName
    }
    Log-Ok "Matched fabric '$($match.name)' (internalIdentifier=$($match.properties.internalIdentifier))."
    return $match
}

function Resolve-Dra {
    param($Ctx, $Fabric)
    $providers = @(Get-List "$($Fabric.id)/replicationRecoveryServicesProviders")
    $mine = $providers | Where-Object { $_.name -ieq $Ctx.DraName }
    if (-not $mine) {
        Log-Warn "DRA '$($Ctx.DraName)' not found on fabric '$($Fabric.name)'. It may already be deleted."
    }
    return @{ All = @($providers); Mine = $mine }
}

function Resolve-Container {
    param($Ctx, $Fabric)
    $containers = @(Get-List "$($Fabric.id)/replicationProtectionContainers")
    if (-not $containers) { return $null }
    if ($Ctx.SrsContainerName) {
        $named = $containers | Where-Object { $_.name -ieq $Ctx.SrsContainerName } | Select-Object -First 1
        if ($named) { return $named }
    }
    # VMwareCbt appliances get exactly one container per fabric.
    if ($containers.Count -eq 1) { return $containers[0] }
    throw ("Multiple containers under fabric '{0}' and no srsContainerName in Appliance.json. " +
           "Refusing to guess.") -f $Fabric.name
}

function Get-ProtectedItems {
    param($Container)

    if ($null -eq $Container) {
        return @()
    }
    return @(Get-List "$($Container.id)/replicationProtectedItems")
}

function ConvertTo-ArmPath {
    param([Parameter(Mandatory)][string] $ResourceId)

    $match = [regex]::Match($ResourceId, '(?i)/subscriptions/.+$')
    if (-not $match.Success) {
        throw "Resource ID is not an Azure subscription resource ID: $ResourceId"
    }
    return $match.Value
}

# --------------------------------------------------------------- Deletion ----
function Wait-ForArmDelete {
    param([string] $Path, [int] $TimeoutSec = 900)
    # az rest waits for the ARM long-running operation on its own for most PUTs,
    # but DELETEs return 202 + Location header. Poll GET on the resource until 404.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 10
        try {
            $probe = Invoke-Arm -Method GET -Path $Path
            if (-not $probe) { return }
        } catch {
            if ($_.Exception.Message -match '"code"\s*:\s*"ResourceNotFound"' -or
                $_.Exception.Message -match 'ResourceNotFound|NotFound') {
                Log-Ok "Confirmed deleted: $Path"
                return
            }
            throw
        }
    }
    throw "Timed out waiting for DELETE completion on $Path"
}

function Delete-Mapping {
    param($Container, $Mapping)
    $rel = ConvertTo-ArmPath -ResourceId $Mapping.id
    Log-Info "Deleting container mapping '$($Mapping.name)' (fires BeforeCleanupCloud -> UnregisterRcm)."
    Invoke-Arm -Method DELETE -Path $rel | Out-Null
    Wait-ForArmDelete -Path $rel
}

function Delete-Container {
    param($Container)
    $rel = ConvertTo-ArmPath -ResourceId $Container.id
    Log-Info "Deleting protection container '$($Container.name)'."
    Invoke-Arm -Method POST -Path "$rel/remove" | Out-Null
    Wait-ForArmDelete -Path $rel
}

function Delete-Dra {
    param($Dra)
    $rel = ConvertTo-ArmPath -ResourceId $Dra.id
    Log-Info "Deleting recovery services provider (DRA) '$($Dra.name)'."
    Invoke-Arm -Method DELETE -Path $rel | Out-Null
    Wait-ForArmDelete -Path $rel
}

function Delete-Fabric {
    param($Fabric)
    $rel = ConvertTo-ArmPath -ResourceId $Fabric.id
    Log-Info "Deleting replication fabric '$($Fabric.name)'."
    Invoke-Arm -Method DELETE -Path $rel | Out-Null
    Wait-ForArmDelete -Path $rel
}

# ------------------------------------------------------------------- Main ----
$originalSubscriptionId = $null
$scriptExitCode = 0
try {
    $account = Assert-AzCli
    $originalSubscriptionId = [string]$account.id
    $ctx     = Read-ApplianceSettings `
        -JsonPath $ApplianceJsonPath `
        -ContextPath $ApplianceContextPath

    if ($account.id -ne $ctx.SubscriptionId) {
        Log-Warn "Signed-in subscription ($($account.id)) differs from appliance's ($($ctx.SubscriptionId))."
        Log-Warn "Switching az context to the appliance's subscription."
        az account set --subscription $ctx.SubscriptionId --only-show-errors | Out-Null
    }

    Write-Host ""
    Log-Info "Appliance context:"
    $ctx | Format-List | Out-String | Write-Host

    $fabric        = Resolve-Fabric   -Ctx $ctx
    $draInfo       = Resolve-Dra      -Ctx $ctx -Fabric $fabric
    $container     = Resolve-Container -Ctx $ctx -Fabric $fabric

    $mappings = @()
    if ($container) {
        $mappings = @(Get-List "$($container.id)/replicationProtectionContainerMappings")
    }
    $protectedItems = @(Get-ProtectedItems -Container $container)
    if ($protectedItems.Count -gt 0) {
        Log-Warn "This appliance still has $($protectedItems.Count) protected machine(s):"
        foreach ($protectedItem in $protectedItems) {
            $friendlyName = if (
                $protectedItem.properties -and
                -not [string]::IsNullOrWhiteSpace([string]$protectedItem.properties.friendlyName)
            ) {
                [string]$protectedItem.properties.friendlyName
            }
            else {
                [string]$protectedItem.name
            }
            $protectionState = if ($protectedItem.properties) {
                [string]$protectedItem.properties.protectionState
            }
            else {
                'Unknown'
            }
            Write-Host "  - $friendlyName ($protectionState)"
        }
        throw 'Complete or disable replication for every protected machine and wait for the protected items to be removed before unregistering the appliance.'
    }

    Write-Host ""
    Log-Info "Planned deletions (only under fabric '$($fabric.name)'):"
    Write-Host ("  Mappings ({0}):" -f $mappings.Count)
    $mappings | ForEach-Object { Write-Host "    - $($_.name)" }
    if ($container) { Write-Host "  Container:      $($container.name)" }
    if ($draInfo.Mine) { Write-Host "  DRA (this appliance): $($draInfo.Mine.name)" }
    $siblingCount = @(
        $draInfo.All | Where-Object { $_.name -ine $ctx.DraName }
    ).Count
    if ($siblingCount -gt 0) {
        Write-Host "  Fabric:         SKIPPED ($siblingCount sibling DRA(s) present)"
    } elseif ($KeepFabric) {
        Write-Host "  Fabric:         SKIPPED (-KeepFabric)"
    } else {
        Write-Host "  Fabric:         $($fabric.name)"
    }
    Write-Host ""

    if (-not $Force) {
        $ans = Read-Host "Proceed with deletion? Type the vault name '$($ctx.VaultName)' to confirm"
        if ($ans -ne $ctx.VaultName) { Log-Warn "Confirmation mismatch. Aborting."; return }
    }

    # 1. Mappings first — this is the hook that clears the RCM tenant identity.
    foreach ($m in $mappings) { Delete-Mapping -Container $container -Mapping $m }

    # 2. Container
    if ($container) { Delete-Container -Container $container }

    # 3. This appliance's DRA
    if ($draInfo.Mine) { Delete-Dra -Dra $draInfo.Mine }

    # 4. Fabric — only if we were the last DRA and caller didn't opt out.
    if ($siblingCount -eq 0 -and -not $KeepFabric) {
        Delete-Fabric -Fabric $fabric
    } else {
        Log-Info "Leaving fabric '$($fabric.name)' in place."
    }

    Log-Ok "Appliance unregistration completed successfully."
}
catch {
    Log-Error $_.Exception.Message
    $scriptExitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($originalSubscriptionId)) {
        $currentSubscriptionId = az account show --query id --output tsv --only-show-errors 2>$null
        if (
            $LASTEXITCODE -eq 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$currentSubscriptionId) -and
            $currentSubscriptionId -ne $originalSubscriptionId
        ) {
            az account set --subscription $originalSubscriptionId --only-show-errors 2>$null
            if ($LASTEXITCODE -ne 0) {
                Log-Warn "Could not restore the original Azure CLI subscription '$originalSubscriptionId'."
            }
        }
    }
}
if ($scriptExitCode -ne 0) {
    exit $scriptExitCode
}
