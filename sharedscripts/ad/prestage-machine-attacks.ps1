# prestage-machine-attacks.ps1
# Pre-stages the SVR1 and ADCS computer accounts in AD and applies all machine-dependent
# attack paths (Chain 6 delegation/RBCD, Chain 7 LAPS) up front during the RootDC phase,
# before the real machines exist. The machines later JOIN and reuse these pre-staged
# accounts (Add-Computer with Domain Admin creds); the ACEs / attributes set here survive
# the join. Only the unconstrained-delegation UAC flag can be cleared by a join, so
# configure-machine-attacks.ps1 re-asserts just that on SVR1 after it joins.

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

$cfg      = Get-LabConfig
$username = $cfg.domain.netbiosName + "\Administrator"
$password = $cfg.domain.administratorPassword

Start-PhaseTimer -PhaseName "PRE-STAGE MACHINE ATTACKS (SVR1/ADCS delegation, RBCD, LAPS)"

$innerScript = @'
Import-Module ActiveDirectory -ErrorAction Stop
. C:\vagrant\sharedscripts\ad\Set-AdAce.ps1

$domainDN  = (Get-ADDomain).DistinguishedName
$domainDNS = (Get-ADDomain).DNSRoot
$dcHost    = (Get-ADDomain).PDCEmulator
$dcShort   = $dcHost.Split('.')[0]

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Pre-staging machine accounts + attack paths" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Pre-create SVR1$ and ADCS$ in the default Computers container. The real machines
# join later with Domain Admin creds and reuse these accounts.
foreach ($m in @("SVR1","ADCS")) {
    if (-not (Get-ADComputer -Filter "Name -eq '$m'" -ErrorAction SilentlyContinue)) {
        New-ADComputer -Name $m -Path "CN=Computers,$domainDN" -Enabled $true
        Write-Host "  [PRESTAGE] Created computer account $m`$" -ForegroundColor Yellow
    } else {
        Write-Host "  [PRESTAGE] $m`$ already exists" -ForegroundColor DarkGray
    }
}

$svr1 = Get-ADComputer "SVR1"
$adcs = Get-ADComputer "ADCS"
$allow = [System.Security.AccessControl.AccessControlType]::Allow

# 6a: Unconstrained delegation on SVR1 (UAC flag - re-asserted post-join).
Set-ADComputer "SVR1" -TrustedForDelegation $true
Write-Host "  [6a] SVR1: TrustedForDelegation = ENABLED" -ForegroundColor Yellow

# 6b: Constrained delegation w/ protocol transition on svc_web (a user - no host needed).
Set-ADUser "svc_web" -Replace @{ 'msDS-AllowedToDelegateTo' = @("CIFS/$dcHost", "CIFS/$dcShort") }
Set-ADAccountControl -Identity "svc_web" -TrustedToAuthForDelegation $true
Write-Host "  [6b] svc_web: Constrained delegation to CIFS/$dcShort (protocol transition)" -ForegroundColor Yellow

# 6c: RBCD - l.garcia GenericWrite on ADCS$ (ACE survives the join).
$gSid = (New-Object System.Security.Principal.NTAccount($domainDNS, "l.garcia")).Translate([System.Security.Principal.SecurityIdentifier])
$gAce = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($gSid, [System.DirectoryServices.ActiveDirectoryRights]::GenericWrite, $allow)
Add-AdAceIfMissing -DirectoryEntry ([ADSI]"LDAP://$($adcs.DistinguishedName)") -Ace $gAce | Out-Null
Write-Host "  [6c] l.garcia: GenericWrite on ADCS$ (RBCD)" -ForegroundColor Yellow

# 7: AllExtendedRights t.brown on SVR1$ (ACE) + planted LAPS value (attribute). Both
# survive the join. LAPS schema was extended earlier by install-laps-schema.ps1.
$tSid = (New-Object System.Security.Principal.NTAccount($domainDNS, "t.brown")).Translate([System.Security.Principal.SecurityIdentifier])
$guidAll = [GUID]'00000000-0000-0000-0000-000000000000'
$tAce = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($tSid, [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight, $allow, $guidAll)
Add-AdAceIfMissing -DirectoryEntry ([ADSI]"LDAP://$($svr1.DistinguishedName)") -Ace $tAce | Out-Null
Set-ADComputer "SVR1" -Replace @{ "ms-Mcs-AdmPwd" = "L@ps#R4ndom2025!" } -ErrorAction SilentlyContinue
Write-Host "  [7]  t.brown: AllExtendedRights on SVR1$ + ms-Mcs-AdmPwd planted" -ForegroundColor Yellow

Write-Host "[+] Pre-staged machine attack paths complete" -ForegroundColor Green
'@

if (Invoke-AsUserTask -Name "PrestageMachineAttacks" -ScriptContent $innerScript -User $username -Password $password -TimeoutSec 180) {
    Write-Host "[*] Pre-stage machine attacks: SUCCESS"
    Stop-PhaseTimer -Status Success
} else {
    Write-Host "[!] Pre-stage machine attacks failed or timed out" -ForegroundColor Red
    Stop-PhaseTimer -Status Failed
}

Show-InstallationSummary
