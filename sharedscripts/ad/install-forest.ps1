param(
    [string] $forestVariables
)

# ==============================================================================
# Script: install-forest.ps1
# Purpose: Install AD Forest (Root Domain Controller) with Phase Timing
# ==============================================================================

$ErrorActionPreference = "Stop"

# Import Phase Timer Module
Import-Module "$PSScriptRoot\PhaseTimer.psm1" -Force

#This script promotes the Windows Server to a domain controller and will start the installation of a forest.
$forest = Get-Content -Raw -Path "C:\vagrant\provision\variables\${forestVariables}" | ConvertFrom-Json
$domain = Get-Content -Raw -Path "C:\vagrant\provision\variables\domain-variables.json" | ConvertFrom-Json

# ==============================================================================
# PHASE 1: Network Adapter Configuration
# ==============================================================================
Start-PhaseTimer -PhaseName "NETWORK ADAPTER CONFIGURATION"

# Configure network adapter for optimal DNS operation
$ip = (Get-NetAdapter -Name "Ethernet 2" | Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' }).IPAddress
Write-Host " [INFO] IP Address: $ip" -ForegroundColor Yellow

# Disable IPv6 on the domain interface
Set-NetAdapterBinding -InterfaceAlias "Ethernet 2" -ComponentID 'ms_tcpip6' -Enabled $false
Write-Host " [OK] IPv6 disabled on Ethernet 2" -ForegroundColor Green

# Configure DNS client settings
$adapter = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPAddress -contains $ip }
if ($adapter) {
    # Clear any existing DNS servers
    $adapter.SetDNSServerSearchOrder(@())
    Write-Host " [OK] DNS servers cleared" -ForegroundColor Green
}

Stop-PhaseTimer -Status Success

# ==============================================================================
# PHASE 2: Administrator Account Configuration
# ==============================================================================
Start-PhaseTimer -PhaseName "ADMINISTRATOR ACCOUNT SETUP"

Write-Host ' Resetting the Administrator account password and settings...'
$localAdminPassword = ConvertTo-SecureString $forest.administratorPassword -AsPlainText -Force
Set-LocalUser `
    -Name Administrator `
    -AccountNeverExpires `
    -Password $localAdminPassword `
    -PasswordNeverExpires:$true `
    -UserMayChangePassword:$true
Write-Host " [OK] Administrator password configured" -ForegroundColor Green

Stop-PhaseTimer -Status Success

# ==============================================================================
# PHASE 3: AD Services Installation
# ==============================================================================
Start-PhaseTimer -PhaseName "AD SERVICES INSTALLATION"

Write-Host ' Installing the AD services and administration tools...'
Install-WindowsFeature AD-Domain-Services,RSAT-AD-AdminCenter,RSAT-ADDS-Tools
Write-Host " [OK] AD-Domain-Services installed" -ForegroundColor Green

Stop-PhaseTimer -Status Success

# ==============================================================================
# PHASE 4: DNS Server Configuration
# ==============================================================================
Start-PhaseTimer -PhaseName "DNS SERVER CONFIGURATION"

Write-Host ' Configuring DNS Server settings...'
if (Get-WindowsFeature -Name DNS | Where-Object { $_.Installed -eq $true }) {
    # Bind DNS Server to specific IP (idempotent: skip if already set)
    $dnsParamsKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters'
    $currentListen = $null
    try { $currentListen = Get-ItemPropertyValue -Path $dnsParamsKey -Name 'ListenAddresses' -ErrorAction Stop } catch { }
    if ($currentListen -and (@($currentListen).Count -eq 1) -and (@($currentListen)[0] -eq $ip)) {
        Write-Host " [SKIP] DNS already bound to $ip" -ForegroundColor DarkGray
    } else {
        Set-ItemProperty -Path $dnsParamsKey -Name 'ListenAddresses' -Value ([string[]]@($ip))
        Write-Host " [OK] DNS bound to $ip" -ForegroundColor Green
    }
    
    # Disable dynamic updates on the NAT interface (idempotent)
    $natAdapter = Get-NetAdapter -Name "Ethernet" -ErrorAction SilentlyContinue
    if ($natAdapter) {
        $natDns = Get-DnsClient -InterfaceIndex $natAdapter.ifIndex
        if ($natDns.RegisterThisConnectionsAddress -eq $false) {
            Write-Host " [SKIP] NAT interface DNS registration already disabled" -ForegroundColor DarkGray
        } else {
            Set-DnsClient -InterfaceIndex $natAdapter.ifIndex -RegisterThisConnectionsAddress $false
            Write-Host " [OK] NAT interface DNS registration disabled" -ForegroundColor Green
        }
    }

    # Enable dynamic updates on the domain interface (idempotent)
    $domainAdapter = Get-NetAdapter -Name "Ethernet 2" -ErrorAction SilentlyContinue
    if ($domainAdapter) {
        $domDns = Get-DnsClient -InterfaceIndex $domainAdapter.ifIndex
        if ($domDns.RegisterThisConnectionsAddress -eq $true) {
            Write-Host " [SKIP] Domain interface DNS registration already enabled" -ForegroundColor DarkGray
        } else {
            Set-DnsClient -InterfaceIndex $domainAdapter.ifIndex -RegisterThisConnectionsAddress $true
            Write-Host " [OK] Domain interface DNS registration enabled" -ForegroundColor Green
        }
    }
}

$safeModePassword = ConvertTo-SecureString $forest.safeModeAdministratorPassword -AsPlainText -Force

$hostEntries = @(
    @{IPAddress = $forest.dcIPAddress; Hostname = $forest.name},
    @{IPAddress = $domain.dcIPAddress; Hostname = $domain.name}
)

# Path to the hosts file
$hostsFilePath = "C:\Windows\System32\drivers\etc\hosts"

# Add each entry to the hosts file
foreach ($entry in $hostEntries) {
    $line = "$($entry.IPAddress) $($entry.Hostname)"
    Add-Content -Path $hostsFilePath -Value $line
    Write-Host " [OK] Added hosts entry: $line" -ForegroundColor Green
}

# Disable firewalls!
Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False
Write-Host " [OK] Firewalls disabled" -ForegroundColor Green

Stop-PhaseTimer -Status Success

# ==============================================================================
# PHASE 5: AD Forest Installation
# ==============================================================================
Start-PhaseTimer -PhaseName "AD FOREST INSTALLATION"

Write-Host ' Installing the AD forest (this will take 30+ minutes)...'
Import-Module ADDSDeployment

# NB ForestMode and DomainMode are set to WinThreshold (Windows Server 2016).
#    see https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/active-directory-functional-levels
Install-ADDSForest `
    -InstallDns `
    -CreateDnsDelegation:$false `
    -ForestMode 6 `
    -DomainMode 6 `
    -DomainName $forest.name `
    -DomainNetbiosName $forest.netbiosName `
    -SafeModeAdministratorPassword $safeModePassword `
    -NoRebootOnCompletion `
    -Force 

Write-Host " [OK] AD Forest installation completed" -ForegroundColor Green

Stop-PhaseTimer -Status Success

# ==============================================================================
# Show Installation Summary
# ==============================================================================
Show-InstallationSummary

Write-Host "`n [COMPLETE] Root Domain Controller provisioning finished!" -ForegroundColor Green
Write-Host " The system will reboot to complete forest configuration.`n" -ForegroundColor Yellow
