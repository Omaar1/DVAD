# anonBind.ps1
# Enables anonymous LDAP bind on the domain controller via dSHeuristics.
# Attack: unauthenticated LDAP queries to enumerate AD objects (users, groups, computers).
# Tool: ldapsearch -x -H ldap://10.10.10.100 -b "DC=silent,DC=run"

Import-Module ActiveDirectory -ErrorAction Stop

$domainDN = (Get-ADDomain).DistinguishedName

Write-Host "[*] Configuring anonymous LDAP bind (dSHeuristics)..." -ForegroundColor Cyan

$dircfgDN = "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN"
try {
    $dircfg = [ADSI]"LDAP://$dircfgDN"
    $dircfg.put("dSHeuristics", "0000002")
    $dircfg.SetInfo()
    Write-Host "[+] dSHeuristics set to '0000002' — anonymous LDAP queries enabled" -ForegroundColor Green
    Write-Host "    Attack: ldapsearch -x -H ldap://10.10.10.100 -b 'DC=silent,DC=run'"
} catch {
    Write-Host "[!] Failed to set dSHeuristics: $_" -ForegroundColor Red
}
