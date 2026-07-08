# ==============================================================================
# Script: deploy-forest.ps1
# Purpose: Install AD Forest (Root Domain Controller) with Phase Timing
# ==============================================================================

$ErrorActionPreference = "Stop"

# Import Phase Timer Module
Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force

#This script promotes the Windows Server to a domain controller and will start the installation of a forest.
. C:\vagrant\provisioners\get-lab-config.ps1
$cfg    = Get-LabConfig
$forest = $cfg.domain
$child  = $cfg.childDomain

# ==============================================================================
# PHASE 1: Network Adapter Configuration
# ==============================================================================
Start-PhaseTimer -PhaseName "NETWORK ADAPTER CONFIGURATION"

# Identify the lab IP/NIC positively by subnet (deterministic, provider-agnostic).
# Per-NIC policy (IPv6 off, metrics, NAT kept out of DNS) is applied in prepare-host.
$labCfg     = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '10.10.10.*' } | Select-Object -First 1
$ip         = $labCfg.IPAddress
$domainName = (Get-NetAdapter -InterfaceIndex $labCfg.InterfaceIndex).Name
Write-Host " [INFO] Domain NIC: $domainName ($ip)" -ForegroundColor Yellow

# Root DC is its own DNS server - clear any client DNS on the domain interface.
$adapter = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPAddress -contains $ip }
if ($adapter) {
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

    # Per-NIC DNS registration policy (NAT kept out of DNS) is applied centrally in
    # prepare-host via configure-network.ps1 -Action Policy and persists across reboots.
}

$safeModePassword = ConvertTo-SecureString $forest.safeModeAdministratorPassword -AsPlainText -Force

$hostEntries = @(
    @{IPAddress = $cfg.hosts.rootdc.ip; Hostname = $forest.name},
    @{IPAddress = $cfg.hosts.childdc.ip; Hostname = $child.name}
)

# Path to the hosts file
$hostsFilePath = "C:\Windows\System32\drivers\etc\hosts"

# Add each entry to the hosts file (idempotent: skip lines already present)
$hostsContent = Get-Content -Path $hostsFilePath -ErrorAction SilentlyContinue
foreach ($entry in $hostEntries) {
    $line = "$($entry.IPAddress) $($entry.Hostname)"
    if ($hostsContent -contains $line) {
        Write-Host " [SKIP] hosts entry already present: $line" -ForegroundColor DarkGray
    } else {
        Add-Content -Path $hostsFilePath -Value $line
        Write-Host " [OK] Added hosts entry: $line" -ForegroundColor Green
    }
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

# Idempotency guard: if this box is already a DC for the target domain, skip promotion
$existingDomain = $null
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $existingDomain = Get-ADDomain -ErrorAction Stop
} catch { }

if ($existingDomain -and ($existingDomain.DNSRoot -eq $forest.name)) {
    Write-Host " [SKIP] Forest already installed: $($existingDomain.DNSRoot)" -ForegroundColor DarkGray
} else {
    # NB ForestMode and DomainMode are set to WinThreshold (Windows Server 2016).
    #    see https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/active-directory-functional-levels
    # -SkipPreChecks bypasses the prereq test framework, which can break under
    # accumulated state from partial/retried provisioning runs. The actual
    # promotion code path is independent and will surface real errors directly.
    Install-ADDSForest `
        -InstallDns `
        -CreateDnsDelegation:$false `
        -ForestMode 6 `
        -DomainMode 6 `
        -DomainName $forest.name `
        -DomainNetbiosName $forest.netbiosName `
        -SafeModeAdministratorPassword $safeModePassword `
        -SkipPreChecks `
        -NoRebootOnCompletion `
        -Force

    Write-Host " [OK] AD Forest installation completed" -ForegroundColor Green
}

Stop-PhaseTimer -Status Success

# ==============================================================================
# Show Installation Summary
# ==============================================================================
Show-InstallationSummary

Write-Host "`n [COMPLETE] Root Domain Controller provisioning finished!" -ForegroundColor Green
Write-Host " The system will reboot to complete forest configuration.`n" -ForegroundColor Yellow
