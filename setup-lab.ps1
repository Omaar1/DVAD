param(
    [switch]$SkipProvision
)

$ErrorActionPreference = "Stop"

function Write-Status  { param($msg) Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok      { param($msg) Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Fail    { param($msg) Write-Host "[X] $msg" -ForegroundColor Red }

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "This script must be run as Administrator."
    Write-Fail "Right-click PowerShell and select 'Run as Administrator', then try again."
    exit 1
}

# Single source of truth for hostnames, IPs, box, and resources.
. "$PSScriptRoot\provisioners\get-lab-config.ps1"
$cfg = Get-LabConfig

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Magenta
Write-Host "   DVAD - Damn Vulnerable Active Directory" -ForegroundColor Magenta
Write-Host "   4 VMs: $($cfg.hosts.rootdc.name) + $($cfg.hosts.adcs.name) + $($cfg.hosts.sccm.name) + $($cfg.hosts.svr1.name) ($($cfg.domain.fqdn))" -ForegroundColor Magenta
Write-Host "  ============================================" -ForegroundColor Magenta
Write-Host ""

$needsReboot = $false
$labPath = $PSScriptRoot
if (-not (Test-Path "$labPath\Vagrantfile")) {
    Write-Fail "Vagrantfile not found in $labPath"
    Write-Fail "Run this script from the lab folder (where Vagrantfile is)."
    exit 1
}

Write-Host "  Where should VMs and box images be stored?" -ForegroundColor Yellow
Write-Host "    [1] C: drive (default Windows drive)" -ForegroundColor White
Write-Host "    [2] D: drive (secondary/larger drive)" -ForegroundColor White
Write-Host ""
$driveChoice = Read-Host "  Choose (1 or 2)"

if ($driveChoice -eq "2") {
    $storageDrive = "D:"
} else {
    $storageDrive = "C:"
}

$boxVersion = $cfg.box.version

Write-Host ""

if ($storageDrive -eq "C:") {
    $vagrantHome = "$env:USERPROFILE\.vagrant.d"
    $vboxVMFolder = "$env:USERPROFILE\VirtualBox VMs"
} else {
    $vagrantHome = "$storageDrive\Vagrant\.vagrant.d"
    $vboxVMFolder = "$storageDrive\VirtualBox VMs"
}

Write-Status "Configuring storage on $storageDrive drive..."
if (-not (Test-Path $storageDrive)) {
    Write-Fail "$storageDrive drive not found."
    exit 1
}

New-Item -ItemType Directory -Path $vagrantHome -Force | Out-Null
New-Item -ItemType Directory -Path $vboxVMFolder -Force | Out-Null

$env:VAGRANT_HOME = $vagrantHome
[Environment]::SetEnvironmentVariable("VAGRANT_HOME", $vagrantHome, "User")
Write-Ok "VAGRANT_HOME = $vagrantHome"

Write-Ok "Box version: $boxVersion"

Write-Status "Checking operating system..."
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch "Windows 10|Windows 11|Server 2016|Server 2019|Server 2022") {
    Write-Fail "Unsupported OS: $($os.Caption)"
    exit 1
}
Write-Ok "OS: $($os.Caption)"

Write-Status "Checking RAM..."
$totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
if ($totalRAM -lt 10) {
    Write-Fail "Only ${totalRAM} GB RAM detected. Minimum 10 GB required (lab needs ~8 GB)."
    exit 1
}
if ($totalRAM -lt 16) {
    Write-Warn "${totalRAM} GB RAM detected. Lab needs ~8 GB. Performance may be limited."
} else {
    Write-Ok "${totalRAM} GB RAM available"
}

Write-Status "Checking disk space on $storageDrive..."
$driveLetter = $storageDrive.TrimEnd(':')
$freeGB = [math]::Round((Get-PSDrive $driveLetter).Free / 1GB, 1)
if ($freeGB -lt 40) {
    Write-Fail "Only ${freeGB} GB free on $storageDrive. At least 40 GB required."
    exit 1
}
if ($freeGB -lt 60) {
    Write-Warn "${freeGB} GB free on $storageDrive. 40 GB minimum, 60+ GB recommended."
} else {
    Write-Ok "${freeGB} GB free on $storageDrive"
}

