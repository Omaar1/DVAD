# Build domain admin credential. Required because this script runs over WinRM
# as the local vagrant admin; installing an Enterprise Root CA writes into
# CN=Public Key Services,CN=Services,CN=Configuration,... and needs Enterprise
# Admins. Without -Credential, the cmdlet fails at set_CAType with
# 0x80072082 ERROR_DS_RANGE_CONSTRAINT (the DC rejects the operation).
. C:\vagrant\provisioners\get-lab-config.ps1
$forest = (Get-LabConfig).domain
$securePassword = ConvertTo-SecureString $forest.administratorPassword -AsPlainText -Force
$username = $forest.netbiosName + "\Administrator"
$domainAdminCredentials = New-Object System.Management.Automation.PSCredential($username, $securePassword)

# Helper to run blocks under a real domain-admin logon token (scheduled task).
# Needed for AD writes that the local WinRM identity cannot perform.
. C:\vagrant\provisioners\invoke-as-user-task.ps1
Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force

Start-PhaseTimer -PhaseName "INSTALL ADCS (CA, ESC1-8 templates)"


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
$ADCSTemplateModulePath =  "c:\vagrant\provisioners\services\ADCS\ADCSTemplate\ADCSTemplate.psm1"
if (-not (Get-Module -Name ADCSTemplate)) {
    Write-Host "[*] Importing local ADCSTemplate module from $ADCSTemplateModulePath..."
    Import-Module $ADCSTemplateModulePath -Force
    if (-not (Get-Module -Name ADCSTemplate)) {
        Write-Host "[!] Failed to import local ADCSTemplate module"
    }
    Write-Host "[+] Successfully imported ADCSTemplate module"
}


# Create vulnerable templates using ADCSTemplate.
# New-ADCSTemplate / Set-ADCSTemplateACL write into AD (CN=Certificate Templates,
# CN=Public Key Services,CN=Services,CN=Configuration,...), which the local WinRM
# identity cannot do ("Access is denied"). Run the loop under a real domain-admin
# logon token via a one-shot scheduled task. The task runs locally on this box, so
# the ADCSTemplate module and JSON files (all under C:\vagrant) are available.
# Note: ESC5-ESC8 are CA-level misconfigurations applied after template import (see Step 5 below)
Write-Host "#### Step 4:Creating vulnerable certificate templates..."

$templateScript = @'
Import-Module ActiveDirectory -Force
Import-Module "C:\vagrant\provisioners\services\ADCS\ADCSTemplate\ADCSTemplate.psm1" -Force

$netbios = (Get-ADDomain).NetBIOSName

$templates = @(
    @{DisplayName = "ESC1_VulnerableTemplate"; JsonPath = "C:\vagrant\provisioners\services\ADCS\ESC1_VulnerableTemplate.json"},
    @{DisplayName = "ESC2_VulnerableTemplate"; JsonPath = "C:\vagrant\provisioners\services\ADCS\ESC2_VulnerableTemplate.json"},
    @{DisplayName = "ESC3_VulnerableTemplate"; JsonPath = "C:\vagrant\provisioners\services\ADCS\ESC3_VulnerableTemplate.json"},
    @{DisplayName = "ESC3_EnrollmentAgent"; JsonPath = "C:\vagrant\provisioners\services\ADCS\ESC3_EnrollmentAgentTemplate.json"},
    @{DisplayName = "ESC4_VulnerableTemplate"; JsonPath = "C:\vagrant\provisioners\services\ADCS\ESC4_VulnerableTemplate.json"}
)

# Resolve every Enterprise CA once. Publication must be re-asserted on EVERY run:
# reinstalling the CA (fresh CA cert) resets its certificateTemplates list, and
# New-ADCSTemplate only publishes at creation time - so a template that already exists
# in AD would silently go unpublished on the new CA (certipy shows "Enabled: False").
$configNC       = (Get-ADRootDSE).configurationNamingContext
$enrollmentPath = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$configNC"
$cas            = @(Get-ADObject -SearchBase $enrollmentPath -SearchScope OneLevel -Filter *)

foreach ($template in $templates) {
    $existingTemplate = Get-ADCSTemplate -DisplayName $template.DisplayName -ErrorAction SilentlyContinue
    if ($existingTemplate) {
        Write-Host "[*] Template '$($template.DisplayName)' already exists. Skipping creation."
    } else {
        Write-Host "[*] Creating template '$($template.DisplayName)'..."
        New-ADCSTemplate -DisplayName $template.DisplayName -JSON (Get-Content $template.JsonPath -Raw) -ErrorAction Stop
        $existingTemplate = Get-ADCSTemplate -DisplayName $template.DisplayName -ErrorAction Stop
    }

    # Ensure the template is published to every CA (idempotent, survives CA reinstall).
    # certificateTemplates stores the template CN, so publish by the object's real name.
    $cn = $existingTemplate.Name
    foreach ($ca in $cas) {
        $published = @((Get-ADObject -Identity $ca.DistinguishedName -Properties certificateTemplates).certificateTemplates)
        if ($published -notcontains $cn) {
            Set-ADObject -Identity $ca.DistinguishedName -Add @{certificateTemplates = $cn}
            Write-Host "[+] Published '$cn' on CA '$($ca.Name)'."
        } else {
            Write-Host "[*] '$cn' already published on CA '$($ca.Name)'."
        }
    }

    Write-Host "[*] Setting ACLs for '$($template.DisplayName)'..."
    Set-ADCSTemplateACL -DisplayName $template.DisplayName -Identity "$netbios\Domain Users" -Type Allow -Enroll -AutoEnroll -ErrorAction Stop
}

# ESC4: Enroll rights alone are NOT ESC4. ESC4 requires a low-priv principal to hold
# WRITE control over the template object so it can be reconfigured (add
# ENROLLEE_SUPPLIES_SUBJECT / client-auth EKU / drop approval) and then abused.
# Set-ADCSTemplateACL only grants Read/Enroll/AutoEnroll, so grant Domain Users
# GenericAll directly (same pattern as the ESC5 CA-object ACE). This is what certipy
# reports as ESC4.
. C:\vagrant\provisioners\domain\set-ad-ace.ps1
$esc4Dn   = (Get-ADCSTemplate -DisplayName "ESC4_VulnerableTemplate").DistinguishedName
$esc4Adsi = [ADSI]"LDAP://$esc4Dn"
$duSid    = (New-Object System.Security.Principal.NTAccount("$netbios\Domain Users")).Translate([System.Security.Principal.SecurityIdentifier])
$esc4Ace  = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $duSid,
    [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
    [System.Security.AccessControl.AccessControlType]::Allow,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None)
Add-AdAceIfMissing -DirectoryEntry $esc4Adsi -Ace $esc4Ace | Out-Null
Write-Host "[+] ESC4: Domain Users granted GenericAll on ESC4_VulnerableTemplate"
'@

$tplUser = "$($forest.netbiosName)\Administrator"
if (Invoke-AsUserTask -Name "CreateAdcsTemplates" -ScriptContent $templateScript -User $tplUser -Password $forest.administratorPassword -TimeoutSec 180) {
    Write-Host "[+] Vulnerable templates created and published." -ForegroundColor Green
} else {
    Write-Host "[!] Template creation task failed or timed out (see log above)." -ForegroundColor Red
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
$esc678Script = "C:\vagrant\provisioners\services\ADCS\configure-esc678.ps1"
if (Test-Path $esc678Script) {
    & $esc678Script
} else {
    Write-Host "[!] configure-esc678.ps1 not found at $esc678Script" -ForegroundColor Red
}

Stop-PhaseTimer -Status Success
Show-InstallationSummary


