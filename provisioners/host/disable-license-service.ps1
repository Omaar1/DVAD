Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force
Start-PhaseTimer -PhaseName "DISABLE LICENSE SERVICE"

# Define the path to PsExec executable
$psexecPath = "C:\vagrant\provisioners\host\psexec64.exe"

# Check if PsExec exists
if (Test-Path $psexecPath) {
    Write-Host "PsExec found. Proceeding with execution..." -ForegroundColor Green

    # Run PsExec with the required parameters to disable the service
    $serviceName = "wlms"  # Windows License Monitoring Service short name

    # Disable the service using PsExec
    Start-Process -FilePath $psexecPath -ArgumentList "-s -accepteula cmd.exe /c sc config $serviceName start= disabled" -Verb RunAs -Wait

    # Stop the service if it's currently running
    Start-Process -FilePath $psexecPath -ArgumentList "-s -accepteula  cmd.exe /c sc stop $serviceName" -Verb RunAs -Wait

    Write-Host "Windows License Monitoring Service has been disabled and stopped." -ForegroundColor Green
} else {
    Write-Host "PsExec not found at $psexecPath. Please check the path and try again." -ForegroundColor Red
}

Stop-PhaseTimer -Status Success
Show-InstallationSummary