Write-Status "Checking Hyper-V and Credential Guard..."
$hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
$hvci = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name EnableVirtualizationBasedSecurity -ErrorAction SilentlyContinue

$hypervBlocking = $false
if ($hyperv -and $hyperv.State -eq "Enabled") {
    Write-Warn "Hyper-V is ENABLED. This may prevent VirtualBox from using VT-x."
    $hypervBlocking = $true
}
if ($hvci -and $hvci.EnableVirtualizationBasedSecurity -eq 1) {
    Write-Warn "Credential Guard / VBS is ENABLED. This may prevent VirtualBox from using VT-x."
    $hypervBlocking = $true
}

if ($hypervBlocking) {
    Write-Warn ""
    Write-Warn "VirtualBox may fail or run very slowly with Hyper-V/Credential Guard enabled."
    Write-Warn "To disable (requires reboot):"
    Write-Warn "  bcdedit /set hypervisorlaunchtype off"
    Write-Warn "  Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart"
    Write-Warn ""
    $choice = Read-Host "Continue anyway? (y/N)"
    if ($choice -ne "y" -and $choice -ne "Y") {
        Write-Status "Exiting. Disable Hyper-V, reboot, and run this script again."
        exit 0
    }
} else {
    Write-Ok "Hyper-V / Credential Guard not blocking"
}

Write-Status "Checking VirtualBox..."
Refresh-Path
$vbox = Get-Command VBoxManage -ErrorAction SilentlyContinue

if (-not $vbox) {
    $vboxPaths = @(
        "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
        "${env:ProgramFiles}\Oracle\VirtualBox\VBoxManage.exe"
    )
    foreach ($p in $vboxPaths) {
        if (Test-Path $p) { $vbox = Get-Command $p; break }
    }
}

if (-not $vbox) {
    Write-Warn "VirtualBox not found. Installing via winget..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Fail "winget not available. Please install VirtualBox manually from:"
        Write-Fail "  https://www.virtualbox.org/wiki/Downloads"
        exit 1
    }
    winget install Oracle.VirtualBox --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "VirtualBox installation failed. Please install it manually."
        exit 1
    }
    Refresh-Path
    $vbox = Get-Command VBoxManage -ErrorAction SilentlyContinue
    if (-not $vbox) {
        foreach ($p in @("C:\Program Files\Oracle\VirtualBox\VBoxManage.exe")) {
            if (Test-Path $p) { $vbox = Get-Command $p; break }
        }
    }
    Write-Ok "VirtualBox installed"
    $needsReboot = $true
} else {
    $vboxVersion = & $vbox.Source --version 2>$null
    Write-Ok "VirtualBox $vboxVersion found"
}

$vboxCmd = $null
if ($vbox) {
    $vboxCmd = $vbox.Source
} elseif (Test-Path "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe") {
    $vboxCmd = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
}

Write-Status "Setting VirtualBox VM folder to $vboxVMFolder..."
if ($vboxCmd -and (Test-Path $vboxCmd)) {
    & $vboxCmd setproperty machinefolder $vboxVMFolder 2>$null
    Write-Ok "VirtualBox VM folder = $vboxVMFolder"
}

