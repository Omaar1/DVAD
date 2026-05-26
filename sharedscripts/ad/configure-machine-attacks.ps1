# configure-machine-attacks.ps1
# Applies attack paths that depend on machine computer objects (SVR1, ADCS).
# Must run AFTER all VMs have joined the domain.
# Called from server1 (SVR1) provisioner as the last provisioning step.

param(
    [string]$ParentdomainVariables
)

$domain   = Get-Content -Raw -Path "C:\vagrant\provision\variables\${ParentdomainVariables}" | ConvertFrom-Json
$username = $domain.netbiosName + "\Administrator"
$password = $domain.administratorPassword

# Ensure RSAT AD module is available (server1 may not have it yet)
if (-not (Get-WindowsFeature RSAT-AD-PowerShell).Installed) {
    Write-Host "[*] Installing RSAT-AD-PowerShell..."
    Install-WindowsFeature -Name RSAT-AD-PowerShell | Out-Null
}

$innerScript = @'
Import-Module ActiveDirectory -ErrorAction Stop

$domainDN  = (Get-ADDomain).DistinguishedName
$domainDNS = (Get-ADDomain).DNSRoot

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
Write-Host "[Chain 6b] Constrained Delegation (svc_web -> CIFS/ROOTDC)" -ForegroundColor Green

Set-ADUser "svc_web" -Add @{
    'msDS-AllowedToDelegateTo' = @(
        "CIFS/ROOTDC.$domainDNS",
        "CIFS/ROOTDC"
    )
}
Set-ADAccountControl -Identity "svc_web" -TrustedToAuthForDelegation $true
Write-Host "  [DELEG] svc_web: Constrained Delegation to CIFS/ROOTDC (protocol transition)" -ForegroundColor Yellow

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
    $acl       = $target.psbase.ObjectSecurity
    $acl.AddAccessRule($ace)
    $target.psbase.CommitChanges()
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
    $acl       = $target.psbase.ObjectSecurity
    $acl.AddAccessRule($ace)
    $target.psbase.CommitChanges()
    Write-Host "  [LAPS] t.brown: AllExtendedRights on SVR1$ set" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Machine Attack Paths Configured" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " 6a: Unconstrained Delegation   SVR1 (TrustedForDelegation)" -ForegroundColor White
Write-Host " 6b: Constrained Delegation     svc_web -> CIFS/ROOTDC (protocol transition)" -ForegroundColor White
Write-Host " 6c: RBCD                       l.garcia GenericWrite on ADCS$" -ForegroundColor White
Write-Host " 7:  LAPS AllExtendedRights     t.brown -> SVR1$ (reads ms-Mcs-AdmPwd)" -ForegroundColor White
'@

$scriptPath = "C:\configure_machine_inner.ps1"
$statusFile = "C:\machine_attacks_status.txt"
$logFile    = "C:\machine_attacks.log"

$innerScript | Out-File -FilePath $scriptPath -Encoding UTF8
Remove-Item $statusFile -Force -ErrorAction SilentlyContinue
Remove-Item $logFile    -Force -ErrorAction SilentlyContinue

$wrapperScript = @"
try {
    & "$scriptPath" *>> "$logFile"
    "SUCCESS" | Out-File "$statusFile"
} catch {
    `$_.Exception.Message | Out-File "$logFile" -Append
    "FAILED" | Out-File "$statusFile"
}
"@
$wrapperScript | Out-File -FilePath "C:\machine_attacks_wrapper.ps1" -Encoding UTF8

Write-Host "[*] Running machine-dependent attack paths as $username via scheduled task..."
schtasks /create /f /tn "MachineAttacks" /sc once /st 00:00 /rl highest /ru $username /rp $password /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\machine_attacks_wrapper.ps1" 2>&1 | Out-Null
schtasks /run /tn "MachineAttacks" 2>&1 | Out-Null

$elapsed = 0
while ($elapsed -lt 180) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    if (Test-Path $statusFile) { break }
    if ($elapsed % 30 -eq 0) { Write-Host "  Still running... ($elapsed seconds)" }
}

if (Test-Path $statusFile) {
    $status = Get-Content $statusFile
    Write-Host "[*] Machine attacks status: $status"
    if (Test-Path $logFile) { Get-Content $logFile }
    if ($status -ne "SUCCESS") {
        Write-Host "[!] Machine attacks configuration failed" -ForegroundColor Red
    }
} else {
    Write-Host "[!] Timed out waiting for machine attacks (180s)" -ForegroundColor Red
}

schtasks /delete /tn "MachineAttacks" /f 2>$null
Remove-Item "C:\machine_attacks_wrapper.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue

Write-Host "[+] configure-machine-attacks.ps1 complete"
