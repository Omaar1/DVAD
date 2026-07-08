. C:\vagrant\provisioners\get-lab-config.ps1
$cfg      = Get-LabConfig
$domain   = $cfg.childDomain
$parent   = $cfg.domain
$childIp  = $cfg.hosts.childdc.ip
$parentIp = $cfg.hosts.rootdc.ip

# Identify the lab IP/NIC positively by subnet (deterministic, provider-agnostic).
# Per-NIC policy (IPv6 off, metrics, NAT kept out of DNS) is applied in prepare-host.
$labCfg     = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '10.10.10.*' } | Select-Object -First 1
$ip         = $labCfg.IPAddress
$domainName = (Get-NetAdapter -InterfaceIndex $labCfg.InterfaceIndex).Name

# Disable IPv6 on the domain interface
Set-NetAdapterBinding -InterfaceAlias $domainName -ComponentID 'ms_tcpip6' -Enabled $false

echo ' ############### Configure DNS properly ###############'
# Configure DNS to point to parent DC
$adapter = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPAddress -contains $childIp }
if ($adapter) {
    # Set parent DC as primary DNS
    $adapter.SetDNSServerSearchOrder(@($parentIp))
    Write-Host "DNS successfully configured to use parent DC"
} else {
    Write-Host "Failed to configure DNS - adapter not found"
    exit 1
}

# Configure DNS Server settings before promotion
echo 'Configuring DNS Server settings...'
if (Get-WindowsFeature -Name DNS | Where-Object { $_.Installed -eq $true }) {
    # Bind DNS Server to specific IP
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters' -Name 'ListenAddresses' -Value @($ip)
    
    # Per-NIC DNS registration policy (NAT kept out of DNS) is applied centrally in
    # prepare-host via configure-network.ps1 -Action Policy and persists across reboots.
}

# Verify DNS resolution to parent DC
$maxAttempts = 30
$attempt = 0
$resolved = $false

while (-not $resolved -and $attempt -lt $maxAttempts) {
    $attempt++
    Write-Host "Attempting to resolve parent DC (Attempt $attempt of $maxAttempts)..."
    
    try {
        $result = Resolve-DnsName -Name $parent.name -ErrorAction Stop
        if ($result.IPAddress -eq $parentIp) {
            $resolved = $true
            Write-Host "Successfully resolved parent DC"
        }
    } catch {
        Write-Host "Failed to resolve parent DC, waiting 10 seconds..."
        Start-Sleep -Seconds 10
    }
}

if (-not $resolved) {
    Write-Host "Failed to resolve parent DC after $maxAttempts attempts. Exiting."
    exit 1
}

$hostEntries = @(
    @{IPAddress = $parentIp; Hostname = $parent.name},
    @{IPAddress = $childIp; Hostname = $domain.name}
)

# Path to the hosts file
$hostsFilePath = "C:\Windows\System32\drivers\etc\hosts"

# Add each entry to the hosts file
foreach ($entry in $hostEntries) {
    $line = "$($entry.IPAddress) $($entry.Hostname)"
    Add-Content -Path $hostsFilePath -Value $line
}

echo 'Resetting the Administrator account password and settings...'
$localAdminPassword = ConvertTo-SecureString $domain.administratorPassword -AsPlainText -Force
Set-LocalUser `
    -Name Administrator `
    -AccountNeverExpires `
    -Password $localAdminPassword `
    -PasswordNeverExpires:$true `
    -UserMayChangePassword:$true



echo 'Installing the AD services and administration tools...'
Install-WindowsFeature AD-Domain-Services,RSAT-AD-AdminCenter,RSAT-ADDS-Tools -IncludeManagementTools

$parentPassword = ConvertTo-SecureString $parent.administratorPassword -AsPlainText -Force
$parentDA =  $parent.name + "\Administrator" 
$parentCredentials = New-Object System.Management.Automation.PSCredential($parentDA, $parentPassword)
echo 'parent creds ~~~:'
echo $parent.fqdn
echo $parentDA
echo $parent.administratorPassword
$safeModePassword = ConvertTo-SecureString $domain.safeModeAdministratorPassword -AsPlainText -Force


echo 'Installing the AD domain (be patient, this will take more than 30m to install)...'
Import-Module ADDSDeployment


# NB ForestMode and DomainMode are set to WinThreshold (Windows Server 2016).
#    see https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/active-directory-functional-levels
try {
    Install-ADDSDomain `
    -Credential $parentCredentials `
    -NewDomainName $domain.name `
    -DomainType Child `
    -ParentDomainName $parent.fqdn `
    -SafeModeAdministratorPassword $safeModePassword `
    -CreateDnsDelegation:$true `
    -DatabasePath "C:\Windows\NTDS" `
    -DomainMode "6" `
    -NewDomainNetbiosName $domain.netbiosName `
    -InstallDns:$true `
    -Force:$true `
    -NoRebootOnCompletion:$true 
}
catch {
    Write-Host "An error occurred: $($_.Exception.Message)"
    Write-Host "Continuing despite error."
    Exit 0  # Continue with provisioning
}


