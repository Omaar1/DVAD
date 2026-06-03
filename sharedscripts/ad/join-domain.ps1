#
# OU is the optional path prefix, e.g. OU=Servers
#
param(
    [string] $ou = "default"
)

#This script will join the machine to the domain, based on lab-config.json and added to the instructed OU

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1
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
# Domain join must run under a real (interactive/batch) logon token. Over the WinRM
# network token NetJoinDomain fails with 0x57 "The parameter is incorrect" (joining as
# a local admin from the console works). Run the join under the box's local admin via a
# one-shot scheduled task (/rl highest = full token); domain cred passed to Add-Computer.
# 'vagrant'/'vagrant' is the StefanScherer box's built-in local admin (the WinRM user).
$ouArg = ""
if ($ou -ne "default") { $ouArg = " -OUPath `"$ou,$($domain.dn)`"" }

$joinScript = @"
`$sp   = ConvertTo-SecureString '$($domain.administratorPassword)' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('$($domain.netbiosName)\Administrator', `$sp)
Add-Computer -DomainName '$($domain.fqdn)' -Credential `$cred$ouArg -ErrorAction Stop
"@

Write-Host "Joining computer (via local-admin scheduled task)..."
if (Invoke-AsUserTask -Name "JoinDomain" -ScriptContent $joinScript -User "vagrant" -Password "vagrant" -TimeoutSec 180) {
    Write-Host "Computer joined to $($domain.fqdn)."
} else {
    throw "Domain join failed (see JoinDomain task log above)."
}

Stop-PhaseTimer -Status Success
Show-InstallationSummary
exit 0
