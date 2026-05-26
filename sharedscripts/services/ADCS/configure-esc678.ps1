<#
.SYNOPSIS
    Configures ESC5, ESC6, ESC7, and ESC8 ADCS escalation paths on the CA server.
.DESCRIPTION
    ESC5: Grants GenericAll on the CA AD object to l.garcia
          -> l.garcia can modify CA settings, add templates, or change the CA cert
    ESC6: Enables EDITF_ATTRIBUTESUBJECTALTNAME2 flag on the CA
          -> Any domain user can request a cert with arbitrary SAN (e.g., administrator@silent.run)
    ESC7: Grants ManageCA permission to a.johnson (IT Helpdesk)
          -> a.johnson can grant herself ManageCertificates or enable EDITF_ATTRIBUTESUBJECTALTNAME2
    ESC8: Ensures Web Enrollment is accessible over HTTP with NTLM auth (relay-vulnerable)
          -> Attacker can relay NTLM auth (e.g., via PetitPotam) to http://ADCS/certsrv/
.NOTES
    Must run as domain admin on the ADCS server.
    Called from install-adcs.ps1 after ESC1-4 template creation.
#>

$caName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration" -Name Active -ErrorAction SilentlyContinue).Active
if (-not $caName) { $caName = "SILENT-CA" }

Write-Host "[*] CA Name: $caName" -ForegroundColor Cyan

# ============================================================
# ESC5: GenericAll on the CA object in AD for l.garcia
# ============================================================
Write-Host "`n[*] === ESC5: GenericAll on CA AD object for l.garcia ===" -ForegroundColor Cyan

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $domainDN  = (Get-ADDomain).DistinguishedName
    $domainDNS = (Get-ADDomain).DNSRoot

    $caObjectDN = "CN=$caName,CN=Enrollment Services,CN=Public Key Services,CN=Services,CN=Configuration,$domainDN"
    $user       = Get-ADUser -Identity "l.garcia" -ErrorAction Stop
    $userSID    = $user.SID

    $target  = [ADSI]"LDAP://$caObjectDN"
    $sid     = New-Object System.Security.Principal.SecurityIdentifier($userSID)
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow
    $rights  = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
    $inherit = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    $ace     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $rights, $allow, $inherit)

    $acl = $target.psbase.ObjectSecurity
    $acl.AddAccessRule($ace)
    $target.psbase.CommitChanges()
    Write-Host "[+] l.garcia: GenericAll on CA AD object ($caName)" -ForegroundColor Green
} catch {
    Write-Host "[!] ESC5 configuration failed: $_" -ForegroundColor Red
}

# ============================================================
# ESC6: Enable EDITF_ATTRIBUTESUBJECTALTNAME2
# ============================================================
Write-Host "`n[*] === ESC6: Enabling EDITF_ATTRIBUTESUBJECTALTNAME2 ===" -ForegroundColor Cyan

try {
    $currentFlags = certutil -getreg policy\EditFlags 2>&1
    if ($currentFlags -match "EDITF_ATTRIBUTESUBJECTALTNAME2") {
        Write-Host "[*] EDITF_ATTRIBUTESUBJECTALTNAME2 is already enabled."
    } else {
        certutil -setreg policy\EditFlags +EDITF_ATTRIBUTESUBJECTALTNAME2
        if ($LASTEXITCODE -ne 0) { throw "certutil returned exit code $LASTEXITCODE" }
        Write-Host "[+] ESC6 flag set successfully." -ForegroundColor Green
    }
} catch {
    Write-Host "[!] ESC6 configuration failed: $_" -ForegroundColor Red
}

# ============================================================
# ESC7: Grant ManageCA to a.johnson
# ============================================================
Write-Host "`n[*] === ESC7: Granting ManageCA to a.johnson ===" -ForegroundColor Cyan

