# Install-ADK.ps1 (Online Version + Network Setup)
# ---------------------------------------------------
# 1. Configures Network for Internet Access
# 2. Downloads and Installs ADK + WinPE (ADK 10.1.26100.2454, Dec 2024 - matches ConfigMgr 2403)
# 3. Verifies Installation

$ErrorActionPreference = "Stop"

# Import Phase Timer Module
Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force

# --- PART 1: NETWORK SETUP (GO ONLINE) ---
Start-PhaseTimer -PhaseName "CONFIGURING NETWORK FOR INTERNET"

# Put public DNS on the NAT NIC so external downloads resolve (single networking script).
& "C:\vagrant\provisioners\net\configure-network.ps1" -Action NatInternetDns

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

# 3. Connectivity Test - probe the actual ADK download host over HTTPS (TCP 443).
# NB VirtualBox NAT commonly drops guest ICMP echo while passing TCP fine, so an ICMP
# ping is a false negative here. ADK downloads over HTTPS, so gate on TCP 443 instead.
Write-Host "Testing Internet Connection (HTTPS to go.microsoft.com)..." -NoNewline
$online = Test-NetConnection -ComputerName "go.microsoft.com" -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
if ($online) {
    Write-Host " [SUCCESS]" -ForegroundColor Green
}
else {
    Stop-PhaseTimer -Status Failed
    Write-Error " [FAIL] No HTTPS access to go.microsoft.com:443. Check host internet / VPN / VirtualBox NAT."
    exit 1
}
Stop-PhaseTimer -Status Success

# --- PART 2: ADK INSTALLATION ---
Start-PhaseTimer -PhaseName "ADK CORE INSTALLATION"

# Guest-local dir (NOT the synced repo folder): keeps binaries out of git and forces a
# fresh download of the current bootstrapper instead of reusing a stale committed one.
$DownloadDir = "C:\ADK-Setup"
$LogPathADK = "C:\ADKinstallerLog.txt"
$LogPathWinPE = "C:\winPEADKinstallerLog.txt"

# Features to install (Standard SCCM requirements)
$ADKFeatures = 'OptionId.DeploymentTools', 'OptionId.ImagingAndConfigurationDesigner', 'OptionId.ICDConfigurationDesigner', 'OptionId.UserStateMigrationTool'
$WinPEFeature = 'OptionId.WindowsPreinstallationEnvironment'

# Current, Microsoft-maintained ADK download links (version-stable fwlinks), pinned to
# ADK 10.1.26100.2454 (Dec 2024): supported by ConfigMgr 2403 and still hosted by MS.
# NB do NOT commit a bootstrapper to the repo - old ones embed a component-download root
# that Microsoft eventually deletes (as happened to ADK 2004), silently breaking clones.
$UrlADK = "https://go.microsoft.com/fwlink/?linkid=2289980"
$UrlWinPE = "https://go.microsoft.com/fwlink/?linkid=2289981"

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
        # Print the log tail BEFORE Write-Error: under $ErrorActionPreference='Stop' a
        # Write-Error terminates immediately, so anything after it never runs.
        Write-Host "--- ADK LOG TAIL (last 20) ---" -ForegroundColor Red
        Get-Content $LogPathADK -Tail 20 -ErrorAction SilentlyContinue
        Write-Host "--- end log ---" -ForegroundColor Red
        Write-Error "ADK Install Failed. Exit Code: $($proc.ExitCode)"
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
        Write-Host "--- WinPE LOG TAIL (last 20) ---" -ForegroundColor Red
        Get-Content $LogPathWinPE -Tail 20 -ErrorAction SilentlyContinue
        Write-Host "--- end log ---" -ForegroundColor Red
        Write-Error "WinPE Install Failed. Exit Code: $($procPE.ExitCode)"
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