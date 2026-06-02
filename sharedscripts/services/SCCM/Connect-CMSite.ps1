# Connect-CMSite.ps1
# ------------------------------------------------------------------------------
# Shared helper: locate the ConfigurationManager PowerShell module, import it,
# and connect to the SCCM site (CMSite PSDrive). Dot-source this file, then call
# Connect-CMSite. Replaces the ~30-line locate/import/connect block that was
# copy-pasted across the SCCM provisioning scripts.
#
#   . C:\vagrant\sharedscripts\services\SCCM\Connect-CMSite.ps1
#   Connect-CMSite -SiteCode $SiteCode -SiteServer $SiteServer
#
# SiteCode/SiteServer default to lab-config.json (sccm.siteCode and the derived
# SCCM FQDN) when omitted. Throws on failure so the ps.ps1 trap / caller catch
# surfaces it. Idempotent: skips import/drive creation if already present.
# ------------------------------------------------------------------------------

function Connect-CMSite {
    param(
        [string] $SiteCode,
        [string] $SiteServer
    )

    if (-not $SiteCode -or -not $SiteServer) {
        . C:\vagrant\sharedscripts\Get-LabConfig.ps1
        $cfg = Get-LabConfig
        if (-not $SiteCode)   { $SiteCode   = $cfg.sccm.siteCode }
        if (-not $SiteServer) { $SiteServer = "$($cfg.hosts.sccm.name).$($cfg.domain.fqdn)" }
    }

    Write-Host "--- INITIALIZING SCCM MODULE ---" -ForegroundColor Cyan

    # 1. Locate ConfigurationManager.psd1: registry first, then standard paths.
    $consolePath = $null
    $regKey = "HKLM:\SOFTWARE\Microsoft\ConfigMgr10\Setup"
    if (Test-Path $regKey) {
        $installDir = (Get-ItemProperty -Path $regKey -Name "UI Installation Directory" -ErrorAction SilentlyContinue)."UI Installation Directory"
        if ($installDir) { $consolePath = Join-Path $installDir "bin\ConfigurationManager.psd1" }
    }
    if (-not $consolePath -or -not (Test-Path $consolePath)) {
        $candidates = @(
            "$($env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1",
            "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
        )
        $consolePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $consolePath -or -not (Test-Path $consolePath)) {
        throw "Could not locate ConfigurationManager.psd1 in any standard location."
    }

    # 2. Import the module (idempotent).
    if (-not (Get-Module -Name ConfigurationManager)) {
        Write-Host " [INFO] Loading module from: $consolePath" -ForegroundColor Gray
        Import-Module $consolePath -ErrorAction Stop
    }
    if (-not (Get-Module -Name ConfigurationManager)) {
        throw "ConfigurationManager module failed to load from $consolePath."
    }

    # 3. Connect to the site (create the CMSite PSDrive if missing) and switch to it.
    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
    }
    Set-Location "$($SiteCode):"
    Write-Host " [OK] Connected to Site $SiteCode" -ForegroundColor Green
}
