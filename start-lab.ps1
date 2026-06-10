# start-lab.ps1
# Deploy and start DVAD (Damn Vulnerable Active Directory). Works both locally and on a fresh remote server.
# On a remote server, run this script directly - it will clone the repo if needed.
#
# Usage:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\start-lab.ps1

$ErrorActionPreference = "Stop"

$repoUrl   = "https://github.com/Omaar1/DVAD.git"
$cloneDest = "C:\DVAD"

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " DVAD - Damn Vulnerable Active Directory" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan


# ----------------------------------------------------------------
# 1. Verify Vagrant and VirtualBox
# ----------------------------------------------------------------
Write-Host ""
Write-Host "[1] Checking prerequisites..." -ForegroundColor Yellow

$vagrantCmd  = Get-Command vagrant -ErrorAction SilentlyContinue
$vagrantPath = $null
if ($vagrantCmd) { $vagrantPath = $vagrantCmd.Source }
if (-not $vagrantPath) {
    Write-Host "[!] Vagrant not found. Install from https://www.vagrantup.com/downloads" -ForegroundColor Red
    exit 1
}
Write-Host "  Vagrant : $(vagrant --version)"

$vboxCmd  = Get-Command VBoxManage -ErrorAction SilentlyContinue
$vboxPath = $null
if ($vboxCmd) {
    $vboxPath = $vboxCmd.Source
} else {
    $vboxFallback = Join-Path $env:ProgramFiles "Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path $vboxFallback) { $vboxPath = $vboxFallback }
}
if (-not $vboxPath) {
    Write-Host "[!] VirtualBox (VBoxManage) not found. Install from https://www.virtualbox.org/" -ForegroundColor Red
    exit 1
}
Write-Host "  VBox    : $(& $vboxPath --version)"

# ----------------------------------------------------------------
# 2. Install required Vagrant plugins
# ----------------------------------------------------------------
Write-Host ""
Write-Host "[2] Checking Vagrant plugins..." -ForegroundColor Yellow

$installedPlugins = vagrant plugin list 2>&1

if ($installedPlugins -match "vagrant-winrm") {
    Write-Host "  [OK] vagrant-winrm"
} else {
    Write-Host "[!] vagrant-winrm plugin is missing. Run setup-lab.ps1 first." -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------
# 3. Ordered VM startup
# ----------------------------------------------------------------
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Starting VMs (ordered)" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

function Start-VM {
    param([string]$Name, [int]$WaitSeconds = 60)
    Write-Host ""
    Write-Host "[*] Starting $Name..." -ForegroundColor Yellow
    vagrant up $Name
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] Failed to start $Name (exit $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
    Write-Host "[+] $Name up. Waiting ${WaitSeconds}s for services to settle..." -ForegroundColor Green
    Start-Sleep -Seconds $WaitSeconds
}

# DVAD-DC first - everything else joins its domain
Start-VM -Name "DVAD-DC" -WaitSeconds 90

# CA01 (ADCS) and CM01 (SCCM) next - both join the domain independently
Write-Host ""
Write-Host "[*] Starting CA01 and CM01..." -ForegroundColor Yellow
vagrant up CA01 CM01
if ($LASTEXITCODE -ne 0) {
    Write-Host "[!] One or more member servers failed to start" -ForegroundColor Red
    exit 1
}
Write-Host "[+] CA01 and CM01 started." -ForegroundColor Green
Start-Sleep -Seconds 60

# SRV01 last - configure-machine-attacks.ps1 needs the CA01 computer object in AD
Start-VM -Name "SRV01" -WaitSeconds 30

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " All VMs started" -ForegroundColor Cyan
Write-Host " Run .\verify-lab.ps1 to check health" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan