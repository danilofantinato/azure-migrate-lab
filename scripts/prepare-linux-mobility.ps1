[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$DeploymentName = 'azure-migrate-lab',
    [ValidatePattern('^\d+\.\d+\.\d+-\d+-azure$')]
    [string]$SupportedKernel = '6.8.0-1041-azure'
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

function Get-RequiredAzureCliValue {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $value = (Invoke-AzureCliText -Arguments $Arguments -FailureMessage $FailureMessage).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw $FailureMessage
    }
    return $value
}

function Wait-LinuxVmAgentReady {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VirtualMachineName,
        [ValidateRange(1, 60)][int]$MaximumAttempts = 30
    )

    foreach ($attempt in 1..$MaximumAttempts) {
        $state = & az vm get-instance-view `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroupName `
            --name $VirtualMachineName `
            --query 'instanceView.vmAgent.statuses[0].displayStatus' `
            --output tsv `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0 -and $state -eq 'Ready') {
            return
        }
        if ($attempt -lt $MaximumAttempts) {
            Start-Sleep -Seconds 10
        }
    }
    throw "The Azure VM Agent for '$VirtualMachineName' did not become ready after restart."
}

function New-LinuxMobilityGuestScript {
    param(
        [Parameter(Mandatory)][ValidateSet('Prepare', 'Verify')][string]$Mode,
        [Parameter(Mandatory)][string]$KernelVersion,
        [Parameter(Mandatory)][string]$PrivateIpAddress,
        [Parameter(Mandatory)][string]$HostName
    )

    $scriptText = @'
#!/bin/bash
set -euo pipefail

MODE='__MODE__'
KERNEL_VERSION='__KERNEL_VERSION__'
PRIVATE_IP='__PRIVATE_IP__'
HOST_NAME='__HOST_NAME__'

if [ "$MODE" = 'Prepare' ]; then
  timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
  PACKAGES=(
    "linux-image-$KERNEL_VERSION"
    "linux-modules-$KERNEL_VERSION"
    "linux-modules-extra-$KERNEL_VERSION"
    "linux-headers-$KERNEL_VERSION"
  )
  apt-get update -qq
  for package in "${PACKAGES[@]}"; do
    candidate=$(apt-cache policy "$package" | awk '/Candidate:/ { print $2 }')
    if [ -z "$candidate" ] || [ "$candidate" = '(none)' ]; then
      echo "Supported kernel package is unavailable: $package" >&2
      exit 1
    fi
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

  fqdn=$(hostname -f 2>/dev/null || true)
  if ! awk -v ip="$PRIVATE_IP" -v host="$HOST_NAME" '
    $1 == ip { for (i = 2; i <= NF; i++) if ($i == host) found = 1 }
    END { exit found ? 0 : 1 }
  ' /etc/hosts; then
    printf '%s %s' "$PRIVATE_IP" "$HOST_NAME" >> /etc/hosts
    if [ -n "$fqdn" ] && [ "$fqdn" != "$HOST_NAME" ]; then
      printf ' %s' "$fqdn" >> /etc/hosts
    fi
    printf '\n' >> /etc/hosts
  fi

  cat > /etc/default/grub.d/99-azure-migrate-lab.cfg <<EOF
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
EOF
  update-grub
  menu_entry="Advanced options for Ubuntu>Ubuntu, with Linux $KERNEL_VERSION"
  if ! grep -Fq "Ubuntu, with Linux $KERNEL_VERSION" /boot/grub/grub.cfg; then
    echo "GRUB entry was not created for $KERNEL_VERSION" >&2
    exit 1
  fi
  grub-set-default "$menu_entry"
fi

current_kernel=$(uname -r)
root_status=$(passwd -S root 2>/dev/null | awk '{ print $2 }')
password_auth=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" { print $2 }')
root_login=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2 }')
sftp_enabled=false
if sshd -T 2>/dev/null | grep -q '^subsystem sftp '; then sftp_enabled=true; fi
host_mapping=false
if awk -v ip="$PRIVATE_IP" -v host="$HOST_NAME" '
  $1 == ip { for (i = 2; i <= NF; i++) if ($i == host) found = 1 }
  END { exit found ? 0 : 1 }
' /etc/hosts; then host_mapping=true; fi
kernel_installed=false
if [ -e "/boot/vmlinuz-$KERNEL_VERSION" ]; then kernel_installed=true; fi

status='Prepared'
if [ "$MODE" = 'Verify' ]; then
  status='Ready'
  if [ "$current_kernel" != "$KERNEL_VERSION" ] ||
     [ "$root_status" != 'P' ] ||
     [ "$password_auth" != 'yes' ] ||
     [ "$root_login" != 'yes' ] ||
     [ "$sftp_enabled" != 'true' ] ||
     [ "$host_mapping" != 'true' ]; then
    status='Failed'
  fi
fi
needs_restart=false
if [ "$current_kernel" != "$KERNEL_VERSION" ]; then needs_restart=true; fi

printf 'AZURE_MIGRATE_LINUX_MOBILITY_RESULT={"Status":"%s","Mode":"%s","CurrentKernel":"%s","ExpectedKernel":"%s","KernelInstalled":%s,"NeedsRestart":%s,"RootPasswordSet":%s,"PasswordAuthentication":"%s","PermitRootLogin":"%s","SftpEnabled":%s,"HostMappingPresent":%s}\n' \
  "$status" "$MODE" "$current_kernel" "$KERNEL_VERSION" "$kernel_installed" "$needs_restart" \
  "$([ "$root_status" = 'P' ] && echo true || echo false)" "$password_auth" "$root_login" "$sftp_enabled" "$host_mapping"

if [ "$status" = 'Failed' ]; then exit 1; fi
'@

    return $scriptText.Replace('__MODE__', $Mode).
        Replace('__KERNEL_VERSION__', $KernelVersion).
        Replace('__PRIVATE_IP__', $PrivateIpAddress).
        Replace('__HOST_NAME__', $HostName)
}

function Invoke-LinuxMobilityGuestCheck {
    param(
        [Parameter(Mandatory)][ValidateSet('Prepare', 'Verify')][string]$Mode,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VirtualMachineName,
        [Parameter(Mandatory)][string]$PrivateIpAddress,
        [Parameter(Mandatory)][string]$KernelVersion
    )

    $temporaryScript = Join-Path $env:TEMP "azure-migrate-linux-mobility-$([Guid]::NewGuid().ToString('N')).sh"
    try {
        $guestScript = New-LinuxMobilityGuestScript `
            -Mode $Mode `
            -KernelVersion $KernelVersion `
            -PrivateIpAddress $PrivateIpAddress `
            -HostName $VirtualMachineName
        Set-Content -LiteralPath $temporaryScript -Value $guestScript -Encoding ascii
        $output = Invoke-AzureCliText @(
            'vm', 'run-command', 'invoke',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--name', $VirtualMachineName,
            '--command-id', 'RunShellScript',
            '--scripts', "@$temporaryScript",
            '--output', 'json',
            '--only-show-errors'
        ) "Linux Mobility prerequisite $Mode failed on '$VirtualMachineName'."
        $response = $output | ConvertFrom-Json
        $message = @($response.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
        $match = [regex]::Match(
            $message,
            '(?m)^\s*AZURE_MIGRATE_LINUX_MOBILITY_RESULT=(?<result>\{[^\r\n]+\})\s*$'
        )
        if (-not $match.Success) {
            throw "Linux Mobility prerequisite $Mode did not return a result.$([Environment]::NewLine)$message"
        }
        return $match.Groups['result'].Value | ConvertFrom-Json
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
$sourceSubscriptionId = [string]$configuration.SourceSubscriptionId
$targetSubscriptionId = [string]$configuration.TargetSubscriptionId
$previousAzureExtensionDirectory = $env:AZURE_EXTENSION_DIR
$isolatedAzureExtensionDirectory = Join-Path $env:TEMP 'azure-migrate-lab-az-extensions'
New-Item -Path $isolatedAzureExtensionDirectory -ItemType Directory -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $isolatedAzureExtensionDirectory

try {
    $sourceResourceGroupId = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--query', 'properties.outputs.sourceResourceGroupId.value',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not resolve the source resource group from deployment '$DeploymentName'."
    $linuxVmName = Get-RequiredAzureCliValue @(
        'deployment', 'sub', 'show',
        '--subscription', $targetSubscriptionId,
        '--name', $DeploymentName,
        '--query', 'properties.outputs.linuxSourceName.value',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not resolve the Linux source VM from deployment '$DeploymentName'."
    $linuxPrivateIp = Get-RequiredAzureCliValue @(
        'vm', 'show',
        '--subscription', $sourceSubscriptionId,
        '--resource-group', ($sourceResourceGroupId -split '/')[-1],
        '--name', $linuxVmName,
        '--show-details',
        '--query', 'privateIps',
        '--output', 'tsv',
        '--only-show-errors'
    ) "Could not resolve the Linux source private IP."
    $sourceResourceGroupName = ($sourceResourceGroupId -split '/')[-1]

    Write-Host "Preparing Linux Mobility prerequisites on $linuxVmName ($linuxPrivateIp)..." -ForegroundColor Cyan
    $prepareResult = Invoke-LinuxMobilityGuestCheck `
        -Mode Prepare `
        -SubscriptionId $sourceSubscriptionId `
        -ResourceGroupName $sourceResourceGroupName `
        -VirtualMachineName $linuxVmName `
        -PrivateIpAddress $linuxPrivateIp `
        -KernelVersion $SupportedKernel

    if ($prepareResult.NeedsRestart) {
        Write-Host "Restarting $linuxVmName to boot supported kernel $SupportedKernel..." -ForegroundColor Cyan
        Invoke-AzureCliText @(
            'vm', 'restart',
            '--subscription', $sourceSubscriptionId,
            '--resource-group', $sourceResourceGroupName,
            '--name', $linuxVmName,
            '--only-show-errors'
        ) "Could not restart Linux source VM '$linuxVmName'." | Out-Null
        Wait-LinuxVmAgentReady `
            -SubscriptionId $sourceSubscriptionId `
            -ResourceGroupName $sourceResourceGroupName `
            -VirtualMachineName $linuxVmName
    }

    $verifyResult = Invoke-LinuxMobilityGuestCheck `
        -Mode Verify `
        -SubscriptionId $sourceSubscriptionId `
        -ResourceGroupName $sourceResourceGroupName `
        -VirtualMachineName $linuxVmName `
        -PrivateIpAddress $linuxPrivateIp `
        -KernelVersion $SupportedKernel
    $resultLine = "AZURE_MIGRATE_LINUX_MOBILITY_RESULT=$($verifyResult | ConvertTo-Json -Compress)"
    Write-Output $resultLine
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_MIGRATE_LAB_RESULT_FILE)) {
        Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE -Value $resultLine -Encoding utf8NoBOM
    }
    Write-Host "Linux Mobility prerequisites ready: kernel $($verifyResult.CurrentKernel), root/SFTP/hostname mapping validated." -ForegroundColor Green
}
finally {
    if ([string]::IsNullOrWhiteSpace($previousAzureExtensionDirectory)) {
        Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_EXTENSION_DIR = $previousAzureExtensionDirectory
    }
}