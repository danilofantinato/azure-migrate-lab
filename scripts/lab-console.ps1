Set-StrictMode -Version Latest

function Write-LabRule {
    param(
        [char]$Character = '=',
        [ValidateRange(40, 120)][int]$Width = 76,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::DarkCyan
    )

    Write-Host ($Character.ToString() * $Width) -ForegroundColor $ForegroundColor
}

function Write-LabCheckpoint {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Steps,
        [hashtable[]]$Tables = @(),
        [string[]]$Notes = @(),
        [Parameter(Mandatory)][string]$ConfirmationText
    )

    Write-Host ''
    Write-LabRule
    Write-Host " MANUAL CHECKPOINT | $Title" -ForegroundColor Yellow
    Write-LabRule
    Write-Host ''
    Write-Host 'Steps' -ForegroundColor Cyan
    for ($index = 0; $index -lt $Steps.Count; $index++) {
        Write-Host ("  [{0}] {1}" -f ($index + 1), $Steps[$index])
    }

    foreach ($table in $Tables) {
        Write-Host ''
        Write-Host ([string]$table.Title) -ForegroundColor Cyan
        $rows = @($table.Rows)
        if ($rows.Count -gt 0) {
            $tableText = ($rows | Format-Table -AutoSize | Out-String -Width 200).Trim()
            Write-Host $tableText
        }
    }

    if ($Notes.Count -gt 0) {
        Write-Host 'Notes' -ForegroundColor Cyan
        foreach ($note in $Notes) {
            Write-Host "  - $note"
        }
        Write-Host ''
    }

    Write-Host 'Confirmation' -ForegroundColor Cyan
    Write-Host "  Complete: $ConfirmationText" -ForegroundColor Green
    Write-Host '  Pause:    press Enter'
    Write-LabRule -Character '-'
}

function Confirm-LabCheckpoint {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Steps,
        [hashtable[]]$Tables = @(),
        [string[]]$Notes = @(),
        [Parameter(Mandatory)][string]$ConfirmationText
    )

    Write-LabCheckpoint `
        -Title $Title `
        -Steps $Steps `
        -Tables $Tables `
        -Notes $Notes `
        -ConfirmationText $ConfirmationText
    $confirmation = (Read-Host 'Action').Trim()
    return $confirmation -ceq $ConfirmationText
}
