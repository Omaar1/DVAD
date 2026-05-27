#DNS Update Script version 1.5

# Detect NICs by ifIndex order. Vagrant attaches NAT first, private_network second.
$nics = Get-NetAdapter | Where-Object Status -ne 'Disabled' | Sort-Object ifIndex
$domainName = $nics[1].Name

$ip = (Get-NetAdapter -Name $domainName | Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' }).IPAddress
$firstOctet = $ip.split(".")[0]
$secondOctet = $ip.split(".")[1]
$thirdOctet = $ip.split(".")[2]

$dnsip = "$firstOctet.$secondOctet.$thirdOctet.100"
$index = ($nics | Select-Object -ExpandProperty 'ifIndex')
Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dnsip