try {
    $userSID = $null
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $user    = Get-ADUser -Identity "a.johnson" -ErrorAction Stop
        $userSID = $user.SID
    } catch {
        Write-Host "[*] AD module unavailable, trying ADSI LDAP..."
        $searcher = New-Object DirectoryServices.DirectorySearcher
        $searcher.Filter = "(sAMAccountName=a.johnson)"
        $searcher.PropertiesToLoad.Add("objectSid") | Out-Null
        $result = $searcher.FindOne()
        if ($result) {
            $sidBytes = $result.Properties["objectsid"][0]
            $userSID  = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)
        }
    }

    if (-not $userSID) { throw "Could not resolve SID for a.johnson" }
    Write-Host "[*] Found a.johnson (SID: $userSID)"

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caName"
    $sdBytes = (Get-ItemProperty -Path $regPath -Name Security -ErrorAction Stop).Security
    $sd      = New-Object System.Security.AccessControl.RawSecurityDescriptor($sdBytes, 0)

    $hasManageCA = $false
    foreach ($ace in $sd.DiscretionaryAcl) {
        if ($ace.SecurityIdentifier -eq $userSID -and ($ace.AccessMask -band 1)) {
            $hasManageCA = $true; break
        }
    }

    if ($hasManageCA) {
        Write-Host "[*] a.johnson already has ManageCA permission."
    } else {
        $newAce = New-Object System.Security.AccessControl.CommonAce(
            [System.Security.AccessControl.AceFlags]::None,
            [System.Security.AccessControl.AceQualifier]::AccessAllowed,
            1,
            $userSID,
            $false,
            $null
        )
        $sd.DiscretionaryAcl.InsertAce($sd.DiscretionaryAcl.Count, $newAce)
        $newBytes = New-Object byte[] $sd.BinaryLength
        $sd.GetBinaryForm($newBytes, 0)
        Set-ItemProperty -Path $regPath -Name Security -Value $newBytes
        Write-Host "[+] ManageCA permission granted to a.johnson." -ForegroundColor Green
    }
} catch {
    Write-Host "[!] ESC7 configuration failed: $_" -ForegroundColor Red
}

# ============================================================
# ESC8: HTTP Web Enrollment with NTLM (relay-vulnerable)
# ============================================================
Write-Host "`n[*] === ESC8: Configuring Web Enrollment for NTLM relay ===" -ForegroundColor Cyan

try {
    Import-Module WebAdministration -ErrorAction Stop

    # Ensure HTTP binding on port 80
    $httpBinding = Get-WebBinding -Name "Default Web Site" -Protocol http -Port 80 -ErrorAction SilentlyContinue
    if (-not $httpBinding) {
        New-WebBinding -Name "Default Web Site" -Protocol http -Port 80 -IPAddress "*"
        Write-Host "[+] HTTP binding on port 80 added." -ForegroundColor Green
    } else {
        Write-Host "[*] HTTP binding on port 80 already exists."
    }

    # Enable Windows Authentication (NTLM) on /certsrv/
    $winAuth = Get-WebConfigurationProperty `
        -Filter "/system.webServer/security/authentication/windowsAuthentication" `
        -Name "enabled" -PSPath "IIS:\Sites\Default Web Site\certsrv" -ErrorAction SilentlyContinue
    if (-not $winAuth -or $winAuth.Value -ne $true) {
        Set-WebConfigurationProperty `
            -Filter "/system.webServer/security/authentication/windowsAuthentication" `
            -Name "enabled" -Value $true -PSPath "IIS:\Sites\Default Web Site\certsrv"
        Write-Host "[+] Windows Authentication enabled on /certsrv/." -ForegroundColor Green
    }

    # Disable Extended Protection (EPA prevents NTLM relay)
    Set-WebConfigurationProperty `
        -Filter "/system.webServer/security/authentication/windowsAuthentication/extendedProtection" `
        -Name "tokenChecking" -Value "None" -PSPath "IIS:\Sites\Default Web Site\certsrv" -ErrorAction SilentlyContinue
    Write-Host "[+] Extended Protection set to None (NTLM relay possible)." -ForegroundColor Green

    # Remove SSL requirement to allow HTTP access
    Set-WebConfigurationProperty `
        -Filter "/system.webServer/security/access" `
        -Name "sslFlags" -Value "None" -PSPath "IIS:\Sites\Default Web Site\certsrv" -ErrorAction SilentlyContinue
    Write-Host "[+] SSL requirement removed — HTTP access to /certsrv/ enabled." -ForegroundColor Green

} catch {
    Write-Host "[!] ESC8 configuration failed: $_" -ForegroundColor Red
}

# ============================================================
# Restart services
# ============================================================
Write-Host "`n[*] Restarting Certificate Services and IIS..." -ForegroundColor Cyan
Restart-Service certsvc -Force
iisreset /noforce

Write-Host "`n[+] === ESC5, ESC6, ESC7, ESC8 configuration complete ===" -ForegroundColor Green
Write-Host "  ESC5: l.garcia has GenericAll on CA AD object ($caName)"
Write-Host "  ESC6: EDITF_ATTRIBUTESUBJECTALTNAME2 enabled on $caName"
Write-Host "  ESC7: a.johnson has ManageCA on $caName"
Write-Host "  ESC8: Web Enrollment on HTTP with NTLM (no EPA, no SSL required)"
