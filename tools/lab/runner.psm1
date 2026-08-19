# runner.psm1 - executes a deployment plan against Vagrant / VirtualBox.
#
# The runner is deliberately thin: plan.psm1 decides WHAT to start and in what
# order, this file only carries it out. That separation is what makes parallel
# start a small change rather than a rewrite.
#
# PARALLEL START
# --------------
# Invoke-LabWave is the single seam. A wave is a set of VMs the planner has
# already proven independent, so the only question is how to iterate it:
#
#   serial   (default) - one vagrant up at a time. Predictable, readable logs.
#   parallel (-Parallel) - one background job per VM in the wave.
#
# Parallel is opt-in because concurrent `vagrant up` against the VirtualBox
# provider can contend on VBoxManage and on host RAM. The plan already
# guarantees correctness; the switch only trades resource pressure for time.

Set-StrictMode -Version Latest

function Invoke-LabVagrant {
    <#
    .SYNOPSIS
        Runs a vagrant command in the repo root and returns its exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [string] $LogPath
    )

    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Push-Location $root
    try {
        # Out-Host is essential: a PowerShell function returns EVERYTHING left on
        # the pipeline, so without it vagrant's output is concatenated with the
        # exit code and callers receive a giant string instead of an integer.
        if ($LogPath) {
            & vagrant @ArgumentList 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Host
        } else {
            & vagrant @ArgumentList 2>&1 | Out-Host
        }
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Invoke-LabWave {
    <#
    .SYNOPSIS
        Brings up every VM in one wave.
    .DESCRIPTION
        THE PARALLEL SEAM. Members of a wave are independent by construction
        (see plan.psm1), so both branches below are equally correct; they differ
        only in resource pressure and log readability.
    .OUTPUTS
        One result object per VM: Name, ExitCode, Duration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $VmNames,
        [switch] $Parallel,
        [string] $LogPath
    )

    $results = @()

    if ($Parallel -and $VmNames.Count -gt 1) {
        Write-Host "    starting $($VmNames.Count) VMs in parallel: $($VmNames -join ', ')" -ForegroundColor Yellow
        Write-Host "    (parallel start is experimental; logs interleave)" -ForegroundColor DarkGray

        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $jobs = @()
        foreach ($vm in $VmNames) {
            # Each VM gets its OWN log file. Interleaving concurrent builds into a
            # single log makes it unreadable, and appending from several jobs at
            # once races on the file handle.
            $vmLog = if ($LogPath) {
                Join-Path (Split-Path -Parent $LogPath) `
                    ("{0}-{1}.log" -f [IO.Path]::GetFileNameWithoutExtension($LogPath), $vm)
            } else { $null }

            $jobs += Start-Job -Name "lab-up-$vm" -ScriptBlock {
                param($repoRoot, $name, $log)
                Set-Location $repoRoot
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                if ($log) { & vagrant up $name 2>&1 | Out-File -FilePath $log -Encoding UTF8 }
                else      { & vagrant up $name 2>&1 | Out-Null }
                $code = $LASTEXITCODE
                $sw.Stop()
                # Sole object on the job's output stream, so the parent never has
                # to sift vagrant's console noise out of the result.
                [PSCustomObject]@{ Name = $name; ExitCode = $code; Seconds = $sw.Elapsed.TotalSeconds }
            } -ArgumentList $root, $vm, $vmLog

            if ($vmLog) { Write-Host "      $vm -> $vmLog" -ForegroundColor DarkGray }
        }

        $null = Wait-Job -Job $jobs
        foreach ($j in $jobs) {
            $name    = $j.Name -replace '^lab-up-', ''
            $payload = Receive-Job -Job $j |
                       Where-Object { $_.PSObject.Properties.Name -contains 'ExitCode' } |
                       Select-Object -Last 1

            $results += if ($payload) {
                [PSCustomObject]@{
                    Name     = $payload.Name
                    ExitCode = $payload.ExitCode
                    Duration = [TimeSpan]::FromSeconds($payload.Seconds)
                }
            } else {
                # Job died without reporting: treat as failure rather than success.
                [PSCustomObject]@{ Name = $name; ExitCode = 1; Duration = [TimeSpan]::Zero }
            }
            Remove-Job -Job $j -Force
        }
    }
    else {
        foreach ($vm in $VmNames) {
            Write-Host "    starting $vm ..." -ForegroundColor Yellow
            $sw   = [System.Diagnostics.Stopwatch]::StartNew()
            $code = Invoke-LabVagrant -ArgumentList @('up', $vm) -LogPath $LogPath
            $sw.Stop()
            $results += [PSCustomObject]@{ Name = $vm; ExitCode = $code; Duration = $sw.Elapsed }

            if ($code -ne 0) { break }   # fail fast inside a serial wave
        }
    }

    # Comma-wrapped so a single-VM wave still returns an array, not a bare object.
    return ,$results
}

function Start-LabDeploy {
    <#
    .SYNOPSIS
        Walks a plan wave by wave, honouring per-host settle time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [switch] $Parallel,
        [string] $LogPath
    )

    $cfg     = $Plan.Config
    $started = @()
    $swAll   = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 0; $i -lt $Plan.Waves.Count; $i++) {
        $keys    = $Plan.Waves[$i]
        $vmNames = @($keys | ForEach-Object { $cfg.hosts.$_.name })

        Write-Host ""
        Write-Host "  Wave $($i + 1) of $($Plan.Waves.Count): $($vmNames -join ', ')" -ForegroundColor Cyan

        $waveResults = Invoke-LabWave -VmNames $vmNames -Parallel:$Parallel -LogPath $LogPath
        $started += $waveResults

        $failed = @($waveResults | Where-Object { $_.ExitCode -ne 0 })
        if ($failed.Count -gt 0) {
            foreach ($f in $failed) {
                Write-Host "  [FAIL] $($f.Name) exited $($f.ExitCode)" -ForegroundColor Red
            }
            Write-Host ""
            Write-Host "  Deployment stopped in wave $($i + 1)." -ForegroundColor Red
            if ($LogPath) { Write-Host "  Log: $LogPath" -ForegroundColor DarkGray }
            Write-Host "  Fix the cause, then re-run: the payload cache and completed VMs are kept." -ForegroundColor DarkGray
            return [PSCustomObject]@{ Success = $false; Results = $started; Duration = $swAll.Elapsed }
        }

        foreach ($r in $waveResults) {
            Write-Host ("    [ok] {0} up in {1:mm\:ss}" -f $r.Name, $r.Duration) -ForegroundColor Green
        }

        # Settle before the next wave: the DC in particular needs AD services to
        # answer before dependants try to join. Skip after the final wave.
        if ($i -lt ($Plan.Waves.Count - 1)) {
            $settle = ($keys | ForEach-Object { $cfg.hosts.$_.settleSeconds } | Measure-Object -Maximum).Maximum
            if ($settle -gt 0) {
                Write-Host "    settling ${settle}s before the next wave..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $settle
            }
        }
    }

    $swAll.Stop()
    return [PSCustomObject]@{ Success = $true; Results = $started; Duration = $swAll.Elapsed }
}

function Get-LabVmState {
    <#
    .SYNOPSIS
        Maps VM name -> VirtualBox state for the VMs in a plan.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan, [string] $VBoxManage)

    if (-not $VBoxManage) {
        Import-Module (Join-Path $PSScriptRoot 'prereq.psm1') -Force
        $VBoxManage = Get-VBoxManagePath
    }

    $running = @()
    $known   = @()
    if ($VBoxManage -and (Test-Path $VBoxManage)) {
        $running = & $VBoxManage list runningvms 2>$null
        $known   = & $VBoxManage list vms 2>$null
    }

    foreach ($name in $Plan.VmNames) {
        $state = 'not created'
        if ($known   -match "`"$name`"") { $state = 'stopped' }
        if ($running -match "`"$name`"") { $state = 'running' }
        [PSCustomObject]@{ Name = $name; State = $state }
    }
}

function Invoke-LabSnapshot {
    <#
    .SYNOPSIS
        Takes a named VirtualBox snapshot of every VM in the plan.
    .DESCRIPTION
        The point of a practice lab is breaking it. Snapshot once after a clean
        build and a botched attack costs seconds to undo instead of a rebuild.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [string] $Name = 'clean-build'
    )

    Import-Module (Join-Path $PSScriptRoot 'prereq.psm1') -Force
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage not found.' }

    $ok = 0
    foreach ($vm in $Plan.VmNames) {
        Write-Host "    snapshotting $vm ..." -ForegroundColor Yellow
        & $vbox snapshot $vm take $Name --pause 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "      [ok] $vm -> '$Name'" -ForegroundColor Green
            $ok++
        } else {
            Write-Host "      [FAIL] $vm (is it created?)" -ForegroundColor Red
        }
    }
    Write-Host "  Snapshot '$Name' taken on $ok/$($Plan.VmNames.Count) VM(s)." -ForegroundColor Cyan
    return $ok
}

function Restore-LabSnapshot {
    <#
    .SYNOPSIS
        Restores every VM in the plan to a named snapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [string] $Name = 'clean-build'
    )

    Import-Module (Join-Path $PSScriptRoot 'prereq.psm1') -Force
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage not found.' }

    $ok = 0
    foreach ($vm in $Plan.VmNames) {
        Write-Host "    restoring $vm ..." -ForegroundColor Yellow
        & $vbox controlvm $vm poweroff 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & $vbox snapshot $vm restore $Name 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "      [ok] $vm restored to '$Name'" -ForegroundColor Green
            $ok++
        } else {
            Write-Host "      [FAIL] $vm has no snapshot '$Name'" -ForegroundColor Red
        }
    }
    Write-Host "  Restored $ok/$($Plan.VmNames.Count) VM(s). Start them with: lab.ps1 up" -ForegroundColor Cyan
    return $ok
}

Export-ModuleMember -Function `
    Invoke-LabVagrant, Invoke-LabWave, Start-LabDeploy, `
    Get-LabVmState, Invoke-LabSnapshot, Restore-LabSnapshot
