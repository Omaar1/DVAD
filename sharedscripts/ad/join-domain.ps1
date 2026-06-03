#
# OU is the optional path prefix, e.g. OU=Servers
#
param(
    [string] $ou = "default"
)

# Joins this machine to the domain defined in lab-config.json (optionally into -ou).

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force
$cfg    = Get-LabConfig
$domain = $cfg.domain
$dcIp   = $cfg.hosts.rootdc.ip

Start-PhaseTimer -PhaseName "DOMAIN JOIN ($($domain.fqdn))"

# Idempotency: if already domain-joined, do nothing (lets re-provisioning succeed).
$cs = Get-WmiObject Win32_ComputerSystem
if ($cs.PartOfDomain) {
    Write-Host "Already joined to domain '$($cs.Domain)'. Skipping."
    Stop-PhaseTimer -Status Success
    Show-InstallationSummary
    exit 0
}

Write-Host "Joining domain: $($domain.fqdn)"
Write-Host "Domain controller to be used as DNS: $dcIp"

# Point DNS at the domain controller.
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration
if ($adapters) {
    $adapters | ForEach-Object {
        $r = $_.SetDNSServerSearchOrder($dcIp)
        if ($r.ReturnValue -ne 0) {
            Write-Warning "DNS set failed on NIC '$($_.Description)' (code $($r.ReturnValue))"
        }
    }
}

$securePassword = ConvertTo-SecureString $domain.administratorPassword -AsPlainText -Force
$username = $domain.netbiosName + "\Administrator"
$domainAdminCredentials = New-Object System.Management.Automation.PSCredential($username, $securePassword)
$params = @{}
if ($ou -ne "default") {
    $params["OUPath"] = $ou + "," + $domain.dn
}

Write-Host "Joining computer..."
Add-Computer -DomainName $domain.fqdn -Credential $domainAdminCredentials @params -ErrorAction Stop
Write-Host "Computer joined to $($domain.fqdn)."

Stop-PhaseTimer -Status Success
Show-InstallationSummary
exit 0
