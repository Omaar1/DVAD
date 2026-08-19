<#
.SYNOPSIS
    DVAD lab control. One entry point for planning, checking, building,
    snapshotting and tearing down the lab.

.DESCRIPTION
    Replaces the old setup-lab.ps1 + start-lab.ps1 pair, which overlapped,
    disagreed about requirements, and each told you to run the other.

    Everything is profile-driven. A profile selects which VMs get built, and
    every threshold (RAM, disk, which payloads to download) derives from that
    profile instead of being hardcoded for the largest possible lab.

.PARAMETER Verb
    plan      Show what would be built. No side effects.
    profiles  List the available profiles.
    check     Host readiness only.
    deps      Stage the payload cache only.
    up        Check, stage, then build. The main command.
    status    Current VM states.
    halt      Gracefully stop the profile's VMs.
    destroy   Delete the profile's VMs.
    snapshot  Take a VirtualBox snapshot of the profile's VMs.
    restore   Roll the profile's VMs back to a snapshot.
    verify    Run the post-build health check.

.PARAMETER Profile
    core  DC + member server. Chains 1-8.            ~4 GB RAM
    adcs  core + Enterprise CA. + ESC1-8.            ~6 GB RAM
    full  adcs + MECM/SQL. + CRED-1..4.             ~14 GB RAM

.PARAMETER Only
    Explicit VM names or config keys, overriding the profile.
    Accepts either form: -Only CA01  /  -Only adcs

.PARAMETER Parallel
    Start independent VMs in a wave concurrently. Experimental: faster, but
    heavier on host RAM and the logs interleave.

.EXAMPLE
    .\lab.ps1 up
    Build the default profile (core) after checking the host.

.EXAMPLE
    .\lab.ps1 up -Profile full -Parallel
    Build everything, starting each wave's VMs concurrently.

.EXAMPLE
    .\lab.ps1 plan -Profile adcs
    Show the wave order and footprint without touching anything.

.EXAMPLE
    .\lab.ps1 snapshot -Name clean-build
    Snapshot a freshly built lab so a botched attack costs seconds to undo.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'profiles', 'check', 'deps', 'up', 'status',
                 'halt', 'destroy', 'snapshot', 'restore', 'verify', 'help')]
    [string] $Verb = 'help',

    # Named LabProfile internally because $Profile is a PowerShell automatic
    # variable; the alias keeps the natural "-Profile core" on the command line.
    [Alias('Profile')]
    [string]   $LabProfile,
    [string[]] $Only,
    [switch]   $Parallel,
    # Where things live. Nothing is assumed about your drive layout: with none of
    # these set, the tool uses whatever Vagrant and VirtualBox are already
    # configured to use on this machine.
    #   -StorageDrive D:   both VM disks and box cache on D:
    #   -VmPath  <dir>     move only the VM disks (the tens-of-GB consumer)
    #   -BoxPath <dir>     move only the box cache (VAGRANT_HOME)
    [string]   $StorageDrive,
    [string]   $VmPath,
    [string]   $BoxPath,
    [string]   $Name = 'clean-build',
    [switch]   $SkipChecks,
    [switch]   $SkipDeps,
    [switch]   $Force,
    # deps only: record each fetched payload's SHA256 into inventory/lab-deps.json
    # so later fetches are verified. Hashes ship unpinned because they cannot be
    # asserted without downloading the file once.
    [switch]   $Pin,
    [switch]   $Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$labRoot = $PSScriptRoot
Import-Module (Join-Path $labRoot 'tools\lab\plan.psm1')   -Force
Import-Module (Join-Path $labRoot 'tools\lab\prereq.psm1') -Force
Import-Module (Join-Path $labRoot 'tools\lab\deps.psm1')   -Force
Import-Module (Join-Path $labRoot 'tools\lab\runner.psm1') -Force

function Write-Banner {
    param([string] $Subtitle)
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Magenta
    Write-Host "   DVAD - Damn Vulnerable Active Directory" -ForegroundColor Magenta
    if ($Subtitle) { Write-Host "   $Subtitle" -ForegroundColor DarkGray }
    Write-Host "  ============================================================" -ForegroundColor Magenta
}

function Confirm-Action {
    param([string] $Message)
    if ($Yes) { return $true }
    $answer = Read-Host "  $Message [y/N]"
    return ($answer -eq 'y' -or $answer -eq 'Y')
}

