# Install-ADK.ps1 (Online Version + Network Setup)
# ---------------------------------------------------
# 1. Configures Network for Internet Access
# 2. Downloads and Installs ADK + WinPE (Version 2004)
# 3. Verifies Installation

$ErrorActionPreference = "Stop"

# Import Phase Timer Module
Import-Module "$PSScriptRoot\PhaseTimer.psm1" -Force

# --- PART 1: NETWORK SETUP (GO ONLINE) ---
Start-PhaseTimer -PhaseName "CONFIGURING NETWORK FOR INTERNET"

# Detect NICs by ifIndex order. Vagrant attaches NAT first, private_network second.
$nics = Get-NetAdapter | Where-Object Status -ne 'Disabled' | Sort-Object ifIndex
$natName = $nics[0].Name

# 1. Configure DNS on NAT Adapter
# We force Google DNS (8.8.8.8) to resolve external downloads
try {
    Write-Host "Setting Public DNS on '$natName'..." -NoNewline
    Set-DnsClientServerAddress -InterfaceAlias $natName -ServerAddresses ("8.8.8.8", "8.8.4.4") -ErrorAction SilentlyContinue
    Write-Host "Done." -ForegroundColor Green
}
catch {
    Write-Warning "Could not set DNS on '$natName'."
}

# 2. Enable Windows Update Service (Required for Installs)
try {
    Write-Host "Enabling Windows Update Service (wuauserv)..." -NoNewline
    Set-Service wuauserv -StartupType Manual
    Start-Service wuauserv
    Write-Host "Done." -ForegroundColor Green
}
catch {
    Write-Warning "Could not start wuauserv."
}

# 3. Connectivity Test
Write-Host "Testing Internet Connection..." -NoNewline
try {
    $test = Test-Connection "google.com" -Count 1 -Quiet
    if ($test) { 
        Write-Host " [SUCCESS]" -ForegroundColor Green 
    }
    else {
        Write-Error " [FAIL] No Internet Access. Check VirtualBox NAT."
        exit 1
    }
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error " [FAIL] Connectivity check failed."
    exit 1
}
Stop-PhaseTimer -Status Success

# --- PART 2: ADK INSTALLATION ---
Start-PhaseTimer -PhaseName "ADK CORE INSTALLATION"

$DownloadDir = "C:\vagrant\sharedscripts\services\SCCM\ADK"
$LogPathADK = "C:\ADKinstallerLog.txt"
$LogPathWinPE = "C:\winPEADKinstallerLog.txt"

# Features to install (Standard SCCM requirements)
$ADKFeatures = 'OptionId.DeploymentTools', 'OptionId.ImagingAndConfigurationDesigner', 'OptionId.ICDConfigurationDesigner', 'OptionId.UserStateMigrationTool'
$WinPEFeature = 'OptionId.WindowsPreinstallationEnvironment'

# URLs for ADK 2004 (Best compatibility for Server 2019)
$UrlADK = "https://go.microsoft.com/fwlink/?linkid=2120254"
$UrlWinPE = "https://go.microsoft.com/fwlink/?linkid=2120253"

# Ensure download directory exists
if (-not (Test-Path $DownloadDir)) { New-Item -Path $DownloadDir -ItemType Directory | Out-Null }

# 1. Download Files
Write-Host "Checking Installers..."
$ADKSetupPath = "$DownloadDir\adksetup.exe"
$WinPESetupPath = "$DownloadDir\adkwinpesetup.exe"

# Download ADK Setup if missing
if (-not (Test-Path $ADKSetupPath)) {
    Write-Host "Downloading ADK Setup..." -NoNewline
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $UrlADK -OutFile $ADKSetupPath -UseBasicParsing
    Write-Host "Done." -ForegroundColor Green
}

# Download WinPE Setup if missing
if (-not (Test-Path $WinPESetupPath)) {
    Write-Host "Downloading WinPE Setup..." -NoNewline
    Invoke-WebRequest -Uri $UrlWinPE -OutFile $WinPESetupPath -UseBasicParsing
    Write-Host "Done." -ForegroundColor Green
}

