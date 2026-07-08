# configure-machine-attacks.ps1
# Post-join safety net. The machine-dependent attack paths (Chain 6/7) are now
# pre-staged on the DC by prestage-machine-attacks.ps1, and their ACEs/attributes
# survive the domain join. The ONE thing a join can clear is the member server's
# TRUSTED_FOR_DELEGATION (unconstrained) UAC flag, so re-assert just that here, after
# the member server has joined and reused its pre-staged account.
# Called from the member server (hosts.svr1) as the last provisioning step.

. C:\vagrant\provisioners\get-lab-config.ps1
$cfg      = Get-LabConfig
$username = $cfg.domain.netbiosName + "\Administrator"
$password = $cfg.domain.administratorPassword
$svr1Name = $cfg.hosts.svr1.name

. C:\vagrant\provisioners\invoke-as-user-task.ps1
Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force

Start-PhaseTimer -PhaseName "MACHINE ATTACKS (re-assert $svr1Name unconstrained delegation)"

# Ensure RSAT AD module is available (server1 may not have it yet).
if (-not (Get-WindowsFeature RSAT-AD-PowerShell).Installed) {
    Write-Host "[*] Installing RSAT-AD-PowerShell..."
    Install-WindowsFeature -Name RSAT-AD-PowerShell | Out-Null
}

$innerScript = @'
Import-Module ActiveDirectory -ErrorAction Stop
# Re-assert unconstrained delegation in case the domain join cleared the UAC flag.
Set-ADComputer "__SVR1__" -TrustedForDelegation $true
Write-Host "[6a] __SVR1__ TrustedForDelegation re-asserted post-join"
'@

# Inject the real hostname from lab-config.json into the literal here-string.
$innerScript = $innerScript -replace '__SVR1__', $svr1Name

Write-Host "[*] Re-asserting $svr1Name unconstrained delegation as $username via scheduled task..."
if (Invoke-AsUserTask -Name "MachineAttacks" -ScriptContent $innerScript -User $username -Password $password -TimeoutSec 120) {
    Write-Host "[*] Machine attacks (re-assert) status: SUCCESS"
    Stop-PhaseTimer -Status Success
} else {
    Write-Host "[!] Re-assert failed or timed out" -ForegroundColor Red
    Stop-PhaseTimer -Status Failed
}

Write-Host "[+] configure-machine-attacks.ps1 complete"
Show-InstallationSummary
