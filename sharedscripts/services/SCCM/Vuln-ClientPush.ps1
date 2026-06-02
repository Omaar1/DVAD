# --- CONFIGURATION VARIABLES ---
. C:\vagrant\sharedscripts\Get-LabConfig.ps1
$cfg = Get-LabConfig
$netbios = $cfg.domain.netbiosName
$SiteCode = $cfg.sccm.siteCode
$SiteServer = "$($cfg.hosts.sccm.name).$($cfg.domain.fqdn)"
$User = "$netbios\$($cfg.sccm.accounts.clientPush)"
$Password = $cfg.sccm.accountPassword
# ---------------------

# ============================================================================== #
# INITIALIZATION: LOAD MODULE & CONNECT TO SITE
# ============================================================================== #
. C:\vagrant\sharedscripts\services\SCCM\Connect-CMSite.ps1
Connect-CMSite -SiteCode $SiteCode -SiteServer $SiteServer

Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force
Start-PhaseTimer -PhaseName "VULN CLIENT PUSH (CRED-3)"

# 1. Define the Credential (SCCM needs the password to store it locally)
$SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force
# $Cred = New-Object System.Management.Automation.PSCredential ($User, $SecurePass)

# 2. Register the AD User into SCCM's internal list of accounts
Write-Host "[*] Registering AD User '$User' into SCCM database..." -ForegroundColor Cyan
if (-not (Get-CMAccount -Name $User -ErrorAction SilentlyContinue)) {
    # This command maps the AD user to an SCCM-managed credential
    New-CMAccount -Password $SecurePass -Name $User -SiteCode $SiteCode | Out-Null
    Write-Host " [OK] AD User is now an authorized SCCM Account." -ForegroundColor Green
}

# 5. Apply Settings (Using your exact parameters)
# Note: Changed -AddAccount $User to -AddAccount $Cred so it passes the password correctly.
Set-CMClientPushInstallation `
    -SiteCode $SiteCode `
    -AllownNTLMFallback $true `
    -EnableSystemTypeServer $true `
    -EnableSystemTypeWorkstation $true `
    -EnableSystemTypeConfigurationManager $true `
    -EnableAutomaticClientPushInstallation $true `
    -AddAccount $User
    # -Verbose

Stop-PhaseTimer -Status Success
Show-InstallationSummary