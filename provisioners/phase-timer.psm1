# PhaseTimer Module - Installation Phase Tracking

$script:PhaseStartTime = $null
$script:PhaseNumber = 0
$script:TotalStartTime = $null
$script:PhaseHistory = @()
$script:CurrentPhaseName = ""

function Start-PhaseTimer {
    param([string]$PhaseName)

    if ($null -eq $script:TotalStartTime) {
        $script:TotalStartTime = Get-Date
    }

    $script:PhaseNumber++
    $script:PhaseStartTime = Get-Date
    $script:CurrentPhaseName = $PhaseName
    $StartTimeFormatted = $script:PhaseStartTime.ToString("hh:mm:ss tt")

    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host " PHASE $script:PhaseNumber : $PhaseName" -ForegroundColor Cyan
    Write-Host " Started: $StartTimeFormatted" -ForegroundColor DarkCyan
    Write-Host "================================================================" -ForegroundColor Cyan
}

function Stop-PhaseTimer {
    param([string]$Status = 'Success')

    if ($null -eq $script:PhaseStartTime) { return }

    $PhaseEndTime = Get-Date
    $PhaseDuration = New-TimeSpan -Start $script:PhaseStartTime -End $PhaseEndTime

    $script:PhaseHistory += [PSCustomObject]@{
        Phase = $script:PhaseNumber
        Name = $script:CurrentPhaseName
        StartTime = $script:PhaseStartTime
        Duration = $PhaseDuration
        Status = $Status
    }

    $Color = if ($Status -eq 'Failed') { 'Red' } else { 'Green' }

    Write-Host "`n Phase Complete ($Status) - Time: " -NoNewline -ForegroundColor $Color
    Write-Host "$([int]$PhaseDuration.TotalMinutes)m $($PhaseDuration.Seconds)s" -ForegroundColor White

    $script:PhaseStartTime = $null
}

function Show-ProgressTimer {
    param(
        [string]$Message,
        [ScriptBlock]$ScriptBlock
    )

    Write-Host "   $Message " -NoNewline -ForegroundColor Yellow

    $StartTime = Get-Date
    $Job = Start-Job -ScriptBlock $ScriptBlock

    while ($Job.State -eq 'Running') {
        Start-Sleep -Milliseconds 500
        $Elapsed = New-TimeSpan -Start $StartTime -End (Get-Date)
        Write-Host -NoNewline "." -ForegroundColor DarkGray
    }

    $Result = Receive-Job -Job $Job -Wait
    Remove-Job -Job $Job

    Write-Host " Done." -ForegroundColor Green
    return $Result
}

function Show-InstallationSummary {
    if ($script:PhaseHistory.Count -eq 0) { return }

    $TotalEndTime = Get-Date
    $TotalDuration = New-TimeSpan -Start $script:TotalStartTime -End $TotalEndTime

    Write-Host "`n================================================================" -ForegroundColor Magenta
    Write-Host "              INSTALLATION SUMMARY" -ForegroundColor Magenta
    Write-Host "================================================================" -ForegroundColor Magenta
    Write-Host " Script Started: $($script:TotalStartTime.ToString('hh:mm:ss tt'))" -ForegroundColor White
    Write-Host " Script Ended:   $($TotalEndTime.ToString('hh:mm:ss tt'))" -ForegroundColor White
    Write-Host " Total Duration: $([int]$TotalDuration.TotalMinutes)m $($TotalDuration.Seconds)s" -ForegroundColor White
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray

    foreach ($Phase in $script:PhaseHistory) {
        $Color = if ($Phase.Status -eq 'Failed') { 'Red' } else { 'Green' }
        $StartStr = $Phase.StartTime.ToString('hh:mm:ss tt')
        Write-Host "  Phase $($Phase.Phase): $($Phase.Name)" -ForegroundColor $Color
        Write-Host "    Started: $StartStr | Duration: $([int]$Phase.Duration.TotalMinutes)m $($Phase.Duration.Seconds)s" -ForegroundColor DarkGray
    }
    Write-Host "================================================================" -ForegroundColor Magenta
    Write-Host ""
}

Export-ModuleMember -Function Start-PhaseTimer, Stop-PhaseTimer, Show-ProgressTimer, Show-InstallationSummary
