# plan.psm1 - profile resolution and start-order planning for the DVAD lab.
#
# Everything here is PURE: it reads inventory/lab-config.json and returns
# objects. It never calls vagrant and never touches the host. That keeps the
# plan testable on its own ("lab.ps1 plan" prints it without building anything)
# and lets the runner stay dumb.
#
# The central idea is the WAVE. Each host declares dependsOn; a topological sort
# groups the selected hosts into ordered waves where every host inside a wave is
# independent of the others. Today the runner walks a wave serially. To go
# parallel later, the ONLY change needed is how the runner iterates one wave -
# the plan already guarantees the members are safe to start together.

Set-StrictMode -Version Latest

function Get-LabPlanConfig {
    <#
    .SYNOPSIS
        Loads lab-config.json via the shared loader.
    #>
    [CmdletBinding()]
    param([string] $ConfigPath)

    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'provisioners\get-lab-config.ps1')
    if ($ConfigPath) { return Get-LabConfig -Path $ConfigPath }
    return Get-LabConfig
}

function Get-LabProfileNames {
    [CmdletBinding()]
    param($Config)
    if (-not $Config) { $Config = Get-LabPlanConfig }
    return @($Config.profiles.PSObject.Properties.Name)
}

function Resolve-LabProfile {
    <#
    .SYNOPSIS
        Turns a profile name (or an explicit host list) into validated host keys.
    .PARAMETER Name
        Profile name from lab-config.json (core / adcs / full).
    .PARAMETER Only
        Explicit host keys or VM names, overriding the profile. Lets you do
        granular work like "lab.ps1 up -Only CA01" without a profile.
    #>
    [CmdletBinding()]
    param(
        [string]   $Name,
        [string[]] $Only,
        $Config
    )

    if (-not $Config) { $Config = Get-LabPlanConfig }

    $allKeys = @($Config.hosts.PSObject.Properties.Name)

    # Explicit -Only wins over the profile. Accept either the config key
    # ("adcs") or the VM name ("CA01"), case-insensitively.
    if ($Only -and $Only.Count -gt 0) {
        $resolved = @()
        foreach ($token in $Only) {
            $match = $allKeys | Where-Object {
                $_ -eq $token -or $Config.hosts.$_.name -eq $token
            } | Select-Object -First 1
            if (-not $match) {
                $known = ($allKeys | ForEach-Object { "$_ ($($Config.hosts.$_.name))" }) -join ', '
                throw "Unknown host '$token'. Known hosts: $known"
            }
            if ($resolved -notcontains $match) { $resolved += $match }
        }
        # Plain return: callers wrap in @(), which restores a single-element
        # result. A comma-wrap here would nest the array one level too deep.
        return $resolved
    }

    if (-not $Name) { $Name = $Config.defaultProfile }

    $profileNames = Get-LabProfileNames -Config $Config
    $hit = $profileNames | Where-Object { $_ -eq $Name } | Select-Object -First 1
    if (-not $hit) {
        throw "Unknown profile '$Name'. Available: $($profileNames -join ', ')"
    }

    return @($Config.profiles.$hit.hosts)
}

