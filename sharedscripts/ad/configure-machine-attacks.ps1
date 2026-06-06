# configure-machine-attacks.ps1
# Post-join safety net. The machine-dependent attack paths (Chain 6/7) are now
# pre-staged on the DC by prestage-machine-attacks.ps1, and their ACEs/attributes
# survive the domain join. The ONE thing a join can clear is SVR1's
# TRUSTED_FOR_DELEGATION (unconstrained) UAC flag, so re-assert just that here, after
# SVR1 has joined and reused its pre-staged account.
# Called from server1 (SVR1) as the last provisioning step.

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
$cfg      = Get-LabConfig
$username = $cfg.domain.netbiosName + "\Administrator"
$password = $cfg.domain.administratorPassword

. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

Start-PhaseTimer -PhaseName "MACHINE ATTACKS (re-assert SVR1 unconstrained delegation)"

# Ensure RSAT AD module is available (server1 may not have it yet).
if (-not (Get-WindowsFeature RSAT-AD-PowerShell).Installed) {
    Write-Host "[*] Installing RSAT-AD-PowerShell..."
    Install-WindowsFeature -Name RSAT-AD-PowerShell | Out-Null
}

$innerScript = @'
Import-Module ActiveDirectory -ErrorAction Stop
# Re-assert unconstrained delegation in case the domain join cleared the UAC flag.
Set-ADComputer "SVR1" -TrustedForDelegation $true
Write-Host "[6a] SVR1 TrustedForDelegation re-asserted post-join"
'@

Write-Host "[*] Re-asserting SVR1 unconstrained delegation as $username via scheduled task..."
if (Invoke-AsUserTask -Name "MachineAttacks" -ScriptContent $innerScript -User $username -Password $password -TimeoutSec 120) {
    Write-Host "[*] Machine attacks (re-assert) status: SUCCESS"
    Stop-PhaseTimer -Status Success
} else {
    Write-Host "[!] Re-assert failed or timed out" -ForegroundColor Red
    Stop-PhaseTimer -Status Failed
}

Write-Host "[+] configure-machine-attacks.ps1 complete"
Show-InstallationSummary
