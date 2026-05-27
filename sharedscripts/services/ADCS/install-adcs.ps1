# Build domain admin credential. Required because this script runs over WinRM
# as the local vagrant admin; installing an Enterprise Root CA writes into
# CN=Public Key Services,CN=Services,CN=Configuration,... and needs Enterprise
# Admins. Without -Credential, the cmdlet fails at set_CAType with
# 0x80072082 ERROR_DS_RANGE_CONSTRAINT (the DC rejects the operation).
$forest = Get-Content -Raw -Path "C:\vagrant\provision\variables\forest-variables.json" | ConvertFrom-Json
$securePassword = ConvertTo-SecureString $forest.administratorPassword -AsPlainText -Force
$username = $forest.netbiosName + "\Administrator"
$domainAdminCredentials = New-Object System.Management.Automation.PSCredential($username, $securePassword)


Write-Host "[*] Installing ADCS with Certification Authority and Web Enrollment features......\n\n"

Write-Host "#### Step 1: Install-WindowsFeature AD-Certificate ######"

# Check and Install ADCS with Certification Authority and Web Enrollment features
if (-not (Get-WindowsFeature Adcs-Cert-Authority).Installed ) {
    Get-WindowsFeature -Name AD-Certificate | Install-WindowsFeature -IncludeManagementTools
} else {
    Write-Host "[*] ADCS features are already installed."
}

