param(
    [string] $zone = "en-US"
)

if (!$zone) {
    $zone = "en-US"
}

Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force
Start-PhaseTimer -PhaseName "BASE OS CONFIGURATION"

#This script is used to setup the base image. We essentially perform the following:
# 1. Set keyboard layout and timezone (Default is UK)
# 3. Create a scheduled task to set the DNS of the system
# 4. Disable password reset dates, which would have caused the VM to break after 3 months.

# set keyboard layout.
# NB you can get the name from the list:
#      [Globalization.CultureInfo]::GetCultures('InstalledWin32Cultures') | Out-GridView
Set-WinUserLanguageList $zone -Force

# set the date format, number format, etc.
Set-Culture $zone

# set the welcome screen culture and keyboard layout.
# NB the .DEFAULT key is for the local SYSTEM account (S-1-5-18).
# New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
# 'Control Panel\International','Keyboard Layout' | ForEach-Object {
#     Remove-Item -Path "HKU:.DEFAULT\$_" -Recurse -Force
#     Copy-Item -Path "HKCU:$_" -Destination "HKU:.DEFAULT\$_" -Recurse -Force
# }

# set the timezone.
# tzutil /l lists all available timezone ids
& $env:windir\system32\tzutil /s "GMT Standard Time"


# disable both firewalls !
Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False

# Apply the deterministic lab NIC policy: identify the domain NIC by lab subnet,
# disable IPv6, set interface metrics, and keep every non-lab (NAT) NIC out of DNS.
# Single source of truth - see configure-network.ps1.
& "C:\vagrant\sharedscripts\networking\configure-network.ps1" -Action Policy

## The old "enable NAT adapter" onstart task was removed as redundant - nothing
## disables the NAT NIC, so there is nothing to re-enable at boot.

# Disable password expiry
net accounts /maxpwage:unlimited

# This is ESSENTIAL to prevent domains from breaking after 3 months!!!
# !!!!!!!!!!!!!!!!!!!! DO NOT REMOVE !!!!!!!!!!!!!!!!!!!!!!!!!
Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name DisablePasswordChange -Value 1

# set the Windows Update service to "disabled"
sc.exe config wuauserv start=disabled
# display the status of the service
sc.exe query wuauserv
# stop the service, in case it is running
sc.exe stop wuauserv
# display the status again, because we're paranoid
sc.exe query wuauserv
# double check it's REALLY disabled - Start value should be 0x4
REG.exe QUERY HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\wuauserv /v Start

Stop-PhaseTimer -Status Success
Show-InstallationSummary 