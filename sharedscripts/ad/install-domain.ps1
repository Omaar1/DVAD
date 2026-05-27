param(
    [string]$domainVariables,
    [string]$parentDomainVariables
)

$domain = Get-Content -Raw -Path "C:\vagrant\provision\variables\domain-variables.json" | ConvertFrom-Json
$parent = Get-Content -Raw -Path "C:\vagrant\provision\variables\forest-variables.json" | ConvertFrom-Json

# Detect NICs by ifIndex order. Vagrant attaches NAT first, private_network second.
$nics = Get-NetAdapter | Where-Object Status -ne 'Disabled' | Sort-Object ifIndex
$natName    = $nics[0].Name
$domainName = $nics[1].Name

# Configure network adapter for optimal DNS operation
$ip = (Get-NetAdapter -Name $domainName | Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' }).IPAddress

# Disable IPv6 on the domain interface
Set-NetAdapterBinding -InterfaceAlias $domainName -ComponentID 'ms_tcpip6' -Enabled $false

echo ' ############### Configure DNS properly ###############'
# Configure DNS to point to parent DC
$adapter = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPAddress -contains $domain.dcIPAddress }
if ($adapter) {
    # Set parent DC as primary DNS
    $adapter.SetDNSServerSearchOrder(@($parent.dcIPAddress))
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
    
    # Disable dynamic updates on the NAT interface
    $natAdapter = Get-NetAdapter -Name $natName
    if ($natAdapter) {
        Set-DnsClient -InterfaceIndex $natAdapter.ifIndex -RegisterThisConnectionsAddress $false
    }

    # Enable dynamic updates on the domain interface
    $domainAdapter = Get-NetAdapter -Name $domainName
    if ($domainAdapter) {
        Set-DnsClient -InterfaceIndex $domainAdapter.ifIndex -RegisterThisConnectionsAddress $true
    }
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
        if ($result.IPAddress -eq $parent.dcIPAddress) {
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
    @{IPAddress = $parent.dcIPAddress; Hostname = $parent.name},
    @{IPAddress = $domain.dcIPAddress; Hostname = $domain.name}
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