# Configure ADCS as Enterprise Root CA if not already configured.
# Service state is not a reliable signal right after a reboot (CertSvc may be
# StartPending or Stopped even though the role is fully configured). Check the
# registry's "Active" value under CertSvc\Configuration, which is set only after
# Install-AdcsCertificationAuthority has run to completion.
$caConfigKey = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
$activeCA = $null
try { $activeCA = Get-ItemPropertyValue -Path $caConfigKey -Name "Active" -ErrorAction Stop } catch { }
if ($activeCA) {
    Write-Host "[*] CA already configured (Active='$activeCA'). Skipping configuration." -ForegroundColor Green
    $svc = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Host "[*] Starting CertSvc..."
        Start-Service CertSvc
    }
} else {
    Write-Host "[*] Configuring ADCS as Enterprise Root CA..."
    # Pass -Credential so the cmdlet writes the CA config into AD as a domain admin,
    # not as the local vagrant WinRM identity (which lacks Enterprise Admin rights).
    $caCommonName = "$env:COMPUTERNAME-CA"
    try {
        Install-AdcsCertificationAuthority `
            -CAType EnterpriseRootCA `
            -Credential $domainAdminCredentials `
            -CACommonName $caCommonName `
            -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
            -KeyLength 2048 `
            -HashAlgorithmName SHA256 `
            -ValidityPeriod Years `
            -ValidityPeriodUnits 10 `
            -DatabaseDirectory "$env:SystemRoot\System32\CertLog" `
            -LogDirectory "$env:SystemRoot\System32\CertLog" `
            -OverwriteExistingKey `
            -OverwriteExistingCAinDS `
            -Force `
            -ErrorAction Stop
    }
    catch {
        Write-Host "[!] Install-AdcsCertificationAuthority failed: $_" -ForegroundColor Red
        $certocm = "$env:SystemRoot\certocm.log"
        if (Test-Path $certocm) {
            Write-Host "----- certocm.log (last 80 lines) -----" -ForegroundColor Yellow
            Get-Content $certocm -Tail 80 | ForEach-Object { Write-Host $_ }
            Write-Host "----- end certocm.log -----" -ForegroundColor Yellow
        } else {
            Write-Host "[!] $certocm not found" -ForegroundColor Yellow
        }
        throw
    }
}




# Wait for ADCS to fully install
Start-Sleep -Seconds 10
Write-Host "#### Step 2:install Web Enrollment ######"

# Check and install Web Enrollment if not already installed
if (-not (Get-WindowsFeature ADCS-Web-Enrollment).Installed) {
    Write-Host "[*] Installing Web Enrollment..."
    Install-WindowsFeature ADCS-Web-Enrollment -IncludeManagementTools
    Install-AdcsWebEnrollment -Credential $domainAdminCredentials -Force
} else {
    Write-Host "[*] Web Enrollment is already installed."
}



# Restart the service to ensure everything is loaded
Restart-Service certsvc



Write-Host "#### Step 3:Installing Dependencies ######"

# Install AD module if not present
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "[*] Installing RSAT ..........."
    Install-WindowsFeature -Name "RSAT-AD-PowerShell" 
    Write-Host "[*] Installing AD module..."
    Import-Module ActiveDirectory -Force
}

# Install ADCSTemplate module if not present
$ADCSTemplateModulePath =  "c:\vagrant\sharedscripts\services\ADCS\ADCSTemplate\ADCSTemplate.psm1"
if (-not (Get-Module -Name ADCSTemplate)) {
    Write-Host "[*] Importing local ADCSTemplate module from $ADCSTemplateModulePath..."
    Import-Module $ADCSTemplateModulePath -Force
    if (-not (Get-Module -Name ADCSTemplate)) {
        Write-Host "[!] Failed to import local ADCSTemplate module"
    }
    Write-Host "[+] Successfully imported ADCSTemplate module"
}


# Create vulnerable templates using ADCSTemplate
Write-Host "#### Step 4:Creating vulnerable certificate templates..."

    # Array of template configurations
    $templates = @(
        @{DisplayName = "ESC1_VulnerableTemplate"; JsonPath = "C:\vagrant\sharedscripts\services\ADCS\ESC1_VulnerableTemplate.json"},
        @{DisplayName = "ESC2_VulnerableTemplate"; JsonPath = "C:\vagrant\sharedscripts\services\ADCS\ESC2_VulnerableTemplate.json"},
        @{DisplayName = "ESC3_VulnerableTemplate"; JsonPath = "C:\vagrant\sharedscripts\services\ADCS\ESC3_VulnerableTemplate.json"},
        @{DisplayName = "ESC4_VulnerableTemplate"; JsonPath = "C:\vagrant\sharedscripts\services\ADCS\ESC4_VulnerableTemplate.json"}
    )
    # Note: ESC5-ESC8 are CA-level misconfigurations applied after template import (see Step 5 below)



    foreach ($template in $templates) {
        try {
            # Check if the template already exists
            $existingTemplate = Get-ADCSTemplate -DisplayName $template.DisplayName -ErrorAction SilentlyContinue
            if ($existingTemplate) {
                Write-Host "[*] Template '$($template.DisplayName)' already exists. Skipping creation."
            } else {
                # Create new template
                Write-Host "[*] Creating template '$($template.DisplayName)'..."
                New-ADCSTemplate -DisplayName $template.DisplayName -JSON (Get-Content $template.JsonPath -Raw) -Publish -ErrorAction Stop
            }

            # Set ACLs for the template
            Write-Host "[*] Setting ACLs for '$($template.DisplayName)'..."
            Set-ADCSTemplateACL -DisplayName $template.DisplayName -Identity "SILENT\Domain Users" -Type Allow -Enroll -AutoEnroll -ErrorAction Stop
        }
        catch {
            Write-Host "[!] Error processing template '$($template.DisplayName)': $_"
            # Continue to the next template instead of halting
            continue
        }
    }

# # Define commands to run as admin
# $commands = {









# # Execute the commands
# try {
#     Invoke-Command -ComputerName localhost -Credential $domainAdminCredentials -ScriptBlock $commands -ErrorAction Stop
#     Write-Host "[*] All templates processed successfully."
# }
# catch {
#     Write-Host "[!] Error executing commands: $_"
# }

# Restart IIS and Certificate Services before ESC5-8
Write-Host "[*] Restarting services..."
iisreset /noforce
Restart-Service certsvc -Force

# Wait for CA service to be fully running before CA-level changes
Write-Host "#### Step 5: Configuring ESC5, ESC6, ESC7, ESC8 escalation paths ######"
$esc678Script = "C:\vagrant\sharedscripts\services\ADCS\configure-esc678.ps1"
if (Test-Path $esc678Script) {
    & $esc678Script
} else {
    Write-Host "[!] configure-esc678.ps1 not found at $esc678Script" -ForegroundColor Red
}


