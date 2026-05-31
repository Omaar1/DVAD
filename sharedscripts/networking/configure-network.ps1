param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Policy', 'MemberDns', 'RootDcDns', 'NatInternetDns')]
    [string] $Action
)

# ==============================================================================
# configure-network.ps1 - the single source of truth for all lab networking.
#
# Every lab host has two NICs: the Vagrant NAT (internet) and the private_network
# (the lab, 10.10.10.0/24). The domain NIC is identified POSITIVELY by its lab-subnet
# IP - deterministic regardless of adapter order, and provider-agnostic (the NAT
# subnet differs between VirtualBox / VMware / Hyper-V).
#
# Actions:
#   Policy         - per-NIC policy applied on every VM (IPv6 off, metrics, and the
#                    key fix: NAT NICs never register in DNS).
#   MemberDns      - point this member's DNS at the Root DC.
#   RootDcDns      - configure the Root DC's DNS server (bind, recursion, forwarder,
#                    plus a belt-and-suspenders scrub of any stray NAT records).
#   NatInternetDns - put public DNS on the NAT NIC so installers can reach the internet.
#
# Run as ordered Vagrant provisioning steps (no scheduled tasks).
# ==============================================================================

$LabSubnet = '10.10.10.'      # lab private subnet prefix
$DcIp      = '10.10.10.100'   # Root DC

function Get-DomainNic {
    # The adapter whose IPv4 is on the lab subnet.
    $cfg = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$LabSubnet*" } |
        Select-Object -First 1
    if (-not $cfg) {
        throw "No network adapter found on lab subnet ${LabSubnet}* - cannot identify the domain NIC."
    }
    [pscustomobject]@{
        Name    = (Get-NetAdapter -InterfaceIndex $cfg.InterfaceIndex).Name
        IfIndex = $cfg.InterfaceIndex
        Ip      = $cfg.IPAddress
    }
}

function Get-NonDomainNics {
    # Every up adapter that is not the domain NIC (e.g. the Vagrant NAT).
    $domain = Get-DomainNic
    Get-NetAdapter | Where-Object { $_.Status -ne 'Disabled' -and $_.ifIndex -ne $domain.IfIndex }
}

switch ($Action) {

    'Policy' {
        $domain = Get-DomainNic
        $others = Get-NonDomainNics

        # IPv6 off on all adapters (AD uses IPv4 in this lab)
        Get-NetAdapter | ForEach-Object {
            Set-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID 'ms_tcpip6' -Enabled $false -ErrorAction SilentlyContinue
        }

        # Domain NIC: preferred route + registers in DNS
        Set-NetIPInterface -InterfaceIndex $domain.IfIndex -InterfaceMetric 5 -ErrorAction SilentlyContinue
        Set-DnsClient -InterfaceIndex $domain.IfIndex -RegisterThisConnectionsAddress $true

        # Every other NIC (NAT etc): deprioritized + kept out of DNS (the NAT-registration fix)
        foreach ($nic in $others) {
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -InterfaceMetric 55 -ErrorAction SilentlyContinue
            Set-DnsClient -InterfaceIndex $nic.ifIndex -RegisterThisConnectionsAddress $false
        }

        $otherNames = ($others | ForEach-Object { $_.Name }) -join ', '
        Write-Host " [OK] NIC policy applied. Domain NIC: $($domain.Name); non-lab NICs (no DNS): $otherNames" -ForegroundColor Green
    }

    'MemberDns' {
        # Point every adapter's DNS at the Root DC.
        $idx = Get-NetAdapter | Where-Object Status -ne 'Disabled' | Select-Object -ExpandProperty ifIndex
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $DcIp
        Write-Host " [OK] DNS pointed at Root DC ($DcIp)" -ForegroundColor Green
    }

    'NatInternetDns' {
        # Put public DNS on the NAT (non-lab) NIC so installers can reach the internet.
        $nat = Get-NonDomainNics | Select-Object -First 1
        if ($nat) {
            Set-DnsClientServerAddress -InterfaceAlias $nat.Name -ServerAddresses ('8.8.8.8', '8.8.4.4') -ErrorAction SilentlyContinue
            Write-Host " [OK] Public DNS (8.8.8.8) set on NAT NIC $($nat.Name)" -ForegroundColor Green
        } else {
            Write-Host " [WARN] No non-lab NIC found to set public DNS on" -ForegroundColor Yellow
        }
    }

    'RootDcDns' {
        Import-Module DnsServer
        $ip = (Get-DomainNic).Ip

        # Bind the DNS server to the lab IP and disable recursion (existing lab posture).
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters' -Name 'ListenAddresses' -Value ([string[]]@($ip))
        Set-DnsServerRecursion -Enable $false

        # Belt-and-suspenders: remove any stray NAT (10.0.2.x) A records. Prevention is in
        # the Policy action (NAT never registers), so this should normally find nothing.
        foreach ($zone in @('silent.run', '_msdcs.silent.run')) {
            $records = Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue
            foreach ($r in $records) {
                if ($r.RecordData.IPv4Address -match '10\.0\.2\.') {
                    Remove-DnsServerResourceRecord -ZoneName $zone -RRType A -Name $r.HostName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Forwarder for outbound DNS.
        $fwd = Get-DnsServerForwarder -ErrorAction SilentlyContinue
        if ($fwd -and $fwd.IPAddress) {
            Remove-DnsServerForwarder -IPAddress $fwd.IPAddress -Force -ErrorAction SilentlyContinue
        }
        Add-DnsServerForwarder -IPAddress 8.8.8.8 -ErrorAction SilentlyContinue

        Restart-Service DNS
        Write-Host " [OK] Root DC DNS configured (bound $ip, recursion off, forwarder 8.8.8.8)" -ForegroundColor Green
    }
}