$labVMNames = @($cfg.hosts.rootdc.name, $cfg.hosts.adcs.name, $cfg.hosts.sccm.name, $cfg.hosts.svr1.name)
Write-Status "Checking for existing VMs with lab names..."
$existingVMs = @()
if ($vboxCmd -and (Test-Path $vboxCmd)) {
    $allVMs = & $vboxCmd list vms 2>$null
    foreach ($vmName in $labVMNames) {
        if ($allVMs -match "`"$vmName`"") {
            $existingVMs += $vmName
        }
    }
}

if ($existingVMs.Count -gt 0) {
    Write-Warn "Found existing VMs with lab names: $($existingVMs -join ', ')"
    Write-Warn "These must be removed before building the lab."
    $choice = Read-Host "Delete these VMs and continue? (y/N)"
    if ($choice -ne "y" -and $choice -ne "Y") {
        Write-Status "Exiting. Remove the VMs manually and run this script again."
        exit 0
    }
    $ErrorActionPreference = "Continue"
    foreach ($vmName in $existingVMs) {
        Write-Status "Removing VM: $vmName..."
        & $vboxCmd controlvm $vmName poweroff 2>$null
        Start-Sleep -Seconds 3
        & $vboxCmd unregistervm $vmName --delete 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Removed $vmName"
        } else {
            & $vboxCmd unregistervm $vmName 2>$null
            Write-Warn "Unregistered $vmName (disk files may remain)"
        }
    }
    $ErrorActionPreference = "Stop"
    Set-Location $labPath
    & vagrant destroy -f 2>$null
    Write-Ok "Existing VMs cleaned up"
}

Write-Status "Checking Vagrant..."
Refresh-Path
$vagrant = Get-Command vagrant -ErrorAction SilentlyContinue

if (-not $vagrant) {
    Write-Warn "Vagrant not found. Installing via winget..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Fail "winget not available. Please install Vagrant manually from:"
        Write-Fail "  https://developer.hashicorp.com/vagrant/downloads"
        exit 1
    }
    winget install Hashicorp.Vagrant --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Vagrant installation failed. Please install it manually."
        exit 1
    }
    Refresh-Path
    $vagrant = Get-Command vagrant -ErrorAction SilentlyContinue
    if (-not $vagrant) {
        Write-Ok "Vagrant installed but PATH not updated in this session."
        Write-Warn "Please CLOSE this terminal, open a new one, and run this script again."
        exit 0
    }
    Write-Ok "Vagrant installed"
    $needsReboot = $true
} else {
    $vagrantVersion = & vagrant --version 2>$null
    Write-Ok "$vagrantVersion found"
}

Write-Status "Checking required Vagrant plugins..."
$plugins = & vagrant plugin list 2>$null
if ($plugins -match "vagrant-winrm") {
    Write-Ok "vagrant-winrm installed"
} else {
    Write-Warn "Installing vagrant-winrm..."
    & vagrant plugin install vagrant-winrm
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to install vagrant-winrm."
        exit 1
    }
    Write-Ok "vagrant-winrm installed"
}

if ($needsReboot) {
    Write-Warn ""
    Write-Warn "Software was installed that may require a REBOOT to work properly."
    $choice = Read-Host "Reboot now? (y/N)"
    if ($choice -eq "y" -or $choice -eq "Y") {
        Write-Status "Rebooting in 10 seconds... Run this script again after reboot."
        shutdown /r /t 10 /c "Rebooting for VirtualBox/Vagrant installation"
        exit 0
    }
}

Write-Status "Checking Vagrant box (StefanScherer/windows_2019 v$boxVersion)..."
$boxes = & vagrant box list 2>$null
if ($boxes -match "StefanScherer/windows_2019\s.*$([regex]::Escape($boxVersion))") {
    Write-Ok "Vagrant box v$boxVersion already available"
} else {
    if ($boxes -match "StefanScherer/windows_2019") {
        Write-Warn "A different version of the box exists, but not v$boxVersion."
        Write-Warn "The correct version will be downloaded during 'vagrant up' (~5-6 GB)."
    } else {
        Write-Warn "Vagrant box not found locally."
        Write-Warn "It will be downloaded automatically during 'vagrant up' (~5-6 GB download)."
    }
    Write-Warn "Make sure you have a stable internet connection."
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "   All Prerequisites Satisfied" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Lab Path:   $labPath" -ForegroundColor White
Write-Host "  Storage:    $storageDrive (boxes + VMs)" -ForegroundColor White
Write-Host "  Box:        $($cfg.box.name) v$boxVersion" -ForegroundColor White
Write-Host "  Domain:     $($cfg.domain.fqdn)" -ForegroundColor White
Write-Host "  $($cfg.hosts.rootdc.name):    $($cfg.hosts.rootdc.ip) ($([math]::Round($cfg.hosts.rootdc.memory/1024)) GB RAM)" -ForegroundColor White
Write-Host "  $($cfg.hosts.adcs.name):       $($cfg.hosts.adcs.ip) ($([math]::Round($cfg.hosts.adcs.memory/1024)) GB RAM)" -ForegroundColor White
Write-Host "  $($cfg.hosts.sccm.name):       $($cfg.hosts.sccm.ip) ($([math]::Round($cfg.hosts.sccm.memory/1024)) GB RAM)" -ForegroundColor White
Write-Host "  $($cfg.hosts.svr1.name):      $($cfg.hosts.svr1.ip) ($([math]::Round($cfg.hosts.svr1.memory/1024)) GB RAM)" -ForegroundColor White
Write-Host "  Total RAM:  ~$([math]::Round(($cfg.hosts.rootdc.memory + $cfg.hosts.adcs.memory + $cfg.hosts.sccm.memory + $cfg.hosts.svr1.memory)/1024)) GB for VMs" -ForegroundColor White
Write-Host ""

if ($SkipProvision) {
    Write-Ok "Prerequisites checked. Skipping vagrant up (-SkipProvision flag)."
    Write-Status "When ready, run: vagrant up"
    exit 0
}

$choice = Read-Host "Start building the lab now? This will take 45-90 minutes (y/N)"
if ($choice -ne "y" -and $choice -ne "Y") {
    Write-Status "Setup complete. When ready, run: vagrant up"
    exit 0
}

Write-Host ""
Write-Status "Building the lab..."
Write-Status "This will create 4 Windows VMs, install Active Directory, ADCS, and configure everything."
Write-Status "Do NOT close this window."
Write-Host ""

Set-Location $labPath
$log = "$labPath\setup.log"

$rootName = $cfg.hosts.rootdc.name
$adcsName = $cfg.hosts.adcs.name
$sccmName = $cfg.hosts.sccm.name
$svr1Name = $cfg.hosts.svr1.name

Write-Status "Step 1/3 - Starting $rootName (domain controller)..."
& vagrant up $rootName 2>&1 | Tee-Object -FilePath $log
if ($LASTEXITCODE -ne 0) {
    Write-Fail "$rootName failed. Check log: $log"
    exit 1
}
Write-Ok "$rootName up. Waiting 90s for AD services to settle..."
Start-Sleep -Seconds 90

Write-Status "Step 2/3 - Starting $adcsName and $sccmName..."
& vagrant up $adcsName $sccmName 2>&1 | Tee-Object -FilePath $log -Append
if ($LASTEXITCODE -ne 0) {
    Write-Fail "$adcsName or $sccmName failed. Check log: $log"
    exit 1
}
Write-Ok "$adcsName and $sccmName up. Waiting 60s..."
Start-Sleep -Seconds 60

Write-Status "Step 3/3 - Starting $svr1Name..."
& vagrant up $svr1Name 2>&1 | Tee-Object -FilePath $log -Append
if ($LASTEXITCODE -ne 0) {
    Write-Fail "$svr1Name failed. Check log: $log"
    exit 1
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "   Lab Built Successfully!" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Domain:     $($cfg.domain.fqdn)" -ForegroundColor White
Write-Host "  $($cfg.hosts.rootdc.name):    $($cfg.hosts.rootdc.ip)" -ForegroundColor White
Write-Host "  $($cfg.hosts.adcs.name):       $($cfg.hosts.adcs.ip)" -ForegroundColor White
Write-Host "  $($cfg.hosts.sccm.name):       $($cfg.hosts.sccm.ip)" -ForegroundColor White
Write-Host "  $($cfg.hosts.svr1.name):      $($cfg.hosts.svr1.ip)" -ForegroundColor White
Write-Host "  Log:        $log" -ForegroundColor White
Write-Host ""
Write-Host "  Run .\verify-lab.ps1 to check health" -ForegroundColor Cyan
Write-Host ""
