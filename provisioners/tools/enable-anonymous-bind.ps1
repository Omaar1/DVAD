# enable-anonymous-bind.ps1
# ------------------------------------------------------------------------------
# Enables anonymous LDAP bind on the domain controller by setting the 7th
# character of dSHeuristics to '2'. Unauthenticated clients can then bind and
# enumerate the directory.
#   Attack: ldapsearch -x -H ldap://10.10.10.100 -b "DC=dvad,DC=lab"
#
# dSHeuristics lives in the Configuration NC, which the plain WinRM provisioner
# token cannot write ("Access is denied"). It is applied under a real domain-admin
# logon token via a one-shot scheduled task (Invoke-AsUserTask), like GMSA/LAPS.
# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

. C:\vagrant\provisioners\get-lab-config.ps1
. C:\vagrant\provisioners\invoke-as-user-task.ps1
Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force

$cfg     = Get-LabConfig
$netbios = $cfg.domain.netbiosName
$adminPw = $cfg.domain.administratorPassword

Import-Module ActiveDirectory -ErrorAction Stop
$domainDN = (Get-ADDomain).DistinguishedName
$dcIp     = $cfg.hosts.rootdc.ip

Start-PhaseTimer -PhaseName "ANONYMOUS LDAP BIND (dSHeuristics)"

# dSHeuristics "0000002001000001":
#   - char 7  = '2' : allow anonymous LDAP bind/operations
#   - char 16 = '1' : dwAdminSDExMask, exclude Account Operators from SDProp so the
#                     Ch2 GenericWrite ACE on r.chen (an Account Operators member) is not
#                     stripped hourly. char 10 = '1' is the required length marker.
$anonScript = @"
. C:\vagrant\provisioners\domain\set-ad-ace.ps1
`$dircfg = [ADSI]"LDAP://CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN"
`$dircfg.put("dSHeuristics", "0000002001000001")
`$dircfg.SetInfo()
Write-Host "dSHeuristics set to 0000002001000001 (anon bind + Account Operators excluded from SDProp)."

# Ch8: anonymous bind alone returns nothing - ANONYMOUS LOGON has no read access by
# default. Grant it GenericRead on the domain head (inherited) so unauthenticated
# clients can enumerate objects and read attributes like 'description'.
`$root    = [ADSI]"LDAP://$domainDN"
`$anonSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-7")
`$rights  = [System.DirectoryServices.ActiveDirectoryRights]::GenericRead
`$allow   = [System.Security.AccessControl.AccessControlType]::Allow
`$inherit = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
`$readAce = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(`$anonSid, `$rights, `$allow, `$inherit)
Add-AdAceIfMissing -DirectoryEntry `$root -Ace `$readAce | Out-Null
Write-Host "ANONYMOUS LOGON granted GenericRead on $domainDN (Ch8)."
"@

if (Invoke-AsUserTask -Name "SetAnonBind" -ScriptContent $anonScript -User "$netbios\Administrator" -Password $adminPw -TimeoutSec 60) {
    Write-Host "[+] dSHeuristics set - anonymous LDAP queries enabled" -ForegroundColor Green
    Write-Host "    Attack: ldapsearch -x -H ldap://$dcIp -b `"$domainDN`""
    Stop-PhaseTimer -Status Success
} else {
    Write-Host "[!] Failed to set dSHeuristics (see SetAnonBind log above)" -ForegroundColor Red
    Stop-PhaseTimer -Status Failed
}

Show-InstallationSummary