function Set-LabStorage {
    <#
        Point the VirtualBox machine folder and/or VAGRANT_HOME at the chosen
        locations. A no-op unless one of the three options is given, so by
        default the tool leaves the host's existing configuration untouched.
    #>
    param([string] $Drive, [string] $VmDir, [string] $BoxDir)
    if (-not ($Drive -or $VmDir -or $BoxDir)) { return }

    $storage = Get-LabStoragePath -StorageDrive $Drive -VmPath $VmDir -BoxPath $BoxDir

    # Only touch VAGRANT_HOME if it is actually changing. Repointing it orphans
    # any box already downloaded under the old one, silently costing a 5-6 GB
    # re-download - which is why VM location and box cache are separate options.
    $current = if ($env:VAGRANT_HOME) { $env:VAGRANT_HOME }
               else { Join-Path $env:USERPROFILE '.vagrant.d' }

    if ($current.TrimEnd('\') -ine $storage.VagrantHome.TrimEnd('\')) {
        $oldBoxes = Join-Path $current 'boxes'
        $newBoxes = Join-Path $storage.VagrantHome 'boxes'
        $haveOld  = (Test-Path $oldBoxes) -and @(Get-ChildItem $oldBoxes -Directory -EA SilentlyContinue).Count -gt 0
        $haveNew  = (Test-Path $newBoxes) -and @(Get-ChildItem $newBoxes -Directory -EA SilentlyContinue).Count -gt 0
        if ($haveOld -and -not $haveNew) {
            Write-Host "  [!] Boxes are cached in $current but not in $($storage.VagrantHome)." -ForegroundColor Yellow
            Write-Host "      Repointing now re-downloads the base box (~5-6 GB)." -ForegroundColor Yellow
            Write-Host "      To move only the VMs and keep the cache, use -VmPath instead of -StorageDrive." -ForegroundColor DarkGray
            if (-not (Confirm-Action 'Repoint the box cache anyway?')) {
                throw 'Aborted so the existing box cache is not orphaned.'
            }
        }
        New-Item -ItemType Directory -Path $storage.VagrantHome -Force | Out-Null
        $env:VAGRANT_HOME = $storage.VagrantHome
        [Environment]::SetEnvironmentVariable('VAGRANT_HOME', $storage.VagrantHome, 'User')
        Write-Host "  Box cache : $($storage.VagrantHome)" -ForegroundColor DarkGray
    }

    New-Item -ItemType Directory -Path $storage.MachineFolder -Force | Out-Null
    $vbox = Get-VBoxManagePath
    if ($vbox) { & $vbox setproperty machinefolder $storage.MachineFolder 2>$null }
    Write-Host "  VM disks  : $($storage.MachineFolder)" -ForegroundColor DarkGray
}

# The plan every verb operates on.
$plan = $null
if ($Verb -notin @('help', 'profiles')) {
    $plan = New-LabPlan -ProfileName $LabProfile -Only $Only
}

switch ($Verb) {

    'help' {
        Write-Banner 'lab control'
        Get-Help $PSCommandPath -Detailed
    }

    'profiles' {
        $cfg = Get-LabPlanConfig
        Write-Banner 'available profiles'
        Write-Host ""
        foreach ($p in $cfg.profiles.PSObject.Properties) {
            $keys = $p.Value.hosts
            $ram  = ($keys | ForEach-Object { $cfg.hosts.$_.memory } | Measure-Object -Sum).Sum
            $mark = if ($p.Name -eq $cfg.defaultProfile) { ' (default)' } else { '' }
            Write-Host ("  {0,-6}{1}" -f $p.Name, $mark) -ForegroundColor Cyan
            Write-Host ("     {0}" -f $p.Value.description)
            Write-Host ("     {0} VMs: {1}" -f $keys.Count, (($keys | ForEach-Object { $cfg.hosts.$_.name }) -join ', ')) -ForegroundColor DarkGray
            Write-Host ("     {0:N1} GB RAM, ~{1} GB disk" -f ($ram / 1024), $p.Value.diskGB) -ForegroundColor DarkGray
            Write-Host ""
        }
        Write-Host "  Build one with:  .\lab.ps1 up -Profile <name>" -ForegroundColor DarkGray
        Write-Host ""
    }

    'plan' {
        Write-Banner 'deployment plan'
        Show-LabPlan -Plan $plan
        $states = Get-LabDeps -ProfileName $plan.DepProfile | ForEach-Object { Test-LabDep -Dep $_ }
        if ($states) { $null = Show-LabDeps -States $states }
    }

    'check' {
        Write-Banner "host readiness for profile '$($plan.ProfileName)'"
        Show-LabPlan -Plan $plan
        $results = Test-LabPrereq -Plan $plan -StorageDrive $StorageDrive -VmPath $VmPath -BoxPath $BoxPath
        if (-not (Show-LabPrereq -Results $results)) { exit 1 }
    }

    'deps' {
        Write-Banner "payload cache for profile '$($plan.ProfileName)'"
        $null = Invoke-LabDepsFetch -ProfileName $plan.DepProfile -Force:$Force -Pin:$Pin
    }

    'up' {
        Write-Banner "building profile '$($plan.ProfileName)'"
        Show-LabPlan -Plan $plan

        if (@($plan.NotBuilt).Count -gt 0) {
            $names = ($plan.NotBuilt | ForEach-Object { $plan.Config.hosts.$_.name }) -join ', '
            Write-Host "  [!] $names are not implemented in the Vagrantfile yet and will be skipped." -ForegroundColor Yellow
        }

        Set-LabStorage -Drive $StorageDrive -VmDir $VmPath -BoxDir $BoxPath

        if (-not $SkipChecks) {
            $results = Test-LabPrereq -Plan $plan -StorageDrive $StorageDrive -VmPath $VmPath -BoxPath $BoxPath
            if (-not (Show-LabPrereq -Results $results)) {
                Write-Host "  Fix the failures above, or re-run with -SkipChecks to override." -ForegroundColor Red
                exit 1
            }
        }

        if (-not $SkipDeps) {
            $null = Invoke-LabDepsFetch -ProfileName $plan.DepProfile
        }

        $mins = if ($Parallel) { $plan.ParallelMin } else { $plan.SerialMin }
        Write-Host "  This will build $(@($plan.HostKeys).Count) VM(s), roughly $mins minutes on an SSD." -ForegroundColor DarkGray
        if (-not (Confirm-Action 'Start the build?')) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            exit 0
        }

        $log = Join-Path $labRoot 'lab-build.log'
        Write-Host "  Log: $log" -ForegroundColor DarkGray

        $outcome = Start-LabDeploy -Plan $plan -Parallel:$Parallel -LogPath $log

        Write-Host ""
        if ($outcome.Success) {
            Write-Host "  ============================================================" -ForegroundColor Green
            Write-Host ("   Lab built in {0:hh\:mm\:ss}" -f $outcome.Duration) -ForegroundColor Green
            Write-Host "  ============================================================" -ForegroundColor Green
            foreach ($k in $plan.HostKeys) {
                $h = $plan.Config.hosts.$k
                Write-Host ("   {0,-9} {1}" -f $h.name, $h.ip)
            }
            Write-Host ""
            Write-Host "   Next:  .\lab.ps1 verify" -ForegroundColor Cyan
            Write-Host "          .\lab.ps1 snapshot     (so you can undo your attacks)" -ForegroundColor Cyan
            Write-Host ""
        } else {
            exit 1
        }
    }

    'status' {
        Write-Banner "status for profile '$($plan.ProfileName)'"
        Write-Host ""
        foreach ($s in (Get-LabVmState -Plan $plan)) {
            $colour = switch ($s.State) {
                'running'     { 'Green' }
                'stopped'     { 'Yellow' }
                default       { 'DarkGray' }
            }
            Write-Host ("  {0,-9} {1}" -f $s.Name, $s.State) -ForegroundColor $colour
        }
        Write-Host ""
    }

    'halt' {
        Write-Banner "stopping profile '$($plan.ProfileName)'"
        foreach ($vm in $plan.VmNames) {
            Write-Host "  halting $vm ..." -ForegroundColor Yellow
            $null = Invoke-LabVagrant -ArgumentList @('halt', $vm)
        }
    }

    'destroy' {
        Write-Banner "destroying profile '$($plan.ProfileName)'"
        Write-Host "  This deletes: $($plan.VmNames -join ', ')" -ForegroundColor Red
        Write-Host "  The payload cache under cache/ is kept." -ForegroundColor DarkGray
        if (-not (Confirm-Action 'Destroy these VMs?')) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            exit 0
        }
        foreach ($vm in $plan.VmNames) {
            Write-Host "  destroying $vm ..." -ForegroundColor Yellow
            $null = Invoke-LabVagrant -ArgumentList @('destroy', '-f', $vm)
        }
    }

    'snapshot' {
        Write-Banner "snapshot '$Name' for profile '$($plan.ProfileName)'"
        Write-Host ""
        $null = Invoke-LabSnapshot -Plan $plan -Name $Name
        Write-Host ""
    }

    'restore' {
        Write-Banner "restore '$Name' for profile '$($plan.ProfileName)'"
        Write-Host "  This discards all changes made since the snapshot." -ForegroundColor Yellow
        if (-not (Confirm-Action "Restore $($plan.VmNames -join ', ') to '$Name'?")) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
        $null = Restore-LabSnapshot -Plan $plan -Name $Name
        Write-Host ""
    }

    'verify' {
        Write-Banner 'health check'
        # Forward the selection so a core lab is not checked against four VMs.
        $verifyArgs = @{}
        if ($Only)       { $verifyArgs['Only'] = $Only }
        elseif ($LabProfile) { $verifyArgs['LabProfile'] = $LabProfile }
        & (Join-Path $labRoot 'verify-lab.ps1') @verifyArgs
    }
}
