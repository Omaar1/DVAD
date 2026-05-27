#DNS updates for DC
Import-Module DnsServer

# Detect NICs by ifIndex order. Vagrant attaches NAT first, private_network second.
$nics = Get-NetAdapter | Where-Object Status -ne 'Disabled' | Sort-Object ifIndex
$domainName = $nics[1].Name

$ip = (Get-NetAdapter -Name $domainName | Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' }).IPAddress
$firstOctet = $ip.split(".")[0]
$secondOctet = $ip.split(".")[1]
$thirdOctet = $ip.split(".")[2]
$fourthOctet = $ip.split(".")[3]

# Bind DNS Server to specific IP
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters' -Name 'ListenAddresses' -Value @($ip)

# Create the primary zone for something.silent.run if it doesn't exist
if (-not (Get-DnsServerZone -Name "something.silent.run" -ErrorAction SilentlyContinue)) {
    Add-DnsServerPrimaryZone -Name "something.silent.run" -ZoneFile "something.silent.run.dns"
}

# Create a secondary zone for silent.run if it doesn't exist
$rootdcip = "$firstOctet.$secondOctet.$thirdOctet.100"
if (-not (Get-DnsServerZone -Name "silent.run" -ErrorAction SilentlyContinue)) {
    Add-DnsServerSecondaryZone -Name "silent.run" -ZoneFile "silent.run.dns" -MasterServers $rootdcip
}

# Clean up DNS records
$zones = @("something.silent.run", "_msdcs.something.silent.run")
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
Import-CSV -Path dns_entries.csv | ForEach-Object {
    Remove-DnsServerResourceRecord -ZoneName "something.silent.run" -RRType "A" -Name $_.Hostname -force -ErrorAction SilentlyContinue
    $hostfullIP = "$firstOctet.$secondOctet.$thirdOctet." + $_.IPEnd
    Add-DnsServerResourceRecordA -Name $_.Hostname -ZoneName "something.silent.run" -IPv4Address $hostfullIP
}

#All done, now we can set the DNS of our actual DC as well
$dnsip = "$firstOctet.$secondOctet.$thirdOctet.$fourthOctet"

#Update our DNS server
Remove-DnsServerResourceRecord -ZoneName "something.silent.run" -RRType "A" -Name "something.silent.run" -force -ErrorAction SilentlyContinue
Add-DNSServerResourceRecordA -Name "something.silent.run" -ZoneName "something.silent.run" -IPv4Address $dnsip

# Verify and clean up SRV records
$srvRecords = Get-DnsServerResourceRecord -ZoneName "something.silent.run" -RRType SRV
foreach ($record in $srvRecords) {
    if ($record.RecordData.DomainName -match "\.10\.0\.2\." -or 
        $record.RecordData.DomainName -match "fd17:") {
        Remove-DnsServerResourceRecord -ZoneName "something.silent.run" -RRType SRV -Name $record.HostName -Force
    }
}

# Configure DNS forwarder to use Root DC
Set-DnsServerForwarder -IPAddress $rootdcip -ErrorAction SilentlyContinue

$index = ($nics | Select-Object -ExpandProperty 'ifIndex')
Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses @($dnsip, $rootdcip)  # Set both DNS servers

# Restart DNS Server to apply changes
Restart-Service DNS

