# ==============================================================================
# SCRIPT: New-VulnerablePackage.ps1
# PURPOSE: Automates the creation of a "Vulnerable" Legacy Package to simulate
#          the 'Distribution Point Looting' attack vector.
# RUN ON:  SCCM Site Server (requires CM Module)
# ==============================================================================

# --- CONFIGURATION ---
$SiteCode = "PS1"                      # Your Site Code
$SiteServer = "SCCM.silent.run"     # Your Site Server FQDN
$DPName = "SCCM.silent.run"     # DP to distribute to
$PackageName = "Server Backup Agent Preparation"
$ProgramName = "Run Pre-Install"
$SourceDir = "C:\Sources\Packages\BackupAgent" # Local path for source files
$ScriptName = "PreInstall-BackupUser.ps1"
$HardcodedPass = "B@ckup`$2024!Secure"       # The secret we will steal
# ---------------------

# 1. INITIALIZE SCCM MODULE
Write-Host "--- SETUP: Loading SCCM Module ---" -ForegroundColor Cyan
if (-not (Get-Module ConfigurationManager)) {
    try {
        Import-Module "$($Env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" -ErrorAction Stop
    }
    catch {
        Write-Error "Could not load Configuration Manager module. Run on Site Server."
        exit
    }
}
if ((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
}
Set-Location "$($SiteCode):"

# 2. CREATE VULNERABLE SOURCE FILE
Write-Host "[*] Creating Source Content at $SourceDir..." -ForegroundColor Yellow
if (-not (Test-Path $SourceDir)) { New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null }

$ScriptContent = @"
# INFRA TICKET-992: Create Backup User
# AUTHOR: admin@silent.run
`$User = "svc_backup_agent"
`$Password = ConvertTo-SecureString "$HardcodedPass" -AsPlainText -Force
New-LocalUser -Name `$User -Password `$Password -Description "Backup Service Account" -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Backup Operators" -Member `$User -ErrorAction SilentlyContinue
Write-Host "User configured."
"@

$ScriptPath = Join-Path $SourceDir $ScriptName
$ScriptContent | Out-File -FilePath $ScriptPath -Encoding ASCII
Write-Host "    + Created file: $ScriptPath"

# 3. CREATE SCCM PACKAGE
Write-Host "[*] Creating Legacy Package: '$PackageName'..." -ForegroundColor Yellow
try {
    # Check if exists
    $Pkg = Get-CMPackage -Name $PackageName -Fast -ErrorAction SilentlyContinue 
    if ($Pkg) { 
        Write-Warning "    - Package already exists. Skipping creation." 
    }
    else {
        $Pkg = New-CMPackage -Name $PackageName -Path $SourceDir -Description "Vulnerable Package for Lab"
        Write-Host "    + Package Created. ID: $($Pkg.PackageID)" -ForegroundColor Green
    }
}
catch {
    Write-Error "Failed to create package: $_"
    exit
}

# 4. CREATE STANDARD PROGRAM
Write-Host "[*] Creating Standard Program..." -ForegroundColor Yellow
try {
    if (Get-CMProgram -PackageName $PackageName -ProgramName $ProgramName -ErrorAction SilentlyContinue) {
        Write-Warning "    - Program already exists."
    }
    else {
        # FIX:
        # 1. Parameter is '-RunMode'
        # 2. Value is 'RunAsAdmin' (Not 'Admin' or 'RunWithAdministrativeRights')
        New-CMProgram -PackageName $PackageName `
            -StandardProgramName $ProgramName `
            -CommandLine "powershell.exe -ExecutionPolicy Bypass -File $ScriptName" `
            -RunMode RunWithAdministrativeRights `
            -ProgramRunType WhetherOrNotUserIsLoggedOn `
            -Duration 15 | Out-Null
                      
        Write-Host "    + Program '$ProgramName' created." -ForegroundColor Green
    }
}
catch {
    Write-Error "Failed to add program: $_"
}

# 5. DISTRIBUTE CONTENT TO DP
Write-Host "[*] Distributing Content to $DPName..." -ForegroundColor Yellow

try {
    # Try to distribute. If it's already there, this might throw an error we can catch.
    Start-CMContentDistribution -PackageName $PackageName -DistributionPointName $DPName -ErrorAction Stop
    
    Write-Host "    + Distribution Initiated. Wait a few minutes for files to appear on DP." -ForegroundColor Green

}
catch {
    # If it fails, check if it's because it's already distributed
    if ($_.Exception.Message -match "already" -or $_.Exception.Message -match "exists") {
        Write-Warning "    - Content is likely already distributed to this DP."
    }
    else {
        # If it failed for another reason (e.g., generic error), just warn the user.
        Write-Warning "    - Distribution command failed (it might already be distributed): $($_.Exception.Message)"
    }
}

Write-Host "`n[SUCCESS] Vulnerability Created." -ForegroundColor Cyan
Write-Host "Attack Path: Browse \\$DPName\SMSPKGD$ or http://$DPName/SMS_DP_SMSPKG$ to find '$ScriptName'"