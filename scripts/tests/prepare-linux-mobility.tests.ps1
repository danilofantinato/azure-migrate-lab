[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\prepare-linux-mobility.ps1')).Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "prepare-linux-mobility.ps1 has parse errors: $($parseErrors -join '; ')"
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($requiredText in @(
    "[string]`$SupportedKernel = '6.8.0-1041-azure'"
    'function New-LinuxMobilityGuestScript'
    'function Invoke-LinuxMobilityGuestCheck'
    'function Wait-LinuxVmAgentReady'
    'linux-image-$KERNEL_VERSION'
    'linux-modules-$KERNEL_VERSION'
    'linux-modules-extra-$KERNEL_VERSION'
    'linux-headers-$KERNEL_VERSION'
    '/etc/default/grub.d/99-azure-migrate-lab.cfg'
    'grub-set-default "$menu_entry"'
    '/etc/hosts'
    'AZURE_MIGRATE_LINUX_MOBILITY_RESULT='
    "'vm', 'restart'"
    'Set-Content -LiteralPath $env:AZURE_MIGRATE_LAB_RESULT_FILE'
)) {
    if (-not $scriptText.Contains($requiredText)) {
        throw "Linux Mobility preparation behavior is missing: $requiredText"
    }
}

foreach ($forbiddenText in '\$adminPassword\b', '\$rootPassword\b', '\$credentialPassword\b') {
    if ($scriptText -match $forbiddenText) {
        throw "Linux Mobility preparation must not accept or embed a secret: $forbiddenText"
    }
}

Write-Host 'prepare-linux-mobility tests passed.' -ForegroundColor Green