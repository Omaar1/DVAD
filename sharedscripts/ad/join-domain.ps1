#
# OU is the optional path prefix, e.g. OU=Servers
#
param(
    [string] $ou = "default"
)

#This script will join the machine to the domain, based on lab-config.json and added to the instructed OU

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force
$cfg    = Get-LabConfig
$domain = $cfg.domain
$dcIp   = $cfg.hosts.rootdc.ip
Start-PhaseTimer -PhaseName "DOMAIN JOIN ($($domain.netbiosName))"
write-Host "Joining domain: $($domain.fqdn)"
write-Host "Domain controller to be used as DNS: $dcIp"
echo "Pointing DNS"
# Point DNS at domain controller
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration
if ($adapters) {
    $adapters | ForEach-Object {
        $r = $_.SetDNSServerSearchOrder($dcIp)
        if ($r.ReturnValue -ne 0) {
            Write-Warning "DNS set failed on NIC '$($_.Description)' (code $($r.ReturnValue))"
        }
    }
}
echo "Creating account"
$securePassword = ConvertTo-SecureString $domain.administratorPassword -AsPlainText -Force
$username = $domain.netbiosName + "\Administrator" 
$domainAdminCredentials = New-Object System.Management.Automation.PSCredential($username, $securePassword)
$params = @{}
if ($ou -ne "default") {
    $params["OUPath"] = $ou + "," + $domain.dn
}
echo "Joining computer"
# Join by DNS FQDN, not the NetBIOS short name. NetJoinDomain rejects a flat name
# when the DC is located via DNS (returns 0x57 "The parameter is incorrect").
Add-Computer -DomainName $domain.fqdn -Credential $domainAdminCredentials @params
echo "Computer Joined"

Stop-PhaseTimer -Status Success
Show-InstallationSummary
exit 0
