# start-lab.ps1
# Deploy and start SilentRUN-Lab. Works both locally and on a fresh remote server.
# On a remote server, run this script directly — it will clone the repo if needed.
#
# Usage:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\start-lab.ps1

$ErrorActionPreference = "Stop"

$repoUrl   = "https://github.com/Omaar1/SilentRUN-Lab.git"
$cloneDest = "C:\SilentRUN-Lab"

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " SilentRUN-Lab" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# ----------------------------------------------------------------
# 0. Ensure we are running from inside the repo
#    (handles fresh remote server deployments via git clone)
# ----------------------------------------------------------------
if (-not (Test-Path ".\Vagrantfile")) {
    Write-Host ""
    Write-Host "[0] Vagrantfile not found — cloning repo..." -ForegroundColor Yellow

    $gitPath = (Get-Command git -ErrorAction SilentlyContinue)?.Source
    if (-not $gitPath) {
        Write-Host "[!] Git not found. Install it first:" -ForegroundColor Red
        Write-Host "      winget install --id Git.Git -e --source winget" -ForegroundColor Red
        Write-Host "    Then open a new PowerShell and re-run this script." -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path $cloneDest)) {
        Write-Host "  [*] git clone $repoUrl -> $cloneDest"
        git clone $repoUrl $cloneDest
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[!] Clone failed — check network connectivity." -ForegroundColor Red
            exit 1
        }
        Write-Host "  [+] Clone complete" -ForegroundColor Green
    } else {
        Write-Host "  [*] $cloneDest already exists — pulling latest..."
        git -C $cloneDest pull
        Write-Host "  [+] Up to date" -ForegroundColor Green
    }

    Set-Location $cloneDest
    Write-Host "  Working directory: $cloneDest"
} elseif (Test-Path ".git") {
    Write-Host ""
    Write-Host "[0] Pulling latest changes..." -ForegroundColor Yellow
    git pull 2>&1 | Out-Null
    Write-Host "  [+] Up to date" -ForegroundColor Green
}

# ----------------------------------------------------------------
# 1. Verify Vagrant and VirtualBox
# ----------------------------------------------------------------
Write-Host ""
Write-Host "[1] Checking prerequisites..." -ForegroundColor Yellow

$vagrantPath = (Get-Command vagrant -ErrorAction SilentlyContinue)?.Source
if (-not $vagrantPath) {
    Write-Host "[!] Vagrant not found. Install from https://www.vagrantup.com/downloads" -ForegroundColor Red
    exit 1
}
Write-Host "  Vagrant : $(vagrant --version)"

$vboxPath = (Get-Command VBoxManage -ErrorAction SilentlyContinue)?.Source
if (-not $vboxPath) {
    Write-Host "[!] VirtualBox (VBoxManage) not found. Install from https://www.virtualbox.org/" -ForegroundColor Red
    exit 1
}
Write-Host "  VBox    : $(VBoxManage --version)"

# ----------------------------------------------------------------
# 2. Install required Vagrant plugins
# ----------------------------------------------------------------
Write-Host ""
Write-Host "[2] Checking Vagrant plugins..." -ForegroundColor Yellow

$installedPlugins = vagrant plugin list 2>&1

foreach ($plugin in @("vagrant-winrm", "vagrant-windows-sysprep")) {
    if ($installedPlugins -match $plugin) {
        Write-Host "  [OK] $plugin"
    } else {
        Write-Host "  [*] Installing $plugin..."
        vagrant plugin install $plugin
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [!] Failed to install $plugin" -ForegroundColor Red
            exit 1
        }
        Write-Host "  [+] $plugin installed" -ForegroundColor Green
    }
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

# RootDC first — everything else joins its domain
Start-VM -Name "RootDC" -WaitSeconds 90

# ADCS and SCCM next — both join the domain independently
Write-Host ""
Write-Host "[*] Starting ADCS_server and SCCM_server..." -ForegroundColor Yellow
vagrant up ADCS_server SCCM_server
if ($LASTEXITCODE -ne 0) {
    Write-Host "[!] One or more member servers failed to start" -ForegroundColor Red
    exit 1
}
Write-Host "[+] ADCS and SCCM started." -ForegroundColor Green
Start-Sleep -Seconds 60

# SVR1 last — configure-machine-attacks.ps1 needs ADCS computer object in AD
Start-VM -Name "server1" -WaitSeconds 30

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " All VMs started" -ForegroundColor Cyan
Write-Host " Run .\verify-lab.ps1 to check health" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
