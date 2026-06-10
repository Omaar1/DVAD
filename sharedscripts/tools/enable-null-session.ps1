# enable-null-session.ps1
# ------------------------------------------------------------------------------
# Configures anonymous (null session) SMB access on the domain controller so an
# unauthenticated client can enumerate users/groups/shares over SMB.
#   Attack: enum4linux -a 10.10.10.100
#           rpcclient -U "" -N 10.10.10.100   (then: enumdomusers / queryuser)
#
# On a DC this needs THREE things - the original script only did (1), which is not
# enough for SAMR/LSARPC enumeration on a modern DC:
#   1. LanmanServer\Parameters: allow null-session pipes (srvsvc/samr/lsarpc/...).
#   2. LSA: RestrictAnonymous=0, RestrictAnonymousSAM=0, EveryoneIncludesAnonymous=1.
#   3. ANONYMOUS LOGON (S-1-5-7) in "Pre-Windows 2000 Compatible Access" - this is
#      what actually lets anonymous read user/group objects via SAMR (and LDAP).
#
# The LSA/LanmanServer changes take effect after the DC reboot that follows this
# step in the Vagrantfile.
# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

. C:\vagrant\sharedscripts\get-lab-config.ps1
Import-Module C:\vagrant\sharedscripts\phase-timer.psm1 -Force

$cfg  = Get-LabConfig
$dcIp = $cfg.hosts.rootdc.ip

Start-PhaseTimer -PhaseName "NULL SESSION / ANONYMOUS SMB"

# 1. LanmanServer null-session pipes
$srvParams = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
Set-ItemProperty -Path $srvParams -Name "RestrictNullSessAccess" -Value 0 -Type DWord
Set-ItemProperty -Path $srvParams -Name "NullSessionPipes" -Value @("srvsvc","samr","wkssvc","browser","lsarpc","netlogon") -Type MultiString
Write-Host "[+] LanmanServer: RestrictNullSessAccess=0, null-session pipes set" -ForegroundColor Green

# 2. LSA anonymous policy
$lsa = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
Set-ItemProperty -Path $lsa -Name "RestrictAnonymous" -Value 0 -Type DWord
Set-ItemProperty -Path $lsa -Name "RestrictAnonymousSAM" -Value 0 -Type DWord
Set-ItemProperty -Path $lsa -Name "EveryoneIncludesAnonymous" -Value 1 -Type DWord
Write-Host "[+] LSA: RestrictAnonymous=0, RestrictAnonymousSAM=0, EveryoneIncludesAnonymous=1" -ForegroundColor Green

# 3. Add ANONYMOUS LOGON to 'Pre-Windows 2000 Compatible Access'. This group lives in
#    the Domain NC (CN=Builtin), which the provisioner token can write - the same
#    place the other Add-ADGroupMember calls in this lab succeed. The <SID=...> bind
#    path resolves the well-known principal and auto-creates its FSP.
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $domainDN = (Get-ADDomain).DistinguishedName
    $grp = [ADSI]"LDAP://CN=Pre-Windows 2000 Compatible Access,CN=Builtin,$domainDN"
    $grp.Add("LDAP://<SID=S-1-5-7>")
    Write-Host "[+] ANONYMOUS LOGON added to 'Pre-Windows 2000 Compatible Access'" -ForegroundColor Green
} catch {
    if ("$_" -match "already a member|object already exists") {
        Write-Host "[*] ANONYMOUS LOGON already in 'Pre-Windows 2000 Compatible Access'" -ForegroundColor DarkGray
    } else {
        Write-Host "[!] Could not add ANONYMOUS LOGON to 'Pre-Windows 2000 Compatible Access': $_" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "    Attack: enum4linux -a $dcIp"
Write-Host "            rpcclient -U `"`" -N $dcIp"

Stop-PhaseTimer -Status Success
Show-InstallationSummary
