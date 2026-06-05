# configure-machine-attacks.ps1
# Applies attack paths that depend on machine computer objects (SVR1, ADCS).
# Must run AFTER all VMs have joined the domain.
# Called from server1 (SVR1) provisioner as the last provisioning step.

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
$cfg      = Get-LabConfig
$domain   = $cfg.domain
$username = $domain.netbiosName + "\Administrator"
$password = $domain.administratorPassword

. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

Start-PhaseTimer -PhaseName "MACHINE ATTACK PATHS (delegation, RBCD, LAPS)"

# Ensure RSAT AD module is available (server1 may not have it yet)
if (-not (Get-WindowsFeature RSAT-AD-PowerShell).Installed) {
    Write-Host "[*] Installing RSAT-AD-PowerShell..."
    Install-WindowsFeature -Name RSAT-AD-PowerShell | Out-Null
}

$innerScript = @'
Import-Module ActiveDirectory -ErrorAction Stop
. C:\vagrant\sharedscripts\ad\Set-AdAce.ps1

$domainDN  = (Get-ADDomain).DistinguishedName
$domainDNS = (Get-ADDomain).DNSRoot
$dcHost    = (Get-ADDomain).PDCEmulator      # e.g. ROOTDC.silent.run
$dcShort   = $dcHost.Split('.')[0]           # e.g. ROOTDC

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Configuring Machine-Dependent Attack Paths" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# ============================================================================
# CHAIN 6a: Unconstrained Delegation on SVR1
# Any user authenticating to SVR1 has their TGT cached in memory.
# Attacker with local admin on SVR1 can extract TGTs (e.g., printer bug / coercion).
# ============================================================================
Write-Host ""
Write-Host "[Chain 6a] Unconstrained Delegation on SVR1" -ForegroundColor Green

$svr1 = Get-ADComputer "SVR1" -ErrorAction SilentlyContinue
if ($svr1) {
    Set-ADComputer "SVR1" -TrustedForDelegation $true
    Write-Host "  [DELEG] SVR1: TrustedForDelegation = ENABLED" -ForegroundColor Yellow
} else {
    Write-Host "  [WARN] SVR1 computer object not found" -ForegroundColor Red
}

# ============================================================================
# CHAIN 6b: Constrained Delegation with Protocol Transition on svc_web
# svc_web can delegate to CIFS/ROOTDC using any auth protocol (S4U2Self).
# ============================================================================
Write-Host ""
Write-Host "[Chain 6b] Constrained Delegation (svc_web -> CIFS/$dcShort)" -ForegroundColor Green

Set-ADUser "svc_web" -Add @{
    'msDS-AllowedToDelegateTo' = @(
        "CIFS/$dcHost",
        "CIFS/$dcShort"
    )
}
Set-ADAccountControl -Identity "svc_web" -TrustedToAuthForDelegation $true
Write-Host "  [DELEG] svc_web: Constrained Delegation to CIFS/$dcShort (protocol transition)" -ForegroundColor Yellow

# ============================================================================
# CHAIN 6c: RBCD — l.garcia has GenericWrite on ADCS computer object
# Allows attacker to write msDS-AllowedToActOnBehalfOfOtherIdentity on ADCS.
# ============================================================================
Write-Host ""
Write-Host "[Chain 6c] RBCD — l.garcia GenericWrite on ADCS$" -ForegroundColor Green

$adcsComputer = Get-ADComputer "ADCS" -ErrorAction SilentlyContinue
if ($adcsComputer) {
    $adcsDN    = $adcsComputer.DistinguishedName
    $principal = New-Object System.Security.Principal.NTAccount($domainDNS, "l.garcia")
    $sid       = $principal.Translate([System.Security.Principal.SecurityIdentifier])
    $allow     = [System.Security.AccessControl.AccessControlType]::Allow
    $rights    = [System.DirectoryServices.ActiveDirectoryRights]::GenericWrite
    $ace       = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $rights, $allow)
    $target    = [ADSI]"LDAP://$adcsDN"
    Add-AdAceIfMissing -DirectoryEntry $target -Ace $ace | Out-Null
    Write-Host "  [RBCD] l.garcia: GenericWrite on ADCS$ (can configure RBCD)" -ForegroundColor Yellow
} else {
    Write-Host "  [WARN] ADCS computer object not found" -ForegroundColor Red
}

# ============================================================================
# CHAIN 7: AllExtendedRights -> LAPS (t.brown -> SVR1$)
# Set AllExtendedRights on SVR1 computer object for t.brown.
# This allows reading ms-Mcs-AdmPwd (LAPS local admin password).
# ============================================================================
Write-Host ""
Write-Host "[Chain 7] AllExtendedRights on SVR1$ for t.brown (LAPS)" -ForegroundColor Green

if ($svr1) {
    $principal = New-Object System.Security.Principal.NTAccount($domainDNS, "t.brown")
    $sid       = $principal.Translate([System.Security.Principal.SecurityIdentifier])
    $allow     = [System.Security.AccessControl.AccessControlType]::Allow
    $guidAll   = [GUID]'00000000-0000-0000-0000-000000000000'
    $ace       = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
        $allow,
        $guidAll
    )
    $target    = [ADSI]"LDAP://$($svr1.DistinguishedName)"
    Add-AdAceIfMissing -DirectoryEntry $target -Ace $ace | Out-Null
    Write-Host "  [LAPS] t.brown: AllExtendedRights on SVR1$ set" -ForegroundColor Yellow

    # Plant a known LAPS password on SVR1 so the attack is demonstrable without
    # deploying the LAPS client. ms-Mcs-AdmPwd is confidential; t.brown's
    # AllExtendedRights (above) is what allows reading it. The schema attribute
    # was registered earlier on the DC by install-laps-schema.ps1.
    Set-ADComputer "SVR1" -Replace @{ "ms-Mcs-AdmPwd" = "L@ps#R4ndom2025!" } -ErrorAction SilentlyContinue
    Write-Host "  [LAPS] SVR1 ms-Mcs-AdmPwd value planted" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Machine Attack Paths Configured" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " 6a: Unconstrained Delegation   SVR1 (TrustedForDelegation)" -ForegroundColor White
Write-Host " 6b: Constrained Delegation     svc_web -> CIFS/$dcShort (protocol transition)" -ForegroundColor White
Write-Host " 6c: RBCD                       l.garcia GenericWrite on ADCS$" -ForegroundColor White
Write-Host " 7:  LAPS AllExtendedRights     t.brown -> SVR1$ (reads ms-Mcs-AdmPwd)" -ForegroundColor White
'@

Write-Host "[*] Running machine-dependent attack paths as $username via scheduled task..."
if (Invoke-AsUserTask -Name "MachineAttacks" -ScriptContent $innerScript -User $username -Password $password -TimeoutSec 180) {
    Write-Host "[*] Machine attacks status: SUCCESS"
} else {
    Write-Host "[!] Machine attacks configuration failed or timed out" -ForegroundColor Red
}

Write-Host "[+] configure-machine-attacks.ps1 complete"

Stop-PhaseTimer -Status Success
Show-InstallationSummary
