# prereq.psm1 - host readiness checks for the DVAD lab.
#
# Every check returns a result object instead of writing to the console and
# calling exit. The caller decides what is fatal. That is what lets "lab.ps1
# check" report EVERY problem in one pass rather than dying on the first one -
# the single most annoying thing about the old setup-lab.ps1 flow.
#
# Thresholds are derived from the deployment plan, never hardcoded, so the
# 'core' profile is not blocked by 'full' profile requirements. The old script
# hardcoded "10 GB RAM / 40 GB disk" for a lab that actually needs 14 GB / 120 GB.

Set-StrictMode -Version Latest

function New-CheckResult {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail')] [string] $Status,
        [string] $Message,
        [string] $Fix
    )
    [PSCustomObject]@{
        Name    = $Name
        Status  = $Status
        Message = $Message
        Fix     = $Fix
    }
}

function Get-VBoxManagePath {
    <#
    .SYNOPSIS
        Locates VBoxManage.exe on PATH or in the usual install locations.
    #>
    [CmdletBinding()]
    param()

    $cmd = Get-Command VBoxManage -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'),
        'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    )
    # VBOX_MSI_INSTALL_PATH is set by the VirtualBox installer.
    if ($env:VBOX_MSI_INSTALL_PATH) {
        $candidates += (Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe')
    }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Get-LabStoragePath {
    <#
    .SYNOPSIS
        Discovers where boxes and VM disks actually land on THIS machine.
    .DESCRIPTION
        Nothing here is hardcoded to a drive letter or a user profile. The box
        cache comes from VAGRANT_HOME (or Vagrant's documented default), and the
        VM location from VirtualBox's own configured machine folder. That keeps
        the checks correct on any host regardless of how the user has set things
        up, instead of assuming the layout of whoever wrote the script.
    .PARAMETER StorageDrive
        Convenience override: put both the box cache and the VMs on this drive.
    .PARAMETER VmPath
        Override just where VM disks go. These are the big consumer (tens of GB).
    .PARAMETER BoxPath
        Override just the box cache (VAGRANT_HOME).

        VmPath and BoxPath are separate because they have genuinely different
        needs: VM disks want lots of free space, while the box cache wants to
        stay put once the 5-6 GB base box has been downloaded. Forcing both onto
        one drive means moving VMs to a bigger disk silently re-downloads the box.
    #>
    [CmdletBinding()]
    param(
        [string] $StorageDrive,
        [string] $VmPath,
        [string] $BoxPath
    )

    # Each path reports its OWN origin: using -VmPath does not mean the box cache
    # was overridden too, and saying so would misreport where the 5-6 GB lands.
    if ($BoxPath)           { $vagrantHome = $BoxPath;                                   $boxSource = 'the -BoxPath override' }
    elseif ($StorageDrive)  { $vagrantHome = Join-Path $StorageDrive 'Vagrant\.vagrant.d'; $boxSource = 'the -StorageDrive override' }
    elseif ($env:VAGRANT_HOME) { $vagrantHome = $env:VAGRANT_HOME;                       $boxSource = 'VAGRANT_HOME' }
    else                    { $vagrantHome = Join-Path $env:USERPROFILE '.vagrant.d';    $boxSource = "Vagrant's default" }

    if ($VmPath -or $StorageDrive) {
        $folder = if ($VmPath) { $VmPath } else { Join-Path $StorageDrive 'VirtualBox VMs' }
        $src    = if ($VmPath) { 'the -VmPath override' } else { 'the -StorageDrive override' }
        return [PSCustomObject]@{
            VagrantHome = $vagrantHome; MachineFolder = $folder
            BoxSource   = $boxSource;   Source = $src
        }
    }

    # Ask VirtualBox where it puts VMs rather than guessing.
    $machineFolder = $null
    $vbox = Get-VBoxManagePath
    if ($vbox) {
        $line = (& $vbox list systemproperties 2>$null) |
                Where-Object { $_ -match '^Default machine folder:' } |
                Select-Object -First 1
        if ($line) { $machineFolder = ($line -split ':', 2)[1].Trim() }
    }
    if (-not $machineFolder) {
        $machineFolder = Join-Path $env:USERPROFILE 'VirtualBox VMs'
    }

    return [PSCustomObject]@{
        VagrantHome   = $vagrantHome
        MachineFolder = $machineFolder
        BoxSource     = $boxSource
        Source        = "VirtualBox's configured machine folder"
    }
}

function Test-LabPrereq {
    <#
    .SYNOPSIS
        Runs every host readiness check for a given deployment plan.
    .PARAMETER Plan
        A plan object from New-LabPlan. Its footprint drives RAM/disk thresholds.
    .PARAMETER StorageDrive
        Drive letter (e.g. "D:") the VMs and boxes will live on.
    .OUTPUTS
        One result object per check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [string] $StorageDrive,
        [string] $VmPath,
        [string] $BoxPath
    )

    $results = @()

    # --- Administrator ------------------------------------------------------
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    # Not a hard requirement. Vagrant + VirtualBox build VMs fine unelevated; the
    # old setup script demanded admin because it ran winget installs, which this
    # one does not. Two things still want it: querying Hyper-V state, and letting
    # VirtualBox create the host-only adapter the first time on a fresh machine.
    $results += if ($isAdmin) {
        New-CheckResult -Name 'Administrator' -Status Pass -Message 'Running elevated'
    } else {
        New-CheckResult -Name 'Administrator' -Status Warn `
            -Message 'Not elevated - fine for building, but two checks are degraded' `
            -Fix 'Elevate if the Hyper-V check is inconclusive, or if VirtualBox cannot create the host-only adapter on first run.'
    }

    # --- Operating system ---------------------------------------------------
    $os = Get-CimInstance Win32_OperatingSystem
    $results += if ($os.Caption -match 'Windows 10|Windows 11|Server 2016|Server 2019|Server 2022|Server 2025') {
        New-CheckResult -Name 'Operating system' -Status Pass -Message $os.Caption
    } else {
        New-CheckResult -Name 'Operating system' -Status Warn `
            -Message "Untested OS: $($os.Caption)" `
            -Fix 'The lab is developed on Windows 10/11. Other builds may work.'
    }

    # --- RAM ----------------------------------------------------------------
    # Guests need Plan.TotalRamMB; the host itself needs headroom on top.
    $hostReserveGB = 4
    $needGB  = [math]::Round(($Plan.TotalRamMB / 1024) + $hostReserveGB, 1)
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $results += if ($totalGB -ge $needGB) {
        New-CheckResult -Name 'RAM' -Status Pass `
            -Message "$totalGB GB present, profile '$($Plan.ProfileName)' needs ~$needGB GB"
    } elseif ($totalGB -ge ($Plan.TotalRamMB / 1024)) {
        New-CheckResult -Name 'RAM' -Status Warn `
            -Message "$totalGB GB present; VMs alone want $([math]::Round($Plan.TotalRamMB/1024,1)) GB, leaving little for the host" `
            -Fix "Close other applications, or use a smaller profile."
    } else {
        New-CheckResult -Name 'RAM' -Status Fail `
            -Message "$totalGB GB present, profile '$($Plan.ProfileName)' needs ~$needGB GB" `
            -Fix "Use a smaller profile (lab.ps1 profiles) or add RAM."
    }

    # --- Disk ---------------------------------------------------------------
    # Always runs. Where the VM disks land is discovered from VirtualBox itself
    # unless -StorageDrive overrides it, so this is correct on any host rather
    # than only where a drive letter was passed in.
    $storage = Get-LabStoragePath -StorageDrive $StorageDrive -VmPath $VmPath -BoxPath $BoxPath
    $letter  = (Split-Path -Qualifier $storage.MachineFolder).TrimEnd(':')
    $drive   = Get-PSDrive $letter -ErrorAction SilentlyContinue

    if (-not $drive) {
        $results += New-CheckResult -Name 'Disk' -Status Fail `
            -Message "Drive $letter`: not found (VMs would go to $($storage.MachineFolder))" `
            -Fix 'Point -StorageDrive at a drive that exists.'
    } else {
        $freeGB   = [math]::Round($drive.Free / 1GB, 1)
        $needDisk = $Plan.DiskGB
        $where    = "$letter`: ($($storage.MachineFolder))"
        $results += if ($freeGB -ge $needDisk) {
            New-CheckResult -Name 'Disk' -Status Pass `
                -Message "$freeGB GB free on $where, need ~$needDisk GB"
        } elseif ($freeGB -ge ($needDisk * 0.7)) {
            New-CheckResult -Name 'Disk' -Status Warn `
                -Message "$freeGB GB free on $where, ~$needDisk GB recommended" `
                -Fix 'Linked clones keep usage below the worst case, but it may run tight.'
        } else {
            New-CheckResult -Name 'Disk' -Status Fail `
                -Message "$freeGB GB free on $where, need ~$needDisk GB" `
                -Fix 'Free up space, or send VMs elsewhere with -StorageDrive.'
        }
    }

    # --- Box cache location -------------------------------------------------
    # Surfaced so the user can see where the 5-6 GB box will be cached, and spot
    # a VAGRANT_HOME that points somewhere unexpected.
    $results += New-CheckResult -Name 'Box cache' -Status Pass `
        -Message "$($storage.VagrantHome) (from $($storage.BoxSource))"

    # --- Hyper-V / VBS conflict --------------------------------------------
    # Querying Hyper-V needs elevation. Without it we must NOT report "clear" -
    # that would be a false negative on the most common cause of VirtualBox
    # failing outright. Report it as unknown instead.
    $blockers = @()
    $hvKnown  = $true
    try {
        $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
        if ($hv -and $hv.State -eq 'Enabled') { $blockers += 'Hyper-V' }
    } catch {
        $hvKnown = $false
    }
    $dg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' `
        -Name EnableVirtualizationBasedSecurity -ErrorAction SilentlyContinue
    if ($dg -and $dg.EnableVirtualizationBasedSecurity -eq 1) { $blockers += 'Credential Guard/VBS' }

    $results += if (-not $hvKnown -and $blockers.Count -eq 0) {
        New-CheckResult -Name 'Hypervisor conflict' -Status Warn `
            -Message 'Could not query Hyper-V (needs elevation)' `
            -Fix 'Re-run elevated to check this properly.'
    } elseif ($blockers.Count -eq 0) {
        New-CheckResult -Name 'Hypervisor conflict' -Status Pass -Message 'Nothing competing for VT-x'
    } else {
        New-CheckResult -Name 'Hypervisor conflict' -Status Warn `
            -Message "$($blockers -join ' and ') enabled - VirtualBox may be slow or fail" `
            -Fix 'bcdedit /set hypervisorlaunchtype off; Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart; then reboot.'
    }

    # --- VirtualBox ---------------------------------------------------------
    $vbox = Get-VBoxManagePath
    $results += if ($vbox) {
        $v = (& $vbox --version 2>$null) -join ''
        New-CheckResult -Name 'VirtualBox' -Status Pass -Message "$v ($vbox)"
    } else {
        New-CheckResult -Name 'VirtualBox' -Status Fail -Message 'VBoxManage.exe not found' `
            -Fix 'winget install Oracle.VirtualBox   (or https://www.virtualbox.org/)'
    }

    # --- Vagrant ------------------------------------------------------------
    $vagrant = Get-Command vagrant -ErrorAction SilentlyContinue
    $results += if ($vagrant) {
        New-CheckResult -Name 'Vagrant' -Status Pass -Message ((& vagrant --version 2>$null) -join '')
    } else {
        New-CheckResult -Name 'Vagrant' -Status Fail -Message 'vagrant not found on PATH' `
            -Fix 'winget install HashiCorp.Vagrant   (then open a NEW terminal)'
    }

    # --- Vagrant plugins ----------------------------------------------------
    # NOTE: do NOT check for 'vagrant-winrm'. The WinRM communicator has been
    # built into Vagrant since 1.6; the standalone plugin is long obsolete, and
    # requiring it produced a false failure that blocked an otherwise ready host.
    # vagrant-windows-sysprep is a genuine third-party plugin and IS required:
    # without it every VM clones with the same SID and domain joins collide.
    if ($vagrant) {
        $plugins = (& vagrant plugin list 2>$null) -join "`n"
        foreach ($p in @('vagrant-windows-sysprep')) {
            $results += if ($plugins -match [regex]::Escape($p)) {
                New-CheckResult -Name "Plugin $p" -Status Pass -Message 'Installed'
            } else {
                New-CheckResult -Name "Plugin $p" -Status Fail -Message 'Missing' `
                    -Fix "vagrant plugin install $p"
            }
        }
    }

    # --- Base box -----------------------------------------------------------
    if ($vagrant) {
        $cfg     = $Plan.Config
        $boxName = $cfg.box.name
        $boxVer  = $cfg.box.version
        $boxes   = (& vagrant box list 2>$null) -join "`n"
        $results += if ($boxes -match ([regex]::Escape($boxName) + '\s.*' + [regex]::Escape($boxVer))) {
            New-CheckResult -Name 'Base box' -Status Pass -Message "$boxName v$boxVer cached"
        } elseif ($boxes -match [regex]::Escape($boxName)) {
            New-CheckResult -Name 'Base box' -Status Warn `
                -Message "$boxName present but not v$boxVer" `
                -Fix "v$boxVer downloads on first 'up' (~5-6 GB)."
        } else {
            New-CheckResult -Name 'Base box' -Status Warn `
                -Message "$boxName v$boxVer not cached" `
                -Fix "Downloads automatically on first 'up' (~5-6 GB). Needs a stable connection."
        }
    }

    return $results
}

function Show-LabPrereq {
    <#
    .SYNOPSIS
        Prints check results and returns $true when nothing failed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] $Results)

    Write-Host ""
    Write-Host "  Host readiness" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray

    foreach ($r in $Results) {
        $glyph, $colour = switch ($r.Status) {
            'Pass' { '[ok]  ', 'Green' }
            'Warn' { '[warn]', 'Yellow' }
            'Fail' { '[FAIL]', 'Red' }
        }
        Write-Host ("  {0} {1,-22} {2}" -f $glyph, $r.Name, $r.Message) -ForegroundColor $colour
        if ($r.Status -ne 'Pass' -and $r.Fix) {
            Write-Host ("         -> {0}" -f $r.Fix) -ForegroundColor DarkGray
        }
    }

    $fails = @($Results | Where-Object { $_.Status -eq 'Fail' })
    $warns = @($Results | Where-Object { $_.Status -eq 'Warn' })

    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
    if ($fails.Count -gt 0) {
        Write-Host "  $($fails.Count) blocking problem(s), $($warns.Count) warning(s)." -ForegroundColor Red
        Write-Host ""
        return $false
    }
    Write-Host "  All checks passed ($($warns.Count) warning(s))." -ForegroundColor Green
    Write-Host ""
    return $true
}

Export-ModuleMember -Function Test-LabPrereq, Show-LabPrereq, Get-VBoxManagePath, Get-LabStoragePath
