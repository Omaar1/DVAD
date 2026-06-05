# anonBind.ps1
# ------------------------------------------------------------------------------
# Enables anonymous LDAP bind on the domain controller by setting the 7th
# character of dSHeuristics to '2'. Unauthenticated clients can then bind and
# enumerate the directory.
#   Attack: ldapsearch -x -H ldap://10.10.10.100 -b "DC=silent,DC=run"
#
# dSHeuristics lives in the Configuration NC, which the plain WinRM provisioner
# token cannot write ("Access is denied"). It is applied under a real domain-admin
# logon token via a one-shot scheduled task (Invoke-AsUserTask), like GMSA/LAPS.
# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

$cfg     = Get-LabConfig
$netbios = $cfg.domain.netbiosName
$adminPw = $cfg.domain.administratorPassword

Import-Module ActiveDirectory -ErrorAction Stop
$domainDN = (Get-ADDomain).DistinguishedName
$dcIp     = $cfg.hosts.rootdc.ip

Start-PhaseTimer -PhaseName "ANONYMOUS LDAP BIND (dSHeuristics)"

# 7th character of dSHeuristics = '2' allows anonymous LDAP bind/operations.
$anonScript = @"
`$dircfg = [ADSI]"LDAP://CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN"
`$dircfg.put("dSHeuristics", "0000002")
`$dircfg.SetInfo()
Write-Host "dSHeuristics set to 0000002 (anonymous LDAP bind enabled)."
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
