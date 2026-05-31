# ==============================================================================
# Script: fixSccmPermissions.ps1
# Purpose: Configure SCCM Console Access & RBAC Permissions (Combined Script)
# ==============================================================================

$ErrorActionPreference = "Stop"

# Import Phase Timer Module
Import-Module "$PSScriptRoot\PhaseTimer.psm1" -Force
. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1

# --- CONFIGURATION ---
$SiteCode = "PS1"
$ProviderMachineName = $Env:COMPUTERNAME
$ProviderFQDN = "SCCM.silent.run"
$TargetUsers = @("SILENT\Administrator", "SILENT\SCCMAdmin")
$AdminConsoleBin = "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin"
$MediaPath = "C:\vagrant\sharedscripts\services\SCCM\MECM_Setup\Media"

# ==============================================================================
# CHECK: Run as SYSTEM if needed. Re-runs this whole script as SYSTEM via the
# shared Invoke-AsUserTask helper (ScriptPath mode keeps $PSScriptRoot correct),
# then exits the non-SYSTEM instance.
# ==============================================================================
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($CurrentUser -ne "NT AUTHORITY\SYSTEM") {
    Write-Host "Running as '$CurrentUser'. Elevating to SYSTEM..." -ForegroundColor Yellow
    Invoke-AsUserTask -Name "FixSCCMPermissions_Task" -ScriptPath $MyInvocation.MyCommand.Definition -TimeoutSec 300 | Out-Null
    exit
}

Write-Host "`n=== SCCM PERMISSIONS FIX (Running as SYSTEM) ===" -ForegroundColor Cyan

# ==============================================================================
# PHASE 1: SMS ADMINS LOCAL GROUP
# ==============================================================================
Start-PhaseTimer -PhaseName "SMS ADMINS GROUP"
try {
    $Group = Get-LocalGroup -Name "SMS Admins" -ErrorAction Stop
    
    foreach ($User in $TargetUsers) {
        $IsMember = Get-LocalGroupMember -Group "SMS Admins" -Member $User -ErrorAction SilentlyContinue
        
        if ($IsMember) {
            Write-Host " [OK] $User already in 'SMS Admins'." -ForegroundColor Green
        }
        else {
            Add-LocalGroupMember -Group "SMS Admins" -Member $User -ErrorAction Stop
            Write-Host " [OK] Added $User to 'SMS Admins'." -ForegroundColor Green
        }
    }
    Stop-PhaseTimer -Status Success
}
catch {
    Write-Warning "SMS Admins group issue: $_"
    Stop-PhaseTimer -Status Warning
}

# ==============================================================================
# PHASE 2: VERIFY/INSTALL SCCM CONSOLE
# ==============================================================================
Start-PhaseTimer -PhaseName "SCCM CONSOLE CHECK"
$ModulePath = "$AdminConsoleBin\ConfigurationManager.psd1"

if (Test-Path $ModulePath) {
    Write-Host " [OK] SCCM Console module found." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
}
else {
    Write-Host " [INFO] Console not found. Installing..." -ForegroundColor Yellow
    
    $ConsoleSetup = Get-ChildItem -Path $MediaPath -Filter "consolesetup.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if ($ConsoleSetup) {
        $Args = @("/q", "TargetDir=`"$($AdminConsoleBin | Split-Path -Parent)`"", "DefaultSiteServerName=$ProviderFQDN")
        $Proc = Start-Process -FilePath $ConsoleSetup.FullName -ArgumentList $Args -Wait -PassThru
        
        if ($Proc.ExitCode -eq 0 -and (Test-Path $ModulePath)) {
            Write-Host " [OK] Console installed successfully." -ForegroundColor Green
            Stop-PhaseTimer -Status Success
        }
        else {
            Stop-PhaseTimer -Status Failed
            throw "Console install failed (Exit: $($Proc.ExitCode))."
        }
    }
    else {
        Stop-PhaseTimer -Status Failed
        throw "ConsoleSetup.exe not found in $MediaPath"
    }
}

# ==============================================================================
# PHASE 3: LOAD SCCM MODULE & CONNECT
# ==============================================================================
Start-PhaseTimer -PhaseName "CONNECT TO SCCM SITE"
try {
    if (-not $env:SMS_ADMIN_UI_PATH) {
        $env:SMS_ADMIN_UI_PATH = $AdminConsoleBin
    }
    
    Import-Module $ModulePath -Force -ErrorAction Stop
    Write-Host " [OK] SCCM Module loaded." -ForegroundColor Green
    
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider "CMSite" -Root $ProviderFQDN | Out-Null
    }
    
    Set-Location "${SiteCode}:"
    Write-Host " [OK] Connected to site '$SiteCode'." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
    
}
catch {
    Stop-PhaseTimer -Status Failed
    throw "Failed to connect to SCCM: $_"
}

# ==============================================================================
# PHASE 4: GRANT FULL ADMINISTRATOR RBAC
# ==============================================================================
Start-PhaseTimer -PhaseName "RBAC CONFIGURATION"
$FailCount = 0

foreach ($User in $TargetUsers) {
    try {
        $Existing = Get-CMAdministrativeUser -Name $User -ErrorAction SilentlyContinue
        
        if ($Existing) {
            Write-Host " [OK] $User already has SCCM RBAC access." -ForegroundColor Green
        }
        else {
            New-CMAdministrativeUser -Name $User -RoleName "Full Administrator" -ErrorAction Stop | Out-Null
            Write-Host " [OK] Granted 'Full Administrator' to $User." -ForegroundColor Green
        }
    }
    catch {
        Write-Warning " [WARN] Failed to configure $User : $_"
        $FailCount++
    }
}

if ($FailCount -eq 0) {
    Stop-PhaseTimer -Status Success
}
elseif ($FailCount -lt $TargetUsers.Count) {
    Stop-PhaseTimer -Status Warning
}
else {
    Stop-PhaseTimer -Status Failed
    throw "Failed to configure any RBAC users."
}

# ==============================================================================
# DONE
# ==============================================================================
Show-InstallationSummary
Write-Host "`n=== SCCM PERMISSIONS FIX COMPLETE ===" -ForegroundColor Magenta