function Get-LabWave {
    <#
    .SYNOPSIS
        Topologically sorts host keys into ordered waves.
    .DESCRIPTION
        Returns an array of arrays. Wave 0 has no unmet dependencies; wave N
        depends only on waves < N. Hosts within a single wave are mutually
        independent and therefore safe to start concurrently.

        Dependencies on hosts OUTSIDE the selection are ignored on purpose: if
        you deploy the 'core' profile, SRV01 still lists dependsOn=[rootdc]
        which IS selected, but a host depending on an unselected optional peer
        must not deadlock the plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $HostKeys,
        $Config
    )

    if (-not $Config) { $Config = Get-LabPlanConfig }

    $selected = @($HostKeys)
    $pending  = @{}
    foreach ($k in $selected) {
        # Only keep edges that point at another SELECTED host.
        $deps = @()
        $declared = $Config.hosts.$k.dependsOn
        if ($declared) {
            foreach ($d in $declared) { if ($selected -contains $d) { $deps += $d } }
        }
        $pending[$k] = $deps
    }

    $waves = @()
    $done  = @()

    while ($pending.Count -gt 0) {
        # Ready = every declared dependency already satisfied by an earlier wave.
        $ready = @()
        foreach ($k in @($pending.Keys)) {
            $unmet = @($pending[$k] | Where-Object { $done -notcontains $_ })
            if ($unmet.Count -eq 0) { $ready += $k }
        }

        if ($ready.Count -eq 0) {
            throw "Circular dependency in lab-config.json among: $($pending.Keys -join ', ')"
        }

        # Stable order inside a wave: cheapest (least RAM) first, so a serial
        # run gets the quick wins up before the heavyweight box.
        $ready = @($ready | Sort-Object { $Config.hosts.$_.memory }, { $_ })

        $waves += ,$ready
        foreach ($k in $ready) { $done += $k; $pending.Remove($k) }
    }

    return ,$waves
}

function New-LabPlan {
    <#
    .SYNOPSIS
        Builds the full deployment plan for a profile or explicit host list.
    .DESCRIPTION
        The single object every other part of the tooling consumes. Contains the
        resolved hosts, the wave graph, and the resource footprint.
    #>
    [CmdletBinding()]
    param(
        [Alias('Profile')]
        [string]   $ProfileName,
        [string[]] $Only,
        $Config
    )

    if (-not $Config) { $Config = Get-LabPlanConfig }

    $keys  = @(Resolve-LabProfile -Name $ProfileName -Only $Only -Config $Config)
    $waves = Get-LabWave -HostKeys $keys -Config $Config

    $notBuilt = @($keys | Where-Object {
        $h = $Config.hosts.$_
        ($h.PSObject.Properties.Name -contains 'built') -and (-not $h.built)
    })

    # Dependencies the caller did NOT select. Legitimate when that VM is already
    # running from an earlier build, but a silent domain-join failure otherwise -
    # so surface it rather than letting the build discover it 20 minutes in.
    $missingDeps = @()
    foreach ($k in $keys) {
        foreach ($d in @($Config.hosts.$k.dependsOn)) {
            if ($d -and $keys -notcontains $d -and $missingDeps -notcontains $d) {
                $missingDeps += $d
            }
        }
    }

    $ramMB = ($keys | ForEach-Object { $Config.hosts.$_.memory } | Measure-Object -Sum).Sum
    $cpus  = ($keys | ForEach-Object { $Config.hosts.$_.cpus }   | Measure-Object -Sum).Sum

    # Build time is driven by WHICH VMs are built, not how many waves there are:
    # CM01 alone (SQL + ADK + MECM) costs more than the rest of the lab combined.
    # Serial walks a wave one VM at a time, so a wave costs the sum; in parallel
    # it costs the slowest member.
    $serialMin = 0; $parallelMin = 0
    foreach ($wave in $waves) {
        $mins = @($wave | ForEach-Object {
            $m = $Config.hosts.$_.buildMinutes
            if ($m) { $m } else { 20 }   # fallback for a host with no estimate
        })
        $serialMin   += ($mins | Measure-Object -Sum).Sum
        $parallelMin += ($mins | Measure-Object -Maximum).Maximum
    }

    $diskGB = 60
    if (-not $Only -and $ProfileName -and $Config.profiles.PSObject.Properties.Name -contains $ProfileName) {
        $diskGB = $Config.profiles.$ProfileName.diskGB
    } elseif (-not $Only -and -not $ProfileName) {
        $diskGB = $Config.profiles.($Config.defaultProfile).diskGB
    }

    $resolvedName = $(if ($Only) { 'custom' } elseif ($ProfileName) { $ProfileName } else { $Config.defaultProfile })

    # Which profile's payload set covers this selection. For a named profile
    # that is itself; for a custom -Only selection, the NARROWEST profile whose
    # hosts are a superset of the selection, so "-Only CM01" still stages the
    # SCCM payloads while "-Only rootdc" does not.
    $depProfile = $resolvedName
    if ($resolvedName -eq 'custom') {
        $depProfile = $null
        $ordered = @($Config.profiles.PSObject.Properties |
            Sort-Object { @($_.Value.hosts).Count })
        foreach ($p in $ordered) {
            $covers = $true
            foreach ($k in $keys) { if ($p.Value.hosts -notcontains $k) { $covers = $false; break } }
            if ($covers) { $depProfile = $p.Name; break }
        }
        # Selection spans hosts no single profile covers (e.g. a stub VM): take
        # the widest profile so nothing needed is skipped.
        if (-not $depProfile -and $ordered.Count -gt 0) { $depProfile = $ordered[-1].Name }
    }

    return [PSCustomObject]@{
        ProfileName = $resolvedName
        DepProfile  = $depProfile
        HostKeys    = $keys
        VmNames     = @($keys | ForEach-Object { $Config.hosts.$_.name })
        Waves       = $waves
        WaveVmNames = @($waves | ForEach-Object { ,@($_ | ForEach-Object { $Config.hosts.$_.name }) })
        TotalRamMB  = $ramMB
        TotalCpus   = $cpus
        DiskGB      = $diskGB
        SerialMin   = $serialMin
        ParallelMin = $parallelMin
        NotBuilt    = $notBuilt
        MissingDeps = $missingDeps
        Config      = $Config
    }
}

