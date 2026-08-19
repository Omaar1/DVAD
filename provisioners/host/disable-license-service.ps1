Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force
Start-PhaseTimer -PhaseName "DISABLE LICENSE SERVICE"

# Resolve PsExec from the host-side cache, falling back to the in-repo copy.
. C:\vagrant\provisioners\get-lab-payload.ps1
$psexecPath = Get-LabPayload -Id psexec

# Check if PsExec exists
if ($psexecPath -and (Test-Path $psexecPath)) {
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
