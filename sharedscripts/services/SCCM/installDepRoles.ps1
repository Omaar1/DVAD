# ==============================================================================
# Script: installDepRoles.ps1
# Purpose: Install IIS, .NET Framework 3.5, BITS, and SCCM prerequisites
# ==============================================================================
#
# This script installs:
#   - IIS Web Server with required modules for SCCM
#   - .NET Framework 3.5 (from Windows Update)
#   - BITS (Background Intelligent Transfer Service) with IIS extension
#   - Remote Differential Compression (RDC)
#   - IIS 6 Management Compatibility (required for SCCM)
#   - Windows Authentication and other security features
#
# ==============================================================================

# Import Phase Timer Module
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

# Start logging
Start-Transcript -Path "C:\IIS_Install_Log.txt" -Append

# Check for administrative privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run with administrative privileges."
    Stop-Transcript
    exit
}
Write-Host "Running with administrative privileges."

# ==============================================================================
# PHASE 1: INITIALIZE
# ==============================================================================
Start-PhaseTimer -PhaseName "INITIALIZING INSTALLATION"

try {
    Import-Module ServerManager -ErrorAction Stop
    Write-Host "ServerManager module loaded successfully."
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Failed to load ServerManager module: $_"
    Stop-Transcript
    exit
}

# ==============================================================================
# PHASE 2: INSTALLING .NET FRAMEWORK 3.5 (NATIVE POWERSHELL)
# ==============================================================================
Start-PhaseTimer -PhaseName "INSTALLING .NET FRAMEWORK 3.5"

try {
    # 1. Check current status
    $FeatureStatus = Get-WindowsOptionalFeature -Online -FeatureName "NetFx3"
    
    if ($FeatureStatus.State -eq "Enabled") {
        Write-Host " [OK] .NET Framework 3.5 is already installed." -ForegroundColor Green
        Stop-PhaseTimer -Status Success
    }
    else {
        # Prefer a pre-staged offline source if present (drop the SxS cabs into
        # ...\SCCM\sxs for air-gapped hosts). The cabs are intentionally NOT committed
        # to the repo - by default we pull NetFx3 from Windows Update instead.
        $LocalSource = "C:\vagrant\sharedscripts\services\SCCM\sxs"
        $haveLocal = (Test-Path $LocalSource) -and
                     (@(Get-ChildItem -Path $LocalSource -Filter '*.cab' -ErrorAction SilentlyContinue).Count -gt 0)

        if ($haveLocal) {
            Write-Host "Installing .NET 3.5 from pre-staged offline source ($LocalSource)..." -ForegroundColor Cyan
            Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -Source $LocalSource -LimitAccess -NoRestart -ErrorAction Stop
        }
        else {
            # Official source: Windows Update Features on Demand (nothing redistributed
            # or committed). Two prerequisites this early in provisioning:
            #  1. Internet DNS - the box's DNS still points only at the DC (set during
            #     join) which cannot route to Windows Update; put public DNS on the NAT
            #     NIC first (the 0x800f0950 "source not found" error is this missing).
            #  2. wuauserv - provision-base disables it; DISM needs it to fetch the FOD.
            # Both are reverted by later steps (installMECM re-points DNS as needed).
            Write-Host "Installing .NET 3.5 from Windows Update (online)..." -ForegroundColor Cyan
            & "C:\vagrant\sharedscripts\networking\configure-network.ps1" -Action NatInternetDns
            $prevStart = (Get-CimInstance Win32_Service -Filter "Name='wuauserv'").StartMode
            try {
                Set-Service wuauserv -StartupType Manual -ErrorAction SilentlyContinue
                Start-Service wuauserv -ErrorAction SilentlyContinue
                Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop
            }
            finally {
                Stop-Service wuauserv -ErrorAction SilentlyContinue
                if ($prevStart -eq 'Disabled') { Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue }
            }
        }

        Write-Host " [SUCCESS] .NET 3.5 Installed." -ForegroundColor Green
        Stop-PhaseTimer -Status Success
    }
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Failed to install .NET Framework 3.5: $_"
    exit 1
}


# ==============================================================================
# PHASE 3: IIS ROLES & FEATURES
# ==============================================================================
Start-PhaseTimer -PhaseName "INSTALLING IIS ROLES & FEATURES"

# Features installed via DeploymentConfigTemplate.xml:
#   - Web-Server (IIS)
#   - Web-ISAPI-Ext, Web-ISAPI-Filter (CRITICAL for Management Point)
#   - Web-Windows-Auth (Windows Authentication)
#   - Web-Metabase, Web-WMI (IIS 6 Compatibility)
#   - BITS, BITS-IIS-Ext (Background Transfer)
#   - RDC (Remote Differential Compression)

try {
    Write-Host "Installing IIS, BITS, and required features from configuration template..."
    Install-WindowsFeature -ConfigurationFilePath C:\vagrant\sharedscripts\services\SCCM\DeploymentConfigTemplate.xml -ErrorAction Stop
    Write-Host "Roles and features installed successfully."
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Failed to install roles and features: $_"
}

# ==============================================================================
# PHASE 4: IIS CLEANUP & CONFIGURATION
# ==============================================================================
Start-PhaseTimer -PhaseName "IIS CLEANUP & CONFIGURATION"

try {
    Write-Host "Cleaning IIS bindings to prevent MP installation errors..."
    
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Remove conflicting HTTPS bindings (prevents Error 25055 during MP Setup)
    $Binding = Get-WebBinding -Name "Default Web Site" -Protocol "https" -ErrorAction SilentlyContinue
    if ($Binding) {
        Write-Host "Removing conflicting HTTPS binding..."
        Remove-WebBinding -Name "Default Web Site" -Protocol "https"
        Write-Host "HTTPS binding removed."
    }
    else {
        Write-Host "No conflicting HTTPS bindings found."
    }

    # Ensure BITS Uploads are enabled
    Write-Host "Enforcing BITS Uploads on Default Web Site..."
    Set-WebConfigurationProperty -Filter "/system.webServer/serverRuntime" -Name "enabled" -Value "True" -PSPath "IIS:/" -ErrorAction SilentlyContinue
    
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Warning
    Write-Warning "Non-critical error during IIS Cleanup: $_"
}

# ==============================================================================
# COMPLETE
# ==============================================================================
Show-InstallationSummary
Write-Host "Installation completed. A server restart may be required."
Write-Host "Check C:\IIS_Install_Log.txt for details."

Stop-Transcript