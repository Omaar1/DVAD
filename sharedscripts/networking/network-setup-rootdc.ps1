#DNS Setup on ROOT DC
Import-Module DnsServer

# Detect NICs by ifIndex order. Vagrant attaches NAT first, private_network second.
$nics = Get-NetAdapter | Where-Object Status -ne 'Disabled' | Sort-Object ifIndex
$domainName = $nics[1].Name

# Get IP from domain interface
$ip = (Get-NetAdapter -Name $domainName | Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' }).IPAddress
$firstOctet = $ip.split(".")[0]
$secondOctet = $ip.split(".")[1]
$thirdOctet = $ip.split(".")[2]
$fourthOctet = $ip.split(".")[3]

# Bind DNS Server to specific IP and disable recursion for security
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters' -Name 'ListenAddresses' -Value @($ip)
Set-DnsServerRecursion -Enable $false

# Clean up DNS records
$zones = @("silent.run", "_msdcs.silent.run")
foreach ($zone in $zones) {
    # Get all DNS records
    $records = Get-DnsServerResourceRecord -ZoneName $zone -ErrorAction SilentlyContinue
    if ($records) {
        foreach ($record in $records) {
            # Check if record contains IPv6 or 10.0.2.x addresses
            if ($record.RecordData.IPv4Address -match "10\.0\.2\." -or 
                $record.RecordData.IPv6Address -match "fd17:" -or 
                $record.HostName -match "^.*\.10\.0\.2\.") {
                Remove-DnsServerResourceRecord -ZoneName $zone -RRType $record.RecordType -Name $record.HostName -Force
            }
        }
    }
}

#Import our file with DNS entries for the DC
Import-CSV -Path C:\vagrant\variables\root_dns_entries.csv | ForEach-Object {
    Remove-DnsServerResourceRecord -ZoneName "silent.run" -RRType "A" -Name $_.Hostname -force -ErrorAction SilentlyContinue
    $hostfullIP = "$firstOctet.$secondOctet.$thirdOctet." + $_.IPEnd
    Add-DnsServerResourceRecordA -Name $_.Hostname -ZoneName "silent.run" -IPv4Address $hostfullIP
}

#Add Child Delegation
$childIP = "$firstOctet.$secondOctet.$thirdOctet.101"
Set-DnsServerZoneDelegation -Name "silent.run" -ChildZoneName "something" -NameServer "CHILDDC.something.silent.run" -IPAddress $childIP

#Add the DNS forwarder for outbound DNS
$forward = Get-DnsServerForwarder
Remove-DnsServerForwarder $forward.IPAddress -force -ErrorAction SilentlyContinue
Add-DnsServerForwarder -IPAddress 8.8.8.8

# Verify and clean up SRV records
$srvRecords = Get-DnsServerResourceRecord -ZoneName "silent.run" -RRType SRV
foreach ($record in $srvRecords) {
    if ($record.RecordData.DomainName -match "\.10\.0\.2\." -or 
        $record.RecordData.DomainName -match "fd17:") {
        Remove-DnsServerResourceRecord -ZoneName "silent.run" -RRType SRV -Name $record.HostName -Force
    }
}

# Restart DNS Server to apply changes
Restart-Service DNS