# 2. Install ADK Core
if (Test-Path "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe") {
    Write-Host "[SKIP] ADK Core is already installed." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
}
else {
    Write-Host "Installing ADK Core (Wait ~5 mins)..." 
    Write-Host " for more info check log file: $LogPathADK" 
    $ADKArgs = "/norestart /quiet /ceip off /log `"$LogPathADK`" /features $($ADKFeatures -join ' ')"
    
    $StartTime = Get-Date
    $proc = Start-Process -FilePath $ADKSetupPath -ArgumentList $ADKArgs -PassThru
    
    # Progress timer
    while (-not $proc.HasExited) {
        $Elapsed = New-TimeSpan -Start $StartTime -End (Get-Date)
        Write-Host -NoNewline "`r   Installing ADK Core...   " -ForegroundColor Yellow
        # Write-Host -NoNewline "$([int]$Elapsed.TotalMinutes)m $($Elapsed.Seconds)s" -ForegroundColor Cyan
        # Write-Host -NoNewline "]" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    
    if ($proc.ExitCode -eq 0) {
        Write-Host "ADK Core Installed Successfully." -ForegroundColor Green
        Stop-PhaseTimer -Status Success
    }
    else {
        Stop-PhaseTimer -Status Failed
        Write-Error "ADK Install Failed. Exit Code: $($proc.ExitCode)"
        Write-Host "--- LOG TAIL ---" -ForegroundColor Red
        Get-Content $LogPathADK -Tail 15
        exit 1
    }
}

# 3. Install WinPE Add-on
Start-PhaseTimer -PhaseName "WINPE ADD-ON INSTALLATION"
if (Test-Path "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim") {
    Write-Host "[SKIP] WinPE is already installed." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
}
else {
    Write-Host "Installing WinPE Add-on (Wait ~15 mins)..."
    Write-Host " for more info check log file: $LogPathWinPE"
    $WinPEArgs = "/norestart /quiet /ceip off /log `"$LogPathWinPE`" /features $WinPEFeature"
    
    $StartTime = Get-Date
    $procPE = Start-Process -FilePath $WinPESetupPath -ArgumentList $WinPEArgs -PassThru
    
    # Progress timer
    while (-not $procPE.HasExited) {
        $Elapsed = New-TimeSpan -Start $StartTime -End (Get-Date)
        Write-Host -NoNewline "`r   Installing WinPE Add-on...   " -ForegroundColor Yellow
        # Write-Host -NoNewline "$([int]$Elapsed.TotalMinutes)m $($Elapsed.Seconds)s" -ForegroundColor Cyan
        # Write-Host -NoNewline "]" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    
    if ($procPE.ExitCode -eq 0) {
        Write-Host "WinPE Add-on Installed Successfully." -ForegroundColor Green
        Stop-PhaseTimer -Status Success
    }
    else {
        Stop-PhaseTimer -Status Failed
        Write-Error "WinPE Install Failed. Exit Code: $($procPE.ExitCode)"
        Write-Host "--- LOG TAIL ---" -ForegroundColor Red
        Get-Content $LogPathWinPE -Tail 15
        exit 1
    }
}

# --- PART 3: VERIFICATION ---
Write-Host "`n--- FINAL VERIFICATION ---" -ForegroundColor Magenta

$Check1 = Test-Path "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe"
$Check2 = Test-Path "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim"

if ($Check1) { Write-Host "[OK] ADK Core Found." -ForegroundColor Green } 
else { Write-Host "[FAIL] ADK Core Missing." -ForegroundColor Red }

if ($Check2) { Write-Host "[OK] WinPE Found." -ForegroundColor Green } 
else { Write-Host "[FAIL] WinPE Missing." -ForegroundColor Red }

# Show installation summary
Show-InstallationSummary