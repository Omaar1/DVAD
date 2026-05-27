param(
    [string] $zone = "en-US"
)

if (!$zone) {
    $zone = "en-US"
}

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

# Detect NICs by ifIndex order. Vagrant attaches NAT first, private_network second.
$nics = Get-NetAdapter | Where-Object Status -ne 'Disabled' | Sort-Object ifIndex
$natName    = $nics[0].Name
$domainName = $nics[1].Name
Write-Host "NAT adapter: $natName"
Write-Host "Domain adapter: $domainName"

## enabale NAT adapter on startUp
schtasks /create /f /tn "enable NAT adapter" /sc onstart /delay 0000:30 /rl highest /ru system /tr "powershell.exe netsh interface set interface '$natName' enable"

# Disable password expiry
net accounts /maxpwage:unlimited

# This is ESSENTIAL to prevent domains from breaking after 3 months!!!
# !!!!!!!!!!!!!!!!!!!! DO NOT REMOVE !!!!!!!!!!!!!!!!!!!!!!!!!
Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name DisablePasswordChange -Value 1

# Add networ metrics very important !!  !!!!!!!!!!!!!!!!!!!
Set-NetIPInterface -InterfaceAlias $domainName -InterfaceMetric 5
Set-NetIPInterface -InterfaceAlias $natName    -InterfaceMetric 55

# Configure network adapters for optimal DNS and domain operation
# Disable IPv6 on all interfaces
Get-NetAdapter | ForEach-Object {
    Set-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID 'ms_tcpip6' -Enabled $false
}

# Disable dynamic DNS registration on NAT interface
$natAdapter = Get-NetAdapter -Name $natName
if ($natAdapter) {
    Set-DnsClient -InterfaceIndex $natAdapter.ifIndex -RegisterThisConnectionsAddress $false
}

# Enable DNS registration on domain interface
$domainAdapter = Get-NetAdapter -Name $domainName
if ($domainAdapter) {
    Set-DnsClient -InterfaceIndex $domainAdapter.ifIndex -RegisterThisConnectionsAddress $true
}

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