function Show-LabPlan {
    <#
    .SYNOPSIS
        Prints a deployment plan in human-readable form.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan)

    $cfg = $Plan.Config

    Write-Host ""
    Write-Host "  Deployment plan: $($Plan.ProfileName)" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Plan.Waves.Count; $i++) {
        $members = $Plan.Waves[$i]
        $tag = if ($members.Count -gt 1) { "(independent - parallelizable)" } else { "" }
        Write-Host ("  Wave {0}  {1}" -f ($i + 1), $tag) -ForegroundColor Yellow
        foreach ($k in $members) {
            $h = $cfg.hosts.$k
            Write-Host ("    {0,-9} {1,-14} {2,5} MB  {3} vCPU   {4}" -f `
                $h.name, $h.ip, $h.memory, $h.cpus, $h.role)
        }
    }

    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Total: {0} VMs, {1:N1} GB RAM, {2} vCPU, ~{3} GB disk" -f `
        @($Plan.HostKeys).Count, ($Plan.TotalRamMB / 1024), $Plan.TotalCpus, $Plan.DiskGB)

    $estimate = if ($Plan.ParallelMin -lt $Plan.SerialMin) {
        "~{0} min serial, ~{1} min with -Parallel" -f $Plan.SerialMin, $Plan.ParallelMin
    } else {
        "~{0} min" -f $Plan.SerialMin
    }
    Write-Host "  Rough build time on an SSD: $estimate" -ForegroundColor DarkGray

    if (@($Plan.NotBuilt).Count -gt 0) {
        $names = ($Plan.NotBuilt | ForEach-Object { $cfg.hosts.$_.name }) -join ', '
        Write-Host "  [!] Not implemented in the Vagrantfile yet: $names" -ForegroundColor Yellow
    }

    if (@($Plan.MissingDeps).Count -gt 0) {
        $names = ($Plan.MissingDeps | ForEach-Object { $cfg.hosts.$_.name }) -join ', '
        Write-Host "  [!] Depends on VMs not in this selection: $names" -ForegroundColor Yellow
        Write-Host "      Domain join will fail unless they are already running." -ForegroundColor DarkGray
    }
    Write-Host ""
}

Export-ModuleMember -Function `
    Get-LabPlanConfig, Get-LabProfileNames, Resolve-LabProfile, `
    Get-LabWave, New-LabPlan, Show-LabPlan
